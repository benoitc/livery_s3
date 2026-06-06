-module(livery_s3_fake_adapter).
-moduledoc """
A `livery_client` adapter for offline tests. It forwards the fully-signed
request to `test_pid` (so a test can assert on what the facade built) and
returns a canned response from `adapter_opts`.

`adapter_opts` carries either `response` (one response, reused for every call)
or `responses` + `counter` (a list consumed in order via an atomics counter,
the last entry repeating). When the request set `stream => true` the canned
`{full, Bin}` body is handed back as a one-chunk `{stream, Reader}`.
""".
-behaviour(livery_client_adapter).

-export([request/2, read/2]).

request(Req, Opts) ->
    case maps:get(test_pid, Opts, undefined) of
        undefined -> ok;
        Pid -> Pid ! {s3_request, Req}
    end,
    case next_response(Opts) of
        {error, _} = Error -> Error;
        Resp -> {ok, maybe_stream(maps:get(stream, Req, false), Resp)}
    end.

read(<<>>, _Timeout) -> {done, <<>>};
read(Bin, _Timeout) when is_binary(Bin) -> {ok, Bin, <<>>};
read(undefined, _Timeout) -> {done, undefined}.

next_response(#{responses := List, counter := Ref}) ->
    N = atomics:add_get(Ref, 1, 1),
    lists:nth(erlang:min(N, length(List)), List);
next_response(#{response := Resp}) ->
    Resp;
next_response(_) ->
    #{status => 200, headers => [], body => {full, <<>>}}.

maybe_stream(true, #{body := {full, Bin}} = Resp) -> Resp#{body => {stream, {?MODULE, Bin}}};
maybe_stream(_, Resp) -> Resp.
