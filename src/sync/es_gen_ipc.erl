-module(es_gen_ipc).

-compile(inline).
-compile({inline_size, 128}).

-include_lib("kernel/include/logger.hrl").

-export([
   %% API for gen_server or gen_statem behaviour
   start/3, start/4, start_link/3, start_link/4
   , start_monitor/3, start_monitor/4
   , stop/1, stop/3
   , cast/2, send/2
   , abcast/2, abcast/3
   , call/2, call/3
   , send_request/2, wait_response/1, wait_response/2, receive_response/1, receive_response/2, check_response/2
   , multi_call/2, multi_call/3, multi_call/4
   , enter_loop/4, enter_loop/5, enter_loop/6
   , reply/1, reply/2

   %% API for gen_event behaviour
   , send_request/3
   , info_notify/2, call_notify/2
   , epm_call/3, epm_call/4, epm_info/3
   , add_epm/3, del_epm/3, add_sup_epm/3
   , swap_epm/3, swap_sup_epm/3
   , which_epm/1

   %% gen callbacks
   , init_it/6

   %% sys callbacks
   , system_continue/3
   , system_terminate/4
   , system_code_change/4
   , system_get_state/1
   , system_replace_state/2
   , format_status/2

   %% Internal callbacks
   , wakeupFromHib/12
   %% logger callback
   , format_log/1
   , format_log/2
   , epm_log/1
]).

% 简写备注**********************************
% isPostpone         isPos
% isHibernate        isHib

% nextEvent          nextE
% nextStatus         nextS

% keepStatus         kpS
% keepStatusState    kpS_S
% repeatStatus       reS
% repeatStatusState  reS_S
% *****************************************

% %% timeout相关宏定义
% -define(REL_TIMEOUT(T), ((is_integer(T) andalso (T) >= 0) orelse (T) =:= infinity)).
% -define(ABS_TIMEOUT(T), (is_integer(T) orelse (T) =:= infinity)).

-define(STACKTRACE(), element(2, erlang:process_info(self(), current_stacktrace))).

-define(CB_FORM_ENTER, 1).             %% 从enter 回调返回
-define(CB_FORM_AFTER, 2).             %% 从after 回调返回
-define(CB_FORM_EVENT, 3).             %% 从event 回调返回

%% debug 调试相关宏定义
-define(NOT_DEBUG, []).
-define(SYS_DEBUG(Debug, Name, SystemEvent),
   case Debug of
      ?NOT_DEBUG ->
         Debug;
      _ ->
         sys:handle_debug(Debug, fun print_event/3, Name, SystemEvent)
   end).

%%%==========================================================================
%%% Interface functions.
%%%==========================================================================
%% gen:call 发送消息来源进程格式类型
-type from() :: {To :: pid(), Tag :: term()}.
-type requestId() :: term().

%% 事件类型
-type eventType() :: externalEventType() | timeoutEventType() | {'onevent', Subtype :: term()}.
-type externalEventType() :: {'call', From :: from()} | 'cast' | 'info'.
-type timeoutEventType() :: GTimeoutName :: term() | 'eTimeout' | 'sTimeout'.              %% 前面的GTimeoutName这个是通用超时标识名

%% 是否捕捉信号 gen_event管理进程需要设置该参数为true
-type isTrapExit() :: boolean().
%% 是否允许进入enter 回调
-type isEnter() :: boolean().
%% 如果为 "true" 则推迟当前事件，并在状态更改时重试(=/=)
-type isPos() :: boolean().
%% 如果为 "true" 则使服务器休眠而不是进入接收状态
-type isHib() :: boolean().

%% 定时器相关
-type timeouts() :: Time :: timeout() | integer().
-type timeoutOption() :: {abs, Abs :: boolean()}.

% gen_event模式下回调模块的标识
-type epmHandler() :: atom() | {atom(), term()}.

%% 在状态更改期间:
%% NextStatus and NewData are set.
%% 按照出现的顺序处理 actions()列表
%% 这些action() 按包含列表中的出现顺序执行。设置选项的选项将覆盖任何以前的选项，因此每种类型的最后一种将获胜。
%% 如果设置了enter 则进入enter回调
%% 如果设置了doAfter 则进入after回调
%% 如果 "postpone" 为 "true"，则推迟当前事件。
%% 如果设置了“超时”，则开始状态超时。 零超时事件将会插入到待处理事件的前面 先执行
%% 如果有postponed 事件则 事件执行顺序为 超时添加和更新 + 零超时 + 当前事件 + 反序的Postpone事件 + LeftEvent
%% 处理待处理的事件，或者如果没有待处理的事件，则服务器进入接收或休眠状态（当“hibernate”为“ true”时）
-type initAction() ::
   {trap_exit, Bool :: isTrapExit()} |                                        % 设置是否捕捉信息 主要用于gen_event模式下
   eventAction().

-type eventAction() ::
   {'doAfter', Args :: term()} |                                           % 设置执行某事件后是否回调 handleAfter
   {'isPos', Bool :: isPos()} |                                            % 设置推迟选项
   {'nextE', EventType :: eventType(), EventContent :: term()} |           % 插入事件作为下一个处理
   commonAction().

-type afterAction() ::
   {'nextE', EventType :: eventType(), EventContent :: term()} |           % 插入事件作为下一个处理
   commonAction().

-type enterAction() ::
   {'isPos', false} |                                                      % 虽然enter action 不能设置postpone 但是可以取消之前event的设置
   commonAction().

-type commonAction() ::
   {'isEnter', Bool :: isEnter()} |
   {'isHib', Bool :: isHib()} |
   timeoutAction() |
   replyAction().

-type timeoutAction() ::
   timeoutNewAction() |
   timeoutCancelAction() |
   timeoutUpdateAction().

-type timeoutNewAction() ::
   {'eTimeout', Time :: timeouts(), EventContent :: term()} |                                                          % Set the event_timeout option
   {'eTimeout', Time :: timeouts(), EventContent :: term(), Options :: ([timeoutOption()])} |                          % Set the event_timeout option
   {'sTimeout', Time :: timeouts(), EventContent :: term()} |                                                          % Set the status_timeout option
   {'sTimeout', Time :: timeouts(), EventContent :: term(), Options :: ([timeoutOption()])} |                          % Set the status_timeout option
   {'gTimeout', Name :: term(), Time :: timeouts(), EventContent :: term()} |                                          % Set the generic_timeout option
   {'gTimeout', Name :: term(), Time :: timeouts(), EventContent :: term(), Options :: ([timeoutOption()])}.           % Set the generic_timeout option



-type timeoutCancelAction() ::
   'c_eTimeout' |                                                                                                      % 不可能也不需要更新此超时，因为任何其他事件都会自动取消它。
   'c_sTimeout' |
   {'c_gTimeout', Name :: term()}.

-type timeoutUpdateAction() ::
   {'u_eTimeout', EventContent :: term()} |                                                                            % 不可能也不需要取消此超时，因为任何其他事件都会自动取消它。
   {'u_sTimeout', EventContent :: term()} |
   {'u_gTimeout', Name :: term(), EventContent :: term()}.

-type actions(ActionType) ::
   ActionType |
   [ActionType, ...].

-type replyAction() ::
   {'reply', From :: from(), Reply :: term()}.

-type eventCallbackResult() ::
   {'reply', Reply :: term(), NewState :: term()} |                                                                    % 用作gen_server模式时快速响应进入消息接收
   {'sreply', Reply :: term(), NextStatus :: term(), NewState :: term()} |                                             % 用作gen_ipc模式便捷式返回reply 而不用把reply放在actions列表中
   {'noreply', NewState :: term()} |                                                                                   % 用作gen_server模式时快速响应进入消息接收
   {'reply', Reply :: term(), NewState :: term(), Options :: hibernate | {doAfter, Args}} |                            % 用作gen_server模式时快速响应进入消息接收
   {'sreply', Reply :: term(), NextStatus :: term(), NewState :: term(), Actions :: actions(eventAction())} |          % 用作gen_ipc模式便捷式返回reply 而不用把reply放在actions列表中
   {'noreply', NewState :: term(), Options :: hibernate | {doAfter, Args}} |                                           % 用作gen_server模式时快速响应进入循环
   {'nextS', NextStatus :: term(), NewState :: term()} |                                                               % {next_status,NextS,NewData,[]}
   {'nextS', NextStatus :: term(), NewState :: term(), Actions :: actions(eventAction())} |                            % Status transition, maybe to the same status
   commonCallbackResult(eventAction()).

-type afterCallbackResult() ::
   {'nextS', NextStatus :: term(), NewState :: term()} |                                                               % {next_status,NextS,NewData,[]}
   {'nextS', NextStatus :: term(), NewState :: term(), Actions :: actions(afterAction())} |                            % Status transition, maybe to the same status
   {'noreply', NewState :: term()} |                                                                                   % 用作gen_server模式时快速响应进入消息接收
   {'noreply', NewState :: term(), Options :: hibernate} |                                                             % 用作gen_server模式时快速响应进入消息接收
   commonCallbackResult(afterAction()).

-type enterCallbackResult() ::
   commonCallbackResult(enterAction()).

-type commonCallbackResult(ActionType) ::
   {'kpS', NewState :: term()} |                                                                                       % {keep_status,NewData,[]}
   {'kpS', NewState :: term(), Actions :: actions(ActionType)} |                                                              % Keep status, change data
   'kpS_S' |                                                                                                           % {keep_status_and_data,[]}
   {'kpS_S', Actions :: [ActionType]} |                                                                                % Keep status and data -> only actions
   {'reS', NewState :: term()} |                                                                                       % {repeat_status,NewData,[]}
   {'reS', NewState :: term(), Actions :: actions(ActionType)} |                                                              % Repeat status, change data
   'reS_S' |                                                                                                           % {repeat_status_and_data,[]}
   {'reS_S', Actions :: actions(ActionType)} |                                                                                % Repeat status and data -> only actions
   'stop' |                                                                                                            % {stop,normal}
   {'stop', Reason :: term()} |                                                                                        % Stop the server
   {'stop', Reason :: term(), NewState :: term()} |                                                                    % Stop the server
   {'stopReply', Reason :: term(), Replies :: replyAction() | [replyAction(), ...] | term()} |                                  % Reply then stop the server
   {'stopReply', Reason :: term(), Replies :: replyAction() | [replyAction(), ...] | term(), NewState :: term()}.               % Reply then stop the server

%% 状态机的初始化功能函数
%% 如果要模拟gen_server init返回定时时间 可以在Actions返回定时动作
%% 如果要把改进程当做gen_event管理进程需要在actions列表包含 {trap_exit, true} 设置该进程捕捉异常
-callback init(Args :: term()) ->
   'ignore' |
   {'stop', Reason :: term()} |
   {'ok', State :: term()} |
   {'ok', Status :: term(), State :: term()} |
   {'ok', Status :: term(), State :: term(), Actions :: actions(initAction())}.

%% 当 enter call 回调函数
-callback handleEnter(OldStatus :: term(), CurStatus :: term(), State :: term()) ->
   enterCallbackResult().

%% 当 init返回actions包含 doAfter 的时候会在 enter调用后 调用该函数 或者
%% 在事件回调函数返回后 enter调用后调用该函数
%% 该回调函数相当于 gen_server 的 handle_continue回调 但是在综合模式时 也可以生效
-callback handleAfter(AfterArgs :: term(), Status :: term(), State :: term()) ->
   afterCallbackResult().

%% call 所以状态的回调函数
-callback handleCall(EventContent :: term(), Status :: term(), State :: term(), From :: {pid(), Tag :: term()}) ->
   eventCallbackResult().

%% cast 回调函数
-callback handleCast(EventContent :: term(), Status :: term(), State :: term()) ->
   eventCallbackResult().

%% info 回调函数
-callback handleInfo(EventContent :: term(), Status :: term(), State :: term()) ->
   eventCallbackResult().

%% 内部事件 Onevent 包括actions 设置的定时器超时产生的事件 和 nextE产生的超时事件 但是不是 call cast info 回调函数 以及其他自定义定时事件 的回调函数
%% 并且这里需要注意 其他erlang:start_timer生成超时事件发送的消息 不能和gen_ipc定时器关键字重合 有可能会导致一些问题
-callback handleOnevent(EventType :: term(), EventContent :: term(), Status :: term(), State :: term()) ->
   eventCallbackResult().

%% 在gen_event模式下 扩展了下面三个回调函数 考虑场景是：
%% 比如游戏里的公会 有时候一个公会一个进程来管理可能开销比较高 只用一个进程来管理所以公会有可能一个进程处理不过来
%% 这个时候可以考虑用gen_ipc来分组管理 一个gen_ipc进程管理 N 个公会 但是管理进程需要做一些数据保存什么 或者定时 就可能会用到下面的这些函数
%% gen_event模式时 notify 有可能需要回调该管理进程的该函数
-callback handleEpmEvent(EventContent :: term(), Status :: term(), State :: term()) ->
   eventCallbackResult().

%% gen_event模式时 call请求 有可能需要回调该管理进程的该函数
-callback handleEpmCall(EventContent :: term(), Status :: term(), State :: term()) ->
   eventCallbackResult().

%% gen_event模式时 info消息 有可能需要回调该管理进程的该函数
-callback handleEpmInfo(EventContent :: term(), Status :: term(), State :: term()) ->
   eventCallbackResult().

%% 在服务器终止之前进行清理。
-callback terminate(Reason :: 'normal' | 'shutdown' | {'shutdown', term()} | term(), Status :: term(), State :: term()) ->
   any().

%% 代码更新回调函数
-callback code_change(OldVsn :: term() | {'down', term()}, OldStatus :: term(), OldState :: term(), Extra :: term()) ->
   {ok, NewStatus :: term(), NewData :: term()} |
   (Reason :: term()).

