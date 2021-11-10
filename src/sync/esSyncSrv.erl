-module(esSyncSrv).
-behaviour(es_gen_ipc).

%%%%%%%%%%%%%%%%%%%%%%%% eSync.hrl start %%%%%%%%%%%%%%%%%%%%%%
-define(LOG_ON(Val), Val == true; Val == all; Val == skip_success; is_list(Val), Val =/= []).

-define(Log, log).
-define(compileCmd, compileCmd).
-define(extraDirs, extraDirs).
-define(descendant, descendant).
-define(onMSyncFun, onMSyncFun).
-define(onCSyncFun, onCSyncFun).
-define(swSyncNode, swSyncNode).
-define(isJustMem, isJustMem).
-define(debugInfoKeyFun, debugInfoKeyFun).

-define(DefCfgList, [{?Log, all}, {?compileCmd, undefined}, {?extraDirs, undefined}, {?descendant, fix}, {?onMSyncFun, undefined}, {?onCSyncFun, undefined}, {?swSyncNode, false}, {?isJustMem, false}, {?debugInfoKeyFun, undefined}]).

-define(esCfgSync, esCfgSync).
-define(rootSrcDir, <<"src">>).

%%%%%%%%%%%%%%%%%%%%%%%% eSync.hrl end %%%%%%%%%%%%%%%%%%%%%%


-compile(inline).
-compile({inline_size, 128}).

%% API
-export([
   start_link/0,
   rescan/0,
   pause/0,
   unpause/0,
   setLog/1,
   getLog/0,
   curInfo/0,
   getOnMSync/0,
   setOnMSync/1,
   getOnCSync/0,
   setOnCSync/1,
   swSyncNode/1
]).

%% es_gen_ipc callbacks
-export([
   init/1,
   handleCall/4,
   handleAfter/3,
   handleCast/3,
   handleInfo/3,
   handleOnevent/4,
   terminate/3
]).

-define(SERVER, ?MODULE).
-define(None, 0).

-record(state, {
   port = undefined
   , onMSyncFun = undefined
   , onCSyncFun = undefined
   , swSyncNode = false
   , srcFiles = #{} :: map()
   , hrlFiles = #{} :: map()
   , configs = #{} :: map()
   , beams = #{} :: map()
}).

%% ************************************  API start ***************************
rescan() ->
   es_gen_ipc:cast(?SERVER, miRescan),
   esUtils:logSuccess("start rescaning source files..."),
   ok.

unpause() ->
   es_gen_ipc:cast(?SERVER, miUnpause),
   ok.

pause() ->
   es_gen_ipc:cast(?SERVER, miPause),
   esUtils:logSuccess("Pausing eSync. Call eSync:run() to restart"),
   ok.

curInfo() ->
   es_gen_ipc:call(?SERVER, miCurInfo).

setLog(T) when ?LOG_ON(T) ->
   esUtils:setEnv(log, T),
   esUtils:loadCfg(),
   esUtils:logSuccess("Console Notifications Enabled"),
   ok;
setLog(_) ->
   esUtils:setEnv(log, none),
   esUtils:loadCfg(),
   esUtils:logSuccess("Console Notifications Disabled"),
   ok.

getLog() ->
   ?esCfgSync:getv(log).

swSyncNode(IsSync) ->
   es_gen_ipc:cast(?SERVER, {miSyncNode, IsSync}),
   ok.

getOnMSync() ->
   es_gen_ipc:call(?SERVER, miGetOnMSync).

setOnMSync(Fun) ->
   es_gen_ipc:call(?SERVER, {miSetOnMSync, Fun}).

getOnCSync() ->
   es_gen_ipc:call(?SERVER, miGetOnCSync).

setOnCSync(Fun) ->
   es_gen_ipc:call(?SERVER, {miSetOnCSync, Fun}).

%% ************************************  API end   ***************************
start_link() ->
   es_gen_ipc:start_link({local, ?SERVER}, ?MODULE, ?None, []).

