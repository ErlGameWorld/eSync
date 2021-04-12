-module(eSync).

-export([
   start/0,
   stop/0,
   run/0,
   pause/0,
   curInfo/0,
   setLog/1,
   getLog/0,
   getOnMSync/0,
   setOnMSync/0,
   setOnMSync/1,
   getOnCSync/0,
   setOnCSync/0,
   setOnCSync/1,
   swSyncNode/1
]).

start() ->
   application:ensure_all_started(eSync).

stop() ->
   application:stop(eSync).

run() ->
   case start() of
      {ok, _Started} ->
         esSyncSrv:unpause(),
         ok;
      {error, Reason} ->
         Msg = io_lib:format("start eSync error:~p~n", [Reason]),
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

getOnMSync() ->
   esSyncSrv:getOnMSync().

setOnMSync() ->
   esSyncSrv:setOnMSync(undefined).

setOnMSync(Fun) ->
   esSyncSrv:setOnMSync(Fun).

getOnCSync() ->
   esSyncSrv:getOnCSync().

setOnCSync() ->
   esSyncSrv:setOnCSync(undefined).

setOnCSync(Fun) ->
   esSyncSrv:setOnCSync(Fun).