%% 以一种通常被精简的方式来格式化回调模块状态。
%% 对于StatusOption =:= 'normal'，首选返回 term 是[{data,[{"Status",FormattedStatus}]}]
%% 对于StatusOption =:= 'terminate'，它只是FormattedStatus
-callback formatStatus(StatusOption, [PDict | term()]) ->
   Status :: term() when
   StatusOption :: 'normal' | 'terminate',
   PDict :: [{Key :: term(), Value :: term()}].

-optional_callbacks([
   formatStatus/2
   , terminate/3
   , code_change/4
   , handleEnter/3
   , handleAfter/3
   , handleOnevent/4
   , handleEpmEvent/3
   , handleEpmCall/3
   , handleEpmInfo/3
]).

-record(epmHer, {
   epmId = undefined :: term(),
   epmM :: atom(),
   epmSup = undefined :: 'undefined' | pid(),
   epmS :: term()
}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% start stop API start %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-type serverName() ::
   {'local', atom()} |
   {'global', GlobalName :: term()} |
   {'via', RegMod :: module(), Name :: term()}.

-type serverRef() ::
   pid()   |
   (LocalName :: atom()) |
   {Name :: atom(), Node :: atom()} |
   {'global', GlobalName :: term()} |
   {'via', RegMod :: module(), ViaName :: term()}.

-type startOpt() ::
   {'timeout', Time :: timeout()} |
   {'spawn_opt', [proc_lib:spawn_option()]} |
   enterLoopOpt().

-type enterLoopOpt() ::
   {'debug', Debugs :: [sys:debug_option()]} |
   {'hibernate_after', HibernateAfterTimeout :: timeout()}.

-type startRet() ::
   'ignore' |
   {'ok', pid()} |
   {'ok', {pid(), reference()}} |
   {'error', term()}.

-spec start(Module :: module(), Args :: term(), Opts :: [startOpt()]) -> startRet().
start(Module, Args, Opts) ->
   gen:start(?MODULE, nolink, Module, Args, Opts).

-spec start(ServerName :: serverName(), Module :: module(), Args :: term(), Opts :: [startOpt()]) -> startRet().
start(ServerName, Module, Args, Opts) ->
   gen:start(?MODULE, nolink, ServerName, Module, Args, Opts).

-spec start_link(Module :: module(), Args :: term(), Opts :: [startOpt()]) -> startRet().
start_link(Module, Args, Opts) ->
   gen:start(?MODULE, link, Module, Args, Opts).

-spec start_link(ServerName :: serverName(), Module :: module(), Args :: term(), Opts :: [startOpt()]) -> startRet().
start_link(ServerName, Module, Args, Opts) ->
   gen:start(?MODULE, link, ServerName, Module, Args, Opts).

%% Start and monitor
-spec start_monitor(Module :: module(), Args :: term(), Opts :: [startOpt()]) -> startRet().
start_monitor(Module, Args, Opts) ->
   gen:start(?MODULE, monitor, Module, Args, Opts).

-spec start_monitor(ServerName :: serverName(), Module :: module(), Args :: term(), Opts :: [startOpt()]) -> startRet().
start_monitor(ServerName, Module, Args, Opts) ->
   gen:start(?MODULE, monitor, ServerName, Module, Args, Opts).


-spec stop(ServerRef :: serverRef()) -> ok.
stop(ServerRef) ->
   gen:stop(ServerRef).

-spec stop(ServerRef :: serverRef(), Reason :: term(), Timeout :: timeout()) -> ok.
stop(ServerRef, Reason, Timeout) ->
   gen:stop(ServerRef, Reason, Timeout).
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% start stop API end %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% gen callbacks start %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
doModuleInit(Module, Args) ->
   try
      Module:init(Args)
   catch
      throw:Ret -> Ret;
      Class:Reason:Stacktrace -> {'EXIT', Class, Reason, Stacktrace}
   end.

init_it(Starter, self, ServerRef, Module, Args, Opts) ->
   init_it(Starter, self(), ServerRef, Module, Args, Opts);
init_it(Starter, Parent, ServerRef, Module, Args, Opts) ->
   Name = gen:name(ServerRef),
   Debug = gen:debug_options(Name, Opts),
   HibernateAfterTimeout = gen:hibernate_after(Opts),
   case doModuleInit(Module, Args) of
      {ok, State} ->
         proc_lib:init_ack(Starter, {ok, self()}),
         loopEntry(Parent, Debug, Module, Name, HibernateAfterTimeout, undefined, State, []);
      {ok, Status, State} ->
         proc_lib:init_ack(Starter, {ok, self()}),
         loopEntry(Parent, Debug, Module, Name, HibernateAfterTimeout, Status, State, []);
      {ok, Status, State, Actions} ->
         proc_lib:init_ack(Starter, {ok, self()}),
         loopEntry(Parent, Debug, Module, Name, HibernateAfterTimeout, Status, State, listify(Actions));
      {stop, Reason} ->
         gen:unregister_name(ServerRef),
         proc_lib:init_ack(Starter, {error, Reason}),
         exit(Reason);
      ignore ->
         gen:unregister_name(ServerRef),
         proc_lib:init_ack(Starter, ignore),
         exit(normal);
      {'EXIT', Class, Reason, Stacktrace} ->
         gen:unregister_name(ServerRef),
         proc_lib:init_ack(Starter, {error, Reason}),
         error_info(Class, Reason, Stacktrace, Parent, Name, Module, HibernateAfterTimeout, fasle, #{}, [], #{}, '$un_init', '$un_init', Debug, []),
         erlang:raise(Class, Reason, Stacktrace);
      _Ret ->
         gen:unregister_name(ServerRef),
         Error = {'init_bad_return', _Ret},
         proc_lib:init_ack(Starter, {error, Error}),
         error_info(error, Error, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, fasle, #{}, [], #{}, '$un_init', '$un_init', Debug, []),
         exit(Error)
   end.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% gen callbacks end %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% 进入循环 调用该进程必须使用proc_lib启动 且已经初始化状态和数据 包括注册名称
%% 可以通过使用与从init / 1返回的参数相同的参数，而不是通过start / 3,4或start_link / 3,4启动状态机，而将当前由proc_lib启动的进程转换为状态机。
-spec enter_loop(Module :: module(), Status :: term(), State :: term(), Opts :: [enterLoopOpt()]) -> no_return().
enter_loop(Module, Status, State, Opts) ->
   enter_loop(Module, Status, State, Opts, self(), []).

-spec enter_loop(Module :: module(), Status :: term(), State :: term(), Opts :: [enterLoopOpt()], ServerOrActions :: serverName() | pid() | actions(eventAction())) -> no_return().
enter_loop(Module, Status, State, Opts, ServerOrActions) ->
   if
      is_list(ServerOrActions) ->
         enter_loop(Module, Status, State, Opts, self(), ServerOrActions);
      true ->
         enter_loop(Module, Status, State, Opts, ServerOrActions, [])
   end.

-spec enter_loop(Module :: module(), Status :: term(), State :: term(), Opts :: [enterLoopOpt()], Server :: serverName() | pid(), Actions :: actions(eventAction())) -> no_return().
enter_loop(Module, Status, State, Opts, ServerName, Actions) ->
   is_atom(Module) orelse error({atom, Module}),
   Parent = gen:get_parent(),
   Name = gen:get_proc_name(ServerName),
   Debug = gen:debug_options(Name, Opts),
   HibernateAfterTimeout = gen:hibernate_after(Opts),
   loopEntry(Parent, Debug, Module, Name, HibernateAfterTimeout, Status, State, Actions).

%% 这里的 init_it/6 和 enter_loop/5,6,7 函数汇聚
loopEntry(Parent, Debug, Module, Name, HibernateAfterTimeout, CurStatus, CurState, Actions) ->
   %% 如果该进程用于 gen_event 或者该进程需要捕捉退出信号 和 捕捉supervisor进程树的退出信息 则需要设置   process_flag(trap_exit, true) 需要在Actions返回 {trap_exit, true}
   MewActions =
      case lists:keyfind(trap_exit, 1, Actions) of
         false ->
            Actions;
         {trap_exit, true} ->
            process_flag(trap_exit, true),
            lists:keydelete(trap_exit, 1, Actions);
         _ ->
            lists:keydelete(trap_exit, 1, Actions)
      end,

   NewDebug = ?SYS_DEBUG(Debug, Name, {enter, CurStatus}),
   %% 强制执行{postpone，false}以确保我们的假事件被丢弃
   LastActions = MewActions ++ [{isPos, false}],
   parseEventAL(Parent, Name, Module, HibernateAfterTimeout, false, #{}, [], #{}, CurStatus, CurState, CurStatus, NewDebug, [{onevent, init_status}], true, LastActions, ?CB_FORM_EVENT).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% sys callbacks start %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
system_continue(Parent, Debug, {Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, IsHib}) ->
   if
      IsHib ->
         proc_lib:hibernate(?MODULE, wakeupFromHib, [Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, IsHib]);
      true ->
         receiveIng(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, IsHib)
   end.

system_terminate(Reason, Parent, Debug, {Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, _IsHib}) ->
   terminate(exit, Reason, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, []).

system_code_change({Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, IsHib}, _Mod, OldVsn, Extra) ->
   case
      try Module:code_change(OldVsn, CurStatus, CurState, Extra)
      catch
         throw:Result -> Result;
         _C:_R -> {_R, _R}
      end
   of
      {ok, NewStatus, NewState} ->
         {ok, {Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, NewStatus, NewState, IsHib}};
      Error ->
         Error
   end.

system_get_state({_Parent, _Name, _Module, _HibernateAfterTimeout, _IsEnter, _EpmHers, _Postponed, _Timers, CurStatus, CurState, _IsHib}) ->
   {ok, {CurStatus, CurState}}.

system_replace_state(StatusFun, {Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, IsHib}) ->
   {NewStatus, NewState} = StatusFun(CurStatus, CurState),
   {ok, {NewStatus, NewState}, {Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, NewStatus, NewState, IsHib}}.

format_status(Opt, [PDict, SysStatus, Parent, Debug, {Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, _IsHib}]) ->
   Header = gen:format_status_header("Status for es_gen_ipc", Name),
   Log = sys:get_log(Debug),
   [
      {header, Header},
      {data,
         [
            {"Status", SysStatus},
            {"Parent", Parent},
            {"Time-outs", listTimeouts(Timers)},
            {"Logged Events", Log},
            {"Postponed", Postponed}
         ]
      } |
      case format_status(Opt, PDict, Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState) of
         L when is_list(L) -> L;
         T -> [T]
      end
   ].
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% sys callbacks end %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% API helpers  start  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec call(ServerRef :: serverRef(), Request :: term()) -> Reply :: term().
call(ServerRef, Request) ->
   try gen:call(ServerRef, '$gen_call', Request) of
      {ok, Reply} ->
         Reply
   catch Class:Reason ->
      erlang:raise(Class, {Reason, {?MODULE, call, [ServerRef, Request]}}, ?STACKTRACE())
   end.

-spec call(ServerRef :: serverRef(), Request :: term(), Timeout :: timeout() |{'clean_timeout', T :: timeout()} | {'dirty_timeout', T :: timeout()}) -> Reply :: term().
call(ServerRef, Request, infinity) ->
   try gen:call(ServerRef, '$gen_call', Request, infinity) of
      {ok, Reply} ->
         Reply
   catch Class:Reason ->
      erlang:raise(Class, {Reason, {?MODULE, call, [ServerRef, Request, infinity]}}, ?STACKTRACE())
   end;
call(ServerRef, Request, {dirty_timeout, T} = Timeout) ->
   try gen:call(ServerRef, '$gen_call', Request, T) of
      {ok, Reply} ->
         Reply
   catch Class:Reason ->
      erlang:raise(Class, {Reason, {?MODULE, call, [ServerRef, Request, Timeout]}}, ?STACKTRACE())
   end;
call(ServerRef, Request, {clean_timeout, T} = Timeout) ->
   callClean(ServerRef, Request, Timeout, T);
call(ServerRef, Request, {_, _} = Timeout) ->
   erlang:error(badarg, [ServerRef, Request, Timeout]);
call(ServerRef, Request, Timeout) ->
   callClean(ServerRef, Request, Timeout, Timeout).

callClean(ServerRef, Request, Timeout, T) ->
   %% 通过代理过程呼叫服务器以躲避任何较晚的答复
   Ref = make_ref(),
   Self = self(),
   Pid = spawn(
      fun() ->
         Self !
            try gen:call(ServerRef, '$gen_call', Request, T) of
               Result ->
                  {Ref, Result}
            catch Class:Reason ->
               {Ref, Class, Reason, ?STACKTRACE()}
            end
      end),
   Mref = monitor(process, Pid),
   receive
      {Ref, Result} ->
         demonitor(Mref, [flush]),
         case Result of
            {ok, Reply} ->
               Reply
         end;
      {Ref, Class, Reason, Stacktrace} ->
         demonitor(Mref, [flush]),
         erlang:raise(Class, {Reason, {?MODULE, call, [ServerRef, Request, Timeout]}}, Stacktrace);
      {'DOWN', Mref, _, _, Reason} ->
         %% 从理论上讲，有可能在try-of和！之间杀死代理进程。因此，在这种情况下
         exit(Reason)
   end.

multi_call(Name, Request) when is_atom(Name) ->
   do_multi_call([node() | nodes()], Name, Request, infinity).

multi_call(Nodes, Name, Request) when is_list(Nodes), is_atom(Name) ->
   do_multi_call(Nodes, Name, Request, infinity).

multi_call(Nodes, Name, Request, infinity) ->
   do_multi_call(Nodes, Name, Request, infinity);
multi_call(Nodes, Name, Request, Timeout) when is_list(Nodes), is_atom(Name), is_integer(Timeout), Timeout >= 0 ->
   do_multi_call(Nodes, Name, Request, Timeout).

do_multi_call(Nodes, Name, Request, infinity) ->
   Tag = make_ref(),
   Monitors = send_nodes(Nodes, Name, Tag, Request),
   rec_nodes(Tag, Monitors, Name, undefined);
do_multi_call(Nodes, Name, Request, Timeout) ->
   Tag = make_ref(),
   Caller = self(),
   Receiver = spawn(
      fun() ->
         process_flag(trap_exit, true),
         Mref = erlang:monitor(process, Caller),
         receive
            {Caller, Tag} ->
               Monitors = send_nodes(Nodes, Name, Tag, Request),
               TimerId = erlang:start_timer(Timeout, self(), ok),
               Result = rec_nodes(Tag, Monitors, Name, TimerId),
               exit({self(), Tag, Result});
            {'DOWN', Mref, _, _, _} ->
               exit(normal)
         end
      end
   ),
   Mref = erlang:monitor(process, Receiver),
   Receiver ! {self(), Tag},
   receive
      {'DOWN', Mref, _, _, {Receiver, Tag, Result}} ->
         Result;
      {'DOWN', Mref, _, _, Reason} ->
         exit(Reason)
   end.

-spec cast(ServerRef :: serverRef(), Msg :: term()) -> ok.
cast({global, Name}, Msg) ->
   try global:send(Name, {'$gen_cast', Msg}),
   ok
   catch _:_ -> ok
   end;
cast({via, RegMod, Name}, Msg) ->
   try RegMod:send(Name, {'$gen_cast', Msg}),
   ok
   catch _:_ -> ok
   end;
cast({Name, Node} = Dest, Msg) when is_atom(Name), is_atom(Node) ->
   try erlang:send(Dest, {'$gen_cast', Msg}),
   ok
   catch _:_ -> ok
   end;
cast(Dest, Msg) ->
   try erlang:send(Dest, {'$gen_cast', Msg}),
   ok
   catch _:_ -> ok
   end.

-spec send(ServerRef :: serverRef(), Msg :: term()) -> ok.
send({global, Name}, Msg) ->
   try global:send(Name, Msg),
   ok
   catch _:_ -> ok
   end;
send({via, RegMod, Name}, Msg) ->
   try RegMod:send(Name, Msg),
   ok
   catch _:_ -> ok
   end;
send({Name, Node} = Dest, Msg) when is_atom(Name), is_atom(Node) ->
   try erlang:send(Dest, Msg),
   ok
   catch _:_ -> ok
   end;
send(Dest, Msg) ->
   try erlang:send(Dest, Msg),
   ok
   catch _:_ -> ok
   end.

%% 异步广播，不返回任何内容，只是发送“ n”祈祷
abcast(Name, Msg) when is_atom(Name) ->
   doAbcast([node() | nodes()], Name, Msg).

abcast(Nodes, Name, Msg) when is_list(Nodes), is_atom(Name) ->
   doAbcast(Nodes, Name, Msg).

doAbcast(Nodes, Name, Msg) ->
   [
      begin
         try erlang:send({Name, Node}, {'$gen_cast', Msg}),
         ok
         catch
            _:_ -> ok
         end
      end || Node <- Nodes
   ],
   ok.

-spec send_request(ServerRef :: serverRef(), Request :: term()) -> RequestId :: requestId().
send_request(Name, Request) ->
   gen:send_request(Name, '$gen_call', Request).

%% gen_event send_request/3
-spec send_request(ServerRef :: serverRef(), epmHandler(), term()) -> requestId().
send_request(Name, Handler, Query) ->
   gen:send_request(Name, self(), {call, Handler, Query}).

-spec wait_response(RequestId :: requestId()) -> {reply, Reply :: term()} | {error, {term(), serverRef()}}.
wait_response(RequestId) ->
   gen:wait_response(RequestId, infinity).

-spec wait_response(RequestId :: requestId(), timeout()) -> {reply, Reply :: term()} | 'timeout' | {error, {term(), serverRef()}}.
wait_response(RequestId, Timeout) ->
   gen:wait_response(RequestId, Timeout).

-spec receive_response(RequestId::serverRef()) -> {reply, Reply::term()} | {error, {term(), serverRef()}}.
receive_response(RequestId) ->
   gen:receive_response(RequestId, infinity).

-spec receive_response(RequestId::requestId(), timeout()) -> {reply, Reply::term()} | 'timeout' | {error, {term(), serverRef()}}.
receive_response(RequestId, Timeout) ->
   gen:receive_response(RequestId, Timeout).

-spec check_response(Msg :: term(), RequestId :: requestId()) ->
   {reply, Reply :: term()} | 'no_reply' | {error, {term(), serverRef()}}.
check_response(Msg, RequestId) ->
   gen:check_response(Msg, RequestId).

send_nodes(Nodes, Name, Tag, Request) ->
   [
      begin
         Monitor = start_monitor(Node, Name),
         try {Name, Node} ! {'$gen_call', {self(), {Tag, Node}}, Request},
         ok
         catch _:_ -> ok
         end,
         Monitor
      end || Node <- Nodes, is_atom(Node)
   ].

rec_nodes(Tag, Nodes, Name, TimerId) ->
   rec_nodes(Tag, Nodes, Name, [], [], 2000, TimerId).

rec_nodes(Tag, [{N, R} | Tail], Name, BadNodes, Replies, Time, TimerId) ->
   receive
      {'DOWN', R, _, _, _} ->
         rec_nodes(Tag, Tail, Name, [N | BadNodes], Replies, Time, TimerId);
      {{Tag, N}, Reply} ->
         erlang:demonitor(R, [flush]),
         rec_nodes(Tag, Tail, Name, BadNodes,
            [{N, Reply} | Replies], Time, TimerId);
      {timeout, TimerId, _} ->
         erlang:demonitor(R, [flush]),
         rec_nodes_rest(Tag, Tail, Name, [N | BadNodes], Replies)
   end;
rec_nodes(Tag, [N | Tail], Name, BadNodes, Replies, Time, TimerId) ->
   receive
      {nodedown, N} ->
         monitor_node(N, false),
         rec_nodes(Tag, Tail, Name, [N | BadNodes], Replies, 2000, TimerId);
      {{Tag, N}, Reply} ->
         receive {nodedown, N} -> ok after 0 -> ok end,
         monitor_node(N, false),
         rec_nodes(Tag, Tail, Name, BadNodes,
            [{N, Reply} | Replies], 2000, TimerId);
      {timeout, TimerId, _} ->
         receive {nodedown, N} -> ok after 0 -> ok end,
         monitor_node(N, false),
         rec_nodes_rest(Tag, Tail, Name, [N | BadNodes], Replies)
   after Time ->
      case erpc:call(N, erlang, whereis, [Name]) of
         Pid when is_pid(Pid) ->
            rec_nodes(Tag, [N | Tail], Name, BadNodes,
               Replies, infinity, TimerId);
         _ ->
            receive {nodedown, N} -> ok after 0 -> ok end,
            monitor_node(N, false),
            rec_nodes(Tag, Tail, Name, [N | BadNodes],
               Replies, 2000, TimerId)
      end
   end;
rec_nodes(_, [], _, BadNodes, Replies, _, TimerId) ->
   case catch erlang:cancel_timer(TimerId) of
      false ->
         receive
            {timeout, TimerId, _} -> ok
         after 0 ->
            ok
         end;
      _ ->
         ok
   end,
   {Replies, BadNodes}.

rec_nodes_rest(Tag, [{N, R} | Tail], Name, BadNodes, Replies) ->
   receive
      {'DOWN', R, _, _, _} ->
         rec_nodes_rest(Tag, Tail, Name, [N | BadNodes], Replies);
      {{Tag, N}, Reply} ->
         erlang:demonitor(R, [flush]),
         rec_nodes_rest(Tag, Tail, Name, BadNodes, [{N, Reply} | Replies])
   after 0 ->
      erlang:demonitor(R, [flush]),
      rec_nodes_rest(Tag, Tail, Name, [N | BadNodes], Replies)
   end;
rec_nodes_rest(Tag, [N | Tail], Name, BadNodes, Replies) ->
   receive
      {nodedown, N} ->
         monitor_node(N, false),
         rec_nodes_rest(Tag, Tail, Name, [N | BadNodes], Replies);
      {{Tag, N}, Reply} ->
         receive {nodedown, N} -> ok after 0 -> ok end,
         monitor_node(N, false),
         rec_nodes_rest(Tag, Tail, Name, BadNodes, [{N, Reply} | Replies])
   after 0 ->
      receive {nodedown, N} -> ok after 0 -> ok end,
      monitor_node(N, false),
      rec_nodes_rest(Tag, Tail, Name, [N | BadNodes], Replies)
   end;
rec_nodes_rest(_Tag, [], _Name, BadNodes, Replies) ->
   {Replies, BadNodes}.

start_monitor(Node, Name) when is_atom(Node), is_atom(Name) ->
   if node() =:= nonode@nohost, Node =/= nonode@nohost ->
      Ref = make_ref(),
      self() ! {'DOWN', Ref, process, {Name, Node}, noconnection},
      {Node, Ref};
      true ->
         case catch erlang:monitor(process, {Name, Node}) of
            {'EXIT', _} ->
               monitor_node(Node, true),
               Node;
            Ref when is_reference(Ref) ->
               {Node, Ref}
         end
   end.

%% Reply from a status machine callback to whom awaits in call/2
-spec reply([replyAction(), ...] | replyAction()) -> ok.
reply({reply, {To, Tag}, Reply}) ->
   try To ! {Tag, Reply},
   ok
   catch _:_ ->
      ok
   end;
reply(Replies) when is_list(Replies) ->
   [
      begin
         try To ! {Tag, Reply},
         ok
         catch _:_ ->
            ok
         end
      end || {reply, {To, Tag}, Reply} <- Replies
   ],
   ok.

-spec reply(From :: from(), Reply :: term()) -> ok.
reply({_To, [alias|Alias] = Tag}, Reply) ->
   Alias ! {Tag, Reply},
   ok;
reply({To, Tag}, Reply) ->
   try To ! {Tag, Reply},
   ok
   catch _:_ ->
      ok
   end.

try_reply(false, _Msg) ->
   ignore;
try_reply({To, Ref}, Msg) ->
   try To ! {Ref, Msg},
   ok
   catch _:_ ->
      ok
   end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% API helpers  end  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% gen_event  start %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
epmRequest({global, Name}, Msg) ->
   try global:send(Name, Msg),
   ok
   catch _:_ -> ok
   end;
epmRequest({via, RegMod, Name}, Msg) ->
   try RegMod:send(Name, Msg),
   ok
   catch _:_ -> ok
   end;
epmRequest(EpmSrv, Cmd) ->
   EpmSrv ! Cmd,
   ok.

-spec epm_info(serverRef(), epmHandler(), term()) -> term().
epm_info(EpmSrv, EpmHandler, Msg) ->
   epmRequest(EpmSrv, {'$epm_info', EpmHandler, Msg}).

-spec info_notify(serverRef(), term()) -> 'ok'.
info_notify(EpmSrv, Event) ->
   epmRequest(EpmSrv, {'$epm_info', '$infoNotify', Event}).

epmRpc(EpmSrv, Cmd) ->
   try gen:call(EpmSrv, '$epm_call', Cmd, infinity) of
      {ok, Reply} ->
         Reply
   catch Class:Reason ->
      erlang:raise(Class, {Reason, {?MODULE, call, [EpmSrv, Cmd, infinity]}}, ?STACKTRACE())
   end.

epmRpc(EpmSrv, Cmd, Timeout) ->
   try gen:call(EpmSrv, '$epm_call', Cmd, Timeout) of
      {ok, Reply} ->
         Reply
   catch Class:Reason ->
      erlang:raise(Class, {Reason, {?MODULE, call, [EpmSrv, Cmd, Timeout]}}, ?STACKTRACE())
   end.

-spec call_notify(serverRef(), term()) -> 'ok'.
call_notify(EpmSrv, Event) ->
   epmRpc(EpmSrv, {'$syncNotify', Event}).

-spec epm_call(serverRef(), epmHandler(), term()) -> term().
epm_call(EpmSrv, EpmHandler, Query) ->
   epmRpc(EpmSrv, {'$epmCall', EpmHandler, Query}).

-spec epm_call(serverRef(), epmHandler(), term(), timeout()) -> term().
epm_call(EpmSrv, EpmHandler, Query, Timeout) ->
   epmRpc(EpmSrv, {'$epmCall', EpmHandler, Query}, Timeout).

-spec add_epm(serverRef(), epmHandler(), term()) -> term().
add_epm(EpmSrv, EpmHandler, Args) ->
   epmRpc(EpmSrv, {'$addEpm', EpmHandler, Args}).

-spec add_sup_epm(serverRef(), epmHandler(), term()) -> term().
add_sup_epm(EpmSrv, EpmHandler, Args) ->
   epmRpc(EpmSrv, {'$addSupEpm', EpmHandler, Args, self()}).

-spec del_epm(serverRef(), epmHandler(), term()) -> term().
del_epm(EpmSrv, EpmHandler, Args) ->
   epmRpc(EpmSrv, {'$delEpm', EpmHandler, Args}).

-spec swap_epm(serverRef(), {epmHandler(), term()}, {epmHandler(), term()}) -> 'ok' | {'error', term()}.
swap_epm(EpmSrv, {H1, A1}, {H2, A2}) ->
   epmRpc(EpmSrv, {'$swapEpm', H1, A1, H2, A2}).

-spec swap_sup_epm(serverRef(), {epmHandler(), term()}, {epmHandler(), term()}) -> 'ok' | {'error', term()}.
swap_sup_epm(EpmSrv, {H1, A1}, {H2, A2}) ->
   epmRpc(EpmSrv, {'$swapSupEpm', H1, A1, H2, A2, self()}).

-spec which_epm(serverRef()) -> [epmHandler()].
which_epm(EpmSrv) ->
   epmRpc(EpmSrv, '$which_handlers').

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% EPM inner fun
addNewEpm(InitRet, EpmHers, Module, EpmId, EpmSup) ->
   case InitRet of
      {ok, State} ->
         EpmHer = #epmHer{epmId = EpmId, epmM = Module, epmS = State, epmSup = EpmSup},
         {ok, EpmHers#{EpmId => EpmHer}, false};
      {ok, State, hibernate} ->
         EpmHer = #epmHer{epmId = EpmId, epmM = Module, epmS = State, epmSup = EpmSup},
         {ok, EpmHers#{EpmId => EpmHer}, true};
      Other ->
         {Other, EpmHers, false}
   end.

doAddEpm(EpmHers, {Module, _SubId} = EpmId, Args, EpmSup) ->
   case EpmHers of
      #{EpmId := _EpmHer} ->
         {{error, existed}, EpmHers, false};
      _ ->
         try Module:init(Args) of
            Result ->
               addNewEpm(Result, EpmHers, Module, EpmId, EpmSup)
         catch
            throw:Ret ->
               addNewEpm(Ret, EpmHers, Module, EpmId, EpmSup);
            C:R:S ->
               {{error, {C, R, S}}, EpmHers, false}
         end
   end;
doAddEpm(EpmHers, Module, Args, EpmSup) ->
   case EpmHers of
      #{Module := _EpmHer} ->
         {{error, existed}, EpmHers, false};
      _ ->
         try Module:init(Args) of
            Result ->
               addNewEpm(Result, EpmHers, Module, Module, EpmSup)
         catch
            throw:Ret ->
               addNewEpm(Ret, EpmHers, Module, Module, EpmSup);
            C:R:S ->
               {{error, {C, R, S}}, EpmHers, false}
         end
   end.

doAddSupEpm(EpmHers, EpmHandler, Args, EpmSup) ->
   case doAddEpm(EpmHers, EpmHandler, Args, EpmSup) of
      {ok, _, _} = Result ->
         link(EpmSup),
         Result;
      Ret ->
         Ret
   end.

doSwapEpm(EpmHers, EpmId1, Args1, EpmMId, Args2) ->
   case EpmHers of
      #{EpmId1 := #epmHer{epmSup = EpmSup} = EpmHer} ->
         State2 = epmTerminate(EpmHer, Args1, swapped, {swapped, EpmMId, EpmSup}),
         NewEpmHers = maps:remove(EpmId1, EpmHers),
         case EpmSup of
            false ->
               doAddEpm(NewEpmHers, EpmMId, {Args2, State2}, undefined);
            _ ->
               doAddSupEpm(NewEpmHers, EpmMId, {Args2, State2}, EpmSup)
         end;
      undefined ->
         doAddEpm(EpmHers, EpmMId, {Args2, undefined}, undefined)
   end.

doSwapSupEpm(EpmHers, EpmId1, Args1, EpmMId, Args2, EpmSup) ->
   case EpmHers of
      #{EpmId1 := EpmHer} ->
         State2 = epmTerminate(EpmHer, Args1, swapped, {swapped, EpmMId, EpmSup}),
         NewEpmHers = maps:remove(EpmId1, EpmHers),
         doAddSupEpm(NewEpmHers, EpmMId, {Args2, State2}, EpmSup);
      undefined ->
         doAddSupEpm(EpmHers, EpmMId, {Args2, undefined}, EpmSup)
   end.

doNotify(EpmHers, Func, Event, _Form) ->
   allNotify(maps:iterator(EpmHers), Func, Event, false, EpmHers, false).

allNotify(Iterator, Func, Event, From, TemEpmHers, IsHib) ->
   case maps:next(Iterator) of
      {K, _V, NextIterator} ->
         {NewEpmHers, NewIsHib} = doEpmHandle(TemEpmHers, K, Func, Event, From),
         allNotify(NextIterator, Func, Event, From, NewEpmHers, IsHib orelse NewIsHib);
      _ ->
         {TemEpmHers, IsHib}
   end.

doEpmHandle(EpmHers, EpmHandler, Func, Event, From) ->
   case EpmHers of
      #{EpmHandler := #epmHer{epmM = EpmM, epmS = EpmS} = EpmHer} ->
         try EpmM:Func(Event, EpmS) of
            Result ->
               handleEpmCR(Result, EpmHers, EpmHer, Event, From)
         catch
            throw:Ret ->
               handleEpmCR(Ret, EpmHers, EpmHer, Event, From);
            C:R:S ->
               epmTerminate(EpmHer, {error, {C, R, S}}, Event, crash),
               NewEpmHers = maps:remove(EpmHandler, EpmHers),
               {NewEpmHers, false}
         end;
      _ ->
         try_reply(From, {error, bad_module}),
         {EpmHers, false}
   end.

doDelEpm(EpmHers, EpmHandler, Args) ->
   case EpmHers of
      #{EpmHandler := EpmHer} ->
         epmTerminate(EpmHer, Args, delete, normal),
         {ok, maps:remove(EpmHandler, EpmHers)};
      undefined ->
         {{error, module_not_found}, EpmHers}
   end.

epmTerminate(#epmHer{epmM = EpmM, epmS = State} = EpmHer, Args, LastIn, Reason) ->
   case erlang:function_exported(EpmM, terminate, 2) of
      true ->
         Res = (catch EpmM:terminate(Args, State)),
         reportTerminate(EpmHer, Reason, Args, LastIn, Res),
         Res;
      false ->
         reportTerminate(EpmHer, Reason, Args, LastIn, ok),
         ok
   end.

reportTerminate(EpmHer, crash, {error, Why}, LastIn, _) ->
   reportTerminate2(EpmHer, Why, LastIn);
%% How == normal | shutdown | {swapped, NewHandler, NewSupervisor}
reportTerminate(EpmHer, How, _, LastIn, _) ->
   reportTerminate2(EpmHer, How, LastIn).

reportTerminate2(#epmHer{epmSup = EpmSup, epmId = EpmId, epmS = State} = EpmHer, Reason, LastIn) ->
   report_error(EpmHer, Reason, State, LastIn),
   case EpmSup of
      undefined ->
         ok;
      _ ->
         EpmSup ! {gen_event_EXIT, EpmId, Reason},
         ok
   end.

report_error(_EpmHer, normal, _, _) -> ok;
report_error(_EpmHer, shutdown, _, _) -> ok;
report_error(_EpmHer, {swapped, _, _}, _, _) -> ok;
report_error(#epmHer{epmId = EpmId, epmM = EpmM}, Reason, State, LastIn) ->
   ?LOG_ERROR(
      #{
         label=>{es_gen_ipc, epm_terminate},
         handler => {EpmId, EpmM},
         name => undefined,
         last_message => LastIn,
         state => State,
         reason => Reason
      },
      #{
         domain => [otp],
         report_cb => fun es_gen_ipc:epm_log/1,
         error_logger => #{tag => error}
      }).

epm_log(#{label := {es_gen_ipc, epm_terminate}, handler := Handler, name := SName, last_message := LastIn, state := State, reason := Reason}) ->
   Reason1 =
      case Reason of
         {'EXIT', {undef, [{M, F, A, L} | MFAs]}} ->
            case code:is_loaded(M) of
               false ->
                  {'module could not be loaded', [{M, F, A, L} | MFAs]};
               _ ->
                  case erlang:function_exported(M, F, length(A)) of
                     true ->
                        {undef, [{M, F, A, L} | MFAs]};
                     false ->
                        {'function not exported', [{M, F, A, L} | MFAs]}
                  end
            end;
         {'EXIT', Why} ->
            Why;
         _ ->
            Reason
      end,
   {"** es_gen_ipc emp handler ~p crashed.~n"
   "** Was installed in ~tp~n"
   "** Last event was: ~tp~n"
   "** When handler state == ~tp~n"
   "** Reason == ~tp~n", [Handler, SName, LastIn, State, Reason1]};
epm_log(#{label := {es_gen_ipc, no_handle_info}, module := Module, message := Msg}) ->
   {"** Undefined handle_info in ~tp~n"
   "** Unhandled message: ~tp~n", [Module, Msg]}.

epmStopAll(EpmHers) ->
   allStop(maps:iterator(EpmHers)).

allStop(Iterator) ->
   case maps:next(Iterator) of
      {_K, V, NextIterator} ->
         epmTerminate(V, stop, 'receive', shutdown),
         case element(#epmHer.epmSup, V) of
            undefined ->
               ignore;
            EpmSup ->
               unlink(EpmSup)
         end,
         allStop(NextIterator);
      none ->
         ok
   end.

epmStopOne(ExitEmpSup, EpmHers) ->
   forStopOne(maps:iterator(EpmHers), ExitEmpSup, EpmHers).

forStopOne(Iterator, ExitEmpSup, TemEpmHers) ->
   case maps:next(Iterator) of
      {K, V, NextIterator} ->
         case element(#epmHer.epmSup, V) =:= ExitEmpSup of
            true ->
               epmTerminate(V, stop, 'receive', shutdown),
               forStopOne(NextIterator, ExitEmpSup, maps:remove(K, TemEpmHers));
            _ ->
               forStopOne(NextIterator, ExitEmpSup, TemEpmHers)
         end;
      none ->
         TemEpmHers
   end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% gen_event  end %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
listify(Item) when is_list(Item) ->
   Item;
listify(Item) ->
   [Item].
%%%==========================================================================
%%% Internal callbacks
wakeupFromHib(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, IsHib) ->
   %% 这是一条新消息，唤醒了我们，因此我们必须立即收到它
   receiveIng(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, IsHib).

%%%==========================================================================
%% Entry point for system_continue/3
reLoopEntry(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, IsHib) ->
   if
      IsHib ->
         proc_lib:hibernate(?MODULE, wakeupFromHib, [Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, IsHib]);
      true ->
         receiveIng(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, IsHib)
   end.

%% 接收新的消息
receiveIng(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, IsHib) ->
   receive
      Msg ->
         case Msg of
            {'$gen_call', From, Request} ->
               matchCallMsg(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, From, Request);
            {'$gen_cast', Cast} ->
               matchCastMsg(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, Cast);
            {timeout, TimerRef, TimeoutType} ->
               case Timers of
                  #{TimeoutType := {TimerRef, TimeoutMsg}} ->
                     NewTimers = maps:remove(TimeoutType, Timers),
                     matchTimeoutMsg(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, NewTimers, CurStatus, CurState, Debug, TimeoutType, TimeoutMsg);
                  _ ->
                     matchInfoMsg(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, Msg)
               end;
            {system, PidFrom, Request} ->
               %% 不返回但尾递归调用 system_continue/3
               sys:handle_system_msg(Request, PidFrom, Parent, ?MODULE, Debug, {Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, IsHib}, IsHib);
            {'EXIT', PidFrom, Reason} ->
               case Parent =:= PidFrom of
                  true ->
                     terminate(exit, Reason, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, []);
                  _ ->
                     NewEpmHers = epmStopOne(PidFrom, EpmHers),
                     matchInfoMsg(Parent, Name, Module, HibernateAfterTimeout, IsEnter, NewEpmHers, Postponed, Timers, CurStatus, CurState, Debug, Msg)
               end;
            {'$epm_call', From, Request} ->
               matchEpmCallMsg(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, From, Request);
            {'$epm_info', CmdOrEmpHandler, Event} ->
               matchEpmInfoMsg(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, CmdOrEmpHandler, Event);
            _ ->
               matchInfoMsg(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, Msg)
         end
   after
      HibernateAfterTimeout ->
         proc_lib:hibernate(?MODULE, wakeupFromHib, [Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, IsHib])
   end.

matchCallMsg(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, From, Request) ->
   CurEvent = {{call, From}, Request},
   NewDebug = ?SYS_DEBUG(Debug, Name, {in, CurEvent, CurStatus}),
   try Module:handleCall(Request, CurStatus, CurState, From) of
      Result ->
         handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, [CurEvent], Result, ?CB_FORM_EVENT, From)
   catch
      throw:Result ->
         handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, [CurEvent], Result, ?CB_FORM_EVENT, From);
      Class:Reason:Strace ->
         terminate(Class, Reason, Strace, Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, [CurEvent])
   end.

matchCastMsg(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, Cast) ->
   CurEvent = {cast, Cast},
   NewDebug = ?SYS_DEBUG(Debug, Name, {in, CurEvent, CurStatus}),
   try Module:handleCast(Cast, CurStatus, CurState) of
      Result ->
         handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, [CurEvent], Result, ?CB_FORM_EVENT, false)
   catch
      throw:Result ->
         handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, [CurEvent], Result, ?CB_FORM_EVENT, false);
      Class:Reason:Strace ->
         terminate(Class, Reason, Strace, Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, [CurEvent])
   end.

matchInfoMsg(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, Msg) ->
   CurEvent = {info, Msg},
   NewDebug = ?SYS_DEBUG(Debug, Name, {in, CurEvent, CurStatus}),
   try Module:handleInfo(Msg, CurStatus, CurState) of
      Result ->
         handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, [CurEvent], Result, ?CB_FORM_EVENT, false)
   catch
      throw:Result ->
         handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, [CurEvent], Result, ?CB_FORM_EVENT, false);
      Class:Reason:Strace ->
         terminate(Class, Reason, Strace, Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, [CurEvent])
   end.

matchTimeoutMsg(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, TimeoutType, TimeoutMsg) ->
   CurEvent = {TimeoutType, TimeoutMsg},
   NewDebug = ?SYS_DEBUG(Debug, Name, {in, CurEvent, CurStatus}),
   try Module:handleOnevent(TimeoutType, TimeoutMsg, CurStatus, CurState) of
      Result ->
         handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, [CurEvent], Result, ?CB_FORM_EVENT, false)
   catch
      throw:Result ->
         handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, [CurEvent], Result, ?CB_FORM_EVENT, false);
      Class:Reason:Strace ->
         terminate(Class, Reason, Strace, Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, [CurEvent])
   end.

matchEpmCallMsg(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, From, Request) ->
   NewDebug = ?SYS_DEBUG(Debug, Name, {in, Request, CurStatus}),
   case Request of
      '$which_handlers' ->
         reply(From, EpmHers);
      {'$addEpm', EpmHandler, Args} ->
         {Reply, NewEpmHers, IsHib} = doAddEpm(EpmHers, EpmHandler, Args, undefined),
         reply(From, Reply),
         reLoopEntry(Parent, Name, Module, HibernateAfterTimeout, IsEnter, NewEpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, IsHib);
      {'$addSupEpm', EpmHandler, Args, EpmSup} ->
         {Reply, NewEpmHers, IsHib} = doAddSupEpm(EpmHers, EpmHandler, Args, EpmSup),
         reply(From, Reply),
         reLoopEntry(Parent, Name, Module, HibernateAfterTimeout, IsEnter, NewEpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, IsHib);
      {'$delEpm', EpmHandler, Args} ->
         {Reply, NewEpmHers} = doDelEpm(EpmHers, EpmHandler, Args),
         reply(From, Reply),
         receiveIng(Parent, Name, Module, HibernateAfterTimeout, IsEnter, NewEpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, false);
      {'$swapEpm', EpmId1, Args1, EpmId2, Args2} ->
         {Reply, NewEpmHers, IsHib} = doSwapEpm(EpmHers, EpmId1, Args1, EpmId2, Args2),
         reply(From, Reply),
         reLoopEntry(Parent, Name, Module, HibernateAfterTimeout, IsEnter, NewEpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, IsHib);
      {'$swapSupEpm', EpmId1, Args1, EpmId2, Args2, SupPid} ->
         {Reply, NewEpmHers, IsHib} = doSwapSupEpm(EpmHers, EpmId1, Args1, EpmId2, Args2, SupPid),
         reply(From, Reply),
         reLoopEntry(Parent, Name, Module, HibernateAfterTimeout, IsEnter, NewEpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, IsHib);
      {'$syncNotify', Event} ->
         {NewEpmHers, IsHib} = doNotify(EpmHers, handleEvent, Event, false),
         reply(From, ok),
         startEpmCall(Parent, Name, Module, HibernateAfterTimeout, IsEnter, NewEpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, handleEpmEvent, Request, IsHib);
      {'$epmCall', EpmHandler, Query} ->
         {NewEpmHers, IsHib} = doEpmHandle(EpmHers, EpmHandler, handleCall, Query, From),
         startEpmCall(Parent, Name, Module, HibernateAfterTimeout, IsEnter, NewEpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, handleEpmCall, Request, IsHib)
   end.

matchEpmInfoMsg(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, CmdOrEmpHandler, Event) ->
   NewDebug = ?SYS_DEBUG(Debug, Name, {in, {CmdOrEmpHandler, Event}, CurStatus}),
   case CmdOrEmpHandler of
      '$infoNotify' ->
         {NewEpmHers, IsHib} = doNotify(EpmHers, handleEvent, Event, false),
         startEpmCall(Parent, Name, Module, HibernateAfterTimeout, IsEnter, NewEpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, handleEpmEvent, Event, IsHib);
      EpmHandler ->
         {NewEpmHers, IsHib} = doEpmHandle(EpmHers, EpmHandler, handleInfo, Event,  false),
         startEpmCall(Parent, Name, Module, HibernateAfterTimeout, IsEnter, NewEpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, handleEpmInfo, Event, IsHib)
   end.

startEpmCall(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, CallbackFun, Event, IsHib) ->
   case erlang:function_exported(Module, CallbackFun, 3) of
      true ->
         NewDebug = ?SYS_DEBUG(Debug, Name, {in, Event, CurStatus}),
         try Module:CallbackFun(Event, CurStatus, CurState) of
            Result ->
               handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, [Event], Result, ?CB_FORM_EVENT, false)
         catch
            throw:Ret ->
               handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, [Event], Ret, ?CB_FORM_EVENT, false);
            Class:Reason:Strace ->
               terminate(Class, Reason, Strace, Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, [Event])
         end;
      _ ->
         receiveIng(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, IsHib)
   end.

startEnterCall(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, PrevStatus, CurState, CurStatus, Debug, LeftEvents, NextEs, IsPos, IsHib, DoAfter) ->
   try Module:handleEnter(PrevStatus, CurStatus, CurState) of
      Result ->
         handleEnterCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, PrevStatus, CurState, CurStatus, Debug, LeftEvents, NextEs, IsPos, IsHib, DoAfter, Result)
   catch
      throw:Result ->
         handleEnterCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, PrevStatus, CurState, CurStatus, Debug, LeftEvents, NextEs, IsPos, IsHib, DoAfter, Result);
      Class:Reason:Strace ->
         terminate(Class, Reason, Strace, Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents)
   end.

