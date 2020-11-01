-module(esSyncSrv).
-behaviour(gen_ipc).

-include("erlSync.hrl").

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

%% gen_ipc callbacks
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
   , sockMod = undefined
   , sock = undefined
}).

%% ************************************  API start ***************************
rescan() ->
   gen_ipc:cast(?SERVER, miRescan),
   esUtils:logSuccess("start rescaning source files..."),
   ok.

unpause() ->
   gen_ipc:cast(?SERVER, miUnpause),
   ok.

pause() ->
   gen_ipc:cast(?SERVER, miPause),
   esUtils:logSuccess("Pausing erlSync. Call erlSync:run() to restart"),
   ok.

curInfo() ->
   gen_ipc:call(?SERVER, miCurInfo).

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
   gen_ipc:cast(?SERVER, {miSyncNode, IsSync}),
   ok.

getOnsync() ->
   gen_ipc:call(?SERVER, miGetOnsync).

setOnsync(Fun) ->
   gen_ipc:call(?SERVER, {miSetOnsync, Fun}).

%% ************************************  API end   ***************************
start_link() ->
   gen_ipc:start_link({local, ?SERVER}, ?MODULE, ?None, []).

%% status :: waiting | running | pause
init(_Args) ->
   erlang:process_flag(trap_exit, true),
   esUtils:loadCfg(),
   {ok, waiting, #state{}, {doAfter, ?None}}.

handleAfter(?None, waiting, State) ->
   %% 启动tcp 异步监听 然后启动文件同步应用 启动定时器  等待建立连接 超时 就表示文件同步应用启动失败了 报错
   ListenPort = ?esCfgSync:getv(?listenPort),
   case gen_tcp:listen(ListenPort, ?TCP_DEFAULT_OPTIONS) of
      {ok, LSock} ->
         case prim_inet:async_accept(LSock, -1) of
            {ok, _Ref} ->
               {ok, SockMod} = inet_db:lookup_socket(LSock),
               spawn(fun() ->
                  case os:type() of
                     {win32, _Osname} ->
                        os:cmd("start ./priv/fileSync.exe ./  " ++ integer_to_list(ListenPort));
                     _ ->
                        os:cmd("./priv/fileSync ./ " ++ integer_to_list(ListenPort))
                  end end),
               {kpS, State#state{sockMod = SockMod}, {sTimeout, 4000, waitConnOver}};
            {error, Reason} ->
               Msg = io_lib:format("init prim_inet:async_accept error ~p~n", [Reason]),
               esUtils:logErrors(Msg),
               {kpS, State, {sTimeout, 2000, waitConnOver}}
         end;
      {error, Reason} ->
         Msg = io_lib:format("failed to listen on ~p - ~p (~s) ~n", [ListenPort, Reason, inet:format_error(Reason)]),
         esUtils:logErrors(Msg),
         {kpS, State, {sTimeout, 2000, waitConnOver}}
   end.

handleCall(miGetOnsync, _, #state{onsyncFun = OnSync} = State, _From) ->
   {reply, OnSync, State};
handleCall({miSetOnsync, Fun}, _, State, _From) ->
   {reply, ok, State#state{onsyncFun = Fun}};
handleCall(miCurInfo, _, State, _Form) ->
   {reply, {erlang:get(), State}, State};
handleCall(_Request, _, _State, _From) ->
   kpS_S.

handleCast(miPause, _, State) ->
   {nextS, pause, State};
handleCast(miUnpause, _, State) ->
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

handleInfo({inet_async, LSock, _Ref, Msg}, _, #state{sockMod = SockMod} = State) ->
   case Msg of
      {ok, Sock} ->
         %% make it look like gen_tcp:accept
         inet_db:register_socket(Sock, SockMod),
         inet:setopts(Sock, [{active, true}]),
         prim_inet:async_accept(LSock, -1),

         %% 建立了连接 先发送监听目录配置
         {AddSrcDirs, OnlySrcDirs, DelSrcDirs} = esUtils:mergeExtraDirs(false),
         AddStr = string:join([filename:nativename(OneDir) || OneDir <- AddSrcDirs], "|"),
         OnlyStr = string:join([filename:nativename(OneDir) || OneDir <- OnlySrcDirs], "|"),
         DelStr = string:join([filename:nativename(OneDir) || OneDir <- DelSrcDirs], "|"),
         AllStr = string:join([AddStr, OnlyStr, DelStr], "\r\n"),
         gen_tcp:send(Sock, AllStr),
         case ?esCfgSync:getv(?compileCmd) of
            undefined ->
               %% 然后收集一下监听目录下的src文件
               SrcFiles = esUtils:collSrcFiles(true),
               {nextS, running, State#state{sock = Sock, srcFiles = SrcFiles}};
            _ ->
               {nextS, running, State}
         end;
      {error, closed} ->
         Msg = io_lib:format("error, closed listen sock error ~p~n", [closed]),
         esUtils:logErrors(Msg),
         {stop, normal};
      {error, Reason} ->
         Msg = io_lib:format("listen sock error ~p~n", [Reason]),
         esUtils:logErrors(Msg),
         {stop, {lsock, Reason}}
   end;
handleInfo({tcp, _Socket, Data}, running, #state{srcFiles = SrcFiles, onsyncFun = OnsyncFun, swSyncNode = SwSyncNode} = State) ->
   FileList = binary:split(Data, <<"\r\n">>, [global]),
   %% 收集改动了beam hrl src 文件 然后执行相应的逻辑
   {Beams, Hrls, Srcs} = esUtils:dealChangeFile(FileList, [], [], []),
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
handleInfo({tcp_closed, _Socket}, running, _State) ->
   Msg = io_lib:format("esSyncSrv receive tcp_closed ~n", []),
   esUtils:logErrors(Msg),
   kpS_S;
handleInfo({tcp_error, _Socket, Reason}, running, _State) ->
   Msg = io_lib:format("esSyncSrv receive tcp_error Reason:~p ~n", [Reason]),
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