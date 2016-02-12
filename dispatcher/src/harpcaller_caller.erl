%%%---------------------------------------------------------------------------
%%% @doc
%%%   Remote procedure calling process.
%%%   Process running this module calls remote procedure, receives whatever it
%%%   returns (both end result and streamed response), and records it in
%%%   {@link harp_sdb}.
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller_caller).

-behaviour(gen_server).

%% public interface
-export([call/3, call/4, locate/1]).
-export([cancel/1, get_result/1, follow_stream/1, get_call_info/1]).
-export([job_id/1]).

%% supervision tree API
-export([start/4, start_link/4]).

%% gen_server callbacks
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2]).
-export([code_change/3]).

%%%---------------------------------------------------------------------------
%%% type specification/documentation {{{

-define(LOG_CAT, caller).

%% I should probably keep `max_exec_time' and `timeout' as microseconds to
%% avoid multiplication and division, but `timeout()' type is usually
%% milliseconds (e.g. in `receive .. end'), so let's leave it this way
-record(state, {
  job_id       :: harpcaller:job_id(),
  stream_table :: harp_sdb:handle(),
  call         :: harp:handle() | {queued, reference()},
  request      :: {harp:procedure(), [harp:argument()], harpcaller:hostname()},
  followers    :: ets:tab(),
  count = 0    :: non_neg_integer(),
  start_time   :: erlang:timestamp(),
  last_read    :: erlang:timestamp(),
  max_exec_time :: timeout(), % ms
  timeout      :: timeout()   % ms
}).

-include("harpcaller_caller.hrl").

-define(RPC_READ_INTERVAL, 100).

-type call_option() ::
    {timeout, timeout()}
  | {max_exec_time, timeout()}
  | {queue, harpcaller_call_queue:queue_name() |
              {harpcaller_call_queue:queue_name(),
                Concurrency :: pos_integer()}}.

-record(ssl_verify, {
  job_id :: harpcaller:job_id(), % for logging
  ca_path_valid = true :: boolean(),
  expected_hostname = any :: binary() | any
}).

% }}}
%%%---------------------------------------------------------------------------

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Spawn a (supervised) caller process to call remote procedure.

-spec call(harp:procedure(), [harp:argument()], harpcaller:hostname()) ->
  {ok, pid(), harpcaller:job_id()} | {error, term()}.

call(Procedure, Args, Host) ->
  call(Procedure, Args, Host, []).

%% @doc Spawn a (supervised) caller process to call remote procedure.

-spec call(harp:procedure(), [harp:argument()], harpcaller:hostname(),
           [call_option()]) ->
  {ok, pid(), harpcaller:job_id()} | {error, term()}.

call(Procedure, Args, Host, Options) when is_list(Host) ->
  call(Procedure, Args, list_to_binary(Host), Options);
call(Procedure, Args, Host, Options) when is_list(Options) ->
  harpcaller_caller_sup:spawn_caller(Procedure, Args, Host, Options).

%% @doc Locate the process that carries out specified job ID.

-spec locate(harpcaller:job_id()) ->
  {ok, pid()} | none.

locate(JobID) when is_list(JobID) ->
  case ets:lookup(?ETS_REGISTRY_TABLE, JobID) of
    [{JobID, Pid}] -> {ok, Pid};
    [] -> none
  end.

%% @doc Determine job ID of a process.
%%
%%   This function is for inspection purposes. The process should be {@link
%%   harpcaller_caller}, otherwise the call may fail in any unexpected way.
%%   You should probably also catch `gen_server:call/2' dying, in case `Pid'
%%   has just terminated.

-spec job_id(pid()) ->
  harpcaller:job_id().

job_id(Pid) when is_pid(Pid) ->
  gen_server:call(Pid, job_id).

%% @doc Send a request to caller process responsible for a job.

-spec request(harpcaller:job_id(), term()) ->
  term() | undefined.

request(JobID, Request) when is_list(JobID) ->
  case ets:lookup(?ETS_REGISTRY_TABLE, JobID) of
    [{JobID, Pid}] ->
      try
        gen_server:call(Pid, Request)
      catch
        exit:{noproc,_} -> undefined; % process has terminated earlier
        exit:{normal,_} -> undefined  % process was terminating during the call
      end;
    [] -> undefined
  end.

