%%%---------------------------------------------------------------------------
%%% @doc
%%%   Supervisor for client connection workers.
%%% @end
%%%---------------------------------------------------------------------------

-module(harpcaller_tcp_worker_sup).

-behaviour(supervisor).

%% public interface
-export([spawn_worker/1]).

%% supervision tree API
-export([start_link/0]).

%% supervisor callbacks
-export([init/1]).

%%%---------------------------------------------------------------------------
%%% public interface
%%%---------------------------------------------------------------------------

%% @doc Spawn a new worker process.

-spec spawn_worker(gen_tcp:socket()) ->
  {ok, pid()} | {error, term()}.

spawn_worker(Socket) ->
  supervisor:start_child(?MODULE, [Socket]).

%%%---------------------------------------------------------------------------
%%% supervision tree API
%%%---------------------------------------------------------------------------

%% @private
%% @doc Start the supervisor process.

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%%%---------------------------------------------------------------------------
%%% supervisor callbacks
%%%---------------------------------------------------------------------------

%% @private
%% @doc Initialize supervisor.

init([] = _Args) ->
  Strategy = {simple_one_for_one, 5, 10},
  Children = [
    {undefined, {harpcaller_tcp_worker, start_link, []},
      temporary, 1000, worker, [harpcaller_tcp_worker]}
  ],
  {ok, {Strategy, Children}}.

%%%---------------------------------------------------------------------------
%%% vim:ft=erlang:foldmethod=marker
