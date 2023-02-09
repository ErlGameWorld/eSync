-module(eSync).

-behaviour(es_gen_ipc).

-include_lib("kernel/include/file.hrl").

-compile(inline).
-compile({inline_size, 128}).

-define(IIF(Cond, Ret1, Ret2), (case Cond of true -> Ret1; _ -> Ret2 end)).
-define(LOG_ON(Val), Val == true; Val == all; Val == skip_success; is_list(Val), Val =/= []).

-define(Log, log).
-define(baseDir, baseDir).
-define(monitorExt, monitorExt).
-define(compileCmd, compileCmd).
-define(extraDirs, extraDirs).
-define(descendant, descendant).
-define(onMSyncFun, onMSyncFun).
-define(onCSyncFun, onCSyncFun).
-define(swSyncNode, swSyncNode).
-define(isJustMem, isJustMem).
-define(debugInfoKeyFun, debugInfoKeyFun).

-define(ExtList, [".hrl", ".erl", ".beam", ".dtl", ".lfe", ".ex", ".config"]).

-define(DefCfgList, [{?Log, all}, {?baseDir, "./"}, {?monitorExt, ?ExtList}, {?compileCmd, undefined}, {?extraDirs, undefined}, {?descendant, fix}, {?onMSyncFun, undefined}, {?onCSyncFun, undefined}, {?swSyncNode, false}, {?isJustMem, false}, {?debugInfoKeyFun, undefined}]).

-define(esCfgSync, esCfgSync).
-define(rootSrcDir, <<"src">>).

-define(logSuccess(Format), canLog(success) andalso error_logger:info_msg("eSync[~p:~p|~p] " ++ Format, [?MODULE, ?FUNCTION_NAME, ?LINE])).
-define(logSuccess(Format, Args), canLog(success) andalso error_logger:info_msg("eSync[~p:~p|~p] " ++ Format, [?MODULE, ?FUNCTION_NAME, ?LINE] ++ Args)).

-define(logErrors(Format), canLog(errors) andalso error_logger:info_msg("eSync[~p:~p|~p] " ++ Format, [?MODULE, ?FUNCTION_NAME, ?LINE])).
-define(logErrors(Format, Args), canLog(errors) andalso error_logger:info_msg("eSync[~p:~p|~p] " ++ Format, [?MODULE, ?FUNCTION_NAME, ?LINE] ++ Args)).

-define(logWarnings(Format), canLog(warnings) andalso error_logger:info_msg("eSync[~p:~p|~p] " ++ Format, [?MODULE, ?FUNCTION_NAME, ?LINE])).
-define(logWarnings(Format, Args), canLog(warnings) andalso error_logger:info_msg("eSync[~p:~p|~p] " ++ Format, [?MODULE, ?FUNCTION_NAME, ?LINE] ++ Args)).

-export([
   start/2,
   start/0,
   stop/0,
   run/0
]).

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

start(_StartType, _StartArgs) ->
   start_link().

start() ->
   application:ensure_all_started(eSync).

stop() ->
   application:stop(eSync).

run() ->
   case start() of
      {ok, _Started} ->
         unpause(),
         ok;
      {error, Reason} ->
         ?logErrors("start eSync error:~p~n", [Reason])
   end.

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
   ?logSuccess("start rescaning source files..."),
   ok.

unpause() ->
   es_gen_ipc:cast(?SERVER, miUnpause),
   ok.

pause() ->
   es_gen_ipc:cast(?SERVER, miPause),
   ?logSuccess("Pausing eSync. Call eSync:run() to restart"),
   ok.

curInfo() ->
   es_gen_ipc:call(?SERVER, miCurInfo).

setLog(T) when ?LOG_ON(T) ->
   setEnv(log, T),
   loadCfg(),
   ?logSuccess("Console Notifications Enabled"),
   ok;
