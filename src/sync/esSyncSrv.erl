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
   , onsyncFun = undefined
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
   es_gen_ipc:call(?SERVER, {miSetOnsync, Fun}).

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

handleCall(miGetOnsync, _, #state{onsyncFun = OnSync} = State, _From) ->
   {reply, OnSync, State};
handleCall({miSetOnsync, Fun}, _, State, _From) ->
   {reply, ok, State#state{onsyncFun = Fun}};
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
   SrcFiles = esUtils:collSrcFiles(false),
   {kpS_S, State#state{srcFiles = SrcFiles}};
handleCast(_Msg, _, _State) ->
   kpS_S.

handleInfo({_Port, {data, Data}}, running, #state{srcFiles = SrcFiles, onsyncFun = OnsyncFun, swSyncNode = SwSyncNode} = State) ->
   FileList = binary:split(Data, <<"\r\n">>, [global]),
   %% 收集改动了beam hrl src 文件 然后执行相应的逻辑
   {Beams, Hrls, Srcs, Configs} = esUtils:classifyChangeFile(FileList, [], [], [], []),
   esUtils:fireOnsync(OnsyncFun, Configs),
   esUtils:reloadChangedMod(Beams, SwSyncNode, OnsyncFun, []),
   case ?esCfgSync:getv(?compileCmd) of
      undefined ->
         esUtils:recompileChangeHrlFile(Hrls, SrcFiles, SwSyncNode),
         esUtils:recompileChangeSrcFile(Srcs, SwSyncNode),
         NewSrcFiles = esUtils:addNewFile(Srcs, SrcFiles),
         {kpS, State#state{srcFiles = NewSrcFiles}};
      CmdStr ->
         case Srcs =/= [] orelse Hrls =/= [] of
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
handleInfo({_Port, {data, Data}}, _, #state{port = Port} = State) ->
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
         case ?esCfgSync:getv(?compileCmd) of
            undefined ->
               %% 然后收集一下监听目录下的src文件
               SrcFiles = esUtils:collSrcFiles(true),
               {nextS, running, State#state{srcFiles = SrcFiles}};
            _ ->
               {nextS, running, State}
         end;
      _ ->
         Msg = io_lib:format("error, esSyncSrv receive unexpect port msg ~p~n", [Data]),
         esUtils:logErrors(Msg),
         kpS_S
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