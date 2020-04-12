-module(erlSync_sup).
-behaviour(supervisor).

-export([
   start_link/0
   , init/1
]).

-define(SERVER, ?MODULE).
-define(ChildSpec(I, Type), #{id => I, start => {I, start_link, []}, restart => permanent, shutdown => 5000, type => Type, modules => [I]}).

start_link() ->
   supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init([]) ->
   SupFlags = #{strategy => one_for_one, intensity => 5, period => 10},
   ChildSpecs = [?ChildSpec(esScanner, worker)],
   {ok, {SupFlags, ChildSpecs}}.