setLog(_) ->
   setEnv(log, none),
   loadCfg(),
   ?logSuccess("Console Notifications Disabled"),
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
   loadCfg(),
   {ok, waiting, #state{onMSyncFun = ?esCfgSync:getv(?onMSyncFun), onCSyncFun = ?esCfgSync:getv(?onCSyncFun), swSyncNode = ?esCfgSync:getv(?swSyncNode)}, {doAfter, ?None}}.

handleAfter(?None, waiting, State) ->
   %% 启动port 发送监听目录信息
   {AddExtraSrcDirs, AddOnlySrcDirs, OnlySrcDirs, DelSrcDirs} = mergeExtraDirs(false),
   AddExtraStr = string:join([filename:nativename(OneDir) || OneDir <- AddExtraSrcDirs], "|"),
   AddOnlyStr = string:join([filename:nativename(OneDir) || OneDir <- AddOnlySrcDirs], "|"),
   OnlyStr = string:join([filename:nativename(OneDir) || OneDir <- OnlySrcDirs], "|"),
   DelStr = string:join([filename:nativename(OneDir) || OneDir <- DelSrcDirs], "|"),
   AllStr = string:join([AddExtraStr, AddOnlyStr, OnlyStr, DelStr], "\r\n"),

   BaseDirStr = filename:nativename(?esCfgSync:getv(?baseDir)),
   MonitorExtStr = string:join(?esCfgSync:getv(?monitorExt), "|"),

   Opts = [{packet, 4}, binary, exit_status, use_stdio, {args, [BaseDirStr, MonitorExtStr, AllStr]}],
   PortName = fileSyncPath("fileSync"),
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
   {Srcs, Hrls, Configs, Beams} = collSrcFiles(false),
   {noreply, State#state{srcFiles = Srcs, hrlFiles = Hrls, configs = Configs, beams = Beams}, hibernate};
handleCast(_Msg, _, _State) ->
   kpS_S.

handleInfo({_Port, {data, Data}}, Status, #state{srcFiles = Srcs, hrlFiles = Hrls, configs = Configs, beams = Beams, onMSyncFun = OnMSyncFun, onCSyncFun = OnCSyncFun, swSyncNode = SwSyncNode} = State) ->
   case Status of
      running ->
         FileList = binary:split(Data, <<"\r\n">>, [global]),
         %% 收集改动了beam hrl src 文件 然后执行相应的逻辑
         {CBeams, CConfigs, CHrls, CSrcs, NewSrcs, NewHrls, NewConfigs, NewBeams} = classifyChangeFile(FileList, [], [], #{}, #{}, Srcs, Hrls, Configs, Beams),
         fireOnSync(OnCSyncFun, CConfigs),
         reloadChangedMod(CBeams, SwSyncNode, OnMSyncFun, []),
         case ?esCfgSync:getv(?compileCmd) of
            undefined ->
               LastCHrls = collIncludeCHrls(maps:keys(CHrls), NewHrls, CHrls, #{}),
               NReSrcs =  collIncludeCErls(maps:keys(LastCHrls), NewSrcs, CSrcs, #{}),
               recompileChangeSrcFile(maps:iterator(NReSrcs), SwSyncNode),
               {kpS, State#state{srcFiles = NewSrcs, hrlFiles = NewHrls, configs = NewConfigs, beams = NewBeams}};
            CmdStr ->
               case maps:size(CSrcs) > 0 orelse CHrls =/= [] of
                  true ->
                     RetStr = os:cmd(CmdStr),
                     RetList = string:split(RetStr, "\n", all),
                     ?logSuccess("compile cmd:~p ~n", [CmdStr]),
                     ?logSuccess("the result: ~n ", []),
                     [
                        begin
                           ?logSuccess("~p ~n", [OneRet])
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
               %% 然后收集一下监听目录下的src文件
               {BSrcs, BHrls, BConfigs, BBeams} = collSrcFiles(true),
               ?logSuccess("eSync connect fileSync success and coll src files over..."),
               {nextS, running, State#state{srcFiles = BSrcs, hrlFiles = BHrls, configs = BConfigs, beams = BBeams}, {isHib, true}};
            _ ->
               ?logErrors("error, receive unexpect port msg ~p~n", [Data]),
               kpS_S
         end
   end;
handleInfo({Port, closed}, running, #state{port = Port} = _State) ->
   ?logErrors("receive port closed ~n"),
   {nextS, port_close, _State};
handleInfo({'EXIT', Port, Reason}, running, #state{port = Port} = _State) ->
   ?logErrors("receive port exit Reason:~p ~n", [Reason]),
   {nextS, {port_EXIT, Reason}, _State};
handleInfo({Port, {exit_status, Status}}, running, #state{port = Port} = _State) ->
   ?logErrors("receive port exit_status Status:~p ~p ~n", [Status, Port]),
   {nextS, {port_exit_status, Status}, _State};
handleInfo({'EXIT', _Pid, _Reason}, running, _State) ->
   kpS_S;
handleInfo(_Msg, _, _State) ->
   ?logErrors("receive unexpect msg:~p ~n", [_Msg]),
   kpS_S.

handleOnevent(sTimeout, waitConnOver, Status, State) ->
   ?logErrors("failed to connect the fileSync to stop stauts:~p state:~p ~n", [Status, State]),
   stop;
handleOnevent(_EventType, _EventContent, _Status, _State) ->
   kpS_S.

terminate(_Reason, _Status, _State) ->
   ok.

%% ************************************************* utils start *******************************************************
getModSrcDir(Module) ->
   case code:is_loaded(Module) of
      {file, _} ->
         try
            %% Get some module info...
            Props = Module:module_info(compile),
            Source = proplists:get_value(source, Props, ""),
            %% Ensure that the file exists, is a decendent of the tree, and how to deal with that
            IsFile = filelib:is_regular(Source),
            IsDescendant = isDescendent(Source),
            Descendant = ?esCfgSync:getv(?descendant),
            LastSource =
               case {IsFile, IsDescendant, Descendant} of
                  %% is file and descendant, we're good to go
                  {true, true, _} -> Source;
                  %% is not a descendant, but we allow them, so good to go
                  {true, false, allow} -> Source;
                  %% is not a descendant, and we fix non-descendants, so let's fix it
                  {_, false, fix} -> fixDescendantSource(Source, IsFile);
                  %% Anything else, and we don't know what to do, so let's just bail.
                  _ -> undefined
               end,
            case LastSource of
               undefined ->
                  undefined;
               _ ->
                  %% Get the source dir...
                  Dir = filename:dirname(LastSource),
                  getSrcDir(Dir)
            end
         catch _ : _ ->
            undefined
         end;
      _ ->
         undefined
   end.

getModOpts(Module) ->
   case code:is_loaded(Module) of
      {file, _} ->
         try
            Props = Module:module_info(compile),
            BeamDir = filename:dirname(code:which(Module)),
            Options1 = proplists:get_value(options, Props, []),
            %% transform `outdir'
            Options2 = transformOutdir(BeamDir, Options1),
            Options3 = ensureInclude(Options2),
            %% transform the include directories
            Options4 = transformAllIncludes(Module, BeamDir, Options3),
            %% maybe_add_compile_info
            Options5 = maybeAddCompileInfo(Options4),
            %% add filetype to options (DTL, LFE, erl, etc)
            Options6 = addFileType(Module, Options5),
            Options7 = lists:keyreplace(debug_info_key, 1, Options6, debugInfoKeyFun()),
            {ok, Options7}
         catch ExType:Error ->
            ?logWarnings("~p:0: ~p looking for options: ~p. ~n", [Module, ExType, Error]),
            undefined
         end;
      _ ->
         undefined
   end.

tryGetModOpts(Module) ->
   try
      Props = Module:module_info(compile),
      BeamDir = filename:dirname(code:which(Module)),
      Options1 = proplists:get_value(options, Props, []),
      %% transform `outdir'
      Options2 = transformOutdir(BeamDir, Options1),
      Options3 = ensureInclude(Options2),
      %% transform the include directories
      Options4 = transformAllIncludes(Module, BeamDir, Options3),
      %% maybe_add_compile_info
      Options5 = maybeAddCompileInfo(Options4),
      %% add filetype to options (DTL, LFE, erl, etc)
      Options6 = addFileType(Module, Options5),
      Options7 = lists:keyreplace(debug_info_key, 1, Options6, debugInfoKeyFun()),
      {ok, Options7}
   catch _ExType:_Error ->
      undefined
   end.

tryGetSrcOpts(SrcDir) ->
   %% Then we dig back through the parent directories until we find our include directory
   NewDirName = filename:dirname(SrcDir),
   case getOptions(NewDirName) of
      {ok, _Options} = Opts ->
         Opts;
      _ ->
         BaseName = filename:basename(SrcDir),
         IsBaseSrcDir = BaseName == ?rootSrcDir,
         case NewDirName =/= SrcDir andalso not IsBaseSrcDir of
            true ->
               tryGetSrcOpts(NewDirName);
            _ when IsBaseSrcDir ->
               try filelib:fold_files(SrcDir, ".*\\.(erl|dtl|lfe|ex)$", true,
                  fun(OneFile, Acc) ->
                     Mod = binary_to_atom(filename:basename(OneFile, filename:extension(OneFile))),
                     case tryGetModOpts(Mod) of
                        {ok, _Options} = Opts ->
                           throw(Opts);
                        _ ->
                           Acc
                     end
                  end, undefined)
               catch
                  {ok, _Options} = Opts ->
                     Opts;
                  _ExType:_Error ->
                     ?logWarnings("looking src options error ~p:~p. ~n", [_ExType, _Error]),
                     undefined
               end;
            _ ->
               undefined
         end
   end.

transformOutdir(BeamDir, Options) ->
   [{outdir, BeamDir} | proplists:delete(outdir, Options)].

ensureInclude(Options) ->
   case proplists:get_value(i, Options) of
      undefined -> [{i, "include"} | Options];
      _ -> Options
   end.

transformAllIncludes(Module, BeamDir, Options) ->
   [begin
       case Opt of
          {i, IncludeDir} ->
             {ok, SrcDir} = getModSrcDir(Module),
             {ok, IncludeDir2} = determineIncludeDir(IncludeDir, BeamDir, SrcDir),
             {i, IncludeDir2};
          _ ->
             Opt
       end
    end || Opt <- Options].

maybeAddCompileInfo(Options) ->
   case lists:member(compile_info, Options) of
      true -> Options;
      false -> addCompileInfo(Options)
   end.

addCompileInfo(Options) ->
   CompInfo = [{K, V} || {K, V} <- Options, lists:member(K, [outdir, i])],
   [{compile_info, CompInfo} | Options].

addFileType(Module, Options) ->
   Type = getFileType(Module),
   [{type, Type} | Options].

%% This will check if the given module or source file is an ErlyDTL template.
%% Currently, this is done by checking if its reported source path ends with
%% ".dtl.erl".
getFileType(Module) when is_atom(Module) ->
   Props = Module:module_info(compile),
   Source = proplists:get_value(source, Props, ""),
   getFileType(Source);

getFileType(Source) ->
   Ext = filename:extension(Source),
   Root = filename:rootname(Source),
   SecondExt = filename:extension(Root),
   case Ext of
      <<".erl">> when SecondExt =:= <<".dtl">> -> dtl;
      <<".dtl">> -> dtl;
      <<".erl">> -> erl;
      <<".lfe">> -> lfe;
      <<".ex">> -> elixir;
      ".erl" when SecondExt =:= ".dtl" -> dtl;
      ".dtl" -> dtl;
      ".erl" -> erl;
      ".lfe" -> lfe;
      ".ex" -> elixir
   end.

%% This will search back to find an appropriate include directory, by
%% searching further back than "..". Instead, it will extract the basename
%% (probably "include" from the include pathfile, and then search backwards in
%% the directory tree until it finds a directory with the same basename found
%% above.
determineIncludeDir(IncludeDir, BeamDir, SrcDir) ->
   IncludeBase = filename:basename(IncludeDir),
   case determineIncludeDirFromBeamDir(IncludeBase, IncludeDir, BeamDir) of
      {ok, _Dir} = RetD -> RetD;
      undefined ->
         {ok, Cwd} = file:get_cwd(),
         % Cwd2 = normalizeCaseWindowsDir(Cwd),
         % SrcDir2 = normalizeCaseWindowsDir(SrcDir),
         % IncludeBase2 = normalizeCaseWindowsDir(IncludeBase),
         case findIncludeDirFromAncestors(SrcDir, Cwd, IncludeBase) of
            {ok, _Dir} = RetD -> RetD;
            undefined -> {ok, IncludeDir} %% Failed, just stick with original
         end
   end.

%% First try to see if we have an include file alongside our ebin directory, which is typically the case
determineIncludeDirFromBeamDir(IncludeBase, IncludeDir, BeamDir) ->
   BeamBasedIncDir = filename:join(filename:dirname(BeamDir), IncludeBase),
   case filelib:is_dir(BeamBasedIncDir) of
      true -> {ok, BeamBasedIncDir};
      false ->
         BeamBasedIncDir2 = filename:join(filename:dirname(BeamDir), IncludeDir),
         case filelib:is_dir(BeamBasedIncDir2) of
            true -> {ok, BeamBasedIncDir2};
            _ ->
               undefined
         end
   end.

%% get the src dir
getRootSrcDirFromSrcDir(SrcDir) ->
   NewDirName = filename:dirname(SrcDir),
   BaseName = filename:basename(SrcDir),
   case BaseName of
      ?rootSrcDir ->
         NewDirName;
      _ ->
         case NewDirName =/= SrcDir of
            true ->
               getRootSrcDirFromSrcDir(NewDirName);
            _ ->
               undefined
         end
   end.

%% Then we dig back through the parent directories until we find our include directory
findIncludeDirFromAncestors(Cwd, Cwd, _) -> undefined;
findIncludeDirFromAncestors("/", _, _) -> undefined;
findIncludeDirFromAncestors(".", _, _) -> undefined;
findIncludeDirFromAncestors("", _, _) -> undefined;
findIncludeDirFromAncestors(Dir, Cwd, IncludeBase) ->
   NewDirName = filename:dirname(Dir),
   AttemptDir = filename:join(NewDirName, IncludeBase),
   case filelib:is_dir(AttemptDir) of
      true ->
         {ok, AttemptDir};
      false ->
         case NewDirName =/= Dir of
            true ->
               findIncludeDirFromAncestors(NewDirName, Cwd, IncludeBase);
            _ ->
               undefined
         end
   end.

% normalizeCaseWindowsDir(Dir) ->
%    case os:type() of
%       {win32, _} -> Dir; %string:to_lower(Dir);
%       {unix, _} -> Dir
%    end.

%% This is an attempt to intelligently fix paths in modules when a
%% release is moved.  Essentially, it takes a module name and its original path
%% from Module:module_info(compile), say
%% "/some/original/path/site/src/pages/somepage.erl", and then breaks down the
%% path one by one prefixing it with the current working directory until it
%% either finds a match, or fails.  If it succeeds, it returns the Path to the
%% new Source file.
fixDescendantSource([], _IsFile) ->
   undefined;
fixDescendantSource(Path, IsFile) ->
   {ok, Cwd} = file:get_cwd(),
   PathParts = filename:split(Path),
   case makeDescendantSource(PathParts, Cwd) of
      undefined -> case IsFile of true -> Path; _ -> undefined end;
      FoundPath -> FoundPath
   end.

makeDescendantSource([], _Cwd) ->
   undefined;
makeDescendantSource([_ | T], Cwd) ->
   PathAttempt = filename:join([Cwd | T]),
   case filelib:is_regular(PathAttempt) of
      true -> PathAttempt;
      false -> makeDescendantSource(T, Cwd)
   end.

isDescendent(Path) ->
   {ok, Cwd} = file:get_cwd(),
   lists:sublist(Path, length(Cwd)) == Cwd.

%% @private Find the src directory for the specified Directory; max 15 iterations
getSrcDir(Dir) ->
   getSrcDir(Dir, 15).

getSrcDir(_Dir, 0) ->
   undefined;
getSrcDir(Dir, Ctr) ->
   HasCode = filelib:wildcard("*.{erl,hrl,ex,dtl,lfe}", Dir) /= [],
   if
      HasCode -> {ok, Dir};
      true -> getSrcDir(filename:dirname(Dir), Ctr - 1)
   end.

mergeExtraDirs(IsAddPath) ->
   case ?esCfgSync:getv(?extraDirs) of
      undefined ->
         {[], [], [], []};
      ExtraList ->
         FunMerge =
            fun(OneExtra, {AddExtraDirs, AddOnlyDirs, OnlyDirs, DelDirs} = AllAcc) ->
               case OneExtra of
                  {addExtra, DirsAndOpts} ->
                     Adds =
                        [
                           begin
                              case IsAddPath of
                                 true ->
                                    case proplists:get_value(outdir, Opts) of
                                       undefined ->
                                          true;
                                       Path ->
                                          ok = filelib:ensure_dir(Path),
                                          true = code:add_pathz(Path)
                                    end;
                                 _ ->
                                    ignore
                              end,
                              filename:absname(Dir)
                           end || {Dir, Opts} <- DirsAndOpts
                        ],
                     setelement(1, AllAcc, Adds ++ AddExtraDirs);
                  {addOnly, DirsAndOpts} ->
                     Adds =
                        [
                           begin
                              case IsAddPath of
                                 true ->
                                    case proplists:get_value(outdir, Opts) of
                                       undefined ->
                                          true;
                                       Path ->
                                          ok = filelib:ensure_dir(Path),
                                          true = code:add_pathz(Path)
                                    end;
                                 _ ->
                                    ignore
                              end,
                              filename:absname(Dir)
                           end || {Dir, Opts} <- DirsAndOpts
                        ],
                     setelement(2, AllAcc, Adds ++ AddOnlyDirs);
                  {only, DirsAndOpts} ->
                     Onlys =
                        [
                           begin
                              case IsAddPath of
                                 true ->
                                    case proplists:get_value(outdir, Opts) of
                                       undefined ->
                                          true;
                                       Path ->
                                          ok = filelib:ensure_dir(Path),
                                          true = code:add_pathz(Path)
                                    end;
                                 _ ->
                                    ignore
                              end,
                              filename:absname(Dir)
                           end || {Dir, Opts} <- DirsAndOpts
                        ],
                     setelement(3, AllAcc, Onlys ++ OnlyDirs);
                  {del, DirsAndOpts} ->
                     Dels =
                        [
                           begin
                              filename:absname(Dir)
                           end || {Dir, _Opts} <- DirsAndOpts
                        ],
                     setelement(4, AllAcc, Dels ++ DelDirs)
               end
            end,
         lists:foldl(FunMerge, {[], [], [], []}, ExtraList)
   end.

toBinary(Value) when is_list(Value) -> list_to_binary(Value);
toBinary(Value) when is_binary(Value) -> Value.

regExp() ->
   % <<".*\\.(erl|hrl|beam|config|dtl|lfe|ex)$">>
   <<_Del:8, RegExpStr/binary>> = << <<"|", (toBinary(Tail))/binary>> || [_Dot | Tail] <- ?esCfgSync:getv(?monitorExt)>>,
   <<".*\\.(", RegExpStr/binary, ")$">>.

-define(RegExp, regExp()).
collSrcFiles(IsAddPath) ->
   {AddExtraSrcDirs, AddOnlySrcDirs, OnlySrcDirs, DelSrcDirs} = mergeExtraDirs(IsAddPath),
   CollFiles = filelib:fold_files(filename:absname(toBinary(?esCfgSync:getv(?baseDir))), ?RegExp, true,
      fun(OneFile, {Srcs, Hrls, Configs, Beams} = Acc) ->
         case isOnlyDir(OnlySrcDirs, OneFile) andalso (not isDelDir(DelSrcDirs, OneFile)) of
            true ->
               MTimeSec = case file:read_file_info(OneFile, [raw]) of
                  {ok, FileInfo} ->
                     dateTimeToSec(FileInfo#file_info.mtime);
                  _ ->
                     0
               end,
               %MTimeSec = dateTimeToSec(filelib:last_modified(OneFile)),
               case filename:extension(OneFile) of
                  <<".beam">> ->
                     BeamMod = binary_to_atom(filename:basename(OneFile, <<".beam">>)),
                     setelement(4, Acc, Beams#{BeamMod => MTimeSec});
                  <<".config">> ->
                     setelement(3, Acc, Configs#{OneFile => MTimeSec});
                  <<".hrl">> ->
                     setelement(2, Acc, Hrls#{OneFile => MTimeSec});
                  <<>> ->
                     Acc;
                  _ ->
                     RootSrcDir =
                        case getRootSrcDirFromSrcDir(OneFile) of
                           undefined ->
                              filename:dirname(OneFile);
                           RetSrcDir ->
                              RetSrcDir
                        end,
                     case getOptions(RootSrcDir) of
                        undefined ->
                           Mod = binary_to_atom(filename:basename(OneFile, filename:extension(OneFile))),
                           case getModOpts(Mod) of
                              {ok, Options} ->
                                 setOptions(RootSrcDir, Options);
                              _ ->
                                 ignore
                           end;
                        _ ->
                           ignore
                     end,
                     setelement(1, Acc, Srcs#{OneFile => MTimeSec})
               end;
            _ ->
               Acc
         end
      end, {#{}, #{}, #{}, #{}}),

   FunCollAddExtra =
      fun(OneDir, FilesAcc) ->
         filelib:fold_files(?IIF(is_list(OneDir), list_to_binary(OneDir), OneDir), ?RegExp, true,
            fun(OneFile, {Srcs, Hrls, Configs, Beams} = Acc) ->
               MTimeSec = dateTimeToSec(filelib:last_modified(OneFile)),
               case filename:extension(OneFile) of
                  <<".beam">> ->
                     BeamMod = binary_to_atom(filename:basename(OneFile, <<".beam">>)),
                     setelement(4, Acc, Beams#{BeamMod => MTimeSec});
                  <<".config">> ->
                     setelement(3, Acc, Configs#{OneFile => MTimeSec});
                  <<".hrl">> ->
                     setelement(2, Acc, Hrls#{OneFile => MTimeSec});
                  <<>> ->
                     Acc;
                  _ ->
                     setelement(1, Acc, Srcs#{OneFile => MTimeSec})
               end
            end, FilesAcc)
      end,
   AddExtraCollFiles = lists:foldl(FunCollAddExtra, CollFiles, AddExtraSrcDirs),

   FunCollAddOnly =
      fun(OneDir, FilesAcc) ->
         filelib:fold_files(?IIF(is_list(OneDir), list_to_binary(OneDir), OneDir), ?RegExp, false,
            fun(OneFile, {Srcs, Hrls, Configs, Beams} = Acc) ->
               MTimeSec = dateTimeToSec(filelib:last_modified(OneFile)),
               case filename:extension(OneFile) of
                  <<".beam">> ->
                     BeamMod = binary_to_atom(filename:basename(OneFile, <<".beam">>)),
                     setelement(4, Acc, Beams#{BeamMod => MTimeSec});
                  <<".config">> ->
                     setelement(3, Acc, Configs#{OneFile => MTimeSec});
                  <<".hrl">> ->
                     setelement(2, Acc, Hrls#{OneFile => MTimeSec});
                  <<>> ->
                     Acc;
                  _ ->
                     setelement(1, Acc, Srcs#{OneFile => MTimeSec})
               end
            end, FilesAcc)
      end,
   lists:foldl(FunCollAddOnly, AddExtraCollFiles, AddOnlySrcDirs).


isOnlyDir([], _) ->
   true;
isOnlyDir(ReplaceDirs, SrcDir) ->
   isMatchDir(ReplaceDirs, SrcDir).

isDelDir([], _) ->
   false;
isDelDir(ReplaceDirs, SrcDir) ->
   isMatchDir(ReplaceDirs, SrcDir).

isMatchDir([], _SrcDir) ->
   false;
isMatchDir([SrcDir | _ReplaceDirs], SrcDir) ->
   true;
isMatchDir([OneDir | ReplaceDirs], SrcDir) ->
   case re:run(SrcDir, OneDir) of
      nomatch -> isMatchDir(ReplaceDirs, SrcDir);
      _ -> true
   end.

getEnv(Var, Default) ->
   case application:get_env(eSync, Var) of
      {ok, Value} ->
         Value;
      _ ->
         Default
   end.

setEnv(Var, Val) ->
   ok = application:set_env(eSync, Var, Val).

canLog(MsgType) ->
   case eSync:getLog() of
      true -> true;
      all -> true;
      none -> false;
      false -> false;
      skip_success -> MsgType == errors orelse MsgType == warnings;
      L when is_list(L) -> lists:member(MsgType, L);
      _ -> false
   end.

%% 注意 map类型的数据不能当做key
-type key() :: atom() | binary() | bitstring() | float() | integer() | list() | tuple().
-type value() :: atom() | binary() | bitstring() | float() | integer() | list() | tuple() | map().

-spec load(term(), [{key(), value()}]) -> ok.
load(Module, KVs) ->
   Forms = forms(Module, KVs),
   {ok, Module, Bin} = compile:forms(Forms),
   code:soft_purge(Module),
   {module, Module} = code:load_binary(Module, atom_to_list(Module), Bin),
   ok.

forms(Module, KVs) ->
   %% -module(Module).
   Mod = erl_syntax:attribute(erl_syntax:atom(module), [erl_syntax:atom(Module)]),
   %% -export([getv/0]).
   ExportList = [erl_syntax:arity_qualifier(erl_syntax:atom(getv), erl_syntax:integer(1))],
   Export = erl_syntax:attribute(erl_syntax:atom(export), [erl_syntax:list(ExportList)]),
   %% getv(K) -> V
   Function = erl_syntax:function(erl_syntax:atom(getv), lookup_clauses(KVs, [])),
   [erl_syntax:revert(X) || X <- [Mod, Export, Function]].

lookup_clause(Key, Value) ->
   Var = erl_syntax:abstract(Key),
   Body = erl_syntax:abstract(Value),
   erl_syntax:clause([Var], [], [Body]).

lookup_clause_anon() ->
   Var = erl_syntax:variable("_"),
   Body = erl_syntax:atom(undefined),
   erl_syntax:clause([Var], [], [Body]).

lookup_clauses([], Acc) ->
   lists:reverse(lists:flatten([lookup_clause_anon() | Acc]));
lookup_clauses([{Key, Value} | T], Acc) ->
   lookup_clauses(T, [lookup_clause(Key, Value) | Acc]).

getOptions(SrcDir) ->
   case erlang:get(SrcDir) of
      undefined ->
         undefined;
      Options ->
         {ok, Options}
   end.

setOptions(SrcDir, Options) ->
   case erlang:get(SrcDir) of
      undefined ->
         erlang:put(SrcDir, Options);
      OldOptions ->
         NewOptions =
            case lists:keytake(compile_info, 1, Options) of
               {value, {compile_info, ValList1}, Options1} ->
                  case lists:keytake(compile_info, 1, OldOptions) of
                     {value, {compile_info, ValList2}, Options2} ->
                        [{compile_info, lists:usort(ValList1 ++ ValList2)} | lists:usort(Options1 ++ Options2)];
                     _ ->
                        lists:usort(Options ++ OldOptions)
                  end;
               _ ->
                  lists:usort(Options ++ OldOptions)
            end,
         erlang:put(SrcDir, NewOptions)
   end.

loadCfg() ->
   KVs = [{Key, getEnv(Key, DefVal)} || {Key, DefVal} <- ?DefCfgList],
   load(?esCfgSync, KVs).

%% *******************************  加载与编译相关 **********************************************************************
printResults(_Module, SrcFile, [], []) ->
   ?logSuccess("~s Recompiled", [SrcFile]);
printResults(_Module, SrcFile, [], Warnings) ->
   formatErrors(logWarnings, SrcFile, [], Warnings);
printResults(_Module, SrcFile, Errors, Warnings) ->
   formatErrors(logErrors, SrcFile, Errors, Warnings).

%% @private Print error messages in a pretty and user readable way.
formatErrors(LogFun, File, Errors, Warnings) ->
   AllErrors1 = lists:sort(lists:flatten([X || {_, X} <- Errors])),
   AllErrors2 = [{Line, "Error", Module, Description} || {Line, Module, Description} <- AllErrors1],
   AllWarnings1 = lists:sort(lists:flatten([X || {_, X} <- Warnings])),
   AllWarnings2 = [{Line, "Warning", Module, Description} || {Line, Module, Description} <- AllWarnings1],
   Everything = lists:sort(AllErrors2 ++ AllWarnings2),
   FPck =
      fun({Line, Prefix, Module, ErrorDescription}) ->
         Msg = formatError(Module, ErrorDescription),
         case LogFun of
            logWarnings ->
               ?logWarnings("~s: ~p: ~s: ~s", [File, Line, Prefix, Msg]);
            logErrors ->
               ?logErrors("~s: ~p: ~s: ~s", [File, Line, Prefix, Msg])
         end
      end,
   [FPck(X) || X <- Everything],
   ok.

formatError(Module, ErrorDescription) ->
   case erlang:function_exported(Module, format_error, 1) of
      true -> Module:format_error(ErrorDescription);
      false -> io_lib:format("~s", [ErrorDescription])
   end.

fireOnSync(OnSyncFun, Modules) ->
   case OnSyncFun of
      undefined -> ok;
      Funs when is_list(Funs) -> onSyncApplyList(Funs, Modules);
      Fun -> onSyncApply(Fun, Modules)
   end.

onSyncApplyList(Funs, Modules) ->
   [onSyncApply(Fun, Modules) || Fun <- Funs].

onSyncApply({M, F}, Modules) ->
   try erlang:apply(M, F, [Modules])
   catch
      C:R:S ->
         ?logErrors("apply sync fun ~p:~p(~p)  error ~p", [M, F, Modules, {C, R, S}])
   end;
onSyncApply(Fun, Modules) when is_function(Fun) ->
   try Fun(Modules)
   catch
      C:R:S ->
         ?logErrors("apply sync fun ~p(~p)  error ~p", [Fun, Modules, {C, R, S}])
   end.

reloadChangedMod([], _SwSyncNode, OnSyncFun, Acc) ->
   fireOnSync(OnSyncFun, Acc);
reloadChangedMod([Module | LeftMod], SwSyncNode, OnSyncFun, Acc) ->
   case Module == es_gen_ipc orelse code:get_object_code(Module) of
      true ->
         ignore;
      error ->
         ?logErrors("Error loading object code for ~p", [Module]),
         reloadChangedMod(LeftMod, SwSyncNode, OnSyncFun, Acc);
      {Module, Binary, Filename} ->
         case code:load_binary(Module, Filename, Binary) of
            {module, Module} ->
               ?logSuccess("Reloaded(Beam changed) Mod: ~s Success", [Module]),
               syncLoadModOnAllNodes(SwSyncNode, Module, Binary, changed);
            {error, What} ->
               ?logErrors("Reloaded(Beam changed) Mod: ~s Errors Reason:~p", [Module, What])
         end,
         reloadChangedMod(LeftMod, SwSyncNode, OnSyncFun, [Module | Acc])
   end.

getNodes() ->
   lists:usort(lists:flatten(nodes() ++ [erpc:call(X, erlang, nodes, []) || X <- nodes()])) -- [node()].

syncLoadModOnAllNodes(false, _Module, _Binary, _Reason) ->
   ignore;
syncLoadModOnAllNodes(true, Module, Binary, Reason) ->
   %% Get a list of nodes known by this node, plus all attached nodes.
   Nodes = getNodes(),
   NumNodes = length(Nodes),
   [
      begin
         ?logSuccess("Do Reloading '~s' on ~p", [Module, Node]),
         erpc:call(Node, code, ensure_loaded, [Module]),
         case erpc:call(Node, code, which, [Module]) of
            Filename when is_binary(Filename) orelse is_list(Filename) ->
               %% File exists, overwrite and load into VM.
               ok = erpc:call(Node, file, write_file, [Filename, Binary]),
               erpc:call(Node, code, purge, [Module]),

               case erpc:call(Node, code, load_file, [Module]) of
                  {module, Module} ->
                     ?logSuccess("Reloaded(Beam ~p) Mod:~s and write Success on node:~p", [Reason, Module, Node]);
                  {error, What} ->
                     ?logErrors("Reloaded(Beam ~p) Mod:~s and write Errors on node:~p Reason:~p", [Module, Node, What])
               end;
            _ ->
               %% File doesn't exist, just load into VM.
               case erpc:call(Node, code, load_binary, [Module, undefined, Binary]) of
                  {module, Module} ->
                     ?logSuccess("Reloaded(Beam ~p) Mod:~s Success on node:~p", [Reason, Module, Node]);
                  {error, What} ->
                     ?logErrors("Reloaded(Beam ~p) Mod:~s Errors on node:~p Reason:~p", [Reason, Module, Node, What])
               end
         end
      end || Node <- Nodes
   ],
   ?logSuccess("Reloaded(Beam changed) Mod: ~s on ~p nodes:~p", [Module, NumNodes, Nodes]).

recompileChangeSrcFile(Iterator, SwSyncNode) ->
   case maps:next(Iterator) of
      {File, _V, NextIterator} ->
         recompileSrcFile(File, SwSyncNode),
         recompileChangeSrcFile(NextIterator, SwSyncNode);
      _ ->
         ok
   end.

erlydtlCompile(SrcFile, Options) ->
   F =
      fun({outdir, OutDir}, Acc) -> [{out_dir, OutDir} | Acc];
         (OtherOption, Acc) -> [OtherOption | Acc]
      end,
   DtlOptions = lists:foldl(F, [], Options),
   Module = binary_to_atom(lists:flatten(filename:basename(SrcFile, ".dtl") ++ "_dtl")),
   Compiler = erlydtl,
   Compiler:compile(SrcFile, Module, DtlOptions).

elixir_compile(SrcFile, Options) ->
   Outdir = proplists:get_value(outdir, Options),
   Compiler = ':Elixir.Kernel.ParallelCompiler',
   Modules = Compiler:files_to_path([SrcFile], Outdir),
   Loader =
      fun(Module) ->
         Outfile = code:which(Module),
         Binary = file:read_file(Outfile),
         {Module, Binary}
      end,
   Results = lists:map(Loader, Modules),
   {ok, multiple, Results, []}.

lfe_compile(SrcFile, Options) ->
   Compiler = lfe_comp,
   Compiler:file(SrcFile, Options).

getCompileFunAndModuleName(SrcFile) ->
   case getFileType(SrcFile) of
      erl ->
         {fun compile:file/2, binary_to_atom(filename:basename(SrcFile, <<".erl">>))};
      dtl ->
         {fun erlydtlCompile/2, list_to_atom(lists:flatten(binary_to_list(filename:basename(SrcFile, <<".dtl">>)) ++ "_dtl"))};
      lfe ->
         {fun lfe_compile/2, binary_to_atom(filename:basename(SrcFile, <<".lfe">>))};
      elixir ->
         {fun elixir_compile/2, binary_to_atom(filename:basename(SrcFile, <<".ex">>))}
   end.

getObjectCode(Module) ->
   case code:get_object_code(Module) of
      {Module, B, Filename} -> {B, Filename};
      _ -> {undefined, undefined}
   end.

reloadIfNecessary(Module, OldBinary, Binary, Filename, SwSyncNode) ->
   case Binary =/= OldBinary of
      true ->
         %% Try to load the module...
         case code:ensure_loaded(Module) of
            {module, Module} ->
               case code:load_binary(Module, Filename, Binary) of
                  {module, Module} ->
                     ?logSuccess("Reloaded(Beam recompiled) Mod:~s Success", [Module]),
                     syncLoadModOnAllNodes(SwSyncNode, Module, Binary, recompiled);
                  {error, What} ->
                     ?logErrors("Reloaded(Beam recompiled) Mod:~s Errors Reason:~p", [Module, What])
               end;
            {error, nofile} ->
               case code:load_binary(Module, Filename, Binary) of
                  {module, Module} ->
                     ?logSuccess("Reloaded(Beam recompiled) Mod:~s Success", [Module]),
                     syncLoadModOnAllNodes(SwSyncNode, Module, Binary, recompiled);
                  {error, What} ->
                     ?logErrors("Reloaded(Beam recompiled) Mod:~s Errors Reason:~p", [Module, What])
               end;
            {error, embedded} ->
               case code:load_file(Module) of                  %% Module is not yet loaded, load it.
                  {module, Module} -> ok;
                  {error, nofile} ->
                     case code:load_binary(Module, Filename, Binary) of
                        {module, Module} ->
                           ?logSuccess("Reloaded(Beam recompiled) Mod:~s Success", [Module]),
                           syncLoadModOnAllNodes(SwSyncNode, Module, Binary, recompiled);
                        {error, What} ->
                           ?logErrors("Reloaded(Beam recompiled) Mod:~s Errors Reason:~p", [Module, What])
                     end
               end
         end;
      _ ->
         ignore
   end.

recompileSrcFile(SrcFile, SwSyncNode) ->
   %% Get the module, src dir, and options...
   RootSrcDir =
      case getRootSrcDirFromSrcDir(SrcFile) of
         undefined ->
            filename:dirname(SrcFile);
         RetSrcDir ->
            RetSrcDir
      end,
   CurSrcDir = filename:dirname(SrcFile),
   {CompileFun, Module} = getCompileFunAndModuleName(SrcFile),
   {OldBinary, Filename} = getObjectCode(Module),
   case Module == es_gen_ipc orelse getOptions(RootSrcDir) of
      true ->
         ignore;
      {ok, Options} ->
         RightFileDir = binary_to_list(filename:join(CurSrcDir, filename:basename(SrcFile))),
         LastOptions = ?IIF(?esCfgSync:getv(?isJustMem), [binary, return | Options], [return | Options]),
         case CompileFun(RightFileDir, LastOptions) of
            {ok, Module, Binary, Warnings} ->
               printResults(Module, RightFileDir, [], Warnings),
               reloadIfNecessary(Module, OldBinary, Binary, Filename, SwSyncNode),
               {ok, [], Warnings};
            {ok, [{ok, Module, Binary, Warnings}], Warnings2} ->
               printResults(Module, RightFileDir, [], Warnings ++ Warnings2),
               reloadIfNecessary(Module, OldBinary, Binary, Filename, SwSyncNode),
               {ok, [], Warnings ++ Warnings2};
            {ok, multiple, Results, Warnings} ->
               printResults(Module, RightFileDir, [], Warnings),
               [reloadIfNecessary(CompiledModule, OldBinary, Binary, Filename, SwSyncNode) || {CompiledModule, Binary} <- Results],
               {ok, [], Warnings};
            {ok, OtherModule, _Binary, Warnings} ->
               Desc = io_lib:format("Module definition (~p) differs from expected (~s)", [OtherModule, filename:rootname(filename:basename(RightFileDir))]),
               Errors = [{RightFileDir, {0, Module, Desc}}],
               printResults(Module, RightFileDir, Errors, Warnings),
               {ok, Errors, Warnings};
            {error, Errors, Warnings} ->
               printResults(Module, RightFileDir, Errors, Warnings),
               {ok, Errors, Warnings};
            {ok, Module, Warnings} ->
               printResults(Module, RightFileDir, [], Warnings),
               {ok, [], Warnings};
            _Err ->
               ?logErrors("compile Mod:~s Errors Reason:~p", [Module, _Err])
         end;
      undefined ->
         case tryGetModOpts(Module) of
            {ok, Options} ->
               setOptions(RootSrcDir, Options),
               recompileSrcFile(SrcFile, SwSyncNode);
            _ ->
               case tryGetSrcOpts(CurSrcDir) of
                  {ok, Options} ->
                     setOptions(RootSrcDir, Options),
                     recompileSrcFile(SrcFile, SwSyncNode);
                  _ ->
                     ?logErrors("Unable to determine options for ~s", [SrcFile])
               end
         end
   end.

collIncludeCHrls([], AllHrls, CHrls, NewAddMap) ->
   case maps:size(NewAddMap) > 0 of
      true ->
         collIncludeCHrls(maps:keys(NewAddMap), AllHrls, CHrls, #{});
      _ ->
         CHrls
   end;
collIncludeCHrls([OneHrl | LeftCHrls], AllHrls, CHrls, NewAddMap) ->
   {NewCHrls, NNewAddMap} = whoInclude(OneHrl, AllHrls, CHrls, NewAddMap),
   collIncludeCHrls(LeftCHrls, AllHrls, NewCHrls, NNewAddMap).

collIncludeCErls([], _SrcFiles, CSrcs, _NewAddMap) ->
   CSrcs;
collIncludeCErls([Hrl | LeftHrl], SrcFiles, CSrcs, NewAddMap) ->
   {NewCSrcs, NNewAddMap} = whoInclude(Hrl, SrcFiles, CSrcs, NewAddMap),
   collIncludeCErls(LeftHrl, SrcFiles, NewCSrcs, NNewAddMap).

whoInclude(HrlFile, AllFiles, CFiles, NewAddMap) ->
   HrlFileBaseName = filename:basename(HrlFile),
   doMathEveryFile(maps:iterator(AllFiles), HrlFileBaseName, CFiles, NewAddMap).

doMathEveryFile(Iterator, HrlFileBaseName, CFiles, NewAddMap) ->
   case maps:next(Iterator) of
      {OneFile, _V, NextIterator} ->
         case file:open(OneFile, [read, binary]) of
            {ok, IoDevice} ->
               IsInclude = doMathEveryLine(IoDevice, HrlFileBaseName),
               file:close(IoDevice),
               case IsInclude of
                  true ->
                     case maps:is_key(OneFile, CFiles) of
                        true ->
                           doMathEveryFile(NextIterator, HrlFileBaseName, CFiles, NewAddMap);
                        _ ->
                           doMathEveryFile(NextIterator, HrlFileBaseName, CFiles#{OneFile => 1}, NewAddMap#{OneFile => 1})
                     end;
                  _ ->
                     doMathEveryFile(NextIterator, HrlFileBaseName, CFiles, NewAddMap)
               end;
            _ ->
               doMathEveryFile(NextIterator, HrlFileBaseName, CFiles, NewAddMap)
         end;
      _ ->
         {CFiles, NewAddMap}
   end.

%% 注释
%% whoInclude(HrlFile, SrcFiles) ->
%%    HrlFileBaseName = filename:basename(HrlFile),
%%    Pred =
%%       fun(SrcFile, _) ->
%%          {ok, Forms} = epp_dodger:parse_file(SrcFile),
%%          isInclude(binary_to_list(HrlFileBaseName), Forms)
%%       end,
%%    maps:filter(Pred, SrcFiles).
%% isInclude(_HrlFile, []) ->
%%    false;
%% isInclude(HrlFile, [{tree, attribute, _, {attribute, _, [{_, _, IncludeFile}]}} | Forms]) when is_list(IncludeFile) ->
%%    IncludeFileBaseName = filename:basename(IncludeFile),
%%    case IncludeFileBaseName of
%%       HrlFile -> true;
%%       _ -> isInclude(HrlFile, Forms)
%%    end;
%% isInclude(HrlFile, [_SomeForm | Forms]) ->
%%    isInclude(HrlFile, Forms).

doMathEveryLine(IoDevice, HrlFileBaseName) ->
   case file:read_line(IoDevice) of
      {ok, Data} ->
         case re:run(Data, HrlFileBaseName) of
            nomatch ->
               case re:run(Data, <<"->">>) of
                  nomatch ->
                     doMathEveryLine(IoDevice, HrlFileBaseName);
                  _ ->
                     false
               end;
            {match, [{Start, _Len} | _]} ->
               case binary:at(Data, max(Start - 1, 0)) of
                  47 ->                   %% /
                     true;
                  34 ->                   %% "
                     true;
                  _ ->
                     false
               end
         end;
      _ ->
         false
   end.

classifyChangeFile([], Beams, Configs, Hrls, Srcs, ColSrcs, ColHrls, ColConfigs, ColBeams) ->
   {Beams, Configs, Hrls, Srcs, ColSrcs, ColHrls, ColConfigs, ColBeams};
classifyChangeFile([OneFile | LeftFile], Beams, Configs, Hrls, Srcs, ColSrcs, ColHrls, ColConfigs, ColBeams) ->
   CurMTimeSec = dateTimeToSec(filelib:last_modified(OneFile)),
   case filename:extension(OneFile) of
      <<".beam">> ->
         BinMod = binary_to_atom(filename:basename(OneFile, <<".beam">>)),
         case ColBeams of
            #{BinMod := OldMTimeSec} ->
               case CurMTimeSec =/= OldMTimeSec andalso CurMTimeSec =/= 0 of
                  true ->
                     classifyChangeFile(LeftFile, [BinMod | Beams], Configs, Hrls, Srcs, ColSrcs, ColHrls, ColConfigs, ColBeams#{BinMod := CurMTimeSec});
                  _ ->
                     classifyChangeFile(LeftFile, Beams, Configs, Hrls, Srcs, ColSrcs, ColHrls, ColConfigs, ColBeams)
               end;
            _ ->
               classifyChangeFile(LeftFile, [BinMod | Beams], Configs, Hrls, Srcs, ColSrcs, ColHrls, ColConfigs, ColBeams#{BinMod => CurMTimeSec})
         end;
      <<".config">> ->
         AbsFile = filename:absname(OneFile),
         case ColConfigs of
            #{AbsFile := OldMTimeSec} ->
               case CurMTimeSec =/= OldMTimeSec andalso CurMTimeSec =/= 0 of
                  true ->
                     CfgMod = erlang:binary_to_atom(filename:basename(AbsFile, <<".config">>), utf8),
                     classifyChangeFile(LeftFile, Beams, [CfgMod | Configs], Hrls, Srcs, ColSrcs, ColHrls, ColConfigs#{AbsFile := CurMTimeSec}, ColBeams);
                  _ ->
                     classifyChangeFile(LeftFile, Beams, Configs, Hrls, Srcs, ColSrcs, ColHrls, ColConfigs, ColBeams)
               end;
            _ ->
               CfgMod = erlang:binary_to_atom(filename:basename(AbsFile, <<".config">>), utf8),
               classifyChangeFile(LeftFile, Beams, [CfgMod | Configs], Hrls, Srcs, ColSrcs, ColHrls, ColConfigs#{AbsFile => CurMTimeSec}, ColBeams)
         end;
      <<".hrl">> ->
         AbsFile = filename:absname(OneFile),
         case ColHrls of
            #{AbsFile := OldMTimeSec} ->
               case CurMTimeSec =/= OldMTimeSec andalso CurMTimeSec =/= 0 of
                  true ->
                     classifyChangeFile(LeftFile, Beams, Configs, Hrls#{AbsFile => 1}, Srcs, ColSrcs, ColHrls#{AbsFile := CurMTimeSec}, ColConfigs, ColBeams);
                  _ ->
                     classifyChangeFile(LeftFile, Beams, Configs, Hrls, Srcs, ColSrcs, ColHrls, ColConfigs, ColBeams)
               end;
            _ ->
               classifyChangeFile(LeftFile, Beams, Configs, Hrls#{AbsFile => 1}, Srcs, ColSrcs, ColHrls#{AbsFile => CurMTimeSec}, ColConfigs, ColBeams)
         end;
      <<>> ->
         classifyChangeFile(LeftFile, Beams, Configs, Hrls, Srcs, ColSrcs, ColHrls, ColConfigs, ColBeams);
      _ ->
         AbsFile = filename:absname(OneFile),
         case ColSrcs of
            #{AbsFile := OldMTimeSec} ->
               case CurMTimeSec =/= OldMTimeSec andalso CurMTimeSec =/= 0 of
                  true ->
                     classifyChangeFile(LeftFile, Beams, Configs, Hrls, Srcs#{AbsFile => 1}, ColSrcs#{AbsFile := CurMTimeSec}, ColHrls, ColConfigs, ColBeams);
                  _ ->
                     classifyChangeFile(LeftFile, Beams, Configs, Hrls, Srcs, ColSrcs, ColHrls, ColConfigs, ColBeams)
               end;
            _ ->
               classifyChangeFile(LeftFile, Beams, Configs, Hrls, Srcs#{AbsFile => 1}, ColSrcs#{AbsFile => CurMTimeSec}, ColHrls, ColConfigs, ColBeams)
         end
   end.

fileSyncPath(ExecName) ->
   case code:priv_dir(?MODULE) of
      {error, _} ->
         case code:which(?MODULE) of
            Filename when is_list(Filename) ->
               filename:join([filename:dirname(filename:dirname(Filename)), "priv", ExecName]);
            _ ->
               filename:join("../priv", ExecName)
         end;
      Dir ->
         filename:join(Dir, ExecName)
   end.

dateTimeToSec(DateTime) ->
   if
      DateTime == 0 ->
         0;
      true ->
         erlang:universaltime_to_posixtime(DateTime)
   end.

debugInfoKeyFun() ->
   case ?esCfgSync:getv(?debugInfoKeyFun) of
      undefined ->
         {debug_info_key, undefined};
      {Mod, Fun} ->
         Mod:Fun()
   end.
%% ************************************************* utils end   *******************************************************