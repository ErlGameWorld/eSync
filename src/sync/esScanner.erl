-module(esScanner).
-behaviour(gen_ipc).

-compile([export_all, nowarn_export_all]).

%% API
-export([
   start_link/0,
   rescan/0,
   info/0,
   enable_patching/0,
   pause/0,
   unpause/0,
   set_log/1,
   get_log/0
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
-define(PRINT(Var), io:format("DEBUG: ~p:~p - ~p~n~n ~p~n~n", [?MODULE, ?LINE, ??Var, Var])).
-define(LOG_OR_GROWL_ON(Val), Val == true;Val == all;Val == skip_success;is_list(Val), Val =/= []).
-define(LOG_OR_GROWL_OFF(Val), Val == false;F == none;F == []).

-define(moduleTime, moduleTime).
-define(srcDirTime, srcDirTime).
-define(srcFileTime, srcFileTime).
-define(compareBeamTime, compareBeamTime).
-define(compareSrcFileTime, compareSrcFileTime).

-type timestamp() :: file:date_time() | 0.

-record(state, {
   modules = [] :: [module()],
   srcDirs = [] :: [file:filename()],
   hrlDirs = [] :: [file:filename()],
   srcFiles = [] :: [file:filename()],
   hrlFiles = [] :: [file:filename()],
   beamTimes = undefined :: [{module(), timestamp()}] | undefined,
   srcFileTimes = [] :: [{file:filename(), timestamp()}],
   hrlFileTimes = [] :: [{file:filename(), timestamp()}],
   onsyncFun = undefined,
   patching = false
}).

rescan() ->
   io:format("Scanning source files...~n"),
   gen_ipc:cast(?SERVER, miCollMods),
   gen_ipc:cast(?SERVER, miCollSrcDirs),
   gen_ipc:cast(?SERVER, miCollSrcFiles),
   gen_ipc:cast(?SERVER, miCompareSrcFiles),
   gen_ipc:cast(?SERVER, miCompareBeams),
   gen_ipc:cast(?SERVER, miCompareHrlFiles),
   ok.

unpause() ->
   gen_ipc:cast(?SERVER, miUnpause),
   ok.

pause() ->
   esUtils:log_success("Pausing Sync. Call sync:go() to restart~n"),
   gen_ipc:cast(?SERVER, miPause),
   ok.

info() ->
   io:format("Sync Info...~n"),
   gen_ipc:cast(?SERVER, info),
   ok.

set_log(T) when ?LOG_OR_GROWL_ON(T) ->
   esUtils:setEnv(log, T),
   esUtils:log_success("Console Notifications Enabled~n"),
   ok;
set_log(F) when ?LOG_OR_GROWL_OFF(F) ->
   esUtils:log_success("Console Notifications Disabled~n"),
   esUtils:setEnv(log, none),
   ok.

get_log() ->
   esUtils:getEnv(log, all).

enable_patching() ->
   gen_ipc:cast(?SERVER, enable_patching),
   ok.

get_onsync() ->
   gen_ipc:call(?SERVER, miGetOnsync).

set_onsync(Fun) ->
   gen_ipc:call(?SERVER, {miSetOnsync, Fun}).


%% status running | pause

start_link() ->
   gen_ipc:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
   erlang:process_flag(trap_exit, true),
   rescan(),
   startup(),
   {ok, running, #state{}}.

handleCall(miGetOnsync, _, State, _From) ->
   OnSync = State#state.onsyncFun,
   {reply, OnSync, State};
handleCall({miSetOnsync, Fun}, _, State, _From) ->
   State2 = State#state{onsyncFun = Fun},
   {reply, ok, State2};
handleCall(_Request, _, _State, _From) ->
   keepStatusState.

handleCast(miPause, _, State) ->
   {nextStatus, pause, State};
handleCast(miUnpause, _, State) ->
   %% TODO restart
   {nextStatus, running, State};
handleCast(miCollMods, running, State) ->
   % Get a list of all loaded non-system modules.
   AllModules = (erlang:loaded() -- esUtils:getSystemModules()),

   % Delete excluded modules/applications
   CollModules = collMods(AllModules),

   %% Schedule the next interval...
   Time = esUtils:getEnv(?moduleTime, 30000),

   {keepStatus, State#state{modules = CollModules}, [{{gTimeout, miCollMods}, Time, miCollMods}]};

handleCast(miCollSrcDirs, running, State) ->
   {USortedSrcDirs, USortedHrlDirs} =
      case application:get_env(erlSync, srcDirs) of
         undefined ->
            collSrcDirs(State, [], []);
         {ok, {add, DirsAndOpts}} ->
            collSrcDirs(State, dirs(DirsAndOpts), []);
         {ok, {replace, DirsAndOpts}} ->
            collSrcDirs(State, [], dirs(DirsAndOpts))
      end,
   Time = esUtils:getEnv(?srcDirTime, 30000),
   {keepStatus, State#state{srcDirs = USortedSrcDirs, hrlDirs = USortedHrlDirs}, [{{gTimeout, miCollSrcDirs}, Time, miCollSrcDirs}]};

handleCast(miCollSrcFiles, running, State) ->
   %% For each source dir, get a list of source files...
   FErl =
      fun(X, Acc) ->
         esUtils:wildcard(X, ".*\\.(erl|dtl|lfe|ex)$") ++ Acc
      end,
   ErlFiles = lists:usort(lists:foldl(FErl, [], State#state.srcDirs)),

   %% For each include dir, get a list of hrl files...
   FHrl =
      fun(X, Acc) ->
         esUtils:wildcard(X, ".*\\.hrl$") ++ Acc
      end,
   HrlFiles = lists:usort(lists:foldl(FHrl, [], State#state.hrlDirs)),

   %% Schedule the next interval...
   Time = esUtils:getEnv(?srcFileTime, 5000),
   %% Return with updated files...
   {keepStatus, State#state{srcFiles = ErlFiles, hrlFiles = HrlFiles}, [{{gTimeout, miCollSrcFiles}, Time, miCollSrcFiles}]};

handleCast(miCompareBeams, running, #state{onsyncFun = OnsyncFun} = State) ->
   %% Create a list of beam file lastmod times, but filter out modules not having
   %% a valid beam file reference.
   F = fun(X) ->
      case code:which(X) of
         Beam when is_list(Beam) ->
            case filelib:last_modified(Beam) of
               0 ->
                  false; %% file not found
               LastMod ->
                  {true, {X, LastMod}}
            end;
         _Other ->
            false %% non_existing | cover_compiled | preloaded
      end
       end,
   NewBeamLastMod = lists:usort(lists:filtermap(F, State#state.modules)),

   %% Compare to previous results, if there are changes, then reload
   %% the beam...
   reloadChangedMod(State#state.beamTimes, NewBeamLastMod, State#state.patching, OnsyncFun, []),

   Time = esUtils:getEnv(?compareBeamTime, 2000),
   {keepStatus, State#state{beamTimes = NewBeamLastMod}, [{{gTimeout, miCompareBeams}, Time, miCompareBeams}]};

handleCast(miCompareSrcFiles, running, State) ->
   %% Create a list of file lastmod times...
   F =
      fun(X) ->
         LastMod = filelib:last_modified(X),
         {X, LastMod}
      end,
   NewSrcFileLastMod = lists:usort([F(X) || X <- State#state.srcFiles]),

   %% Compare to previous results, if there are changes, then recompile the file...
   recompileChangeSrcFile(State#state.srcFileTimes, NewSrcFileLastMod, State#state.patching),

   %% Schedule the next interval...

   Time = esUtils:getEnv(?compareSrcFileTime, 2000),
   {keepStatus, State#state{srcFileTimes = NewSrcFileLastMod}, [{{gTimeout, miCompareSrcFiles}, Time, miCompareSrcFiles}]};

handleCast(miCompareHrlFiles, running, State) ->
   %% Create a list of file lastmod times...
   F =
      fun(X) ->
         LastMod = filelib:last_modified(X),
         {X, LastMod}
      end,
   NewHrlFileLastMod = lists:usort([F(X) || X <- State#state.hrlFiles]),

   %% Compare to previous results, if there are changes, then recompile src files that depends
   recompileChangeHrlFile(State#state.hrlFileTimes, NewHrlFileLastMod, State#state.srcFiles, State#state.patching),

   %% Schedule the next interval...
   Time = esUtils:getEnv(?compareSrcFileTime, 2000),
   {keepStatus, State#state{hrlFileTimes = NewHrlFileLastMod}, [{{gTimeout, miCompareHrlFiles}, Time, miCompareHrlFiles}]};

handleCast(info, _, State) ->
   io:format("Modules: ~p~n", [State#state.modules]),
   io:format("Source Dirs: ~p~n", [State#state.srcDirs]),
   io:format("Source Files: ~p~n", [State#state.srcFiles]),
   {noreply, State};

handleCast(enable_patching, _, State) ->
   NewState = State#state{patching = true},
   {noreply, NewState};

handleCast(_Msg, _, _State) ->
   keepStatusState.

handleInfo(_Msg, _, _State) ->
   keepStatusState.

handleOnevent({gTimeout, _}, Msg, Status, State) ->
   handleCast(Msg, Status, State);
handleOnevent(_EventType, _EventContent, _Status, _State) ->
   keepStatusState.


dirs(DirsAndOpts) ->
   [
      begin
      %% ensure module out path exists & in our code list
         case proplists:get_value(outdir, Opts) of
            undefined ->
               true;
            Path ->
               ok = filelib:ensure_dir(Path),
               true = code:add_pathz(Path)
         end,
         setOptions(Dir, Opts),
         Dir
      end || {Dir, Opts} <- DirsAndOpts].

handle_info(_Info, State) ->
   {noreply, State}.

terminate(_Reason, _Status, _State) ->
   ok.

%%% PRIVATE FUNCTIONS %%%

schedule_cast(Msg, Default, Timers) ->
   %% Cancel the old timer...
   TRef = proplists:get_value(Msg, Timers),
   timer:cancel(TRef),

   %% Lookup the interval...
   IntervalKey = list_to_atom(atom_to_list(Msg) ++ "_interval"),
   Interval = esUtils:getEnv(IntervalKey, Default),

   %% Schedule the call...
   {ok, NewTRef} = timer:apply_after(Interval, gen_ipc, cast, [?SERVER, Msg]),

   %% Return the new timers structure...
   lists:keystore(Msg, 1, Timers, {Msg, NewTRef}).

reloadChangedMod([{Module, LastMod} | T1], [{Module, LastMod} | T2], EnablePatching, OnsyncFun, Acc) ->
   %% Beam hasn't changed, do nothing...
   reloadChangedMod(T1, T2, EnablePatching, OnsyncFun, Acc);
reloadChangedMod([{Module, _} | T1], [{Module, _} | T2], EnablePatching, OnsyncFun, Acc) ->
   %% Beam has changed, reload...
   case code:get_object_code(Module) of
      error ->
         Msg = io_lib:format("Error loading object code for ~p~n", [Module]),
         esUtils:log_errors(Msg),
         reloadChangedMod(T1, T2, EnablePatching, OnsyncFun, Acc);
      {Module, Binary, Filename} ->
         code:load_binary(Module, Filename, Binary),
         %% If patching is enabled, then reload the module across *all* connected
         %% erlang VMs, and save the compiled beam to disk.
         case EnablePatching of
            true ->
               {ok, NumNodes} = syncLoadModOnAllNodes(Module),
               Msg = io_lib:format("~s: Reloaded on ~p nodes! (Beam changed.)~n", [Module, NumNodes]),
               esUtils:log_success(Msg);
            false ->
               %% Print a status message...
               Msg = io_lib:format("~s: Reloaded! (Beam changed.)~n", [Module]),
               esUtils:log_success(Msg)
         end,
         reloadChangedMod(T1, T2, EnablePatching, OnsyncFun, [Module | Acc])
   end;

reloadChangedMod([{Module1, _LastMod1} | T1] = OldLastMods, [{Module2, _LastMod2} | T2] = NewLastMods, EnablePatching, OnsyncFun, Acc) ->
   %% Lists are different, advance the smaller one...
   case Module1 < Module2 of
      true ->
         reloadChangedMod(T1, NewLastMods, EnablePatching, OnsyncFun, Acc);
      false ->
         reloadChangedMod(OldLastMods, T2, EnablePatching, OnsyncFun, Acc)
   end;
reloadChangedMod(A, B, _EnablePatching, OnsyncFun, Acc) when A =:= []; B =:= [] ->
   % MsgAdd =
   %    case EnablePatching of
   %             true -> " on " ++ integer_to_list(length(get_nodes())) ++ " nodes.";
   %             false -> "."
   %          end,
   %% Done.
   fireOnsync(OnsyncFun, Acc),
   ok;
reloadChangedMod(undefined, _Other, _, _, _) ->
   %% First load, do nothing.
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
   %% Get a list of nodes known by this node, plus all attached
   %% nodes.
   Nodes = getNodes(),
   io:format("[~s:~p] DEBUG - Nodes: ~p~n", [?MODULE, ?LINE, Nodes]),
   NumNodes = length(Nodes),

   {Module, Binary, _} = code:get_object_code(Module),
   FSync =
      fun(Node) ->
         io:format("[~s:~p] DEBUG - Node: ~p~n", [?MODULE, ?LINE, Node]),
         Msg = io_lib:format("Reloading '~s' on ~s.~n", [Module, Node]),
         esUtils:log_success(Msg),
         rpc:call(Node, code, ensure_loaded, [Module]),
         case rpc:call(Node, code, which, [Module]) of
            Filename when is_binary(Filename) orelse is_list(Filename) ->
               %% File exists, overwrite and load into VM.
               ok = rpc:call(Node, file, write_file, [Filename, Binary]),
               rpc:call(Node, code, purge, [Module]),
               {module, Module} = rpc:call(Node, code, load_file, [Module]);
            _ ->
               %% File doesn't exist, just load into VM.
               {module, Module} = rpc:call(Node, code, load_binary, [Module, undefined, Binary])
         end
      end,
   [FSync(X) || X <- Nodes],
   {ok, NumNodes}.

recompileChangeSrcFile([{File, LastMod} | T1], [{File, LastMod} | T2], EnablePatching) ->
   %% Beam hasn't changed, do nothing...
   recompileChangeSrcFile(T1, T2, EnablePatching);
recompileChangeSrcFile([{File, _} | T1], [{File, _} | T2], EnablePatching) ->
   %% File has changed, recompile...
   recompileSrcFile(File, EnablePatching),
   recompileChangeSrcFile(T1, T2, EnablePatching);
recompileChangeSrcFile([{File1, _LastMod1} | T1] = OldSrcFiles, [{File2, LastMod2} | T2] = NewSrcFiles, EnablePatching) ->
   %% Lists are different...
   case File1 < File2 of
      true ->
         %% File was removed, do nothing...
         recompileChangeSrcFile(T1, NewSrcFiles, EnablePatching);
      false ->
         maybeRecompileSrcFile(File2, LastMod2, EnablePatching),
         recompileChangeSrcFile(OldSrcFiles, T2, EnablePatching)
   end;
recompileChangeSrcFile([], [{File, LastMod} | T2], EnablePatching) ->
   maybeRecompileSrcFile(File, LastMod, EnablePatching),
   recompileChangeSrcFile([], T2, EnablePatching);
recompileChangeSrcFile(_A, [], _) ->
   %% All remaining files, if any, were removed.
   ok;
recompileChangeSrcFile(undefined, _Other, _) ->
   %% First load, do nothing.
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

maybeRecompileSrcFile(File, LastMod, EnablePatching) ->
   Module = list_to_atom(filename:basename(File, ".erl")),
   case code:which(Module) of
      BeamFile when is_list(BeamFile) ->
         %% check with beam file
         case filelib:last_modified(BeamFile) of
            BeamLastMod when LastMod > BeamLastMod ->
               recompileSrcFile(File, EnablePatching);
            _ ->
               ok
         end;
      _ ->
         %% File is new, recompile...
         recompileSrcFile(File, EnablePatching)
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

reloadIfNecessary(_CompileFun, SrcFile, Module, Binary, Binary, _Options, Warnings) ->
   %% Compiling didn't change the beam code. Don't reload...
   printResults(Module, SrcFile, [], Warnings),
   {ok, [], Warnings};

reloadIfNecessary(CompileFun, SrcFile, Module, _OldBinary, _Binary, Options, Warnings) ->
   %% Compiling changed the beam code. Compile and reload.
   CompileFun(SrcFile, Options),
   %% Try to load the module...
   case code:ensure_loaded(Module) of
      {module, Module} -> ok;
      {error, nofile} -> errorNoFile(Module);
      {error, embedded} ->
         %% Module is not yet loaded, load it.
         case code:load_file(Module) of
            {module, Module} -> ok;
            {error, nofile} -> errorNoFile(Module)
         end
   end,
   gen_ipc:cast(?SERVER, miCompareBeams),

   %% Print the warnings...
   printResults(Module, SrcFile, [], Warnings),
   {ok, [], Warnings}.

errorNoFile(Module) ->
   Msg = io_lib:format("~p:0: Couldn't load module: nofile~n", [Module]),
   esUtils:log_warnings([Msg]).

recompileSrcFile(SrcFile, _EnablePatching) ->
   %% Get the module, src dir, and options...
   {ok, SrcDir} = esUtils:getSrcDir(SrcFile),
   {CompileFun, Module} = getCompileFunAndModuleName(SrcFile),

   %% Get the old binary code...
   OldBinary = getObjectCode(Module),

   case getOptions(SrcDir) of
      {ok, Options} ->
         case CompileFun(SrcFile, [binary, return | Options]) of
            {ok, Module, Binary, Warnings} ->
               reloadIfNecessary(CompileFun, SrcFile, Module, OldBinary, Binary, Options, Warnings);

            {ok, [{ok, Module, Binary, Warnings}], Warnings2} ->
               reloadIfNecessary(CompileFun, SrcFile, Module, OldBinary, Binary, Options, Warnings ++ Warnings2);

            {ok, multiple, Results, Warnings} ->
               Reloader =
                  fun({CompiledModule, Binary}) ->
                     {ok, _, _} = reloadIfNecessary(CompileFun, SrcFile, CompiledModule, OldBinary, Binary, Options, Warnings)
                  end,
               lists:foreach(Reloader, Results),
               {ok, [], Warnings};

            {ok, OtherModule, _Binary, Warnings} ->
               Desc = io_lib:format("Module definition (~p) differs from expected (~s)", [OtherModule, filename:rootname(filename:basename(SrcFile))]),

               Errors = [{SrcFile, {0, Module, Desc}}],
               printResults(Module, SrcFile, Errors, Warnings),
               {ok, Errors, Warnings};

            {error, Errors, Warnings} ->
               %% Compiling failed. Print the warnings and errors...
               printResults(Module, SrcFile, Errors, Warnings),
               {ok, Errors, Warnings}
         end;
      undefined ->
         Msg = io_lib:format("Unable to determine options for ~p", [SrcFile]),
         esUtils:log_errors(Msg)
   end.


printResults(Module, SrcFile, [], []) ->
   Msg = io_lib:format("~s:0: Recompiled.~n", [SrcFile]),
   case code:is_loaded(Module) of
      {file, _} ->
         ok;
      false ->
         ignore
   end,
   esUtils:log_success(lists:flatten(Msg));

printResults(_Module, SrcFile, [], Warnings) ->
   Msg = [
      formatErrors(SrcFile, [], Warnings),
      io_lib:format("~s:0: Recompiled with ~p warnings~n", [SrcFile, length(Warnings)])
   ],
   esUtils:log_warnings(Msg);

printResults(_Module, SrcFile, Errors, Warnings) ->
   Msg = [formatErrors(SrcFile, Errors, Warnings)],
   esUtils:log_errors(Msg).


%% @private Print error messages in a pretty and user readable way.
formatErrors(File, Errors, Warnings) ->
   AllErrors1 = lists:sort(lists:flatten([X || {_, X} <- Errors])),
   AllErrors2 = [{Line, "Error", Module, Description} || {Line, Module, Description} <- AllErrors1],
   AllWarnings1 = lists:sort(lists:flatten([X || {_, X} <- Warnings])),
   AllWarnings2 = [{Line, "Warning", Module, Description} || {Line, Module, Description} <- AllWarnings1],
   Everything = lists:sort(AllErrors2 ++ AllWarnings2),
   F = fun({Line, Prefix, Module, ErrorDescription}) ->
      Msg = formatError(Module, ErrorDescription),
      io_lib:format("~s:~p: ~s: ~s~n", [File, Line, Prefix, Msg])
       end,
   [F(X) || X <- Everything].

formatError(Module, ErrorDescription) ->
   case erlang:function_exported(Module, format_error, 1) of
      true -> Module:format_error(ErrorDescription);
      false -> io_lib:format("~s", [ErrorDescription])
   end.

recompileChangeHrlFile([{File, LastMod} | T1], [{File, LastMod} | T2], SrcFiles, Patching) ->
   %% Hrl hasn't changed, do nothing...
   recompileChangeHrlFile(T1, T2, SrcFiles, Patching);
recompileChangeHrlFile([{File, _} | T1], [{File, _} | T2], SrcFiles, Patching) ->
   %% File has changed, recompile...
   WhoInclude = whoInclude(File, SrcFiles),
   [recompileSrcFile(SrcFile, Patching) || SrcFile <- WhoInclude],
   recompileChangeHrlFile(T1, T2, SrcFiles, Patching);
recompileChangeHrlFile([{File1, _LastMod1} | T1] = OldHrlFiles, [{File2, LastMod2} | T2] = NewHrlFiles, SrcFiles, Patching) ->
   %% Lists are different...
   case File1 < File2 of
      true ->
         %% File was removed, do nothing...
         warnDelHrlFiles(File1, SrcFiles),
         recompileChangeHrlFile(T1, NewHrlFiles, SrcFiles, Patching);
      false ->
         %% File is new, look for src that include it
         WhoInclude = whoInclude(File2, SrcFiles),
         [maybeRecompileSrcFile(SrcFile, LastMod2, Patching) || SrcFile <- WhoInclude],
         recompileChangeHrlFile(OldHrlFiles, T2, SrcFiles, Patching)
   end;
recompileChangeHrlFile([], [{File, LastMod} | T2], SrcFiles, Patching) ->
   %% File is new, look for src that include it
   WhoInclude = whoInclude(File, SrcFiles),
   [maybeRecompileSrcFile(SrcFile, LastMod, Patching) || SrcFile <- WhoInclude],
   recompileChangeHrlFile([], T2, SrcFiles, Patching);
recompileChangeHrlFile([{File1, _LastMod1} | T1], [], SrcFiles, Patching) ->
   %% Rest of file(s) removed, warn and process next
   warnDelHrlFiles(File1, SrcFiles),
   recompileChangeHrlFile(T1, [], SrcFiles, Patching);
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
      _ -> io:format(
         "Warning. Deleted ~p file included in existing src files: ~p~n",
         [filename:basename(HrlFile), lists:map(fun(File) -> filename:basename(File) end, WhoInclude)])
   end.

whoInclude(HrlFile, SrcFiles) ->
   HrlFileBaseName = filename:basename(HrlFile),
   Pred = fun(SrcFile) ->
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

collMods(Modules) ->
   excludeMods(whitelistMods(Modules)).

whitelistMods(Modules) ->
   case application:get_env(erlSync, whitelistMods) of
      {ok, []} ->
         Modules;
      {ok, WhitelistMods} ->
         [Mod || Mod <- Modules, checkModIsMatch(Mod, WhitelistMods) == true];
      _ ->
         Modules
   end.

excludeMods(Modules) ->
   case application:get_env(erlSync, excludedMods) of
      {ok, []} ->
         Modules;
      {ok, ExcludedModules} ->
         [Mod || Mod <- Modules, checkModIsMatch(Mod, ExcludedModules) == false];
      _ ->
         Modules
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

collSrcDirs(State, ExtraDirs, ReplaceDirs) ->
   %% Extract the compile / options / source / dir from each module.
   F =
      fun
         (X, {SrcAcc, HrlAcc} = Acc) ->
            %% Get the dir...
            case esUtils:getSrcDirFromMod(X) of
               {ok, SrcDir} ->
                  case isReplaceDir(SrcDir, ReplaceDirs) of
                     true ->
                        %% Get the options, storse under the dir...
                        {ok, Options} = esUtils:getOptionsFromMod(X),
                        %% Store the options for later reference...
                        HrlDir = proplists:get_all_values(i, Options),

                        setOptions(SrcDir, Options),
                        %% Return the dir...
                        {[SrcDir | SrcAcc], HrlDir ++ HrlAcc};
                     _ ->
                        Acc
                  end;
               undefined ->
                  Acc
            end
      end,
   {SrcDirs, HrlDirs} = lists:foldl(F, {ExtraDirs, []}, State#state.modules),
   USortedSrcDirs = lists:usort(SrcDirs),
   USortedHrlDirs = lists:usort(HrlDirs),
   %% InitialDirs = sync_utils:initial_src_dirs(),

   %% Return with updated dirs...
   {USortedSrcDirs, USortedHrlDirs}.

isReplaceDir(_, []) ->
   true;
isReplaceDir(SrcDir, ReplaceDirs) ->
   lists:foldl(
      fun
         (Dir, false) ->
            case re:run(SrcDir, Dir) of
               nomatch -> false;
               _ -> true
            end;
         (_, Acc) -> Acc
      end, false, ReplaceDirs).

%% ***********************************misc fun start *******************************************
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

startup() ->
   io:format("Growl notifications disabled~n").
%% ***********************************misc fun end *********************************************

