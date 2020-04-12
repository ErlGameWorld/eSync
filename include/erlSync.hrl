-define(LOG_ON(Val), Val == true; Val == all; Val == skip_success; is_list(Val), Val =/= []).

-define(gTimeout(Type, Time), {{gTimeout, Type}, Time, Type}).

-define(Log, log).
-define(moduleTime, moduleTime).
-define(srcDirTime, srcDirTime).
-define(srcFileTime, srcFileTime).
-define(compareBeamTime, compareBeamTime).
-define(compareSrcFileTime, compareSrcFileTime).
-define(srcDirs, srcDirs).
-define(onlyMods, onlyMods).
-define(excludedMods, excludedMods).
-define(descendant, descendant).
-define(CfgList, [{?Log, all}, {?moduleTime, 30000}, {?srcDirTime, 5000}, {?srcFileTime, 5000}, {?compareBeamTime, 3000}, {?compareSrcFileTime, 3000}, {?srcDirs, undefined}, {?onlyMods, []}, {?excludedMods, []}, {?descendant, fix}]).

-define(esCfgSync, esCfgSync).

-define(esRecompileCnt, '$esRecompileCnt').