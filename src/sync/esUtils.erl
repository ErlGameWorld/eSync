-module(esUtils).

-include("erlSync.hrl").

-compile(inline).
-compile({inline_size, 128}).
-compile([export_all, nowarn_export_all]).

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
         catch _ : _ : _ ->
            undefined
         end;
      _ ->
         undefined
   end.

getModOptions(Module) ->
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
            {ok, Options6}
         catch ExType:Error:Stacktrace ->
            Msg = [io_lib:format("~p:0: ~p looking for options: ~p. Stack: ~p~n", [Module, ExType, Error, Stacktrace])],
            logWarnings(Msg),
            {ok, []}
         end;
      _ ->
         {ok, []}
   end.

tryGetModOptions(Module) ->
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
      {ok, Options6}
   catch _ExType:_Error:_Stacktrace ->
      undefiend
   end.

tryGetSrcOptions(SrcDir) ->
   %% Then we dig back through the parent directories until we find our include directory
   NewDirName = filename:dirname(SrcDir),
   case getOptions(NewDirName) of
      {ok, _Options} = Opts ->
         Opts;
      _ ->
         case NewDirName =/= SrcDir of
            true ->
               tryGetSrcOptions(NewDirName);
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
   [transformInclude(Module, BeamDir, Opt) || Opt <- Options].

transformInclude(Module, BeamDir, {i, IncludeDir}) ->
   {ok, SrcDir} = getModSrcDir(Module),
   {ok, IncludeDir2} = determineIncludeDir(IncludeDir, BeamDir, SrcDir),
   {i, IncludeDir2};
transformInclude(_, _, Other) ->
   Other.

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
      {ok, D} -> {ok, D};
      undefined ->
         {ok, Cwd} = file:get_cwd(),
         % Cwd2 = normalizeCaseWindowsDir(Cwd),
         % SrcDir2 = normalizeCaseWindowsDir(SrcDir),
         % IncludeBase2 = normalizeCaseWindowsDir(IncludeBase),
         case findIncludeDirFromAncestors(SrcDir, Cwd, IncludeBase) of
            {ok, D} -> {ok, D};
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
   HasCode = filelib:wildcard("*.erl", Dir) /= [] orelse
      filelib:wildcard("*.hrl", Dir) /= [] orelse
      filelib:wildcard("*.dtl", Dir) /= [] orelse
      filelib:wildcard("*.lfe", Dir) /= [] orelse
      filelib:wildcard("*.ex", Dir) /= [],
   if
      HasCode -> {ok, Dir};
      true -> getSrcDir(filename:dirname(Dir), Ctr - 1)
   end.

mergeExtraDirs(IsAddPath) ->
   case ?esCfgSync:getv(?extraDirs) of
      undefined ->
         {[], [], []};
      ExtraList ->
         FunMerge =
            fun(OneExtra, {AddDirs, OnlyDirs, DelDirs} = AllAcc) ->
               case OneExtra of
                  {add, DirsAndOpts} ->
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
                     setelement(1, AllAcc, Adds ++ AddDirs);
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
                     setelement(2, AllAcc, Onlys ++ OnlyDirs);
                  {del, DirsAndOpts} ->
                     Dels =
                        [
                           begin
                              filename:absname(Dir)
                           end || {Dir, _Opts} <- DirsAndOpts
                        ],
                     setelement(3, AllAcc, Dels ++ DelDirs)
               end
            end,
         lists:foldl(FunMerge, {[], [], []}, ExtraList)
   end.

