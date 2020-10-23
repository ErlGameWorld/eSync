-module(erlSync).

-export([
   start/0,
   stop/0,
   run/0,
   pause/0,
   curInfo/0,
   setLog/1,
   getLog/0,
   getOnsync/0,
   setOnsync/0,
   setOnsync/1,
   swSyncNode/1
]).

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
      {error, Reason} ->
         Msg = io_lib:format("start erlSync error ~p~n", [Reason]),
         esUtils:logErrors(Msg)
   end.

pause() ->
   esScanner:pause().

swSyncNode(IsSync) ->
   run(),
   esScanner:swSyncNode(IsSync),
   ok.

curInfo() ->
   esScanner:curInfo().

setLog(Val) ->
   esScanner:setLog(Val).

getLog() ->
   esScanner:getLog().

getOnsync() ->
   esScanner:getOnsync().

setOnsync() ->
   esScanner:setOnsync(undefined).

setOnsync(Fun) ->
   esScanner:setOnsync(Fun).




