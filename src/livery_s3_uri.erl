%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(livery_s3_uri).
-moduledoc """
URL building and RFC 3986 encoding for S3 requests.

S3 SigV4 is unforgiving about encoding: the canonical request must use the same
percent-encoding and query ordering as the bytes actually put on the wire. This
module is the single source of truth for both. Operations build the absolute
request URL here; the signer (`livery_s3_sigv4`) reads the path and query back
out of that URL with `url_parts/1`, so the signed and sent forms cannot drift.

Two encoders are exposed: `encode/1` (encode every reserved byte, used for
buckets and query components) and `encode_path/1` (the same but keeping `/` so
object keys with slashes map to literal path separators).
""".

-include("livery_s3.hrl").

-export([encode/1, encode_path/1]).
-export([canonical_query/1]).
-export([parse_endpoint/1]).
-export([request_target/4]).
-export([url_parts/1]).

-type config() :: #s3_config{}.
-type query_params() :: [{binary(), binary()}].

%%====================================================================
%% Percent-encoding
%%====================================================================

-doc "Percent-encode every byte outside the RFC 3986 unreserved set.".
-spec encode(binary()) -> binary().
encode(Bin) -> encode(Bin, false).

-doc "Like `encode/1` but keep `/` (for object keys used as path segments).".
-spec encode_path(binary()) -> binary().
encode_path(Bin) -> encode(Bin, true).

-spec encode(binary(), boolean()) -> binary().
encode(Bin, KeepSlash) ->
    <<<<(encode_byte(B, KeepSlash))/binary>> || <<B>> <= Bin>>.

