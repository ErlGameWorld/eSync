-module(esSyncSrv).
-behaviour(es_gen_ipc).

-include("eSync.hrl").

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
   getOnsync/0,
   setOnsync/1,
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
   srcFiles = #{} :: map()
   , hrlFiles = #{} :: map()
   , configs = #{} :: map()
   , beams = #{} :: map()
   , onSyncFun = undefined
   , swSyncNode = false
   , port = undefined
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

getOnsync() ->
   es_gen_ipc:call(?SERVER, miGetOnsync).

setOnsync(Fun) ->
   es_gen_ipc:call(?SERVER, {miSetOnSync, Fun}).

%% ************************************  API end   ***************************
start_link() ->
   es_gen_ipc:start_link({local, ?SERVER}, ?MODULE, ?None, []).

%% status :: waiting | running | pause
init(_Args) ->
   erlang:process_flag(trap_exit, true),
   esUtils:loadCfg(),
   {ok, waiting, #state{}, {doAfter, ?None}}.

handleAfter(?None, waiting, State) ->
   %% 启动port 发送监听目录信息
   PortName = esUtils:fileSyncPath("fileSync"),
   Opts = [{packet, 4}, binary, exit_status, use_stdio],
   Port = erlang:open_port({spawn_executable, PortName}, Opts),
   {kpS, State#state{port = Port}, {sTimeout, 4000, waitConnOver}}.

handleCall(miGetOnsync, _, #state{onSyncFun = OnSyncFun} = State, _From) ->
   {reply, OnSyncFun, State};
handleCall({miSetOnSync, Fun}, _, State, _From) ->
   {reply, ok, State#state{onSyncFun = Fun}};
handleCall(miCurInfo, _, State, _Form) ->
   {reply, {erlang:get(), State}, State};
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

handleInfo({Port, {data, Data}}, Status, #state{srcFiles = Srcs, hrlFiles = Hrls, configs = Configs, beams = Beams, onSyncFun = OnSyncFun, swSyncNode = SwSyncNode} = State) ->
   case Status of
      running ->
         FileList = binary:split(Data, <<"\r\n">>, [global]),
         %% 收集改动了beam hrl src 文件 然后执行相应的逻辑
         {CBeams, CConfigs, CHrls, CSrcs, NewSrcs, NewHrls, NewConfigs, NewBeams} = esUtils:classifyChangeFile(FileList, [], [], [], #{}, Srcs, Hrls, Configs, Beams),
         esUtils:fireOnsync(OnSyncFun, CConfigs),
         esUtils:reloadChangedMod(CBeams, SwSyncNode, OnSyncFun, []),
         case ?esCfgSync:getv(?compileCmd) of
            undefined ->
               NReSrcs = esUtils:recompileChangeHrlFile(CHrls, NewSrcs, CSrcs),
               esUtils:recompileChangeSrcFile(maps:iterator(NReSrcs), SwSyncNode),
               {kpS, State#state{srcFiles = NewSrcs, hrlFiles = NewHrls, configs = NewConfigs, beams = NewBeams}};
            CmdStr ->
               case maps:size(CSrcs) > 0 orelse CHrls =/= [] of
                  true ->
                     RetStr = os:cmd(CmdStr),
                     RetList = string:split(RetStr, "\n", all),
                     CmdMsg = io_lib:format("compile cmd:~p ~n", [CmdStr]),
                     esUtils:logSuccess(CmdMsg),
                     RetMsg = io_lib:format("the result: ~n ", []),
                     esUtils:logSuccess(RetMsg),
                     [
                        begin
                           OneMsg = io_lib:format("~p ~n", [OneRet]),
                           esUtils:logSuccess(OneMsg)
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
               {AddSrcDirs, OnlySrcDirs, DelSrcDirs} = esUtils:mergeExtraDirs(false),
               AddStr = string:join([filename:nativename(OneDir) || OneDir <- AddSrcDirs], "|"),
               OnlyStr = string:join([filename:nativename(OneDir) || OneDir <- OnlySrcDirs], "|"),
               DelStr = string:join([filename:nativename(OneDir) || OneDir <- DelSrcDirs], "|"),
               AllStr = string:join([AddStr, OnlyStr, DelStr], "\r\n"),
               erlang:port_command(Port, AllStr),
               esUtils:logSuccess("eSync connect fileSync success..."),
               %% 然后收集一下监听目录下的src文件
               {BSrcs, BHrls, BConfigs, BBeams} = esUtils:collSrcFiles(true),
               {nextS, running, State#state{srcFiles = BSrcs, hrlFiles = BHrls, configs = BConfigs, beams = BBeams}};
            _ ->
               ErrMsg = io_lib:format("error, esSyncSrv receive unexpect port msg ~p~n", [Data]),
               esUtils:logErrors(ErrMsg),
               kpS_S
         end
   end;
handleInfo({_Port, closed}, running, _State) ->
   Msg = io_lib:format("esSyncSrv receive port closed ~n", []),
   esUtils:logErrors(Msg),
   kpS_S;
handleInfo({'EXIT', _Port, Reason}, running, _State) ->
   Msg = io_lib:format("esSyncSrv receive port exit Reason:~p ~n", [Reason]),
   esUtils:logErrors(Msg),
   kpS_S;
handleInfo({_Port, {exit_status, Status}}, running, _State) ->
   Msg = io_lib:format("esSyncSrv receive port exit_status Status:~p ~n", [Status]),
   esUtils:logErrors(Msg),
   kpS_S;
handleInfo(_Msg, _, _State) ->
   Msg = io_lib:format("esSyncSrv receive unexpect msg:~p ~n", [_Msg]),
   esUtils:logErrors(Msg),
   kpS_S.

handleOnevent(sTimeout, waitConnOver, Status, State) ->
   Msg = io_lib:format("failed to connect the fileSync to stop stauts:~p state:~p ~n", [Status, State]),
   esUtils:logErrors(Msg),
   stop;
handleOnevent(_EventType, _EventContent, _Status, _State) ->
   kpS_S.

terminate(_Reason, _Status, _State) ->
   ok.