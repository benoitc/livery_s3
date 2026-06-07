%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(livery_s3_app).
-moduledoc "Application callback: starts the credential refresh cache.".
-behaviour(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_Type, _Args) ->
    livery_s3_sup:start_link().

-spec stop(term()) -> ok.
stop(_State) ->
    ok.
