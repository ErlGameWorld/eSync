-module(esScanner).
-include("erlSync.hrl").

-behaviour(gen_ipc).

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
   handleCast/3,
   handleInfo/3,
   handleOnevent/4,
   terminate/3
]).

-define(SERVER, ?MODULE).

-type timestamp() :: file:date_time() | 0.
-record(state, {
   modules = [] :: [module()]
   , hrlDirs = [] :: [file:filename()]
   , srcDirs = [] :: [file:filename()]
   , hrlFiles = [] :: [file:filename()]
   , srcFiles = [] :: [file:filename()]
   , beamTimes = undefined :: [{module(), timestamp()}] | undefined
   , hrlFileTimes = undefined :: [{file:filename(), timestamp()}] | undefined
   , srcFileTimes = undefined :: [{file:filename(), timestamp()}] | undefined
   , onsyncFun = undefined
   , swSyncNode = false
}).

%% ************************************  API start ***************************
rescan() ->
   gen_ipc:cast(?SERVER, miCollMods),
   gen_ipc:cast(?SERVER, miCollSrcDirs),
   gen_ipc:cast(?SERVER, miCollSrcFiles),
   gen_ipc:cast(?SERVER, miCompareHrlFiles),
   gen_ipc:cast(?SERVER, miCompareSrcFiles),
   gen_ipc:cast(?SERVER, miCompareBeams),
   esUtils:logSuccess("start Scanning source files..."),
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
   loadCfg(),
   esUtils:logSuccess("Console Notifications Enabled"),
   ok;
setLog(_) ->
   esUtils:setEnv(log, none),
   loadCfg(),
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
   gen_ipc:start_link({local, ?SERVER}, ?MODULE, [], []).

