-define(LOG_ON(Val), Val == true; Val == all; Val == skip_success; is_list(Val), Val =/= []).

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
-define(compileCmd, compileCmd).
-define(extraDirs, extraDirs).
-define(descendant, descendant).
-define(CfgList, [{?Log, all}, {?compileCmd, undefined}, {?extraDirs, undefined}, {?descendant, fix}]).

-define(esCfgSync, esCfgSync).
-define(rootSrcDir, <<"src">>).