%% @doc Cancel remote call job.

-spec cancel(harpcaller:job_id()) ->
  ok | undefined.

cancel(JobID) ->
  request(JobID, cancel).

%% @doc Retrieve result of a job (non-blocking).

-spec get_result(harpcaller:job_id()) ->
    {return, harp:result()}
  | still_running
  | cancelled
  | missing
  | {exception, harp:error_description()}
  | {error, harp:error_description() | term()}
  | undefined.

get_result(JobID) ->
  case request(JobID, get_sdb) of
    {ok, StreamTable} ->
      harp_sdb:result(StreamTable);
    undefined ->
      case harp_sdb:load(JobID) of
        {ok, DBH} ->
          Result = harp_sdb:result(DBH),
          harp_sdb:close(DBH),
          Result;
        {error, enoent} ->
          undefined;
        {error, Reason} ->
          {error, Reason}
      end
  end.

%% @doc Follow stream of records returned by the job.
%%
%%   Caller will receive a sequence of {@type {record, harpcaller:job_id(),
%%   Id :: non_neg_integer(), harp:stream_record()@}} messages, ended with
%%   {@type {terminated, harpcaller:job_id(), cancelled | Result@}}, where
%%   `Result' has the same form and meaning as returned value of {@link
%%   harp:recv/1}.

-spec follow_stream(harpcaller:job_id()) ->
  ok | undefined.

follow_stream(JobID) ->
  request(JobID, {follow, self()}).

%% @doc Retrieve information about RPC call.
%%   `{error,_}' is returned in case of read errors. `undefined' is returned
%%   when there's no job with identifier of `JobID'.

-spec get_call_info(harpcaller:job_id()) ->
    {ok, {harp_sdb:info_call(), Host :: term(), harp_sdb:info_time()}}
  | {error, term()}
  | undefined.

get_call_info(JobID) ->
  case request(JobID, get_sdb) of
    {ok, StreamTable} ->
      harp_sdb:info(StreamTable);
    undefined ->
      case harp_sdb:load(JobID) of
        {ok, DBH} ->
          {ok, Info} = harp_sdb:info(DBH),
          harp_sdb:close(DBH),
          {ok, Info};
        {error, enoent} ->
          undefined;
        {error, Reason} ->
          {error, Reason}
      end
  end.

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start caller process.

start(Procedure, ProcArgs, Host, Options) ->
  {ok, Pid} = gen_server:start(?MODULE, [], []),
  % make the process crash on severe operational error (SDB opening error)
  {ok, JobID} =
    gen_server:call(Pid, {start_call, Procedure, ProcArgs, Host, Options}),
  {ok, Pid, JobID}.

%% @private
%% @doc Start caller process.

start_link(Procedure, ProcArgs, Host, Options) ->
  {ok, Pid} = gen_server:start_link(?MODULE, [], []),
  % make the process crash on severe operational error (SDB opening error)
  {ok, JobID} =
    gen_server:call(Pid, {start_call, Procedure, ProcArgs, Host, Options}),
  {ok, Pid, JobID}.