%% status :: running | pause
init([]) ->
   erlang:process_flag(trap_exit, true),
   loadCfg(),
   case persistent_term:get(?esRecompileCnt, undefined) of
      undefined ->
         IndexRef = atomics:new(1, [{signed, false}]),
         persistent_term:put(?esRecompileCnt, IndexRef);
      _ ->
         ignore
   end,
   {ok, running, #state{}}.

handleCall(miGetOnsync, _, #state{onsyncFun = OnSync} = State, _From) ->
   {reply, OnSync, State};
handleCall({miSetOnsync, Fun}, _, State, _From) ->
   {reply, ok, State#state{onsyncFun = Fun}};
handleCall(miCurInfo, _, State, _Form) ->
   {reply, {erlang:get(), State}, State};
handleCall(_Request, _, _State, _From) ->
   keepStatusState.

handleCast(miPause, _, State) ->
   {nextStatus, pause, State};
handleCast(miUnpause, _, State) ->
   {nextStatus, running, State};
handleCast(miCollMods, running, State) ->
   AllModules = (erlang:loaded() -- esUtils:getSystemModules()),
   LastCollMods = filterCollMods(AllModules),
   Time = ?esCfgSync:getv(?moduleTime),
   {keepStatus, State#state{modules = LastCollMods}, [?gTimeout(miCollMods, Time)]};
handleCast(miCollSrcDirs, running, #state{modules = Modules} = State) ->
   {USortedSrcDirs, USortedHrlDirs} =
      case ?esCfgSync:getv(srcDirs) of
         undefined ->
            collSrcDirs(Modules, [], []);
         {add, DirsAndOpts} ->
            collSrcDirs(Modules, addSrcDirs(DirsAndOpts), []);
         {only, DirsAndOpts} ->
            collSrcDirs(Modules, [], addSrcDirs(DirsAndOpts))
      end,

   Time = ?esCfgSync:getv(?srcDirTime),
   {keepStatus, State#state{srcDirs = USortedSrcDirs, hrlDirs = USortedHrlDirs}, [?gTimeout(miCollSrcDirs, Time)]};
handleCast(miCollSrcFiles, running, #state{hrlDirs = HrlDirs, srcDirs = SrcDirs} = State) ->
   FSrc =
      fun(Dir, Acc) ->
         esUtils:wildcard(Dir, ".*\\.(erl|dtl|lfe|ex)$") ++ Acc
      end,
   SrcFiles = lists:usort(lists:foldl(FSrc, [], SrcDirs)),
   FHrl =
      fun(Dir, Acc) ->
         esUtils:wildcard(Dir, ".*\\.hrl$") ++ Acc
      end,
   HrlFiles = lists:usort(lists:foldl(FHrl, [], HrlDirs)),
   Time = ?esCfgSync:getv(?srcFileTime),
   {keepStatus, State#state{srcFiles = SrcFiles, hrlFiles = HrlFiles}, [?gTimeout(miCollSrcFiles, Time)]};
handleCast(miCompareBeams, running, #state{modules = Modules, beamTimes = BeamTimes, onsyncFun = OnsyncFun, swSyncNode = SwSyncNode} = State) ->
   BeamTimeList = [{Mod, LastMod} || Mod <- Modules, LastMod <- [modLastmod(Mod)], LastMod =/= 0],
   NewBeamLastMod = lists:usort(BeamTimeList),
   reloadChangedMod(BeamTimes, NewBeamLastMod, SwSyncNode, OnsyncFun, []),
   Time = ?esCfgSync:getv(?compareBeamTime),
   {keepStatus, State#state{beamTimes = NewBeamLastMod}, [?gTimeout(miCompareBeams, Time)]};
handleCast(miCompareSrcFiles, running, #state{srcFiles = SrcFiles, srcFileTimes = SrcFileTimes, swSyncNode = SwSyncNode} = State) ->
   atomics:put(persistent_term:get(?esRecompileCnt), 1, 0),
   %% Create a list of file lastmod times...
   SrcFileTimeList = [{Src, LastMod} || Src <- SrcFiles, LastMod <- [filelib:last_modified(Src)], LastMod =/= 0],
   NewSrcFileLastMod = lists:usort(SrcFileTimeList),
   %% Compare to previous results, if there are changes, then recompile the file...
   recompileChangeSrcFile(SrcFileTimes, NewSrcFileLastMod, SwSyncNode),
   case atomics:get(persistent_term:get(?esRecompileCnt), 1) > 0 of
      true ->
         gen_ipc:cast(?SERVER, miCompareBeams);
      _ ->
         ignore
   end,
   Time = ?esCfgSync:getv(?compareSrcFileTime),
   {keepStatus, State#state{srcFileTimes = NewSrcFileLastMod}, [?gTimeout(miCompareSrcFiles, Time)]};
handleCast(miCompareHrlFiles, running, #state{hrlFiles = HrlFiles, srcFiles = SrcFiles, hrlFileTimes = HrlFileTimes, swSyncNode = SwSyncNode} = State) ->
   atomics:put(persistent_term:get(?esRecompileCnt), 1, 0),
   %% Create a list of file lastmod times...
   HrlFileTimeList = [{Hrl, LastMod} || Hrl <- HrlFiles, LastMod <- [filelib:last_modified(Hrl)], LastMod =/= 0],
   NewHrlFileLastMod = lists:usort(HrlFileTimeList),
   %% Compare to previous results, if there are changes, then recompile src files that depends
   recompileChangeHrlFile(HrlFileTimes, NewHrlFileLastMod, SrcFiles, SwSyncNode),
   case atomics:get(persistent_term:get(?esRecompileCnt), 1) > 0 of
      true ->
         gen_ipc:cast(?SERVER, miCompareBeams);
      _ ->
         ignore
   end,
   Time = ?esCfgSync:getv(?compareSrcFileTime),
   {keepStatus, State#state{hrlFileTimes = NewHrlFileLastMod}, [?gTimeout(miCompareHrlFiles, Time)]};
handleCast({miSyncNode, IsSync}, _, State) ->
   case IsSync of
      true ->
         {keepStatus, State#state{swSyncNode = true}};
      _ ->
         {keepStatus, State#state{swSyncNode = false}}
   end;
handleCast(_Msg, _, _State) ->
   keepStatusState.

handleInfo(_Msg, _, _State) ->
   keepStatusState.

handleOnevent({gTimeout, _}, Msg, Status, State) ->
   handleCast(Msg, Status, State);
handleOnevent(_EventType, _EventContent, _Status, _State) ->
   keepStatusState.

terminate(_Reason, _Status, _State) ->
   ok.

%% ***********************************PRIVATE FUNCTIONS start *******************************************

addSrcDirs(DirsAndOpts) ->
   [
      begin
      %% ensure module out path exists & in our code path list
         case proplists:get_value(outdir, Opts) of
            undefined ->
               true;
            Path ->
               ok = filelib:ensure_dir(Path),
               true = code:add_pathz(Path)
         end,
         setOptions(Dir, Opts),
         Dir
      end || {Dir, Opts} <- DirsAndOpts
   ].

reloadChangedMod([{Module, LastMod} | T1], [{Module, LastMod} | T2], SwSyncNode, OnsyncFun, Acc) ->
   reloadChangedMod(T1, T2, SwSyncNode, OnsyncFun, Acc);
reloadChangedMod([{Module, _} | T1], [{Module, _} | T2], SwSyncNode, OnsyncFun, Acc) ->
   case code:get_object_code(Module) of
      error ->
         Msg = io_lib:format("Error loading object code for ~p", [Module]),
         esUtils:logErrors(Msg),
         reloadChangedMod(T1, T2, SwSyncNode, OnsyncFun, Acc);
      {Module, Binary, Filename} ->
         case code:load_binary(Module, Filename, Binary) of
            {module, Module} ->
               Msg = io_lib:format("Reloaded(Beam changed) Mod:~s Success", [Module]),
               esUtils:logSuccess(Msg);
            {error, What} ->
               Msg = io_lib:format("Reloaded(Beam changed) Mod:~s Errors Reason:~p", [Module, What]),
               esUtils:logErrors(Msg)
         end,
         case SwSyncNode of
            true ->
               {ok, NumNodes, Nodes} = syncLoadModOnAllNodes(Module),
               MsgNodes = io_lib:format("Reloaded(Beam changed) Mod:~s on ~p nodes:~p", [Module, NumNodes, Nodes]),
               esUtils:logSuccess(MsgNodes);
            false ->
               ignore
         end,
         reloadChangedMod(T1, T2, SwSyncNode, OnsyncFun, [Module | Acc])
   end;
reloadChangedMod([{Module1, _LastMod1} | T1] = OldLastMods, [{Module2, _LastMod2} | T2] = NewLastMods, SwSyncNode, OnsyncFun, Acc) ->
   %% Lists are different, advance the smaller one...
   case Module1 < Module2 of
      true ->
         reloadChangedMod(T1, NewLastMods, SwSyncNode, OnsyncFun, Acc);
      false ->
         reloadChangedMod(OldLastMods, T2, SwSyncNode, OnsyncFun, Acc)
   end;
reloadChangedMod(A, B, _SwSyncNode, OnsyncFun, Acc) when A =:= []; B =:= [] ->
   fireOnsync(OnsyncFun, Acc),
   ok;
reloadChangedMod(undefined, _Other, _, _, _) ->
   ok.

fireOnsync(OnsyncFun, Modules) ->
   case OnsyncFun of
      undefined -> ok;
      Funs when is_list(Funs) -> onsyncApplyList(Funs, Modules);
      Fun -> onsyncApply(Fun, Modules)
   end.

onsyncApplyList(Funs, Modules) ->
   [onsyncApply(Fun, Modules) || Fun <- Funs].

onsyncApply({M, F}, Modules) ->
   erlang:apply(M, F, [Modules]);
onsyncApply(Fun, Modules) when is_function(Fun) ->
   Fun(Modules).

getNodes() ->
   lists:usort(lists:flatten(nodes() ++ [rpc:call(X, erlang, nodes, []) || X <- nodes()])) -- [node()].

syncLoadModOnAllNodes(Module) ->
   %% Get a list of nodes known by this node, plus all attached nodes.
   Nodes = getNodes(),
   NumNodes = length(Nodes),
   {Module, Binary, _} = code:get_object_code(Module),
   FSync =
      fun(Node) ->
         io:format("[~s:~p] DEBUG - Node: ~p", [?MODULE, ?LINE, Node]),
         Msg = io_lib:format("Reloading '~s' on ~s", [Module, Node]),
         esUtils:logSuccess(Msg),
         rpc:call(Node, code, ensure_loaded, [Module]),
         case rpc:call(Node, code, which, [Module]) of
            Filename when is_binary(Filename) orelse is_list(Filename) ->
               %% File exists, overwrite and load into VM.
               ok = rpc:call(Node, file, write_file, [Filename, Binary]),
               rpc:call(Node, code, purge, [Module]),

               case rpc:call(Node, code, load_file, [Module]) of
                  {module, Module} ->
                     Msg = io_lib:format("Reloaded(Beam changed) Mod:~s and write Success on node:~p", [Node, Module]),
                     esUtils:logSuccess(Msg);
                  {error, What} ->
                     Msg = io_lib:format("Reloaded(Beam changed) Mod:~s and write Errors on node:~p Reason:~p", [Module, Node, What]),
                     esUtils:logErrors(Msg)
               end;
            _ ->
               %% File doesn't exist, just load into VM.
               case rpc:call(Node, code, load_binary, [Module, undefined, Binary]) of
                  {module, Module} ->
                     Msg = io_lib:format("Reloaded(Beam changed) Mod:~s Success on node:~p", [Node, Module]),
                     esUtils:logSuccess(Msg);
                  {error, What} ->
                     Msg = io_lib:format("Reloaded(Beam changed) Mod:~s Errors on node:~p Reason:~p", [Module, Node, What]),
                     esUtils:logErrors(Msg)
               end
         end
      end,
   [FSync(X) || X <- Nodes],
   {ok, NumNodes, Nodes}.

recompileChangeSrcFile([{File, LastMod} | T1], [{File, LastMod} | T2], SwSyncNode) ->
   recompileChangeSrcFile(T1, T2, SwSyncNode);
recompileChangeSrcFile([{File, _} | T1], [{File, _} | T2], SwSyncNode) ->
   recompileSrcFile(File, SwSyncNode),
   recompileChangeSrcFile(T1, T2, SwSyncNode);
recompileChangeSrcFile([{File1, _LastMod1} | T1] = OldSrcFiles, [{File2, LastMod2} | T2] = NewSrcFiles, SwSyncNode) ->
   %% Lists are different...
   case File1 < File2 of
      true ->
         %% File was removed, do nothing...
         recompileChangeSrcFile(T1, NewSrcFiles, SwSyncNode);
      false ->
         maybeRecompileSrcFile(File2, LastMod2, SwSyncNode),
         recompileChangeSrcFile(OldSrcFiles, T2, SwSyncNode)
   end;
recompileChangeSrcFile([], [{File, LastMod} | T2], SwSyncNode) ->
   maybeRecompileSrcFile(File, LastMod, SwSyncNode),
   recompileChangeSrcFile([], T2, SwSyncNode);
recompileChangeSrcFile(_A, [], _) ->
   %% All remaining files, if any, were removed.
   ok;
recompileChangeSrcFile(undefined, _Other, _) ->
   ok.

erlydtlCompile(SrcFile, Options) ->
   F =
      fun({outdir, OutDir}, Acc) -> [{out_dir, OutDir} | Acc];
         (OtherOption, Acc) -> [OtherOption | Acc]
      end,
   DtlOptions = lists:foldl(F, [], Options),
   Module = list_to_atom(lists:flatten(filename:basename(SrcFile, ".dtl") ++ "_dtl")),
   Compiler = erlydtl,
   Compiler:compile(SrcFile, Module, DtlOptions).

elixir_compile(SrcFile, Options) ->
   Outdir = proplists:get_value(outdir, Options),
   Compiler = ':Elixir.Kernel.ParallelCompiler',
   Modules = Compiler:files_to_path([list_to_binary(SrcFile)], list_to_binary(Outdir)),
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

maybeRecompileSrcFile(File, LastMod, SwSyncNode) ->
   Module = list_to_atom(filename:basename(File, ".erl")),
   case code:which(Module) of
      BeamFile when is_list(BeamFile) ->
         %% check with beam file
         case filelib:last_modified(BeamFile) of
            BeamLastMod when LastMod > BeamLastMod ->
               recompileSrcFile(File, SwSyncNode);
            _ ->
               ok
         end;
      _ ->
         %% File is new, recompile...
         recompileSrcFile(File, SwSyncNode)
   end.

getCompileFunAndModuleName(SrcFile) ->
   case esUtils:getFileType(SrcFile) of
      erl ->
         {fun compile:file/2, list_to_atom(filename:basename(SrcFile, ".erl"))};
      dtl ->
         {fun erlydtlCompile/2, list_to_atom(lists:flatten(filename:basename(SrcFile, ".dtl") ++ "_dtl"))};
      lfe ->
         {fun lfe_compile/2, list_to_atom(filename:basename(SrcFile, ".lfe"))};
      elixir ->
         {fun elixir_compile/2, list_to_atom(filename:basename(SrcFile, ".ex"))}
   end.

getObjectCode(Module) ->
   case code:get_object_code(Module) of
      {Module, B, _Filename} -> B;
      _ -> undefined
   end.

reloadIfNecessary(_CompileFun, _SrcFile, _Module, Binary, Binary, _Options) ->
   ok;
reloadIfNecessary(CompileFun, SrcFile, Module, _OldBinary, _Binary, Options) ->
   %% Compiling changed the beam code. Compile and reload.
   CompileFun(SrcFile, Options),
   %% Try to load the module...
   case code:ensure_loaded(Module) of
      {module, Module} -> ok;
      {error, nofile} -> errorNoFile(Module);
      {error, embedded} ->
         case code:load_file(Module) of                  %% Module is not yet loaded, load it.
            {module, Module} -> ok;
            {error, nofile} -> errorNoFile(Module)
         end
   end,
   atomics:add(persistent_term:get(?esRecompileCnt), 1, 1).

errorNoFile(Module) ->
   Msg = io_lib:format("~p Couldn't load module: nofile", [Module]),
   esUtils:logWarnings([Msg]).

recompileSrcFile(SrcFile, _SwSyncNode) ->
   %% Get the module, src dir, and options...
   case esUtils:getSrcDir(SrcFile) of
      {ok, SrcDir} ->
         {CompileFun, Module} = getCompileFunAndModuleName(SrcFile),
         OldBinary = getObjectCode(Module),
         case getOptions(SrcDir) of
            {ok, Options} ->
               case CompileFun(SrcFile, [binary, return | Options]) of
                  {ok, Module, Binary, Warnings} ->
                     reloadIfNecessary(CompileFun, SrcFile, Module, OldBinary, Binary, Options),
                     printResults(Module, SrcFile, [], Warnings),
                     {ok, [], Warnings};
                  {ok, [{ok, Module, Binary, Warnings}], Warnings2} ->
                     reloadIfNecessary(CompileFun, SrcFile, Module, OldBinary, Binary, Options),
                     printResults(Module, SrcFile, [], Warnings ++ Warnings2),
                     {ok, [], Warnings ++ Warnings2};
                  {ok, multiple, Results, Warnings} ->
                     [reloadIfNecessary(CompileFun, SrcFile, CompiledModule, OldBinary, Binary, Options) || {CompiledModule, Binary} <- Results],
                     printResults(Module, SrcFile, [], Warnings),
                     {ok, [], Warnings};
                  {ok, OtherModule, _Binary, Warnings} ->
                     Desc = io_lib:format("Module definition (~p) differs from expected (~s)", [OtherModule, filename:rootname(filename:basename(SrcFile))]),
                     Errors = [{SrcFile, {0, Module, Desc}}],
                     printResults(Module, SrcFile, Errors, Warnings),
                     {ok, Errors, Warnings};
                  {error, Errors, Warnings} ->
                     printResults(Module, SrcFile, Errors, Warnings),
                     {ok, Errors, Warnings}
               end;
            undefined ->
               Msg = io_lib:format("Unable to determine options for ~p", [SrcFile]),
               esUtils:logErrors(Msg)
         end;
      _ ->
         Msg = io_lib:format("not find the file ~p", [SrcFile]),
         esUtils:logErrors(Msg)
   end.

printResults(_Module, SrcFile, [], []) ->
   Msg = io_lib:format("~s Recompiled", [SrcFile]),
   esUtils:logSuccess(lists:flatten(Msg));
printResults(_Module, SrcFile, [], Warnings) ->
   Msg = [formatErrors(SrcFile, [], Warnings), io_lib:format("~s Recompiled with ~p warnings", [SrcFile, length(Warnings)])],
   esUtils:logWarnings(Msg);

printResults(_Module, SrcFile, Errors, Warnings) ->
   Msg = [formatErrors(SrcFile, Errors, Warnings)],
   esUtils:logErrors(Msg).


%% @private Print error messages in a pretty and user readable way.
formatErrors(File, Errors, Warnings) ->
   AllErrors1 = lists:sort(lists:flatten([X || {_, X} <- Errors])),
   AllErrors2 = [{Line, "Error", Module, Description} || {Line, Module, Description} <- AllErrors1],
   AllWarnings1 = lists:sort(lists:flatten([X || {_, X} <- Warnings])),
   AllWarnings2 = [{Line, "Warning", Module, Description} || {Line, Module, Description} <- AllWarnings1],
   Everything = lists:sort(AllErrors2 ++ AllWarnings2),
   FPck =
      fun({Line, Prefix, Module, ErrorDescription}) ->
         Msg = formatError(Module, ErrorDescription),
         io_lib:format("~s:~p: ~s: ~s", [File, Line, Prefix, Msg])
      end,
   [FPck(X) || X <- Everything].

formatError(Module, ErrorDescription) ->
   case erlang:function_exported(Module, format_error, 1) of
      true -> Module:format_error(ErrorDescription);
      false -> io_lib:format("~s", [ErrorDescription])
   end.

recompileChangeHrlFile([{File, LastMod} | T1], [{File, LastMod} | T2], SrcFiles, SwSyncNode) ->
   recompileChangeHrlFile(T1, T2, SrcFiles, SwSyncNode);
recompileChangeHrlFile([{File, _} | T1], [{File, _} | T2], SrcFiles, SwSyncNode) ->
   WhoInclude = whoInclude(File, SrcFiles),
   [recompileSrcFile(SrcFile, SwSyncNode) || SrcFile <- WhoInclude],
   recompileChangeHrlFile(T1, T2, SrcFiles, SwSyncNode);
recompileChangeHrlFile([{File1, _LastMod1} | T1] = OldHrlFiles, [{File2, LastMod2} | T2] = NewHrlFiles, SrcFiles, SwSyncNode) ->
   %% Lists are different...
   case File1 < File2 of
      true ->
         %% File was removed, do nothing...
         warnDelHrlFiles(File1, SrcFiles),
         recompileChangeHrlFile(T1, NewHrlFiles, SrcFiles, SwSyncNode);
      false ->
         %% File is new, look for src that include it
         WhoInclude = whoInclude(File2, SrcFiles),
         [maybeRecompileSrcFile(SrcFile, LastMod2, SwSyncNode) || SrcFile <- WhoInclude],
         recompileChangeHrlFile(OldHrlFiles, T2, SrcFiles, SwSyncNode)
   end;
recompileChangeHrlFile([], [{File, LastMod} | T2], SrcFiles, SwSyncNode) ->
   WhoInclude = whoInclude(File, SrcFiles),
   [maybeRecompileSrcFile(SrcFile, LastMod, SwSyncNode) || SrcFile <- WhoInclude],
   recompileChangeHrlFile([], T2, SrcFiles, SwSyncNode);
recompileChangeHrlFile([{File1, _LastMod1} | T1], [], SrcFiles, SwSyncNode) ->
   warnDelHrlFiles(File1, SrcFiles),
   recompileChangeHrlFile(T1, [], SrcFiles, SwSyncNode);
recompileChangeHrlFile([], [], _, _) ->
   %% Done
   ok;
recompileChangeHrlFile(undefined, _Other, _, _) ->
   %% First load, do nothing
   ok.

warnDelHrlFiles(HrlFile, SrcFiles) ->
   WhoInclude = whoInclude(HrlFile, SrcFiles),
   case WhoInclude of
      [] -> ok;
      _ ->
         Msg = io_lib:format("Warning. Deleted ~p file included in existing src files: ~p", [filename:basename(HrlFile), lists:map(fun(File) -> filename:basename(File) end, WhoInclude)]),
         esUtils:logSuccess(lists:flatten(Msg))
   end.

whoInclude(HrlFile, SrcFiles) ->
   HrlFileBaseName = filename:basename(HrlFile),
   Pred =
      fun(SrcFile) ->
         {ok, Forms} = epp_dodger:parse_file(SrcFile),
         isInclude(HrlFileBaseName, Forms)
      end,
   lists:filter(Pred, SrcFiles).

isInclude(_HrlFile, []) ->
   false;
isInclude(HrlFile, [{tree, attribute, _, {attribute, _, [{_, _, IncludeFile}]}} | Forms]) when is_list(IncludeFile) ->
   IncludeFileBaseName = filename:basename(IncludeFile),
   case IncludeFileBaseName of
      HrlFile -> true;
      _ -> isInclude(HrlFile, Forms)
   end;
isInclude(HrlFile, [_SomeForm | Forms]) ->
   isInclude(HrlFile, Forms).

filterCollMods(Modules) ->
   excludeMods(onlyMods(Modules)).

onlyMods(Modules) ->
   case ?esCfgSync:getv(?onlyMods) of
      [] ->
         Modules;
      OnlyMods ->
         [Mod || Mod <- Modules, checkModIsMatch(OnlyMods, Mod) == true]
   end.

excludeMods(Modules) ->
   case ?esCfgSync:getv(?excludedMods) of
      [] ->
         Modules;
      ExcludedModules ->
         [Mod || Mod <- Modules, checkModIsMatch(ExcludedModules, Mod) == false]
   end.

checkModIsMatch([], _Module) ->
   false;
checkModIsMatch([ModOrPattern | T], Module) ->
   case ModOrPattern of
      Module ->
         true;
      _ when is_list(ModOrPattern) ->
         case re:run(atom_to_list(Module), ModOrPattern) of
            {match, _} ->
               true;
            nomatch ->
               checkModIsMatch(T, Module)
         end;
      _ ->
         checkModIsMatch(T, Module)
   end.

collSrcDirs(Modules, AddDirs, OnlyDirs) ->
   FColl =
      fun
         (Mod, {SrcAcc, HrlAcc} = Acc) ->
            case esUtils:getModSrcDir(Mod) of
               {ok, SrcDir} ->
                  case isOnlyDir(OnlyDirs, SrcDir) of
                     true ->
                        {ok, Options} = esUtils:getModOptions(Mod),
                        HrlDir = proplists:get_all_values(i, Options),
                        setOptions(SrcDir, Options),
                        {[SrcDir | SrcAcc], HrlDir ++ HrlAcc};
                     _ ->
                        Acc
                  end;
               undefined ->
                  Acc
            end
      end,
   {SrcDirs, HrlDirs} = lists:foldl(FColl, {AddDirs, []}, Modules),
   USortedSrcDirs = lists:usort(SrcDirs),
   USortedHrlDirs = lists:usort(HrlDirs),
   {USortedSrcDirs, USortedHrlDirs}.

isOnlyDir([], _) ->
   true;
isOnlyDir(ReplaceDirs, SrcDir) ->
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

modLastmod(Mod) ->
   case code:which(Mod) of
      Beam when is_list(Beam) ->
         filelib:last_modified(Beam);
      _Other ->
         0 %% non_existing | cover_compiled | preloaded
   end.

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
         NewOptions = lists:usort(Options ++ OldOptions),
         erlang:put(SrcDir, NewOptions)
   end.

loadCfg() ->
   KVs = [{Key, esUtils:getEnv(Key, DefVal)} || {Key, DefVal} <- ?CfgList],
   esUtils:load(?esCfgSync, KVs).
%% ***********************************PRIVATE FUNCTIONS end *********************************************