startAfterCall(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents, Args) ->
   try Module:handleAfter(Args, CurStatus, CurState) of
      Result ->
         handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents, Result, ?CB_FORM_AFTER, false)
   catch
      throw:Result ->
         handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents, Result, ?CB_FORM_AFTER, false);
      Class:Reason:Strace ->
         terminate(Class, Reason, Strace, Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents)
   end.

startEventCall(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents, {Type, Content}) ->
   case Type of
      'cast' ->
         try Module:handleCast(Content, CurStatus, CurState) of
            Result ->
               handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents, Result, ?CB_FORM_EVENT, false)
         catch
            throw:Ret ->
               handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents, Ret, ?CB_FORM_EVENT, false);
            Class:Reason:Strace ->
               terminate(Class, Reason, Strace, Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents)
         end;
      'info' ->
         try Module:handleInfo(Content, CurStatus, CurState) of
            Result ->
               handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents, Result, ?CB_FORM_EVENT, false)
         catch
            throw:Ret ->
               handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents, Ret, ?CB_FORM_EVENT, false);
            Class:Reason:Strace ->
               terminate(Class, Reason, Strace, Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents)
         end;
      {'call', From} ->
         try Module:handleCall(Content, CurStatus, CurState, From) of
            Result ->
               handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents, Result, ?CB_FORM_EVENT, From)
         catch
            throw:Ret ->
               handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents, Ret, ?CB_FORM_EVENT, From);
            Class:Reason:Strace ->
               terminate(Class, Reason, Strace, Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents)
         end;
      _ ->
         try Module:handleOnevent(Type, Content, CurStatus, CurState) of
            Result ->
               handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents, Result, ?CB_FORM_EVENT, false)
         catch
            throw:Ret ->
               handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents, Ret, ?CB_FORM_EVENT, false);
            Class:Reason:Strace ->
               terminate(Class, Reason, Strace, Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents)
         end
   end.

