-module(erlSync).

-export([
   start/0,
   stop/0,
   run/0,
   pause/0,
   unpause/0,
   patch/0,
   info/0,
   log/1,
   log/0,
   onsync/0,
   onsync/1
]).

-include_lib("kernel/include/file.hrl").
-define(SERVER, ?MODULE).
-define(PRINT(Var), io:format("DEBUG: ~p:~p - ~p~n~n ~p~n~n", [?MODULE, ?LINE, ??Var, Var])).
-define(VALID_GROWL_OR_LOG(X), is_boolean(X); is_list(X); X == all; X == none; X == skip_success).

start() ->
   application:ensure_all_started(erlSync).

stop() ->
   application:stop(erlSync).

run() ->
   case start() of
      {ok, _Started} ->
         ok;
      {error, _Reason} ->
         esScanner:unpause(),
         esScanner:rescan()
   end.

patch() ->
   run(),
   esScanner:enable_patching(),
   ok.

pause() ->
   esScanner:pause().

unpause() ->
   esScanner:unpause().

info() ->
   esScanner:info().

log(Val) when ?VALID_GROWL_OR_LOG(Val) ->
   esScanner:set_log(Val).

log() ->
   esScanner:get_log().

onsync(Fun) ->
   esOptions:set_onsync(Fun).

onsync() ->
   esOptions:get_onsync().