collSrcFiles(IsAddPath) ->
   {AddSrcDirs, OnlySrcDirs, DelSrcDirs} = mergeExtraDirs(IsAddPath),
   CollFiles = filelib:fold_files(filename:absname("./"), ".*\\.(erl|dtl|lfe|ex)$", true,
      fun(OneFiles, Acc) ->
         case isOnlyDir(OnlySrcDirs, OneFiles) of
            true ->
               case isDelDir(DelSrcDirs, OneFiles) of
                  false ->
                     SrcDir = list_to_binary(filename:dirname(OneFiles)),
                     case getOptions(SrcDir) of
                        undefined ->
                           Mod = list_to_atom(filename:basename(OneFiles, filename:extension(OneFiles))),
                           {ok, Options} = getModOptions(Mod),
                           setOptions(SrcDir, Options);
                        _ ->
                           ignore
                     end,
                     Acc#{list_to_binary(OneFiles) => 1};
                  _ ->
                     Acc
               end;
            _ ->
               Acc
         end
      end, #{}),

   FunCollAdds =
      fun(OneDir, FilesAcc) ->
         filelib:fold_files(OneDir, ".*\\.(erl|dtl|lfe|ex)$", true, fun(OneFiles, Acc) ->
            Acc#{list_to_binary(OneFiles) => 1} end, FilesAcc)
      end,
   lists:foldl(FunCollAdds, CollFiles, AddSrcDirs).

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
   case application:get_env(erlSync, Var) of
      {ok, Value} ->
         Value;
      _ ->
         Default
   end.

setEnv(Var, Val) ->
   ok = application:set_env(erlSync, Var, Val).

logSuccess(Message) ->
   canLog(success) andalso error_logger:info_msg(lists:flatten(Message)).

logErrors(Message) ->
   canLog(errors) andalso error_logger:error_msg(lists:flatten(Message)).

logWarnings(Message) ->
   canLog(warnings) andalso error_logger:warning_msg(lists:flatten(Message)).

canLog(MsgType) ->
   case esSyncSrv:getLog() of
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
   KVs = [{Key, esUtils:getEnv(Key, DefVal)} || {Key, DefVal} <- ?CfgList],
   esUtils:load(?esCfgSync, KVs).

%% *******************************  加载与编译相关 **********************************************************************
errorNoFile(Module) ->
   Msg = io_lib:format("~p Couldn't load module: nofile", [Module]),
   esUtils:logWarnings([Msg]).

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

reloadChangedMod([], _SwSyncNode, OnsyncFun, Acc) ->
   fireOnsync(OnsyncFun, Acc);
reloadChangedMod([Module | LeftMod], SwSyncNode, OnsyncFun, Acc) ->
   case code:get_object_code(Module) of
      error ->
         Msg = io_lib:format("Error loading object code for ~p", [Module]),
         esUtils:logErrors(Msg),
         reloadChangedMod(LeftMod, SwSyncNode, OnsyncFun, Acc);
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
         reloadChangedMod(LeftMod, SwSyncNode, OnsyncFun, [Module | Acc])
   end.

getNodes() ->
   lists:usort(lists:flatten(nodes() ++ [rpc:call(X, erlang, nodes, []) || X <- nodes()])) -- [node()].

syncLoadModOnAllNodes(Module) ->
   %% Get a list of nodes known by this node, plus all attached nodes.
   Nodes = getNodes(),
   NumNodes = length(Nodes),
   {Module, Binary, _} = code:get_object_code(Module),
   FSync =
      fun(Node) ->
         MsgNode = io_lib:format("Reloading '~s' on ~p", [Module, Node]),
         esUtils:logSuccess(MsgNode),
         rpc:call(Node, code, ensure_loaded, [Module]),
         case rpc:call(Node, code, which, [Module]) of
            Filename when is_binary(Filename) orelse is_list(Filename) ->
               %% File exists, overwrite and load into VM.
               ok = rpc:call(Node, file, write_file, [Filename, Binary]),
               rpc:call(Node, code, purge, [Module]),

               case rpc:call(Node, code, load_file, [Module]) of
                  {module, Module} ->
                     Msg = io_lib:format("Reloaded(Beam changed) Mod:~s and write Success on node:~p", [Module, Node]),
                     esUtils:logSuccess(Msg);
                  {error, What} ->
                     Msg = io_lib:format("Reloaded(Beam changed) Mod:~s and write Errors on node:~p Reason:~p", [Module, Node, What]),
                     esUtils:logErrors(Msg)
               end;
            _ ->
               %% File doesn't exist, just load into VM.
               case rpc:call(Node, code, load_binary, [Module, undefined, Binary]) of
                  {module, Module} ->
                     Msg = io_lib:format("Reloaded(Beam changed) Mod:~s Success on node:~p", [Module, Node]),
                     esUtils:logSuccess(Msg);
                  {error, What} ->
                     Msg = io_lib:format("Reloaded(Beam changed) Mod:~s Errors on node:~p Reason:~p", [Module, Node, What]),
                     esUtils:logErrors(Msg)
               end
         end
      end,
   [FSync(X) || X <- Nodes],
   {ok, NumNodes, Nodes}.

recompileChangeSrcFile([], _SwSyncNode) ->
   ok;
recompileChangeSrcFile([File | LeftFile], SwSyncNode) ->
   recompileSrcFile(File, SwSyncNode),
   recompileChangeSrcFile(LeftFile, SwSyncNode).

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

getCompileFunAndModuleName(SrcFile) ->
   case esUtils:getFileType(SrcFile) of
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


reloadIfNecessary(Module, OldBinary, Binary, Filename) ->
   case Binary =/= OldBinary of
      true ->
         %% Try to load the module...
         case code:ensure_loaded(Module) of
            {module, Module} ->
               case code:load_binary(Module, Filename, Binary) of
                  {module, Module} ->
                     Msg = io_lib:format("Reloaded(Beam changed) Mod:~s Success", [Module]),
                     esUtils:logSuccess(Msg);
                  {error, What} ->
                     Msg = io_lib:format("Reloaded(Beam changed) Mod:~s Errors Reason:~p", [Module, What]),
                     esUtils:logErrors(Msg)
               end;
            {error, nofile} -> errorNoFile(Module);
            {error, embedded} ->
               case code:load_file(Module) of                  %% Module is not yet loaded, load it.
                  {module, Module} -> ok;
                  {error, nofile} -> errorNoFile(Module)
               end
         end;
      _ ->
         ignore
   end.

recompileSrcFile(SrcFile, SwSyncNode) ->
   %% Get the module, src dir, and options...
   SrcDir = filename:dirname(SrcFile),
   {CompileFun, Module} = getCompileFunAndModuleName(SrcFile),
   {OldBinary, Filename}  = getObjectCode(Module),
   case getOptions(SrcDir) of
      {ok, Options} ->
         RightFileDir = binary_to_list(filename:join(SrcDir, filename:basename(SrcFile))),
         case CompileFun(RightFileDir, [binary, return | Options]) of
            {ok, Module, Binary, Warnings} ->
               printResults(Module, RightFileDir, [], Warnings),
               reloadIfNecessary(Module, OldBinary, Binary, Filename),
               {ok, [], Warnings};
            {ok, [{ok, Module, Binary, Warnings}], Warnings2} ->
               printResults(Module, RightFileDir, [], Warnings ++ Warnings2),
               reloadIfNecessary(Module, OldBinary, Binary, Filename),
               {ok, [], Warnings ++ Warnings2};
            {ok, multiple, Results, Warnings} ->
               printResults(Module, RightFileDir, [], Warnings),
               [reloadIfNecessary(CompiledModule, OldBinary, Binary, Filename) || {CompiledModule, Binary} <- Results],
               {ok, [], Warnings};
            {ok, OtherModule, _Binary, Warnings} ->
               Desc = io_lib:format("Module definition (~p) differs from expected (~s)", [OtherModule, filename:rootname(filename:basename(RightFileDir))]),
               Errors = [{RightFileDir, {0, Module, Desc}}],
               printResults(Module, RightFileDir, Errors, Warnings),
               {ok, Errors, Warnings};
            {error, Errors, Warnings} ->
               printResults(Module, RightFileDir, Errors, Warnings),
               {ok, Errors, Warnings}
         end;
      undefined ->
         case esUtils:tryGetModOptions(Module) of
            {ok, Options} ->
               setOptions(SrcDir, Options),
               recompileSrcFile(SrcFile, SwSyncNode);
            _ ->
               case esUtils:tryGetSrcOptions(SrcDir) of
                  {ok, _Options} ->
                     recompileSrcFile(SrcFile, SwSyncNode);
                  _ ->
                     Msg = io_lib:format("Unable to determine options for ~s", [SrcFile]),
                     esUtils:logErrors(Msg)
               end
         end
   end.

recompileChangeHrlFile([], _SrcFiles, _SwSyncNode) ->
   ok;
recompileChangeHrlFile([Hrl | LeftHrl], SrcFiles, SwSyncNode) ->
   WhoInclude = whoInclude(Hrl, SrcFiles),
   [recompileSrcFile(SrcFile, SwSyncNode) || {SrcFile, _} <- maps:to_list(WhoInclude)],
   recompileChangeHrlFile(LeftHrl, SrcFiles, SwSyncNode).

whoInclude(HrlFile, SrcFiles) ->
   HrlFileBaseName = filename:basename(HrlFile),
   Pred =
      fun(SrcFile, _) ->
         {ok, Forms} = epp_dodger:parse_file(SrcFile),
         isInclude(binary_to_list(HrlFileBaseName), Forms)
      end,
   maps:filter(Pred, SrcFiles).

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

dealChangeFile([], Beams, Hrls, Srcs) ->
   {Beams, Hrls, Srcs};
dealChangeFile([OneFile | LeftFile], Beams, Hrls, Srcs) ->
   case filename:extension(OneFile) of
      <<".beam">> ->
         Module = binary_to_atom(filename:basename(OneFile, <<".beam">>)),
         dealChangeFile(LeftFile, [Module | Beams], Hrls, Srcs);
      <<".hrl">> ->
         dealChangeFile(LeftFile, Beams, [OneFile | Hrls], Srcs);
      <<>> ->
         dealChangeFile(LeftFile, Beams, Hrls, Srcs);
      _ ->
         dealChangeFile(LeftFile, Beams, Hrls, [OneFile | Srcs])
   end.

addNewFile([], SrcFiles) ->
   SrcFiles;
addNewFile([OneFile | LeftFile], SrcFiles) ->
   case SrcFiles of
      #{OneFile := _value} ->
         addNewFile(LeftFile, SrcFiles);
      _ ->
         addNewFile(LeftFile, SrcFiles#{OneFile => 1})
   end.