%% handleEpmCallbackRet
handleEpmCR(Result, EpmHers, #epmHer{epmId = EpmId} = EpmHer, Event, From) ->
   case Result of
      kpS ->
         {EpmHers, false};
      {ok, NewEpmS} ->
         MewEpmHer = setelement(#epmHer.epmS, EpmHer, NewEpmS),
         {EpmHers#{EpmId := MewEpmHer}, false};
      {ok, NewEpmS, hibernate} ->
         MewEpmHer = setelement(#epmHer.epmS, EpmHer, NewEpmS),
         {EpmHers#{EpmId := MewEpmHer}, true};
      {swapEpm, NewEpmS, Args1, EpmMId, Args2} ->
         #epmHer{epmId = OldEpmMId, epmSup = EpmSup} = MewEpmHer = setelement(#epmHer.epmS, EpmHer, NewEpmS),
         State = epmTerminate(MewEpmHer, Args1, swapped, {swapped, OldEpmMId, EpmSup}),
         TemEpmHers = maps:remove(EpmId, EpmHers),
         {_, NewEpmHers, IsHib} =
            case EpmSup of
               undefined ->
                  doAddEpm(TemEpmHers, EpmMId, {Args2, State}, undefined);
               _ ->
                  doAddSupEpm(TemEpmHers, EpmMId, {Args2, State}, EpmSup)
            end,
         {NewEpmHers, IsHib};
      {swapEpm, Reply, NewEpmS, Args1, EpmMId, Args2} ->
         reply(From, Reply),
         #epmHer{epmId = OldEpmMId, epmSup = EpmSup} = MewEpmHer = setelement(#epmHer.epmS, EpmHer, NewEpmS),
         State = epmTerminate(MewEpmHer, Args1, swapped, {swapped, OldEpmMId, EpmSup}),
         TemEpmHers = maps:remove(EpmId, EpmHers),
         {_, NewEpmHers, IsHib} =
            case EpmSup of
               undefined ->
                  doAddEpm(TemEpmHers, EpmMId, {Args2, State}, undefined);
               _ ->
                  doAddSupEpm(TemEpmHers, EpmMId, {Args2, State}, EpmSup)
            end,
         {NewEpmHers, IsHib};
      removeEpm ->
         epmTerminate(EpmHer, removeEpm, remove, normal),
         {maps:remove(EpmId, EpmHers), false};
      {removeEpm, Reply} ->
         reply(From, Reply),
         epmTerminate(EpmHer, removeEpm, remove, normal),
         {maps:remove(EpmId, EpmHers), false};
      {reply, Reply} ->
         reply(From, Reply),
         {EpmHers, false};
      {reply, Reply, NewEpmS} ->
         reply(From, Reply),
         MewEpmHer = setelement(#epmHer.epmS, EpmHer, NewEpmS),
         {EpmHers#{EpmId := MewEpmHer}, false};
      {reply, Reply, NewEpmS, hibernate} ->
         reply(From, Reply),
         MewEpmHer = setelement(#epmHer.epmS, EpmHer, NewEpmS),
         {EpmHers#{EpmId := MewEpmHer}, true};
      Other ->
         epmTerminate(EpmHer, {error, Other}, Event, crash),
         {maps:remove(EpmId, EpmHers), false}
   end.

%% handleEnterCallbackRet
handleEnterCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, PrevStatus, CurState, CurStatus, Debug, LeftEvents, NextEs, IsPos, IsHib, DoAfter, Result) ->
   case Result of
      {kpS, NewState} ->
         dealEnterCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, PrevStatus, NewState, CurStatus, Debug, LeftEvents, NextEs, IsPos, IsHib, DoAfter, false);
      {kpS, NewState, Actions} ->
         parseEnterAL(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, PrevStatus, NewState, CurStatus, Debug, LeftEvents, NextEs, IsPos, IsHib, DoAfter, false, listify(Actions));
      kpS_S ->
         dealEnterCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, PrevStatus, CurState, CurStatus, Debug, LeftEvents, NextEs, IsPos, IsHib, DoAfter, false);
      {kpS_S, Actions} ->
         parseEnterAL(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, PrevStatus, CurState, CurStatus, Debug, LeftEvents, NextEs, IsPos, IsHib, DoAfter, false, listify(Actions));
      {reS, NewState} ->
         dealEnterCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, PrevStatus, NewState, CurStatus, Debug, LeftEvents, NextEs, IsPos, IsHib, DoAfter, true);
      {reS, NewState, Actions} ->
         parseEnterAL(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, PrevStatus, NewState, CurStatus, Debug, LeftEvents, NextEs, IsPos, IsHib, DoAfter, true, listify(Actions));
      reS_S ->
         dealEnterCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, PrevStatus, CurState, CurStatus, Debug, LeftEvents, NextEs, IsPos, IsHib, DoAfter, true);
      {reS_S, Actions} ->
         parseEnterAL(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, PrevStatus, CurState, CurStatus, Debug, LeftEvents, NextEs, IsPos, IsHib, DoAfter, true, listify(Actions));
      stop ->
         terminate(exit, normal, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents);
      {stop, Reason} ->
         terminate(exit, Reason, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents);
      {stop, Reason, NewState} ->
         terminate(exit, Reason, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, Debug, LeftEvents);
      {stopReply, Reason, Replies} ->
         NewDebug = ?SYS_DEBUG(Debug, Name, {out, Replies}),
         try
            terminate(exit, Reason, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, LeftEvents)
         after
            case Replies of
               {reply, RFrom, Reply} ->
                  reply(RFrom, Reply);
               _ ->
                  [reply(RFrom, Reply) || {reply, RFrom, Reply} <- Replies],
                  ok
            end
         end;
      {stopReply, Reason, Replies, NewState} ->
         NewDebug = ?SYS_DEBUG(Debug, Name, {out, Replies}),
         try
            terminate(exit, Reason, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, NewDebug, LeftEvents)
         after
            case Replies of
               {reply, RFrom, Reply} ->
                  reply(RFrom, Reply);
               _ ->
                  [reply(RFrom, Reply) || {reply, RFrom, Reply} <- Replies],
                  ok
            end
         end;
      _ ->
         terminate(error, {bad_handleEnterCR, Result}, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents)
   end.

handleEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents, Result, CallbackForm, From) ->
   case Result of
      {noreply, NewState} ->
         receiveIng(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, Debug, false);
      {noreply, NewState, Option} ->
         case Option of
            hibernate ->
               reLoopEntry(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, Debug, true);
            {doAfter, Args} ->
               startAfterCall(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, Debug, [], Args);
            _Ret ->
               terminate(error, {bad_noreply, _Ret}, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, Debug, [])
         end;
      {reply, Reply, NewState} ->
         reply(From, Reply),
         NewDebug = ?SYS_DEBUG(Debug, Name, {out, Reply, From}),
         receiveIng(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, NewDebug, false);
      {reply, Reply, NewState, Option} ->
         reply(From, Reply),
         NewDebug = ?SYS_DEBUG(Debug, Name, {out, Reply, From}),
         case Option of
            hibernate ->
               reLoopEntry(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, NewDebug, true);
            {doAfter, Args} ->
               startAfterCall(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, NewDebug, [], Args);
            _Ret ->
               terminate(error, {bad_reply, _Ret}, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, Debug, [])
         end;
      {sreply, Reply, NewStatus, NewState} ->
         reply(From, Reply),
         NewDebug = ?SYS_DEBUG(Debug, Name, {out, Reply, From}),
         dealEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, NewStatus, NewDebug, LeftEvents, NewStatus =/= CurStatus);
      {sreply, Reply, NewStatus, NewState, Actions} ->
         reply(From, Reply),
         NewDebug = ?SYS_DEBUG(Debug, Name, {out, Reply, From}),
         parseEventAL(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, NewStatus, NewDebug, LeftEvents, NewStatus =/= CurStatus, listify(Actions), CallbackForm);
      {nextS, NewStatus, NewState} ->
         dealEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, NewStatus, Debug, LeftEvents, NewStatus =/= CurStatus);
      {nextS, NewStatus, NewState, Actions} ->
         parseEventAL(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, NewStatus, Debug, LeftEvents, NewStatus =/= CurStatus, listify(Actions), CallbackForm);
      {kpS, NewState} ->
         dealEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, CurStatus, Debug, LeftEvents, false);
      {kpS, NewState, Actions} ->
         parseEventAL(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, CurStatus, Debug, LeftEvents, false, listify(Actions), CallbackForm);
      kpS_S ->
         dealEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, CurStatus, Debug, LeftEvents, false);
      {kpS_S, Actions} ->
         parseEventAL(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, CurStatus, Debug, LeftEvents, false, listify(Actions), CallbackForm);
      {reS, NewState} ->
         dealEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, CurStatus, Debug, LeftEvents, true);
      {reS, NewState, Actions} ->
         parseEventAL(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, CurStatus, Debug, LeftEvents, true, listify(Actions), CallbackForm);
      reS_S ->
         dealEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, CurStatus, Debug, LeftEvents, true);
      {reS_S, Actions} ->
         parseEventAL(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, CurStatus, Debug, LeftEvents, true, listify(Actions), CallbackForm);
      stop ->
         terminate(exit, normal, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents);
      {stop, Reason} ->
         terminate(exit, Reason, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents);
      {stop, Reason, NewState} ->
         terminate(exit, Reason, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, Debug, LeftEvents);
      {stopReply, Reason, Replies} ->
         NewDebug = ?SYS_DEBUG(Debug, Name, {out, Replies}),
         try
            terminate(exit, Reason, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewDebug, LeftEvents)
         after
            case Replies of
               {reply, RFrom, Reply} ->
                  reply(RFrom, Reply);
               _ when is_list(Replies) ->
                  [reply(RFrom, Reply) || {reply, RFrom, Reply} <- Replies],
                  ok;
               _ ->
                  _ = reply(From, Replies)
            end
         end;
      {stopReply, Reason, Replies, NewState} ->
         NewDebug = ?SYS_DEBUG(Debug, Name, {out, Replies}),
         try
            terminate(exit, Reason, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, NewState, NewDebug, LeftEvents)
         after
            case Replies of
               {reply, RFrom, Reply} ->
                  _ = reply(RFrom, Reply);
               _ when is_list(Replies) ->
                  [reply(RFrom, Reply) || {reply, RFrom, Reply} <- Replies],
                  ok;
               _ ->
                  _ = reply(From, Replies)
            end
         end;
      _ ->
         terminate(error, {bad_handleEventCR, Result}, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents)
   end.

dealEnterCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewStatus, Debug, LeftEvents, NextEs, IsPos, IsHib, DoAfter, IsCallEnter) ->
   NewTimers = cancelESTimeout(CurStatus =:= NewStatus, Timers),
   case IsEnter andalso IsCallEnter of
      true ->
         startEnterCall(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, NewTimers, CurStatus, CurState, NewStatus, Debug, LeftEvents, NextEs, IsPos, IsHib, DoAfter);
      false ->
         performTransitions(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, NewTimers, CurStatus, CurState, NewStatus, Debug, LeftEvents, NextEs, IsPos, IsHib, DoAfter)
   end.

%% dealEventCallbackRet
dealEventCR(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewStatus, Debug, LeftEvents, IsCallEnter) ->
   NewTimers = cancelESTimeout(CurStatus =:= NewStatus, Timers),
   case IsEnter andalso IsCallEnter of
      true ->
         startEnterCall(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, NewTimers, CurStatus, CurState, NewStatus, Debug, LeftEvents, [], false, false, false);
      false ->
         performTransitions(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, NewTimers, CurStatus, CurState, NewStatus, Debug, LeftEvents, [], false, false, false)
   end.

%% 处理enter callback 动作列表
%% parseEnterActionsList
parseEnterAL(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewStatus, Debug, LeftEvents, NextEs, IsPos, IsCallEnter, IsHib, DoAfter, Actions) ->
   NewTimers = cancelESTimeout(CurStatus =:= NewStatus, Timers),
   %% enter 调用不能改成状态 actions 不能返回 IsPos = true 但是可以取消之前的推迟  设置IsPos = false 不能设置 doafter 不能插入事件
   case Actions of
      [] ->
         case IsEnter andalso IsCallEnter of
            true ->
               startEnterCall(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, NewTimers, CurStatus, CurState, NewStatus, Debug, LeftEvents, NextEs, IsPos, IsHib, DoAfter);
            _ ->
               performTransitions(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, NewTimers, CurStatus, CurState, NewStatus, Debug, LeftEvents, NextEs, IsPos, IsHib, DoAfter)
         end;
      _ ->
         case doParseAL(Actions, ?CB_FORM_ENTER, Name, IsEnter, NewTimers, Debug, IsPos, IsHib, DoAfter, NextEs) of
            {error, ErrorContent} ->
               terminate(error, ErrorContent, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, NewTimers, CurStatus, CurState, Debug, LeftEvents);
            {NewIsEnter, NNewTimers, NewDebug, NewIsPos, NewIsHib, DoAfter, NewNextEs} ->
               case NewIsEnter andalso IsCallEnter of
                  true ->
                     startEnterCall(Parent, Name, Module, HibernateAfterTimeout, NewIsEnter, EpmHers, Postponed, NNewTimers, CurStatus, CurState, NewStatus, NewDebug, LeftEvents, NewNextEs, NewIsPos, NewIsHib, DoAfter);
                  _ ->
                     performTransitions(Parent, Name, Module, HibernateAfterTimeout, NewIsEnter, EpmHers, Postponed, NNewTimers, CurStatus, CurState, NewStatus, NewDebug, LeftEvents, NewNextEs, NewIsPos, NewIsHib, DoAfter)
               end
         end
   end.

