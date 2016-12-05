%%%---------------------------------------------------------------------------
%%% @doc
%%%   Administrative command handler for Indira.
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller_command_handler).

-behaviour(gen_indira_command).

%% gen_indira_command callbacks
-export([handle_command/2]).

%% `harpcaller_cli_handler' interface
-export([format_request/1, parse_reply/2, hardcoded_reply/1]).

%%%---------------------------------------------------------------------------
%%% gen_indira_command callbacks
%%%---------------------------------------------------------------------------

%%----------------------------------------------------------
%% daemon control

handle_command([{<<"command">>, <<"stop">>}] = _Command, _Args) ->
  harpcaller_log:info(control, "stopping harpcaller daemon", []),
  init:stop(),
  [{result, ok}, {pid, list_to_binary(os:getpid())}];

handle_command([{<<"command">>, <<"status">>}, {<<"wait">>, true}] = _Command,
               _Args) ->
  true = wait_for_start(),
  [{result, <<"running">>}];

handle_command([{<<"command">>, <<"status">>}, {<<"wait">>, false}] = _Command,
               _Args) ->
  case is_started() of
    true  -> [{result, <<"running">>}];
    false -> [{result, <<"stopped">>}]
  end;

handle_command([{<<"command">>, <<"reload_config">>}] = _Command, _Args) ->
  [{error, <<"command not implemented yet">>}];

%%----------------------------------------------------------
%% RPC job control

handle_command([{<<"command">>, <<"list_jobs">>}] = _Command, _Args) ->
  Jobs = list_jobs_info(),
  [{result, ok}, {jobs, Jobs}];

handle_command([{<<"command">>, <<"cancel_job">>},
                {<<"job">>, JobID}] = _Command, _Args) ->
  case harpcaller_caller:cancel(binary_to_list(JobID)) of
    ok -> [{result, ok}];
    undefined -> [{result, no_such_job}]
  end;

handle_command([{<<"command">>, <<"job_info">>},
                {<<"job">>, JobID}] = _Command, _Args) ->
  case job_info(binary_to_list(JobID)) of
    JobInfo when is_list(JobInfo) ->
      [{result, ok}, {info, JobInfo}];
    undefined ->
      [{result, no_such_job}]
  end;

%%----------------------------------------------------------
%% hosts registry control

handle_command([{<<"command">>, <<"list_hosts">>}] = _Command, _Args) ->
  Hosts = [format_host_entry(H) || H <- harpcaller_hostdb:list()],
  [{result, ok}, {hosts, Hosts}];

handle_command([{<<"command">>, <<"refresh_hosts">>}] = _Command, _Args) ->
  harpcaller_hostdb:refresh(),
  [{result, ok}];

%%----------------------------------------------------------
%% queues control

handle_command([{<<"command">>, <<"list_queues">>}] = _Command, _Args) ->
  {ok, Queues} = harpcaller_call_queue:list(),
  [{result, ok}, {queues, Queues}];

handle_command([{<<"command">>, <<"list_queue">>},
                {<<"queue">>, Queue}] = _Command, _Args) ->
  Jobs = list_queue(Queue),
  [{result, ok}, {jobs, Jobs}];

handle_command([{<<"command">>, <<"cancel_queue">>},
                {<<"queue">>, Queue}] = _Command, _Args) ->
  harpcaller_call_queue:cancel(Queue),
  [{result, ok}];

%%----------------------------------------------------------
%% Erlang networking control

handle_command([{<<"command">>, <<"dist_start">>}] = _Command, _Args) ->
  % TODO: handle errors
  ok = indira_app:distributed_start(),
  [{result, ok}];

handle_command([{<<"command">>, <<"dist_stop">>}] = _Command, _Args) ->
  % TODO: handle errors
  ok = indira_app:distributed_stop(),
  [{result, ok}];

%%----------------------------------------------------------
%% Log handling/rotation

handle_command([{<<"command">>, <<"prune_jobs">>},
                {<<"max_age">>, Age}] = _Command, _Args) ->
  harp_sdb:remove_older(Age),
  [{result, ok}];

handle_command([{<<"command">>, <<"reopen_logs">>}] = _Command, _Args) ->
  % the only log file that can possibly be opened is disk log for error_logger
  case application:get_env(harpcaller, error_logger_file) of
    {ok, File} ->
      case indira_disk_h:reopen(error_logger, File) of
        ok ->
          [{result, ok}];
        {error, Reason} ->
          Message = [
            "can't open ", File, ": ", indira_disk_h:format_error(Reason)
          ],
          [{result, error}, {reason, iolist_to_binary(Message)}]
      end;
    undefined ->
      % it's OK not to find this handler
      indira_disk_h:remove(error_logger),
      [{result, ok}]
  end;

%%----------------------------------------------------------

handle_command(_Command, _Args) ->
  [{error, <<"unsupported command">>}].

%%%---------------------------------------------------------------------------
%%% interface for `harpcaller_cli_handler'
%%%---------------------------------------------------------------------------

