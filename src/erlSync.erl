-module(erlSync).

-export([
   start/0,
   stop/0,
   run/0,
   pause/0,
   info/0,
   log/1,
   log/0,
   onsync/0,
   onsync/1,
   swSyncNode/1
]).

-define(VALID_GROWL_OR_LOG(X), is_boolean(X); is_list(X); X == all; X == none; X == skip_success).

start() ->
   application:ensure_all_started(erlSync).

stop() ->
   application:stop(erlSync).

run() ->
   case start() of
      {ok, _Started} ->
         esScanner:unpause(),
         esScanner:rescan(),
         ok;
      {error, _Reason} ->
         io:format("Err")
   end.

pause() ->
   esScanner:pause().

swSyncNode(IsSync) ->
   run(),
   esScanner:swSyncNode(IsSync),
   ok.

info() ->
   esScanner:info().

log(Val) when ?VALID_GROWL_OR_LOG(Val) ->
   esScanner:setLog(Val).

log() ->
   esScanner:getLog().

onsync(Fun) ->
   esScanner:setOnsync(Fun).

onsync() ->
   esScanner:getOnsync().