%% 处理非 enter 或者after callback 返回的动作列表
%% parseEventActionsList
parseEventAL(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewStatus, Debug, LeftEvents, IsCallEnter, Actions, CallbackForm) ->
   NewTimers = cancelESTimeout(CurStatus =:= NewStatus, Timers),
   case Actions of
      [] ->
         case IsEnter andalso IsCallEnter of
            true ->
               startEnterCall(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, NewTimers, CurStatus, CurState, NewStatus, Debug, LeftEvents, [], false, false, false);
            _ ->
               performTransitions(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, NewTimers, CurStatus, CurState, NewStatus, Debug, LeftEvents, [], false, false, false)
         end;
      _ ->
         case doParseAL(Actions, CallbackForm, Name, IsEnter, NewTimers, Debug, false, false, false, []) of
            {error, ErrorContent} ->
               terminate(error, ErrorContent, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, []);
            {NewIsEnter, NNewTimers, NewDebug, NewIsPos, NewIsHib, MewDoAfter, NewNextEs} ->
               case NewIsEnter andalso IsCallEnter of
                  true ->
                     startEnterCall(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, NNewTimers, CurStatus, CurState, NewStatus, NewDebug, LeftEvents, NewNextEs, NewIsPos, NewIsHib, MewDoAfter);
                  _ ->
                     performTransitions(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, NNewTimers, CurStatus, CurState, NewStatus, NewDebug, LeftEvents, NewNextEs, NewIsPos, NewIsHib, MewDoAfter)
               end
         end
   end.

%% loopParseActionsList
doParseAL([], _CallbackForm, _Name, IsEnter, Times, Debug, IsPos, IsHib, DoAfter, NextEs) ->
   {IsEnter, Times, Debug, IsPos, IsHib, DoAfter, NextEs};
doParseAL([OneAction | LeftActions], CallbackForm, Name, IsEnter, Timers, Debug, IsPos, IsHib, DoAfter, NextEs) ->
   case OneAction of
      {reply, From, Reply} ->
         reply(From, Reply),
         NewDebug = ?SYS_DEBUG(Debug, Name, {out, Reply, From}),
         doParseAL(LeftActions, CallbackForm, Name, IsEnter, Timers, NewDebug, IsPos, IsHib, DoAfter, NextEs);
      {eTimeout, Time, TimeoutMsg} ->
         case Time of
            infinity ->
               NewTimers = doCancelTimer(eTimeout, Timers),
               doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, Debug, IsPos, IsHib, DoAfter, NextEs);
            _ ->
               TimerRef = erlang:start_timer(Time, self(), eTimeout),
               NewDebug = ?SYS_DEBUG(Debug, Name, {start_timer, {eTimeout, Time, TimeoutMsg, []}}),
               NewTimers = doRegisterTimer(eTimeout, TimerRef, TimeoutMsg, Timers),
               doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, NewDebug, IsPos, IsHib, DoAfter, NextEs)
         end;
      {sTimeout, Time, TimeoutMsg} ->
         case Time of
            infinity ->
               NewTimers = doCancelTimer(sTimeout, Timers),
               doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, Debug, IsPos, IsHib, DoAfter, NextEs);
            _ ->
               TimerRef = erlang:start_timer(Time, self(), sTimeout),
               NewDebug = ?SYS_DEBUG(Debug, Name, {start_timer, {sTimeout, Time, TimeoutMsg, []}}),
               NewTimers = doRegisterTimer(sTimeout, TimerRef, TimeoutMsg, Timers),
               doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, NewDebug, IsPos, IsHib, DoAfter, NextEs)
         end;
      {gTimeout, TimeoutName, Time, TimeoutMsg} ->
         case Time of
            infinity ->
               NewTimers = doCancelTimer(TimeoutName, Timers),
               doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, Debug, IsPos, IsHib, DoAfter, NextEs);
            _ ->
               TimerRef = erlang:start_timer(Time, self(), TimeoutName),
               NewDebug = ?SYS_DEBUG(Debug, Name, {start_timer, {TimeoutName, Time, TimeoutMsg, []}}),
               NewTimers = doRegisterTimer(TimeoutName, TimerRef, TimeoutMsg, Timers),
               doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, NewDebug, IsPos, IsHib, DoAfter, NextEs)
         end;
      {eTimeout, Time, TimeoutMsg, Options} ->
         case Time of
            infinity ->
               NewTimers = doCancelTimer(eTimeout, Timers),
               doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, Debug, IsPos, IsHib, DoAfter, NextEs);
            _ ->
               TimerRef = erlang:start_timer(Time, self(), eTimeout, Options),
               NewDebug = ?SYS_DEBUG(Debug, Name, {start_timer, {eTimeout, Time, TimeoutMsg, Options}}),
               NewTimers = doRegisterTimer(eTimeout, TimerRef, TimeoutMsg, Timers),
               doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, NewDebug, IsPos, IsHib, DoAfter, NextEs)
         end;
      {sTimeout, Time, TimeoutMsg, Options} ->
         case Time of
            infinity ->
               NewTimers = doCancelTimer(sTimeout, Timers),
               doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, Debug, IsPos, IsHib, DoAfter, NextEs);
            _ ->
               TimerRef = erlang:start_timer(Time, self(), sTimeout, Options),
               NewDebug = ?SYS_DEBUG(Debug, Name, {start_timer, {sTimeout, Time, TimeoutMsg, Options}}),
               NewTimers = doRegisterTimer(sTimeout, TimerRef, TimeoutMsg, Timers),
               doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, NewDebug, IsPos, IsHib, DoAfter, NextEs)
         end;
      {gTimeout, TimeoutName, Time, TimeoutMsg, Options} ->
         case Time of
            infinity ->
               NewTimers = doCancelTimer(TimeoutName, Timers),
               doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, Debug, IsPos, IsHib, DoAfter, NextEs);
            _ ->
               TimerRef = erlang:start_timer(Time, self(), TimeoutName, Options),
               NewDebug = ?SYS_DEBUG(Debug, Name, {start_timer, {TimeoutName, Time, TimeoutMsg, Options}}),
               NewTimers = doRegisterTimer(TimeoutName, TimerRef, TimeoutMsg, Timers),
               doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, NewDebug, IsPos, IsHib, DoAfter, NextEs)
         end;
      {u_eTimeout, NewTimeoutMsg} ->
         NewTimers = doUpdateTimer(eTimeout, NewTimeoutMsg, Timers),
         doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, Debug, IsPos, IsHib, DoAfter, NextEs);
      {u_sTimeout, NewTimeoutMsg} ->
         NewTimers = doUpdateTimer(sTimeout, NewTimeoutMsg, Timers),
         doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, Debug, IsPos, IsHib, DoAfter, NextEs);
      {u_gTimeout, TimeoutName, NewTimeoutMsg} ->
         NewTimers = doUpdateTimer(TimeoutName, NewTimeoutMsg, Timers),
         doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, Debug, IsPos, IsHib, DoAfter, NextEs);
      c_eTimeout ->
         NewTimers = doCancelTimer(eTimeout, Timers),
         doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, Debug, IsPos, IsHib, DoAfter, NextEs);
      c_sTimeout ->
         NewTimers = doCancelTimer(sTimeout, Timers),
         doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, Debug, IsPos, IsHib, DoAfter, NextEs);
      {c_gTimeout, TimeoutName} ->
         NewTimers = doCancelTimer(TimeoutName, Timers),
         doParseAL(LeftActions, CallbackForm, Name, IsEnter, NewTimers, Debug, IsPos, IsHib, DoAfter, NextEs);
      {isEnter, NewIsEnter} ->
         NewDebug = ?SYS_DEBUG(Debug, Name, {change_isEnter, NewIsEnter}),
         doParseAL(LeftActions, CallbackForm, Name, Timers, NewIsEnter, NewDebug, IsPos, IsHib, DoAfter, NextEs);
      {isHib, NewIsHib} ->
         doParseAL(LeftActions, CallbackForm, Name, IsEnter, Timers, Debug, IsPos, NewIsHib, DoAfter, NextEs);
      {isPos, NewIsPos} when (not NewIsPos orelse CallbackForm == ?CB_FORM_EVENT) ->
         doParseAL(LeftActions, CallbackForm, Name, IsEnter, Timers, Debug, NewIsPos, IsHib, DoAfter, NextEs);
      {doAfter, Args} when CallbackForm == ?CB_FORM_EVENT ->
         doParseAL(LeftActions, CallbackForm, Name, IsEnter, Timers, Debug, IsPos, IsHib, {true, Args}, NextEs);
      {nextE, Type, Content} when CallbackForm == ?CB_FORM_EVENT orelse CallbackForm == ?CB_FORM_AFTER ->
         %% 处理next_event动作
         doParseAL(LeftActions, CallbackForm, Name, IsEnter, Timers, Debug, IsPos, IsHib, DoAfter, [{Type, Content} | NextEs]);
      _ ->
         {error, {bad_ActionType, OneAction}}
   end.

