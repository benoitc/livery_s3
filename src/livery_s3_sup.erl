%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(livery_s3_sup).
-moduledoc "Top supervisor: owns the credential refresh cache.".
-behaviour(supervisor).

-export([start_link/0, init/1]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    Children = [
        #{
            id => livery_s3_credentials_store,
            start => {livery_s3_credentials_store, start_link, []},
            type => worker
        }
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.
