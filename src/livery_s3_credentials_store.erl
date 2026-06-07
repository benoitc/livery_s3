%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(livery_s3_credentials_store).
-moduledoc """
Cache for refreshing credential providers.

A `gen_server` owns a public ETS table keyed by provider key, holding the last
fetched `creds()`. `current/2` serves cached credentials directly (no process
round-trip) and only routes through the server to (re)fetch when the entry is
missing or within the refresh margin of `expires_at` (default 300 s). Fetches
are single-flighted by the server, so a thundering herd of expired reads triggers
one refresh. Started by the `livery_s3` application; only refreshing providers
(imds, web-identity, custom funs) need it.
""".
-behaviour(gen_server).

-export([start_link/0, current/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TABLE, ?MODULE).
-define(CALL_TIMEOUT, 15000).
-record(state, {}).
-type state() :: #state{}.

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Return cached credentials for `Key`, refreshing via `Provider` if stale.".
-spec current(term(), livery_s3_credentials:provider()) ->
    {ok, livery_s3_credentials:creds()} | {error, term()}.
current(Key, Provider) ->
    case erlang:whereis(?MODULE) of
        undefined ->
            {error, credentials_store_not_started};
        _ ->
            case lookup(Key) of
                {ok, Creds} -> {ok, Creds};
                miss -> gen_server:call(?MODULE, {refresh, Key, Provider}, ?CALL_TIMEOUT)
            end
    end.

%%====================================================================
%% gen_server
%%====================================================================

-spec init([]) -> {ok, state()}.
init([]) ->
    _ = ets:new(?TABLE, [named_table, public, set, {read_concurrency, true}]),
    {ok, #state{}}.

-spec handle_call(term(), {pid(), term()}, state()) ->
    {reply, {ok, livery_s3_credentials:creds()} | {error, term()}, state()}.
handle_call({refresh, Key, Provider}, _From, State) ->
    %% Re-check: another caller may have refreshed while we queued.
    case lookup(Key) of
        {ok, Creds} ->
            {reply, {ok, Creds}, State};
        miss ->
            case livery_s3_credentials:fetch(Provider) of
                {ok, Creds} ->
                    true = ets:insert(?TABLE, {Key, Creds}),
                    {reply, {ok, Creds}, State};
                {error, _} = Error ->
                    {reply, Error, State}
            end
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) -> {noreply, State}.

-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info(_Info, State) -> {noreply, State}.

%%====================================================================
%% Internals
%%====================================================================

-spec lookup(term()) -> {ok, livery_s3_credentials:creds()} | miss.
lookup(Key) ->
    case ets:lookup(?TABLE, Key) of
        [{_, Creds}] ->
            case fresh(Creds) of
                true -> {ok, Creds};
                false -> miss
            end;
        [] ->
            miss
    end.

-spec fresh(livery_s3_credentials:creds()) -> boolean().
fresh(#{expires_at := ExpiresAt}) ->
    erlang:system_time(second) < ExpiresAt - margin();
fresh(_Creds) ->
    true.

-spec margin() -> non_neg_integer().
margin() ->
    application:get_env(livery_s3, credentials_refresh_margin, 300).