% checkTimeOptions({TimeoutType, Time, TimeoutMsg, Options} = NewTV) ->
%    case Options of
%       [{abs, true}] when ?ABS_TIMEOUT(Time) ->
%          NewTV;
%       [{abs, false}] when ?REL_TIMEOUT(Time) ->
%          {TimeoutType, Time, TimeoutMsg};
%       [] when ?REL_TIMEOUT(Time) ->
%          {TimeoutType, Time, TimeoutMsg};
%       _ ->
%          %% 如果将来 start_timer opt扩展了 这里的代码也要修改
%          error_timeout_opt
%    end.

%% 进行状态转换
performTransitions(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, NewStatus, Debug, AllLeftEvents, NextEs, IsPos, IsHib, DoAfter) ->
   %% 已收集所有选项，并缓冲next_events。执行实际状态转换。如果推迟则将当前事件移至推迟
   %% 此时 NextEs的顺序与最开始出现的顺序相反. 后面执行的顺序 当前新增事件 + 反序的Postpone事件 + LeftEvents
   case AllLeftEvents of
      [] ->
         CurEvent = undefined,
         LeftEvents = [];
      _ ->
         [CurEvent | LeftEvents] = AllLeftEvents
   end,

   NewDebug = ?SYS_DEBUG(Debug, Name, case IsPos of true -> {postpone, CurEvent, CurStatus, NewStatus}; _ -> {consume, CurEvent, CurStatus, NewStatus} end),
   if
      CurStatus =:= NewStatus ->
         %% Cancel event timeout
         if
            IsPos ->
               LastLeftEvents =
                  case NextEs of
                     [] ->
                        LeftEvents;
                     [Es1] ->
                        [Es1 | LeftEvents];
                     [Es2, Es1] ->
                        [Es1, Es2 | LeftEvents];
                     _ ->
                        lists:reverse(NextEs, LeftEvents)
                  end,
               performEvents(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, [CurEvent | Postponed], Timers, NewStatus, CurState, NewDebug, LastLeftEvents, IsHib, DoAfter);
            true ->
               LastLeftEvents =
                  case NextEs of
                     [] ->
                        LeftEvents;
                     [Es1] ->
                        [Es1 | LeftEvents];
                     [Es2, Es1] ->
                        [Es1, Es2 | LeftEvents];
                     _ ->
                        lists:reverse(NextEs, LeftEvents)
                  end,
               performEvents(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, NewStatus, CurState, NewDebug, LastLeftEvents, IsHib, DoAfter)
         end;
      true ->
         %% 状态发生改变 重试推迟的事件
         if
            IsPos ->
               NewLeftEvents =
                  case Postponed of
                     [] ->
                        [CurEvent | LeftEvents];
                     [E1] ->
                        [E1, CurEvent | LeftEvents];
                     [E2, E1] ->
                        [E1, E2, CurEvent | LeftEvents];
                     _ ->
                        lists:reverse(Postponed, [CurEvent | LeftEvents])
                  end,
               LastLeftEvents =
                  case NextEs of
                     [] ->
                        NewLeftEvents;
                     [Es1] ->
                        [Es1 | NewLeftEvents];
                     [Es2, Es1] ->
                        [Es1, Es2 | NewLeftEvents];
                     _ ->
                        lists:reverse(NextEs, NewLeftEvents)
                  end,
               performEvents(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, [], Timers, NewStatus, CurState, NewDebug, LastLeftEvents, IsHib, DoAfter);
            true ->
               NewLeftEvents =
                  case Postponed of
                     [] ->
                        LeftEvents;
                     [E1] ->
                        [E1 | LeftEvents];
                     [E2, E1] ->
                        [E1, E2 | LeftEvents];
                     _ ->
                        lists:reverse(Postponed, LeftEvents)
                  end,
               LastLeftEvents =
                  case NextEs of
                     [] ->
                        NewLeftEvents;
                     [Es1] ->
                        [Es1 | NewLeftEvents];
                     [Es2, Es1] ->
                        [Es1, Es2 | NewLeftEvents];
                     _ ->
                        lists:reverse(NextEs, NewLeftEvents)
                  end,
               performEvents(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, [], Timers, NewStatus, CurState, NewDebug, LastLeftEvents, IsHib, DoAfter)
         end
   end.

%% 状态转换已完成，如果有排队事件，则继续循环，否则获取新事件
performEvents(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents, IsHib, DoAfter) ->
%  io:format("loop_done: status_data = ~p ~n postponed = ~p  LeftEvents = ~p ~n timers = ~p.~n", [S#status.status_data,,S#status.postponed,LeftEvents,S#status.timers]),
   case DoAfter of
      {true, Args} ->
         %% 这里 IsHib设置会被丢弃 按照gen_server中的设计 continue 和 hiernate是互斥的
         startAfterCall(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents, Args);
      _ ->
         case LeftEvents of
            [] ->
               reLoopEntry(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, IsHib);
            [Event | _Events] ->
               %% 循环直到没有排队事件
               if
                  IsHib ->
                     %% _ = garbage_collect(),
                     erts_internal:garbage_collect(major);
                  true ->
                     ignore
               end,
               startEventCall(Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents, Event)
         end
   end.

%% 取消事件超时 和  状态超时
cancelESTimeout(true, Timers) ->
   %% Cancel event timeout
   case Timers of
      #{eTimeout := {TimerRef, _TimeoutMsg}} ->
         cancelTimer(eTimeout, TimerRef, Timers);
      _ ->
         Timers
   end;
cancelESTimeout(false, Timers) ->
%% 取消 status and event timeout
   case Timers of
      #{sTimeout := {STimerRef, _STimeoutMsg}} ->
         TemTimer = cancelTimer(sTimeout, STimerRef, Timers),
         case TemTimer of
            #{eTimeout := {ETimerRef, _ETimeoutMsg}} ->
               cancelTimer(eTimeout, ETimerRef, TemTimer);
            _ ->
               TemTimer
         end;
      _ ->
         case Timers of
            #{eTimeout := {ETimerRef, _ETimeoutMsg}} ->
               cancelTimer(eTimeout, ETimerRef, Timers);
            _ ->
               Timers
         end
   end.

doRegisterTimer(TimeoutType, NewTimerRef, TimeoutMsg, Timers) ->
   case Timers of
      #{TimeoutType := {OldTimerRef, _OldTimeMsg}} ->
         justCancelTimer(TimeoutType, OldTimerRef),
         Timers#{TimeoutType := {NewTimerRef, TimeoutMsg}};
      _ ->
         Timers#{TimeoutType => {NewTimerRef, TimeoutMsg}}
   end.

doCancelTimer(TimeoutType, Timers) ->
   case Timers of
      #{TimeoutType := {TimerRef, _TimeoutMsg}} ->
         cancelTimer(TimeoutType, TimerRef, Timers);
      _ ->
         Timers
   end.

doUpdateTimer(TimeoutType, Timers, TimeoutMsg) ->
   case Timers of
      #{TimeoutType := {TimerRef, _OldTimeoutMsg}} ->
         Timers#{TimeoutType := {TimerRef, TimeoutMsg}};
      _ ->
         Timers
   end.

justCancelTimer(TimeoutType, TimerRef) ->
   case erlang:cancel_timer(TimerRef) of
      false ->
         %% 找不到计时器，我们还没有看到超时消息
         receive
            {timeout, TimerRef, TimeoutType} ->
               %% 丢弃该超时消息
               ok
         after 0 ->
            ok
         end;
      _ ->
         %% Timer 已经运行了
         ok
   end.

cancelTimer(TimeoutType, TimerRef, Timers) ->
   case erlang:cancel_timer(TimerRef) of
      false ->
         %% 找不到计时器，我们还没有看到超时消息
         receive
            {timeout, TimerRef, TimeoutType} ->
               %% 丢弃该超时消息
               ok
         after 0 ->
            ok
         end;
      _ ->
         %% Timer 已经运行了
         ok
   end,
   maps:remove(TimeoutType, Timers).

%% 排队立即超时事件（超时0事件）
%% 自事件超时0起，事件得到特殊处理
%% 任何收到的事件都会取消事件超时，
%% 因此，如果在事件超时0事件之前存在入队事件-事件超时被取消，因此没有事件。
%% 其他（status_timeout和{timeout，Name}）超时0个事件
%% 在事件计时器超时0事件之后发生的事件被认为是
%% 属于在事件计时器之后启动的计时器
%% 已触发超时0事件，因此它们不会取消事件计时器。
%% mergeTimeoutEvents([], _Status, _CycleData, Debug, Events) ->
%%    {Events, Debug};
%% mergeTimeoutEvents([{eTimeout, _} = TimeoutEvent | TimeoutEvents], Status, CycleData, Debug, []) ->
%%    %% 由于队列中没有其他事件，因此添加该事件零超时事件
%%    NewDebug = ?SYS_DEBUG(Debug, CycleData, {insert_timeout, TimeoutEvent, Status}),
%%    mergeTimeoutEvents(TimeoutEvents, Status, CycleData, NewDebug, [TimeoutEvent]);
%% mergeTimeoutEvents([{eTimeout, _} | TimeoutEvents], Status, CycleData, Debug, Events) ->
%%    %% 忽略，因为队列中还有其他事件，因此它们取消了事件超时0。
%%    mergeTimeoutEvents(TimeoutEvents, Status, CycleData, Debug, Events);
%% mergeTimeoutEvents([TimeoutEvent | TimeoutEvents], Status, CycleData, Debug, Events) ->
%%    %% Just prepend all others
%%    NewDebug = ?SYS_DEBUG(Debug, CycleData, {insert_timeout, TimeoutEvent, Status}),
%%    mergeTimeoutEvents(TimeoutEvents, Status, CycleData, NewDebug, [TimeoutEvent | Events]).

%% Return a list of all pending timeouts
listTimeouts(Timers) ->
   {maps:size(Timers), allTimer(maps:iterator(Timers), [])}.

allTimer(Iterator, Acc) ->
   case maps:next(Iterator) of
      {TimeoutType, {_TimerRef, TimeoutMsg}, NextIterator}  ->
         allTimer(NextIterator, [{TimeoutType, TimeoutMsg} | Acc]);
      none ->
         Acc
   end.

%%---------------------------------------------------------------------------

terminate(Class, Reason, Stacktrace, Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents) ->
   epmStopAll(EpmHers),
   %% 这里停止所有的epm 但是并没有更新 epmHers为#{} 目前感觉没必要清理掉
   case erlang:function_exported(Module, terminate, 3) of
      true ->
         try Module:terminate(Reason, CurStatus, CurState) of
            _ -> ok
         catch
            throw:_ -> ok;
            C:R ->
               error_info(C, R, ?STACKTRACE(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents),
               erlang:raise(C, R, ?STACKTRACE())
         end;
      false ->
         ok
   end,
   case Reason of
      normal ->
         ?SYS_DEBUG(Debug, Name, {terminate, Reason, CurStatus});
      shutdown ->
         ?SYS_DEBUG(Debug, Name, {terminate, Reason, CurStatus});
      {shutdown, _} ->
         ?SYS_DEBUG(Debug, Name, {terminate, Reason, CurStatus});
      _ ->
         error_info(Class, Reason, Stacktrace, Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents)
   end,
   case Stacktrace of
      [] ->
         erlang:Class(Reason);
      _ ->
         erlang:raise(Class, Reason, Stacktrace)
   end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% debug 日志 Start%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
error_info(Class, Reason, Stacktrace, Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState, Debug, LeftEvents) ->
   Log = sys:get_log(Debug),
   ?LOG_ERROR(
      #{
         label => {es_gen_ipc, terminate},
         name => Name,
         module => Module,
         queue => LeftEvents,
         postponed => Postponed,
         isEnter => IsEnter,
         status => format_status(terminate, get(), Parent, Name, Module, HibernateAfterTimeout, IsEnter, EpmHers, Postponed, Timers, CurStatus, CurState),
         timeouts => listTimeouts(Timers),
         log => Log,
         reason => {Class, Reason, Stacktrace},
         client_info => cliStacktrace(LeftEvents)
      },
      #{
         domain => [otp],
         report_cb => fun es_gen_ipc:format_log/2,
         error_logger => #{tag => error, report_cb => fun es_gen_ipc:format_log/1}}).

cliStacktrace([]) ->
   undefined;
cliStacktrace([{{call, {Pid, _Tag}}, _Req} | _]) when is_pid(Pid) ->
   if
      node(Pid) =:= node() ->
         case process_info(Pid, [current_stacktrace, registered_name]) of
            undefined ->
               {Pid, dead};
            [{current_stacktrace, Stacktrace}, {registered_name, []}] ->
               {Pid, {Pid, Stacktrace}};
            [{current_stacktrace, Stacktrace}, {registered_name, Name}] ->
               {Pid, {Name, Stacktrace}}
         end;
      true ->
         {Pid, remote}
   end;
cliStacktrace([_ | _]) ->
   undefined;
cliStacktrace(_) ->
   undefined.

%% format_log/1 is the report callback used by Logger handler
%% error_logger only. It is kept for backwards compatibility with
%% legacy error_logger event handlers. This function must always
%% return {Format,Args} compatible with the arguments in this module's
%% calls to error_logger prior to OTP-21.0.
format_log(Report) ->
   Depth = error_logger:get_format_depth(),
   FormatOpts = #{
      chars_limit => unlimited,
      depth => Depth,
      single_line => false,
      encoding => utf8
   },
   format_log_multi(limit_report(Report, Depth), FormatOpts).

limit_report(Report, unlimited) ->
   Report;
limit_report(
   #{
      label := {es_gen_ipc, terminate},
      queue := Q,
      postponed := Postponed,
      module := Module,
      status := FmtData,
      timeouts := Timeouts,
      log := Log,
      reason := {Class, Reason, Stacktrace},
      client_info := ClientInfo
   } = Report,
   Depth) ->
   Report#{
      queue =>
      case Q of
         [Event | Events] ->
            [io_lib:limit_term(Event, Depth) | io_lib:limit_term(Events, Depth)];
         _ ->
            []
      end,
      postponed =>
      case Postponed of
         [] -> [];
         _ -> io_lib:limit_term(Postponed, Depth)
      end,
      modules => io_lib:limit_term(Module, Depth),
      status => io_lib:limit_term(FmtData, Depth),
      timeouts =>
      case Timeouts of
         {0, _} -> Timeouts;
         _ -> io_lib:limit_term(Timeouts, Depth)
      end,
      log =>
      case Log of
         [] -> [];
         _ -> [io_lib:limit_term(T, Depth) || T <- Log]
      end,
      reason =>
      {Class, io_lib:limit_term(Reason, Depth), io_lib:limit_term(Stacktrace, Depth)},
      client_info => limit_client_info(ClientInfo, Depth)
   }.

