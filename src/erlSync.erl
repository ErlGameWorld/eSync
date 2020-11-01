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
         esSyncSrv:unpause(),
         esSyncSrv:rescan(),
         ok;
      {error, Reason} ->
         Msg = io_lib:format("start erlSync error:~p~n", [Reason]),
         esUtils:logErrors(Msg)
   end.

pause() ->
   esSyncSrv:pause().

swSyncNode(IsSync) ->
   run(),
   esSyncSrv:swSyncNode(IsSync),
   ok.

curInfo() ->
   esSyncSrv:curInfo().

setLog(Val) ->
   esSyncSrv:setLog(Val).

getLog() ->
   esSyncSrv:getLog().

getOnsync() ->
   esSyncSrv:getOnsync().

setOnsync() ->
   esSyncSrv:setOnsync(undefined).

setOnsync(Fun) ->
   esSyncSrv:setOnsync(Fun).