-spec encode_byte(byte(), boolean()) -> binary().
encode_byte(B, _) when B >= $A, B =< $Z -> <<B>>;
encode_byte(B, _) when B >= $a, B =< $z -> <<B>>;
encode_byte(B, _) when B >= $0, B =< $9 -> <<B>>;
encode_byte($-, _) -> <<"-">>;
encode_byte($., _) -> <<".">>;
encode_byte($_, _) -> <<"_">>;
encode_byte($~, _) -> <<"~">>;
encode_byte($/, true) -> <<"/">>;
encode_byte(B, _) -> <<$%, (hex(B bsr 4)), (hex(B band 16#0F))>>.

-spec hex(0..15) -> byte().
hex(N) when N < 10 -> $0 + N;
hex(N) -> $A + (N - 10).

%%====================================================================
%% Canonical query string
%%====================================================================

-doc """
Build the canonical query string from key/value pairs: each component is
percent-encoded, then the pairs are sorted by encoded key (ties by value) and
joined with `&`. This is both what we sign and what we put in the URL.
""".
-spec canonical_query(query_params()) -> binary().
canonical_query([]) ->
    <<>>;
canonical_query(Params) ->
    Encoded = [{encode(K), encode(V)} || {K, V} <- Params],
    Pairs = [<<K/binary, "=", V/binary>> || {K, V} <- lists:sort(Encoded)],
    join(Pairs, <<"&">>).

-spec join([binary()], binary()) -> binary().
join([], _Sep) -> <<>>;
join([H | T], Sep) -> lists:foldl(fun(P, Acc) -> <<Acc/binary, Sep/binary, P/binary>> end, H, T).

%%====================================================================
%% Endpoint parsing
%%====================================================================

-doc """
Parse an endpoint URL into scheme/host/port. Accepts `https://host`,
`http://host:port`, bare `host[:port]` (defaults to https), and bracketed IPv6
literals. A trailing path is ignored.
""".
-spec parse_endpoint(binary()) ->
    #{scheme := binary(), host := binary(), port := undefined | inet:port_number()}.
parse_endpoint(Endpoint) ->
    {Scheme, Rest} =
        case binary:split(Endpoint, <<"://">>) of
            [S, R] -> {S, R};
            [R] -> {<<"https">>, R}
        end,
    [HostPort | _] = binary:split(Rest, <<"/">>),
    {Host, Port} = split_host_port(HostPort),
    #{scheme => Scheme, host => Host, port => Port}.

-spec split_host_port(binary()) -> {binary(), undefined | inet:port_number()}.
split_host_port(<<"[", Rest/binary>>) ->
    [Host, After] = binary:split(Rest, <<"]">>),
    Port =
        case After of
            <<":", P/binary>> -> binary_to_integer(P);
            _ -> undefined
        end,
    {<<"[", Host/binary, "]">>, Port};
split_host_port(HostPort) ->
    case binary:split(HostPort, <<":">>) of
        [Host, P] -> {Host, binary_to_integer(P)};
        [Host] -> {Host, undefined}
    end.

%%====================================================================
%% Request URL construction
%%====================================================================

-doc """
Build the absolute request URL and the matching `host` header value.

`Bucket` and `Key` may be `undefined` (service- and bucket-level requests). The
returned authority is the exact `host[:port]` we will sign, computed from the
addressing style: path-style keeps the endpoint host and puts the bucket in the
path; virtual-hosted prefixes the bucket onto the host.
""".
-spec request_target(config(), undefined | binary(), undefined | binary(), query_params()) ->
    {binary(), binary()}.
request_target(Cfg, Bucket, Key, Query) ->
    {Authority, Path} = locate(Cfg, Bucket, Key),
    Base = <<(Cfg#s3_config.scheme)/binary, "://", Authority/binary, Path/binary>>,
    Url =
        case canonical_query(Query) of
            <<>> -> Base;
            QS -> <<Base/binary, "?", QS/binary>>
        end,
    {Url, Authority}.

-spec locate(config(), undefined | binary(), undefined | binary()) -> {binary(), binary()}.
locate(Cfg, undefined, _Key) ->
    {authority(Cfg, undefined), <<"/">>};
locate(#s3_config{addressing = path} = Cfg, Bucket, undefined) ->
    {authority(Cfg, undefined), <<"/", (encode(Bucket))/binary>>};
locate(#s3_config{addressing = path} = Cfg, Bucket, Key) ->
    {authority(Cfg, undefined), <<"/", (encode(Bucket))/binary, "/", (encode_path(Key))/binary>>};
locate(#s3_config{addressing = virtual} = Cfg, Bucket, undefined) ->
    {authority(Cfg, Bucket), <<"/">>};
locate(#s3_config{addressing = virtual} = Cfg, Bucket, Key) ->
    {authority(Cfg, Bucket), <<"/", (encode_path(Key))/binary>>}.

-spec authority(config(), undefined | binary()) -> binary().
authority(#s3_config{host = H, port = Port}, undefined) ->
    with_port(H, Port);
authority(#s3_config{host = H, port = Port}, Bucket) ->
    with_port(<<Bucket/binary, ".", H/binary>>, Port).

-spec with_port(binary(), undefined | inet:port_number()) -> binary().
with_port(Host, undefined) -> Host;
with_port(Host, Port) -> <<Host/binary, ":", (integer_to_binary(Port))/binary>>.

%%====================================================================
%% URL decomposition (used by the signer)
%%====================================================================

-doc """
Split an absolute URL into authority, path, and (already canonical) query. The
path and query are returned verbatim so the signer reuses the exact bytes that
were placed in the URL.
""".
-spec url_parts(binary()) -> #{authority := binary(), path := binary(), query := binary()}.
url_parts(Url) ->
    [_Scheme, Rest] = binary:split(Url, <<"://">>),
    {Authority, PathQuery} =
        case binary:split(Rest, <<"/">>) of
            [A, PQ] -> {A, <<"/", PQ/binary>>};
            [A] -> {A, <<"/">>}
        end,
    {Path, Query} =
        case binary:split(PathQuery, <<"?">>) of
            [P, Q] -> {P, Q};
            [P] -> {P, <<>>}
        end,
    #{authority => Authority, path => Path, query => Query}.
