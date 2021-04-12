-define(LOG_ON(Val), Val == true; Val == all; Val == skip_success; is_list(Val), Val =/= []).

-define(Log, log).
-define(compileCmd, compileCmd).
-define(extraDirs, extraDirs).
-define(descendant, descendant).
-define(onMSyncFun, onMSyncFun).
-define(onCSyncFun, onCSyncFun).
-define(swSyncNode, swSyncNode).

-define(DefCfgList, [{?Log, all}, {?compileCmd, undefined}, {?extraDirs, undefined}, {?descendant, fix}, {?onMSyncFun, undefined}, {?onCSyncFun, undefined}, {?swSyncNode, false}]).

-define(esCfgSync, esCfgSync).
-define(rootSrcDir, <<"src">>).