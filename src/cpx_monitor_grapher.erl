%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is Spice Telephony.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <athompson at spicecsm dot com>
%%	Micah Warren <mwarren at spicecsm dot com>
%%

-module(cpx_monitor_grapher).

-behaviour(gen_server).

-include("contrib/errd/include/errd.hrl").

-include("log.hrl").
%% API
-export([
	start_link/0,
	start_link/1,
	start/0,
	start/1
]).

%% gen_server callbacks
-export([
	init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3
]).

-record(state, {
		rrd :: pid(),
		lastrun,
		agents,
		outdir = "rrd"
}).

% API

start() ->
	start([]).

%% @doc Props:
%%	*	outdir Directory
start(Props) ->
	gen_server:start(?MODULE, Props, []).

start_link() ->
	start_link([]).

start_link(Props) ->
	gen_server:start_link(?MODULE, Props, []).

% gen_server callbacks

init(Props) ->
	case errd_server:start_link() of
		{ok, RRD} ->
			Dir = proplists:get_value(outdir, Props, "rrd"),
			Now = now(),
			GroupedAgents = get_agents(Now),
			timer:send_after(30000, update),
			timer:send_after(65000, graph),
			cpx_monitor:subscribe(),
			case filelib:ensure_dir(Dir) of
				ok ->
					file:make_dir(Dir),
					errd_server:cd(RRD, Dir),
					{ok, #state{rrd = RRD, lastrun = Now, agents = GroupedAgents, outdir = Dir}, hibernate};
				_ ->
					{stop, {no_rrd_dir, Dir}}
			end;
		_ ->
			{stop, no_rrd}
	end.

handle_call(_Request, _From, State) ->
	Reply = ok,
	{reply, Reply, State, hibernate}.

handle_cast(_Msg, State) ->
	{noreply, State, hibernate}.

handle_info(graph, #state{rrd = RRD, outdir = Dir} = State) ->
	timer:send_after(60000, graph),

	Graphs = [
		{"util-15m", "15 minute trend", "now-30m", 900},
		{"util-1h", "1 hour trend", "now-2h", 3600},
		{"util-8h", "8 hour trend", "now-16h", 28800}
	],

	Fun = fun(F, {Defines, CDefines, Lines}) ->
			FileName = filename:basename(F),
			Name = filename:rootname(FileName),
			{
				["DEF:"++Name++"raw="++FileName++":"++Name++":LAST:start=~s" | Defines],
				["CDEF:"++Name++"="++Name++"raw,~B,TRENDNAN" | CDefines],
				["LINE2:"++Name++name_to_color(Name)++":"++Name | Lines]
			}
	end,

	{D, C, L} = filelib:fold_files(Dir, ".rrd", false, Fun , {[], [], []}),

	%Command = "graph util-15m.png --end now --start end-~B --slope-mode --title \"~s\" --imgformat PNG --height 200 --width 600 " ++
		%string:join(D, " ") ++ " " ++ string:join(C, " ") ++ " " ++ string:join(L, " ") ++ "\n",
	
	lists:map(fun({Imgname, Title, Start, Duration}) ->
		Defines = re:replace(string:join(D, " "), "~s", Start, [{return, list}, global]),
		CDefines = re:replace(string:join(C, " "), "~B", integer_to_list(Duration), [{return, list}, global]),
		Command = "graph "++Imgname++".png --end now --start end-"++integer_to_list(Duration)++" --slope-mode --title \""++Title++"\" --imgformat PNG --height 200 --width 600 " ++
			Defines ++ " " ++ CDefines ++ " " ++ string:join(L, " ") ++ "\n",
		errd_server:raw(RRD, Command)
	end, Graphs),
	{noreply, State};
handle_info(update, State) ->
	Now = now(),
	GroupedAgents = get_agents(Now),
	timer:send_after(30000, update),
	Util = calculate_utilization(State#state.agents),
	update_utilization(Util, State#state.rrd),
	{noreply, State#state{lastrun = Now, agents = GroupedAgents}, hibernate};
handle_info({cpx_monitor_event, {set, {{agent, _}, _, Agent, _}}}, #state{agents = Agents} = State) ->
	NewAgents = update_agent(Agent, Agents),
	{noreply, State#state{agents = NewAgents}, hibernate};
handle_info(Info, State) ->
	{noreply, State, hibernate}.

terminate(_Reason, _State) ->
	ok.

code_change(_Oldvsn, State, _Extra) ->
	{ok, State}.

% internal functions

get_agents(Now) ->
	Agents = lists:map(fun({_, _, Agent}) -> [{lastchangetimestamp, Now} | proplists:delete(lastchangetimestamp, Agent)] end, element(2, cpx_monitor:get_health(agent))),
	util:group_by_with_key(fun(Agent) -> proplists:get_value(profile, Agent) end, Agents).

update_agent(Agent, Agents) ->
	Profile = proplists:get_value(profile, Agent),
	case proplists:get_value(Profile, Agents) of
		undefined ->
			[{Profile, [Agent]} | Agents];
		PAgents ->
			NAgents = proplists:delete(Profile, Agents),
			[{Profile, [Agent | PAgents]} | NAgents]
	end.

calculate_utilization(Agents) ->
	calculate_utilization_by_profile(Agents, []).

calculate_utilization_by_profile([], Acc) ->
	Acc;
calculate_utilization_by_profile([{Profile, Agents} | Tail], Acc) ->
	GroupedAgents = util:group_by_with_key(fun(Agent) -> proplists:get_value(login, Agent) end, Agents),
	Util = round(calculate_utilization_by_agent(GroupedAgents, 0) / length(GroupedAgents)),
	calculate_utilization_by_profile(Tail, [{Profile, Util} | Acc]).

calculate_utilization_by_agent([], Acc) ->
	Acc;
calculate_utilization_by_agent([{Agent, States} | Tail], Acc) ->
	Util = calc(lists:reverse(States), 0, 0),
	calculate_utilization_by_agent(Tail, Acc + Util).


calc([State], Util, Total) ->
	Diff = round(timer:now_diff(now(), proplists:get_value(lastchangetimestamp, State)) /1000000),
	AgentState = proplists:get_value(state, State),
	NUtil = get_util(AgentState, Diff, Util),
	round((NUtil / (Total + Diff)) * 100);
calc([State1, State2 | Tail], Util, Total) ->
	Diff = round(timer:now_diff(proplists:get_value(lastchangetimestamp, State2), proplists:get_value(lastchangetimestamp, State1)) /1000000),
	AgentState = proplists:get_value(state, State1),
	NUtil = get_util(AgentState, Diff, Util),
	calc([State2 | Tail], NUtil, Total + Diff).

get_util(AgentState, Diff, Util) when AgentState =:= oncall; AgentState =:= wrapup; AgentState =:= precall; AgentState =:= outgoing ->
	Diff + Util;
get_util(_, _Diff, Util) ->
	Util.


update_utilization([], _RRD) ->
	ok;
update_utilization([{Profile, Util} | Tail], RRD) ->
	Filename = re:replace(Profile, "[^a-zA-Z0-9_]", "", [{return, list}, global]),
	case errd_server:info(RRD, [Filename, ".rrd"]) of
		{error, _} ->
			% try to create on the assumption it doesn't exist
			{ok, _} = errd_server:command(RRD,
				#rrd_create{file=Filename++".rrd",
					step=30,
					ds_defs = [#rrd_ds{name=Filename, args="60:0:100", type = gauge}],
					rra_defs = [
						#rrd_rra{cf=last, args="0.5:1:2880"} % 1 day of 1 minute averages
						%#rrd_rra{cf=average, args="0.5:2:30"}, % 15 minutes of 1 minute averages
						%#rrd_rra{cf=average, args="0.5:10:12"}, % 1 hour of 5 minute averages
						%#rrd_rra{cf=average, args="0.5:120:24"}, % 1 day of 1 hour averages
						%#rrd_rra{cf=average, args="0.5:960:42"} % 2 weeks of 8 hour averages
					]
				});
		_ ->
			ok
	end,
	errd_server:command(RRD, #rrd_update{file=Filename++".rrd", updates=[#rrd_ds_update{name=Filename, value=Util}]}),
	update_utilization(Tail, RRD).

name_to_color(Name) ->
	SeedIn = lists:sum(binary_to_list(erlang:md5(Name))) + length(Name),
	Seed = {SeedIn bsl 4, SeedIn bsl 6, SeedIn bsl 9},
	random:seed(Seed),
	HSV = {random:uniform(360) -1, (random:uniform() * 0.6) + 0.4, (random:uniform() * 0.4) + 0.6},
	rgb2hex(hsv2rgb(HSV)).

%% HSL where
%% H is 0-359 inclusive
%% S and V are 0-1 inclusive
hsv2rgb({H, S, V}) ->
	Hi = floor(H/60) rem 6,
	F = (H/60) - floor(H/60),
	P = round((V * (1 - S)) * 255),
	Q = round((V * (1 - F * S)) * 255),
	T = round((V * (1 - (1 - F) * S)) * 255),
	V2 = round(V * 255),

	case Hi of
		0 -> {V2, T, P};
		1 -> {Q, V2, P};
		2 -> {P, V2, T};
		3 -> {P, Q, V2};
		4 -> {T, P, V2};
		5 -> {V2, P, Q}
	end.

rgb2hex({R, G, B}) ->
	lists:flatten(io_lib:format("#~2.16.0b~2.16.0b~2.16.0b", [R, G, B])).

get_colors(Profiles) ->
	SeedIn = lists:sum(lists:append(Profiles)),
	%lazily seed the RNG
	Seed = {SeedIn bsl 4, SeedIn bsl 6, SeedIn bsl 9},
	random:seed(Seed),

	Fun = fun() ->
			rgb2hex(hsv2rgb({random:uniform(360) -1, random:uniform(), random:uniform()}))
	end,

	Colors = lists:map(fun(Profile) -> {Profile, Fun()} end, Profiles).

floor(X) ->
		T = trunc(X),
		if X < T -> T - 1
				; true  -> T
		end.