limit_client_info({Pid, {Name, Stacktrace}}, Depth) ->
   {Pid, {Name, io_lib:limit_term(Stacktrace, Depth)}};
limit_client_info(Client, _Depth) ->
   Client.

%% format_log/2 is the report callback for any Logger handler, except
%% error_logger.
format_log(Report, FormatOpts0) ->
   Default = #{
      chars_limit => unlimited,
      depth => unlimited,
      single_line => false,
      encoding => utf8
   },
   FormatOpts = maps:merge(Default, FormatOpts0),
   IoOpts =
      case FormatOpts of
         #{chars_limit := unlimited} -> [];
         #{chars_limit := Limit} -> [{chars_limit, Limit}]
      end,
   {Format, Args} = format_log_single(Report, FormatOpts),
   io_lib:format(Format, Args, IoOpts).

format_log_single(
   #{
      label := {es_gen_ipc, terminate},
      name := Name,
      queue := Q,
      %% postponed
      %% isEnter
      status := FmtData,
      %% timeouts
      log := Log,
      reason := {Class, Reason, Stacktrace},
      client_info := ClientInfo
   },
   #{single_line := true, depth := Depth} = FormatOpts) ->
   P = p(FormatOpts),
   {FixedReason, FixedStacktrace} = fix_reason(Class, Reason, Stacktrace),
   {ClientFmt, ClientArgs} = format_client_log_single(ClientInfo, P, Depth),
   Format =
      lists:append(
         ["State machine ", P, " terminating. Reason: ", P,
            case FixedStacktrace of
               [] -> "";
               _ -> ". Stack: " ++ P
            end,
            case Q of
               [] -> "";
               _ -> ". Last event: " ++ P
            end,
            ". State: ", P,
            case Log of
               [] -> "";
               _ -> ". Log: " ++ P
            end,
            "."]
      ),
   Args0 =
      [Name, FixedReason] ++
      case FixedStacktrace of
         [] -> [];
         _ -> [FixedStacktrace]
      end ++
      case Q of
         [] -> [];
         [Event | _] -> [Event]
      end ++
      [FmtData] ++
      case Log of
         [] -> [];
         _ -> [Log]
      end,
   Args =
      case Depth of
         unlimited ->
            Args0;
         _ ->
            lists:flatmap(fun(A) -> [A, Depth] end, Args0)
      end,
   {Format ++ ClientFmt, Args ++ ClientArgs};
format_log_single(Report, FormatOpts) ->
   format_log_multi(Report, FormatOpts).

format_log_multi(
   #{
      label := {es_gen_ipc, terminate},
      name := Name,
      queue := Q,
      postponed := Postponed,
      module := Module,
      isEnter := StateEnter,
      status := FmtData,
      timeouts := Timeouts,
      log := Log,
      reason := {Class, Reason, Stacktrace},
      client_info := ClientInfo
   },
   #{depth := Depth} = FormatOpts) ->
   P = p(FormatOpts),
   {FixedReason, FixedStacktrace} = fix_reason(Class, Reason, Stacktrace),
   {ClientFmt, ClientArgs} = format_client_log(ClientInfo, P, Depth),
   CBMode =
      case StateEnter of
         true ->
            [Module, 'isEnter=true'];
         false ->
            Module
      end,
   Format =
      lists:append(
         ["** es_gen_ipc State machine ", P, " terminating~n",
            case Q of
               [] -> "";
               _ -> "** Last event = " ++ P ++ "~n"
            end,
            "** When server status  = ", P, "~n",
            "** Reason for termination = ", P, ":", P, "~n",
            "** Callback modules = ", P, "~n",
            "** Callback mode = ", P, "~n",
            case Q of
               [_, _ | _] -> "** Queued = " ++ P ++ "~n";
               _ -> ""
            end,
            case Postponed of
               [] -> "";
               _ -> "** Postponed = " ++ P ++ "~n"
            end,
            case FixedStacktrace of
               [] -> "";
               _ -> "** Stacktrace =~n**  " ++ P ++ "~n"
            end,
            case Timeouts of
               {0, _} -> "";
               _ -> "** Time-outs: " ++ P ++ "~n"
            end,
            case Log of
               [] -> "";
               _ -> "** Log =~n**  " ++ P ++ "~n"
            end]),
   Args0 =
      [Name |
         case Q of
            [] -> [];
            [Event | _] -> [Event]
         end] ++
      [FmtData,
         Class, FixedReason,
         Module,
         CBMode] ++
      case Q of
         [_ | [_ | _] = Events] -> [Events];
         _ -> []
      end ++
      case Postponed of
         [] -> [];
         _ -> [Postponed]
      end ++
      case FixedStacktrace of
         [] -> [];
         _ -> [FixedStacktrace]
      end ++
      case Timeouts of
         {0, _} -> [];
         _ -> [Timeouts]
      end ++
      case Log of
         [] -> [];
         _ -> [Log]
      end,
   Args =
      case Depth of
         unlimited ->
            Args0;
         _ ->
            lists:flatmap(fun(A) -> [A, Depth] end, Args0)
      end,
   {Format ++ ClientFmt, Args ++ ClientArgs}.

fix_reason(Class, Reason, Stacktrace) ->
   case Stacktrace of
      [{M, F, Args, _} | ST]
         when Class =:= error, Reason =:= undef ->
         case code:is_loaded(M) of
            false ->
               {{'module could not be loaded', M}, ST};
            _ ->
               Arity =
                  if
                     is_list(Args) ->
                        length(Args);
                     is_integer(Args) ->
                        Args
                  end,
               case erlang:function_exported(M, F, Arity) of
                  true ->
                     {Reason, Stacktrace};
                  false ->
                     {{'function not exported', {M, F, Arity}}, ST}
               end
         end;
      _ -> {Reason, Stacktrace}
   end.

format_client_log_single(undefined, _, _) ->
   {"", []};
format_client_log_single({Pid, dead}, _, _) ->
   {" Client ~0p is dead.", [Pid]};
format_client_log_single({Pid, remote}, _, _) ->
   {" Client ~0p is remote on node ~0p.", [Pid, node(Pid)]};
format_client_log_single({_Pid, {Name, Stacktrace0}}, P, Depth) ->
   %% Minimize the stacktrace a bit for single line reports. This is
   %% hopefully enough to point out the position.
   Stacktrace = lists:sublist(Stacktrace0, 4),
   Format = lists:append([" Client ", P, " stacktrace: ", P, "."]),
   Args =
      case Depth of
         unlimited ->
            [Name, Stacktrace];
         _ ->
            [Name, Depth, Stacktrace, Depth]
      end,
   {Format, Args}.

format_client_log(undefined, _, _) ->
   {"", []};
format_client_log({Pid, dead}, _, _) ->
   {"** Client ~p is dead~n", [Pid]};
format_client_log({Pid, remote}, _, _) ->
   {"** Client ~p is remote on node ~p~n", [Pid, node(Pid)]};
format_client_log({_Pid, {Name, Stacktrace}}, P, Depth) ->
   Format = lists:append(["** Client ", P, " stacktrace~n** ", P, "~n"]),
   Args =
      case Depth of
         unlimited ->
            [Name, Stacktrace];
         _ ->
            [Name, Depth, Stacktrace, Depth]
      end,
   {Format, Args}.

p(#{single_line := Single, depth := Depth, encoding := Enc}) ->
   "~" ++ single(Single) ++ mod(Enc) ++ p(Depth);
p(unlimited) ->
   "p";
p(_Depth) ->
   "P".

single(true) -> "0";
single(false) -> "".

mod(latin1) -> "";
mod(_) -> "t".

%% Call Module:format_status/2 or return a default value
format_status(Opt, PDict, _Parent, _Name, Module, _HibernateAfterTimeout, _IsEnter, _EpmHers, _Postponed, _Timers, CurStatus, CurState) ->
   case erlang:function_exported(Module, formatStatus, 2) of
      true ->
         try Module:formatStatus(Opt, [PDict, CurStatus, CurState])
         catch
            throw:Result -> Result;
            _:_ ->
               format_status_default(Opt, {{CurStatus, CurState}, atom_to_list(Module) ++ ":formatStatus/2 crashed"})
         end;
      false ->
         format_status_default(Opt, {CurStatus, CurState})
   end.

%% The default Module:format_status/3
format_status_default(Opt, State_Data) ->
   case Opt of
      terminate ->
         State_Data;
      _ ->
         [{data, [{"State", State_Data}]}]
   end.

print_event(Dev, SystemEvent, Name) ->
   case SystemEvent of
      {in, Event, Status} ->
         io:format(
            Dev, "*DBG* ~tp receive ~ts in Status ~tp~n",
            [Name, event_string(Event), Status]);
      {code_change, Event, Status} ->
         io:format(
            Dev, "*DBG* ~tp receive ~ts after code change in Status ~tp~n",
            [Name, event_string(Event), Status]);
      {out, Reply, {To, _Tag}} ->
         io:format(
            Dev, "*DBG* ~tp send ~tp to ~tw~n",
            [Name, Reply, To]);
      {out, Replys} ->
         io:format(
            Dev, "*DBG* ~tp sends to: ~tp~n",
            [Name, Replys]);
      {enter, Status} ->
         io:format(
            Dev, "*DBG* ~tp enter in Status ~tp~n",
            [Name, Status]);
      {start_timer, Action} ->
         io:format(
            Dev, "*DBG* ~tp start_timer ~tp ~n",
            [Name, Action]);
      {insert_timeout, Event, Status} ->
         io:format(
            Dev, "*DBG* ~tp insert_timeout ~tp in Status ~tp~n",
            [Name, Event, Status]);
      {terminate, Reason, Status} ->
         io:format(
            Dev, "*DBG* ~tp terminate ~tp in Status ~tp~n",
            [Name, Reason, Status]);
      {change_isEnter, IsEnter} ->
         io:format(
            Dev, "*DBG* ~tp change_isEnter to ~tp ~n",
            [Name, IsEnter]);
      {Tag, Event, Status, NextStatus}
         when Tag =:= postpone; Tag =:= consume ->
         StateString =
            case NextStatus of
               Status ->
                  io_lib:format("~tp", [Status]);
               _ ->
                  io_lib:format("~tp => ~tp", [Status, NextStatus])
            end,
         io:format(
            Dev, "*DBG* ~tp ~tw ~ts in state ~ts~n",
            [Name, Tag, event_string(Event), StateString]);
      _NotMatch ->
         io:format(
            Dev, "*DBG* ~tp NotMatch ~tp ~n",
            [Name, _NotMatch])
   end.

event_string(Event) ->
   case Event of
      {{call, {Pid, _Tag}}, Request} ->
         io_lib:format("call ~tp from ~tw", [Request, Pid]);
      {EventType, EventContent} ->
         io_lib:format("~tw ~tp", [EventType, EventContent])
   end.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%% debug 日志 End %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%