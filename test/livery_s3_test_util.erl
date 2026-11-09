-module(livery_s3_test_util).
-moduledoc """
Shared helpers for the feature test modules: a single-attempt client over the
fake adapter, request capture, and header lookup.
""".

-export([client/1, client/2, run/2, run/3, run_seq/3, resp/3, header/2]).

-doc "Signed single-attempt client returning `Resp` for every request.".
client(Resp) ->
    client(Resp, #{}).

-doc "Like `client/1`, with `Extra` merged over the base `new/1` options.".
client(Resp, Extra) ->
    Base = #{
        endpoint => <<"https://s3.example.com">>,
        region => <<"us-east-1">>,
        access_key_id => <<"AKIDEXAMPLE">>,
        secret_access_key => <<"SECRET">>,
        retry => false,
        adapter => livery_s3_fake_adapter,
        adapter_opts => #{test_pid => self(), response => Resp}
    },
    Opts =
        case maps:is_key(credentials, Extra) of
            true -> maps:without([access_key_id, secret_access_key], Base);
            false -> Base
        end,
    livery_s3:new(maps:merge(Opts, Extra)).

-doc "Run `Fun(Client)` and return the captured request with the result.".
run(Resp, Fun) ->
    run(Resp, #{}, Fun).

run(Resp, Extra, Fun) ->
    Result = Fun(client(Resp, Extra)),
    receive
        {s3_request, Req} -> {Req, Result}
    after 2000 ->
        error(no_request_captured)
    end.

-doc "Consume `Responses` in order; return every captured request.".
run_seq(Responses, Extra, Fun) ->
    Ref = atomics:new(1, [{signed, false}]),
    AdapterOpts = #{test_pid => self(), responses => Responses, counter => Ref},
    C = client(undefined, Extra#{adapter_opts => AdapterOpts}),
    Result = Fun(C),
    {drain(), Result}.

drain() ->
    receive
        {s3_request, Req} -> [Req | drain()]
    after 200 -> []
    end.

resp(Status, Headers, Body) ->
    #{status => Status, headers => Headers, body => {full, Body}}.

-doc "Case-insensitive header lookup; `undefined` when absent.".
header(Name, Headers) ->
    L = string:lowercase(Name),
    case [V || {N, V} <- Headers, string:lowercase(N) =:= L] of
        [V | _] -> V;
        [] -> undefined
    end.