%% status :: waiting | running | pause
init(_Args) ->
   erlang:process_flag(trap_exit, true),
   esUtils:loadCfg(),
   {ok, waiting, #state{onMSyncFun = ?esCfgSync:getv(?onMSyncFun), onCSyncFun = ?esCfgSync:getv(?onCSyncFun), swSyncNode = ?esCfgSync:getv(?swSyncNode)}, {doAfter, ?None}}.

handleAfter(?None, waiting, State) ->
   %% 启动port 发送监听目录信息
   PortName = esUtils:fileSyncPath("fileSync"),
   Opts = [{packet, 4}, binary, exit_status, use_stdio],
   Port = erlang:open_port({spawn_executable, PortName}, Opts),
   {kpS, State#state{port = Port}, {sTimeout, 4000, waitConnOver}}.

handleCall(miGetOnMSync, _, #state{onMSyncFun = OnMSyncFun} = State, _From) ->
   {reply, OnMSyncFun, State};
handleCall({miSetOnMSync, Fun}, _, State, _From) ->
   {reply, ok, State#state{onMSyncFun = Fun}};
handleCall(miGetOnCSync, _, #state{onCSyncFun = OnCSyncFun} = State, _From) ->
   {reply, OnCSyncFun, State};
handleCall({miSetOnCSync, Fun}, _, State, _From) ->
   {reply, ok, State#state{onCSyncFun = Fun}};
handleCall(miCurInfo, Status, State, _Form) ->
   {reply, {Status, erlang:get(), State}, State};
handleCall(_Request, _, _State, _From) ->
   kpS_S.

handleCast(miPause, running, State) ->
   {nextS, pause, State};
handleCast(miUnpause, pause, State) ->
   {nextS, running, State};
handleCast({miSyncNode, IsSync}, _, State) ->
   case IsSync of
      true ->
         {kpS, State#state{swSyncNode = true}};
      _ ->
         {kpS, State#state{swSyncNode = false}}
   end;
handleCast(miRescan, _, State) ->
   {Srcs, Hrls, Configs, Beams} = esUtils:collSrcFiles(false),
   {kpS_S, State#state{srcFiles = Srcs, hrlFiles = Hrls, configs = Configs, beams = Beams}};
handleCast(_Msg, _, _State) ->
   kpS_S.

handleInfo({Port, {data, Data}}, Status, #state{srcFiles = Srcs, hrlFiles = Hrls, configs = Configs, beams = Beams, onMSyncFun = OnMSyncFun, onCSyncFun = OnCSyncFun, swSyncNode = SwSyncNode} = State) ->
   case Status of
      running ->
         FileList = binary:split(Data, <<"\r\n">>, [global]),
         %% 收集改动了beam hrl src 文件 然后执行相应的逻辑
         {CBeams, CConfigs, CHrls, CSrcs, NewSrcs, NewHrls, NewConfigs, NewBeams} = esUtils:classifyChangeFile(FileList, [], [], #{}, #{}, Srcs, Hrls, Configs, Beams),
         esUtils:fireOnSync(OnCSyncFun, CConfigs),
         esUtils:reloadChangedMod(CBeams, SwSyncNode, OnMSyncFun, []),
         case ?esCfgSync:getv(?compileCmd) of
            undefined ->
               LastCHrls = esUtils:collIncludeCHrls(maps:keys(CHrls), NewHrls, CHrls, #{}),
               NReSrcs =  esUtils:collIncludeCErls(maps:keys(LastCHrls), NewSrcs, CSrcs, #{}),
               esUtils:recompileChangeSrcFile(maps:iterator(NReSrcs), SwSyncNode),
               {kpS, State#state{srcFiles = NewSrcs, hrlFiles = NewHrls, configs = NewConfigs, beams = NewBeams}};
            CmdStr ->
               case maps:size(CSrcs) > 0 orelse CHrls =/= [] of
                  true ->
                     RetStr = os:cmd(CmdStr),
                     RetList = string:split(RetStr, "\n", all),
                     esUtils:logSuccess("compile cmd:~p ~n", [CmdStr]),
                     esUtils:logSuccess("the result: ~n ", []),
                     [
                        begin
                           esUtils:logSuccess("~p ~n", [OneRet])
                        end || OneRet <- RetList, OneRet =/= []
                     ],
                     ok;
                  _ ->
                     ignore
               end,
               kpS_S
         end;
      _ ->
         case Data of
            <<"init">> ->
               %% port启动成功 先发送监听目录配置
               {AddExtraSrcDirs, AddOnlySrcDirs, OnlySrcDirs, DelSrcDirs} = esUtils:mergeExtraDirs(false),
               AddExtraStr = string:join([filename:nativename(OneDir) || OneDir <- AddExtraSrcDirs], "|"),
               AddOnlyStr = string:join([filename:nativename(OneDir) || OneDir <- AddOnlySrcDirs], "|"),
               OnlyStr = string:join([filename:nativename(OneDir) || OneDir <- OnlySrcDirs], "|"),
               DelStr = string:join([filename:nativename(OneDir) || OneDir <- DelSrcDirs], "|"),
               AllStr = string:join([AddExtraStr, AddOnlyStr, OnlyStr, DelStr], "\r\n"),
               erlang:port_command(Port, AllStr),
               esUtils:logSuccess("eSync connect fileSync success..."),
               %% 然后收集一下监听目录下的src文件
               {BSrcs, BHrls, BConfigs, BBeams} = esUtils:collSrcFiles(true),
               {nextS, running, State#state{srcFiles = BSrcs, hrlFiles = BHrls, configs = BConfigs, beams = BBeams}, {isHib, true}};
            _ ->
               esUtils:logErrors("error, esSyncSrv receive unexpect port msg ~p~n", [Data]),
               kpS_S
         end
   end;
handleInfo({Port, closed}, running, #state{port = Port} = _State) ->
   esUtils:logErrors("esSyncSrv receive port closed ~n"),
   {nextS, port_close, _State};
handleInfo({'EXIT', Port, Reason}, running, #state{port = Port} = _State) ->
   esUtils:logErrors("esSyncSrv receive port exit Reason:~p ~n", [Reason]),
   {nextS, {port_EXIT, Reason}, _State};
handleInfo({Port, {exit_status, Status}}, running, #state{port = Port} = _State) ->
   esUtils:logErrors("esSyncSrv receive port exit_status Status:~p ~p ~n", [Status, Port]),
   {nextS, {port_exit_status, Status}, _State};
handleInfo({'EXIT', _Pid, _Reason}, running, _State) ->
   kpS_S;
handleInfo(_Msg, _, _State) ->
   esUtils:logErrors("esSyncSrv receive unexpect msg:~p ~n", [_Msg]),
   kpS_S.

handleOnevent(sTimeout, waitConnOver, Status, State) ->
   esUtils:logErrors("failed to connect the fileSync to stop stauts:~p state:~p ~n", [Status, State]),
   stop;
handleOnevent(_EventType, _EventContent, _Status, _State) ->
   kpS_S.

terminate(_Reason, _Status, _State) ->
   ok.