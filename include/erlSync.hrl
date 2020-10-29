-define(LOG_ON(Val), Val == true; Val == all; Val == skip_success; is_list(Val), Val =/= []).

-define(gTimeout(Type, Time), {gTimeout, {doSync, Type}, Time, Type}).

-define(TCP_DEFAULT_OPTIONS, [
   binary
   , {packet, 4}
   , {active, true}
   , {reuseaddr, true}
   , {nodelay, false}
   , {delay_send, true}
   , {send_timeout, 15000}
   , {keepalive, true}
   , {exit_on_close, true}]).

-define(Log, log).
-define(moduleTime, moduleTime).
-define(srcDirTime, srcDirTime).
-define(srcFileTime, srcFileTime).
-define(compareBeamTime, compareBeamTime).
-define(compareSrcFileTime, compareSrcFileTime).
-define(listenPort, listenPort).
-define(srcDirs, srcDirs).
-define(onlyMods, onlyMods).
-define(excludedMods, excludedMods).
-define(descendant, descendant).
-define(CfgList, [{?Log, all}, {?moduleTime, 30000}, {?srcDirTime, 6000}, {?srcFileTime, 6000}, {?compareBeamTime, 4000}, {?compareSrcFileTime, 4000}, {?listenPort, 12369}, {?srcDirs, undefined}, {?onlyMods, []}, {?excludedMods, []}, {?descendant, fix}]).

-define(esCfgSync, esCfgSync).

-define(esRecompileCnt, '$esRecompileCnt').