%%%---------------------------------------------------------------------------
%%% gen_server callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% initialization/termination {{{

%% @private
%% @doc Initialize event handler.

init([] = _Args) ->
  JobID = harpcaller:generate_job_id(),
  ets:insert(?ETS_REGISTRY_TABLE, {JobID, self()}),
  Followers = ets:new(followers, [set]),
  State = #state{
    job_id = JobID,
    followers = Followers
  },
  {ok, State}.

%% @private
%% @doc Clean up after event handler.

terminate(_Arg, _State = #state{job_id = JobID, followers = Followers,
                                stream_table = StreamTable}) ->
  ets:delete(?ETS_REGISTRY_TABLE, JobID),
  ets:delete(Followers),
  case StreamTable of
    undefined -> ok;
    _ -> harp_sdb:close(StreamTable)
  end,
  ok.

%% }}}
%%----------------------------------------------------------
%% communication {{{

%% @private
%% @doc Handle {@link gen_server:call/2}.

handle_call({start_call, Procedure, ProcArgs, Host, Options} = _Request, _From,
            State = #state{job_id = JobID, call = undefined}) ->
  {Timeout, MaxExecTime, Queue} = decode_options(Options),
  harpcaller_log:info(?LOG_CAT, "starting a new call",
                      [{job, {str, JobID}}]),
  case harp_sdb:new(JobID, Procedure, ProcArgs, Host) of
    {ok, StreamTable} ->
      FilledState = State#state{
        stream_table = StreamTable,
        request = {Procedure, ProcArgs, Host},
        max_exec_time = MaxExecTime,
        timeout = Timeout
      },
      case Queue of
        undefined ->
          % execute immediately
          harpcaller_log:info(?LOG_CAT, "starting immediately",
                              [{job, {str, JobID}}]),
          case start_request(FilledState) of
            {ok, Handle} ->
              Now = now(),
              NewState = FilledState#state{
                call = Handle,
                start_time = Now,
                last_read = Now
              },
              {reply, {ok, JobID}, NewState, 0};
            {error, Reason} ->
              harpcaller_log:warn(?LOG_CAT, "call failed",
                                  [{job, {str, JobID}},
                                  {reason, {term, Reason}}]),
              harp_sdb:set_result(StreamTable, {error, Reason}),
              % request itself failed, but the job was carried successfully;
              % tell the parent that that part got done
              {stop, {call, Reason}, {ok, JobID}, FilledState}
          end;
        {QueueName, Concurrency} ->
          % enqueue and wait for a message
          harpcaller_log:info(?LOG_CAT, "waiting for a queue",
                              [{job, {str, JobID}}, {queue, QueueName}]),
          QRef = harpcaller_call_queue:enqueue(QueueName, Concurrency),
          NewState = FilledState#state{
            call = {queued, QRef}
          },
          {reply, {ok, JobID}, NewState}
      end;
    {error, Reason} ->
      harpcaller_log:err(?LOG_CAT, "opening stream storage failed",
                         [{job, {str, JobID}}, {error, {term, Reason}}]),
      % operational and (mostly) unexpected error; signal crashing
      StopReason = {open, Reason},
      {stop, StopReason, {error, StopReason}, State}
  end;

handle_call({follow, Pid} = _Request, _From,
            State = #state{followers = Followers}) ->
  Ref = erlang:monitor(process, Pid),
  ets:insert(Followers, {Pid, Ref}),
  {reply, ok, State, 0};

handle_call(job_id = _Request, _From, State = #state{job_id = JobID}) ->
  {reply, JobID, State, 0};

handle_call(get_sdb = _Request, _From,
            State = #state{stream_table = StreamTable}) ->
  {reply, {ok, StreamTable}, State, 0};

handle_call(cancel = _Request, _From,
            State = #state{stream_table = StreamTable, job_id = JobID}) ->
  harpcaller_log:info(?LOG_CAT, "got a cancel order", [{job, {str, JobID}}]),
  notify_followers(State, {terminated, JobID, cancelled}),
  harp_sdb:set_result(StreamTable, cancelled),
  {stop, normal, ok, State};

%% unknown calls
handle_call(_Request, _From, State) ->
  {reply, {error, unknown_call}, State}.

%% @private
%% @doc Handle {@link gen_server:cast/2}.

%% unknown casts
handle_cast(_Request, State) ->
  {noreply, State}.

%% @private
%% @doc Handle incoming messages.

handle_info({'DOWN', Ref, process, Pid, _Reason} = _Message,
            State = #state{followers = Followers}) ->
  ets:delete_object(Followers, {Pid, Ref}),
  {noreply, State, 0};

handle_info({cancel, _QRef} = _Message,
            State = #state{stream_table = StreamTable, job_id = JobID}) ->
  % NOTE: the same as `cancel()' call, except it's a message
  harpcaller_log:info(?LOG_CAT, "got a cancel order", [{job, {str, JobID}}]),
  notify_followers(State, {terminated, JobID, cancelled}),
  harp_sdb:set_result(StreamTable, cancelled),
  {stop, normal, State};

handle_info({go, QRef} = _Message,
            State = #state{call = {queued, QRef}, job_id = JobID,
                           stream_table = StreamTable}) ->
  harpcaller_log:info(?LOG_CAT, "job dequeued", [{job, {str, JobID}}]),
  case start_request(State) of
    {ok, Handle} ->
      Now = now(),
      NewState = State#state{
        call = Handle,
        start_time = Now,
        last_read = Now
      },
      {noreply, NewState, 0};
    {error, Reason} ->
      harpcaller_log:warn(?LOG_CAT, "call failed",
                          [{job, {str, JobID}}, {reason, {term, Reason}}]),
      harp_sdb:set_result(StreamTable, {error, Reason}),
      % request itself failed, but the job was carried successfully;
      % tell the parent that that part got done
      {stop, {call, Reason}, State}
  end;

handle_info(timeout = _Message, State = #state{call = {queued, _QRef}}) ->
  % go back to sleep, typically after `follow_stream()' on a queued job
  {noreply, State};

handle_info(timeout = _Message,
            State = #state{call = Handle, stream_table = StreamTable,
                           job_id = JobID, count = Count}) ->
  case harp:recv(Handle, ?RPC_READ_INTERVAL) of
    timeout ->
      % NOTE: we need a monotonic clock, so `erlang:now()' is the way to go
      Now = erlang:now(),
      % timer:now_diff() returns microseconds; make it milliseconds
      ReadTime = timer:now_diff(Now, State#state.last_read)  div 1000,
      RunTime  = timer:now_diff(Now, State#state.start_time) div 1000,
      case State of
        % `ReadTime < infinity' for all integers
        #state{timeout = Timeout} when ReadTime >= Timeout ->
          TimeoutDesc = {<<"timeout">>, <<"reading result timed out">>},
          notify_followers(State, {terminated, JobID, {error, TimeoutDesc}}),
          harpcaller_log:warn(?LOG_CAT, "read timeout", [{job, {str, JobID}}]),
          ok = harp_sdb:set_result(StreamTable, {error, TimeoutDesc}),
          {stop, normal, State};
        #state{max_exec_time = MaxExecTime} when RunTime >= MaxExecTime ->
          TimeoutDesc = {<<"timeout">>, <<"maximum execution time exceeded">>},
          notify_followers(State, {terminated, JobID, {error, TimeoutDesc}}),
          harpcaller_log:warn(?LOG_CAT, "total execution time exceeded",
                              [{job, {str, JobID}}]),
          ok = harp_sdb:set_result(StreamTable, {error, TimeoutDesc}),
          {stop, normal, State};
        _ ->
          {noreply, State, 0}
      end;
    {packet, Packet} ->
      notify_followers(State, {record, JobID, Count, Packet}),
      ok = harp_sdb:insert(StreamTable, Packet),
      NewState = State#state{count = Count + 1, last_read = now()},
      {noreply, NewState, 0};
    {result, Result} ->
      notify_followers(State, {terminated, JobID, {return, Result}}),
      harpcaller_log:info(?LOG_CAT, "job finished",
                          [{job, {str, JobID}}, {reason, return}]),
      ok = harp_sdb:set_result(StreamTable, {return, Result}),
      {stop, normal, State};
    {exception, Exception} ->
      notify_followers(State, {terminated, JobID, {exception, Exception}}),
      harpcaller_log:info(?LOG_CAT, "job finished",
                          [{job, {str, JobID}}, {reason, exception}]),
      ok = harp_sdb:set_result(StreamTable, {exception, Exception}),
      {stop, normal, State};
    {error, Reason} ->
      notify_followers(State, {terminated, JobID, {error, Reason}}),
      harpcaller_log:warn(?LOG_CAT, "job finished abnormally",
                          [{job, {str, JobID}}, {reason, {term, Reason}}]),
      ok = harp_sdb:set_result(StreamTable, {error, Reason}),
      {stop, normal, State}
  end;

%% unknown messages
handle_info(_Message, State) ->
  {noreply, State}.

%% }}}
%%----------------------------------------------------------
%% code change {{{

%% @private
%% @doc Handle code change.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% }}}
%%----------------------------------------------------------

%%%---------------------------------------------------------------------------

-spec decode_options([call_option()]) ->
  {Timeout :: timeout(), MaxExecTime :: timeout(),
    Queue :: {harpcaller_call_queue:queue_name(), pos_integer()} | undefined}.

decode_options(Options) ->
  T = proplists:get_value(timeout, Options),
  {ok, TA} = application:get_env(default_timeout),
  E = proplists:get_value(max_exec_time, Options),
  {ok, EA} = application:get_env(max_exec_time),
  Queue = case proplists:get_value(queue, Options) of
    undefined ->
      undefined;
    {QueueName, Concurrency} when is_integer(Concurrency), Concurrency > 0 ->
      {QueueName, Concurrency};
    QueueName ->
      {QueueName, 1}
  end,
  Timeout = case {T, TA} of
    {undefined, _}      -> TA * 1000;
    {infinity, _}       -> T; % effect limited by `MaxExecTime' anyway
    {_, _} when T  > TA -> TA * 1000;
    {_, _} when T =< TA -> T  * 1000
  end,
  MaxExecTime = case {E, EA} of
    {undefined, _}      -> EA * 1000;
    {infinity, _}       -> EA * 1000;
    {_, _} when E  > EA -> EA * 1000;
    {_, _} when E =< EA -> E  * 1000
  end,
  {Timeout, MaxExecTime, Queue}.

notify_followers(_State = #state{followers = Followers}, Message) ->
  ets:foldl(fun send_message/2, Message, Followers),
  ok.

send_message({Pid, _Ref} = _Entry, Message) ->
  Pid ! Message,
  % `Message' is actually an accumulator, but it works well this way
  Message.

-spec start_request(#state{}) ->
  {ok, harp:handle()} | {error, term()}.

start_request(State = #state{request = {Procedure, ProcArgs, Hostname},
                             stream_table = StreamTable}) ->
  case harpcaller_hostdb:resolve(Hostname) of
    {Hostname, Address, Port, {User, Password} = _Credentials} ->
      harp_sdb:started(StreamTable),
      SSLVerifyOpts = ssl_verify_options(State),
      RequestOpts = [
        {host, Address}, {port, Port},
        {user, User}, {password, Password}
      ],
      harp:request(Procedure, ProcArgs, RequestOpts ++ SSLVerifyOpts);
    none ->
      {error, unknown_host}
  end.

ssl_verify_options(_State = #state{job_id = JobID}) ->
  CAOpts = case application:get_env(ca_file) of
    {ok, CAFile} -> [{cafile, CAFile}];
    undefined -> []
  end,
  VerifyOpts = case application:get_env(known_certs_file) of
    {ok, _KnownCertsFile} ->
      VerifyArg = #ssl_verify{job_id = JobID},
      [{ssl_verify, {fun verify_cert/3, VerifyArg}}];
    undefined ->
      % FIXME: no certificate verification logs when only `ca_file' defined
      []
  end,
  CAOpts ++ VerifyOpts.

%%%---------------------------------------------------------------------------

%% @doc SSL certificate verification function.
%%
%% @todo Logging `Event'

verify_cert(_Cert, {extension, _} = _Event, Options) ->
  % ignore extensions whatsoever
  {unknown, Options};

verify_cert(_Cert, _Event,
            _Options = #ssl_verify{ca_path_valid = false, job_id = JobID}) ->
  % there was an invalid certificate somewhere above, even if accepted
  % conditionally; signal it's an unknown CA
  harpcaller_log:info(?LOG_CAT, "invalid server certificate (parent CA whitelisted)",
                      [{job, {str, JobID}}]),
  {fail, {error, unknown_ca}};

verify_cert(Cert, {bad_cert, _} = Event,
            Options = #ssl_verify{job_id = JobID}) ->
  % if the certificate is in known certs store, accept it conditionally:
  % if it's a leaf, then the cert is valid, but if it's used as a CA,
  % verification will be rejected
  NewOptions = Options#ssl_verify{ca_path_valid = false},
  case harpcaller_x509_store:known(Cert) of
    true ->
      {valid, NewOptions};
    false ->
      harpcaller_log:info(?LOG_CAT, "invalid server certificate",
                          [{job, {str, JobID}}]),
      {fail, Event}
  end;

verify_cert(_Cert, valid = _Event, Options) ->
  {valid, Options};

verify_cert(_Cert, valid_peer = _Event, Options) ->
  {valid, Options}. % TODO: verify hostname

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker