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

%% @doc When a new email connection is made, this is resposible for handling the
%% callbacks from gen_smtp_server.  When an email is completed / ready to be 
%% queued, this gen_server:cast's back to email_media_manager to create an
%% email_media and queue it.

-module(email_media_session).
-author(spicecsm).

-behaviour(gen_smtp_server_session).

%% gen_smtp callbacks
-export([
	init/3,
	handle_HELO/2,
	handle_EHLO/3,
	handle_MAIL/2,
	handle_MAIL_extension/2,
	handle_RCPT/2,
	handle_RCPT_extension/2,
	handle_DATA/5,
	handle_RSET/1,
	handle_VRFY/2,
	handle_other/3,
	terminate/2,
	code_change/3
]).

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include("log.hrl").
-include("smtp.hrl").

-record(state, {
	mail_map :: #mail_map{}
}).

%% API

%% gen_smtp_server_session callbacks
-spec(init/3 :: (Hostname :: string(), SessionCount :: pos_integer(), Address :: string()) -> {'stop', 'normal', any(), [string()]} | {'ok', string(), #state{}}).
init(Hostname, SessionCount, Address) when SessionCount > 20 ->
	?ERROR("Session limit exceeded at ~s by ~s", [Hostname, Address]),
	{stop, normal, io_lib:format("421 ~s is too busy to accecpt mail right now", [Hostname])};
init(Hostname, _SessionCount, _Address) ->
	Banner = io_lib:format("~s ESMTP spice_telephony", [Hostname]),
	{ok, Banner, #state{}}.

-spec(handle_HELO/2 :: (Hostname :: string(), State :: #state{}) -> {'ok', #state{}}).
handle_HELO(_Hostname, State) ->
	{ok, State}.

-spec(handle_EHLO/3 :: (Hostname :: string(), Extension :: [string()], State :: #state{}) -> {'ok', [string()], #state{}}).
handle_EHLO(_Hostname, Extensions, State) ->
	{ok, Extensions, State}.

-spec(handle_MAIL/2 :: (From :: string(), State :: #state{}) -> {'ok', #state{}}).
handle_MAIL(_From, State) ->
	{ok, State}.

-spec(handle_MAIL_extension/2 :: (Extension :: any(), State :: #state{}) -> {'ok', #state{}}).
handle_MAIL_extension(_Extension, State) ->
	{ok, State}.

-spec(handle_RCPT/2 :: (To :: string(), State :: #state{}) -> {'ok', #state{}} | {'error', string(), #state{}}).
handle_RCPT(To, #state{mail_map = undefined} = State) ->
	F = fun() ->
		mnesia:read({mail_map, To})
	end,
	case mnesia:transaction(F) of
		{atomic, []} ->
			?WARNING("Could not find mapping for mail to ~s", [To]),
			{ok, State#state{mail_map = #mail_map{address = To}}};
		{atomic, [Mailmap]} ->
			{ok, State#state{mail_map = Mailmap}}
	end;
handle_RCPT(_To, State) ->
	{error, "452 only one recipient, fool!", State}.

-spec(handle_RCPT_extension/2 :: (Extension :: any(), State :: #state{}) -> {'ok', #state{}}).
handle_RCPT_extension(_Extension, State) ->
	{ok, State}.

-spec(handle_DATA/5 :: (From :: string(), To :: [string()], Headers :: [any()], Data :: string(), State :: #state{}) -> {'ok', string(), #state{}}).
handle_DATA(_From, [To | _Allelse], Headers, Data, #state{mail_map = Mailmap} = State) when To =:= Mailmap#mail_map.address ->
	Reference = begin
		Ref = erlang:ref_to_list(make_ref()),
		Refstr = util:bin_to_hexstr(erlang:md5(Ref)),
		[Domain, _To] = util:string_split(lists:reverse(Mailmap#mail_map.address), "@", 2),
		lists:flatten(io_lib:format("~s@~s", [Refstr, lists:reverse(Domain)]))
	end,
	%?DEBUG("headers:  ~p", [Headers]),
	gen_server:cast(email_media_manager, {queue, Mailmap, Headers, Data}),
	%mimemail:decode(Headers, Data),
	{ok, Reference, State#state{mail_map = undefined}}.

-spec(handle_RSET/1 :: (State :: #state{}) -> #state{}).
handle_RSET(State) ->
	% reset any relevant internal state
	State#state{mail_map = undefined}.

-spec(handle_VRFY/2 :: (Address :: string(), State :: #state{}) -> {'error', any(), #state{}} | {'ok', any(), #state{}}).
handle_VRFY(Address, State) ->
	F = fun() ->
		mnesia:read({mail_map, Address})
	end,
	case mnesia:transaction(F) of
		{atomic, []} ->
			?WARNING("Could not find mapping for mail to ~s", [Address]),
			{error, "252 unabled to verify address, will be put in default queue", State};
		{atomic, [Mailmap]} ->
			{ok, io_lib:format("250 will queue the mail to ~s", [Mailmap#mail_map.queue]), State}
	end.

-spec(handle_other/3 :: (Verb :: any(), Args :: any(), State :: #state{}) -> {string(), #state{}}).
handle_other(_Verb, _Args, State) ->
	{"500 Error: command not recognized", State}.

-spec(terminate/2 :: (Reason :: any(), State :: #state{}) -> 'ok').
terminate(_Reason, _State) ->
	ok.

-spec(code_change/3 :: (Oldvsn :: any(), State :: #state{}, Extra :: any()) -> {'ok', #state{}}).
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.