format_request(status) ->
  [{command, status}, {wait, false}];
format_request(status_wait) ->
  [{command, status}, {wait, true}];
format_request(stop) ->
  [{command, stop}];
format_request(reload_config) ->
  [{command, reload_config}];

format_request(list_jobs) ->
  [{command, list_jobs}];
format_request({cancel_job, JobID}) when is_list(JobID) ->
  format_request({cancel_job, list_to_binary(JobID)});
format_request({cancel_job, JobID}) when is_binary(JobID) ->
  [{command, cancel_job}, {job, JobID}];
format_request({job_info, JobID}) when is_list(JobID) ->
  format_request({job_info, list_to_binary(JobID)});
format_request({job_info, JobID}) when is_binary(JobID) ->
  [{command, job_info}, {job, JobID}];

format_request(list_hosts) ->
  [{command, list_hosts}];
format_request(refresh_hosts) ->
  [{command, refresh_hosts}];

format_request(list_queues) ->
  [{command, list_queues}];
format_request({list_queue, Queue}) ->
  [{command, list_queue}, {queue, Queue}];
format_request({cancel_queue, Queue}) ->
  [{command, cancel_queue}, {queue, Queue}];

format_request(dist_start) ->
  [{command, dist_start}];
format_request(dist_stop) ->
  [{command, dist_stop}];

format_request({prune_jobs, Days}) when is_integer(Days), Days > 0 ->
  [{command, prune_jobs}, {max_age, Days * 24 * 3600}];
format_request(reopen_logs) ->
  [{command, reopen_logs}].

parse_reply([{<<"result">>, <<"ok">>}] = _Reply, _Request) ->
  ok;
parse_reply([{<<"reason">>, Reason}, {<<"result">>, <<"error">>}] = _Reply,
            _Request) when is_binary(Reason) ->
  {error, Reason};

parse_reply([{<<"result">>, Status}] = _Reply, status = _Request) ->
  {ok, Status};
parse_reply([{<<"result">>, Status}] = _Reply, status_wait = _Request) ->
  {ok, Status};

parse_reply([{<<"pid">>, Pid}, {<<"result">>, <<"ok">>}] = _Reply,
            stop = _Request) when is_binary(Pid) ->
  {ok, binary_to_list(Pid)};

parse_reply([{<<"info">>, JobInfo}, {<<"result">>, <<"ok">>}] = _Reply,
            {job_info, _} = _Request) ->
  {ok, JobInfo};
parse_reply([{<<"result">>, <<"no_such_job">>}] = _Reply,
            {job_info, _} = _Request) ->
  {error, <<"no such job">>};

parse_reply([{<<"jobs">>, Jobs}, {<<"result">>, <<"ok">>}] = _Reply,
            list_jobs = _Request) when is_list(Jobs) ->
  {ok, Jobs};

