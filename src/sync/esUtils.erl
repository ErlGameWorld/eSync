-module(esUtils).
-include("erlSync.hrl").

-compile(inline).
-compile({inline_size, 128}).

-export([
   getModSrcDir/1,
   getModOptions/1,
   getFileType/1,
   getSrcDir/1,
   wildcard/2,
   getEnv/2,
   setEnv/2,
   load/2,
   logSuccess/1,
   logErrors/1,
   logWarnings/1,
   getSystemModules/0,
   tryGetModOptions/1
]).

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

getFileType(Source) when is_list(Source) ->
   Ext = filename:extension(Source),
   Root = filename:rootname(Source),
   SecondExt = filename:extension(Root),
   case Ext of
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
         case findIncludeDirFromAncestors(Cwd, IncludeBase, SrcDir) of
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
findIncludeDirFromAncestors(Cwd, _, Cwd) -> undefined;
findIncludeDirFromAncestors(_, _, "/") -> undefined;
findIncludeDirFromAncestors(_, _, ".") -> undefined;
findIncludeDirFromAncestors(_, _, "") -> undefined;
findIncludeDirFromAncestors(Cwd, IncludeBase, Dir) ->
   NewDirName = filename:dirname(Dir),
   AttemptDir = filename:join(NewDirName, IncludeBase),
   case filelib:is_dir(AttemptDir) of
      true ->
         {ok, AttemptDir};
      false ->
         case NewDirName =/= Dir of
            true ->
               findIncludeDirFromAncestors(Cwd, IncludeBase, NewDirName);
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
   case makeDescendantSource(Cwd, PathParts) of
      undefined -> case IsFile of true -> Path; _ -> undefined end;
      FoundPath -> FoundPath
   end.

makeDescendantSource(_Cwd, []) ->
   undefined;
makeDescendantSource(Cwd, [_ | T]) ->
   PathAttempt = filename:join([Cwd | T]),
   case filelib:is_regular(PathAttempt) of
      true -> PathAttempt;
      false -> makeDescendantSource(Cwd, T)
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

%% Return all files in a directory matching a regex.
wildcard(Dir, Regex) ->
   filelib:fold_files(Dir, Regex, true, fun(Y, Acc) -> [Y | Acc] end, []).

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
   case esScanner:getLog() of
      true -> true;
      all -> true;
      none -> false;
      false -> false;
      skip_success -> MsgType == errors orelse MsgType == warnings;
      L when is_list(L) -> lists:member(MsgType, L);
      _ -> false
   end.

%% Return a list of all modules that belong to Erlang rather than whatever application we may be running.
getSystemModules() ->
   Apps = [
      appmon, asn1, common_test, compiler, crypto, debugger,
      dialyzer, docbuilder, edoc, erl_interface, erts, et,
      eunit, gs, hipe, inets, inets, inviso, jinterface, kernel,
      mnesia, observer, orber, os_mon, parsetools, percept, pman,
      reltool, runtime_tools, sasl, snmp, ssl, stdlib, syntax_tools,
      test_server, toolbar, tools, tv, webtool, wx, xmerl, zlib, rebar, rebar3
   ],
   FAppMod =
      fun(App) ->
         case application:get_key(App, modules) of
            {ok, Modules} -> Modules;
            _Other -> []
         end
      end,
   lists:flatten([FAppMod(X) || X <- Apps]).

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