parse_reply([{<<"result">>, <<"no_such_job">>}] = _Reply,
            {cancel_job, _} = _Request) ->
  {error, <<"no such job">>};

parse_reply([{<<"hosts">>, Hosts}, {<<"result">>, <<"ok">>}] = _Reply,
            list_hosts = _Request) when is_list(Hosts) ->
  {ok, Hosts};

parse_reply([{<<"queues">>, Queues}, {<<"result">>, <<"ok">>}] = _Reply,
            list_queues = _Request) when is_list(Queues) ->
  {ok, Queues};

parse_reply([{<<"jobs">>, Jobs}, {<<"result">>, <<"ok">>}] = _Reply,
            {list_queue, _} = _Request) when is_list(Jobs) ->
  {ok, Jobs};

parse_reply(_Reply, _Request) ->
  {error, <<"unrecognized reply from daemon">>}.

hardcoded_reply(ok = _Reply) ->
  [{<<"result">>, <<"ok">>}];
hardcoded_reply(status_stopped = _Reply) ->
  [{<<"result">>, <<"stopped">>}].

%%%---------------------------------------------------------------------------
%%% helper functions
%%%---------------------------------------------------------------------------

wait_for_start() ->
  % XXX: this will wait until the children of top-level supervisor all
  % started (and each child supervisor waits for its children, transitively)
  % or the supervisor shuts down due to an error
  try supervisor:which_children(harpcaller_sup) of
    _ -> true
  catch
    _:_ -> false
  end.

is_started() ->
  % `{AppName :: atom(), Desc :: string(), Version :: string()}' or `false';
  % only non-false when the application started successfully (it's still
  % `false' during boot time)
  AppEntry = lists:keyfind(harpcaller, 1, application:which_applications()),
  AppEntry /= false.

list_jobs_info() ->
  _Result = [
    pid_job_info(Pid) ||
    {_,Pid,_,_} <- supervisor:which_children(harpcaller_caller_sup)
  ].

pid_job_info(Pid) ->
  % TODO: catch errors from `harpcaller_caller:job_id()' when task terminated
  %   between listing processes and checking out its info
  {ok, JobID} = harpcaller_caller:job_id(Pid),
  job_info(JobID).

job_info(JobID) ->
  case harpcaller_caller:get_call_info(JobID) of
    {ok, {{ProcName, ProcArgs} = _ProcInfo, Host,
          {SubmitTime, StartTime, EndTime} = _TimeInfo}} ->
      _JobInfo = [
        {<<"job">>, list_to_binary(JobID)},
        {<<"call">>, [
          {<<"procedure">>, ProcName},
          {<<"arguments">>, ProcArgs},
          {<<"host">>, Host}
        ]},
        {<<"time">>, [
          {<<"submit">>, undef_null(SubmitTime)}, % non-null, but consistency
          {<<"start">>,  undef_null(StartTime)},
          {<<"end">>,    undef_null(EndTime)}
        ]}
      ];
    undefined ->
      undefined
    % XXX: let it die on other errors
  end.

format_host_entry({Hostname, Address, Port}) ->
  _Entry = [
    {<<"hostname">>, Hostname}, % binary
    {<<"address">>, format_address(Address)}, % list
    {<<"port">>, Port} % integer
  ].

list_queue(QueueName) ->
  {Running, Queued} = harpcaller_call_queue:list_processes(QueueName),
  _Result = [
    [{running, true} | pid_job_info(P)] || P <- Running
  ] ++ [
    [{running, false} | pid_job_info(P)] || P <- Queued
  ].

undef_null(undefined = _Value) -> null;
undef_null(Value) -> Value.

format_address({A,B,C,D} = _Address) ->
  % TODO: IPv6
  iolist_to_binary(io_lib:format("~B.~B.~B.~B", [A,B,C,D]));
format_address(Address) when is_list(Address) ->
  list_to_binary(Address).

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
