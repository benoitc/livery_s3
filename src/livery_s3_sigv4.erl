%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(livery_s3_sigv4).
-moduledoc """
AWS Signature Version 4 for S3, as a `livery_client` layer.

Used two ways:

* As the innermost client layer (`call/3`): it derives the payload hash, sets
  `host`/`x-amz-date`/`x-amz-content-sha256` (and `x-amz-security-token` when a
  session token is configured), signs `host` plus every `x-amz-*` header, and
  adds the `authorization` header before handing the request to the transport.
* As a presigner (`presigned_url/8`): query-string signing for time-limited
  GET/PUT URLs, with `UNSIGNED-PAYLOAD` and `host` as the only signed header.

The pure `authorization/1` primitive computes a signature from explicit inputs;
it is exercised against AWS's published S3 worked examples in the tests.
""".

-include("livery_s3.hrl").

-export([call/3]).
-export([authorization/1]).
-export([presigned_url/8]).
-export([now_timestamps/0]).

-type sign_input() :: #{
    method := binary(),
    path := binary(),
    query := binary(),
    headers := [{binary(), binary()}],
    payload_hash := binary(),
    secret := binary(),
    region := binary(),
    service := binary(),
    datetime := binary(),
    date := binary(),
    %% Required by authorization/1; sign/1 and presign do not use it.
    access_key_id => binary()
}.

%%====================================================================
%% Client layer
%%====================================================================

-doc "Sign the request, then hand it to the next layer.".
-spec call(livery_client:request(), livery_client:next(), #s3_config{}) ->
    livery_client:result().
call(#{method := M, url := Url, headers := Headers0, body := Body} = Req, Next, Cfg) ->
    {DateTime, Date} = now_timestamps(),
    PayloadHash = payload_hash(Body),
    #{authority := Authority, path := Path, query := Query} = livery_s3_uri:url_parts(Url),
    Added0 = [
        {<<"host">>, Authority},
        {<<"x-amz-date">>, DateTime},
        {<<"x-amz-content-sha256">>, PayloadHash}
    ],
    Added =
        case Cfg#s3_config.session_token of
            undefined -> Added0;
            Tok -> [{<<"x-amz-security-token">>, Tok} | Added0]
        end,
    Headers1 = upsert_all(Headers0, Added),
    ToSign = [{N, V} || {N, V} <- Headers1, sign_header(N)],
    Auth = authorization(#{
        method => method_bin(M),
        path => Path,
        query => Query,
        headers => ToSign,
        payload_hash => PayloadHash,
        access_key_id => Cfg#s3_config.access_key_id,
        secret => Cfg#s3_config.secret_access_key,
        region => Cfg#s3_config.region,
        service => ?S3_SERVICE,
        datetime => DateTime,
        date => Date
    }),
    Next(Req#{headers := upsert(Headers1, <<"authorization">>, Auth)}).

%%====================================================================
%% Pure signing primitive
%%====================================================================

-doc """
Compute the `Authorization` header value from explicit, already-canonical
inputs. `headers` is the exact set to sign; `path`/`query` are the canonical URI
and query string; `payload_hash` is the hex SHA-256 (or `UNSIGNED-PAYLOAD`).
""".
-spec authorization(sign_input()) -> binary().
authorization(#{access_key_id := AK} = P) ->
    {Sig, SignedHeaders, Scope} = sign(P),
    <<
        ?SIGV4_ALGORITHM/binary,
        " Credential=",
        AK/binary,
        "/",
        Scope/binary,
        ", SignedHeaders=",
        SignedHeaders/binary,
        ", Signature=",
        Sig/binary
    >>.

-spec sign(sign_input()) -> {binary(), binary(), binary()}.
sign(#{
    method := Method,
    path := Path,
    query := Query,
    headers := Headers,
    payload_hash := PayloadHash,
    secret := Secret,
    region := Region,
    service := Service,
    datetime := DateTime,
    date := Date
}) ->
    {CanonHeaders, SignedHeaders} = canonical_headers(Headers),
    CanonReq = <<
        Method/binary,
        "\n",
        Path/binary,
        "\n",
        Query/binary,
        "\n",
        CanonHeaders/binary,
        "\n",
        SignedHeaders/binary,
        "\n",
        PayloadHash/binary
    >>,
    Scope = <<Date/binary, "/", Region/binary, "/", Service/binary, "/aws4_request">>,
    StringToSign = <<
        ?SIGV4_ALGORITHM/binary,
        "\n",
        DateTime/binary,
        "\n",
        Scope/binary,
        "\n",
        (sha256_hex(CanonReq))/binary
    >>,
    Key = signing_key(Secret, Date, Region, Service),
    {hex_lower(hmac(Key, StringToSign)), SignedHeaders, Scope}.

%%====================================================================
%% Presigned URLs
%%====================================================================

-doc """
Build a presigned URL (query-string SigV4). `ExtraQuery` holds operation params
(e.g. `versionId`); they are signed alongside the `X-Amz-*` auth params. Only
the `host` header is signed and the payload is `UNSIGNED-PAYLOAD`.
""".
-spec presigned_url(
    #s3_config{},
    atom() | binary(),
    binary(),
    binary(),
    pos_integer(),
    [{binary(), binary()}],
    binary(),
    binary()
) -> binary().
presigned_url(Cfg, Method, Bucket, Key, Expires, ExtraQuery, DateTime, Date) ->
    {Url0, Authority} = livery_s3_uri:request_target(Cfg, Bucket, Key, []),
    #{path := Path} = livery_s3_uri:url_parts(Url0),
    Scope = <<
        Date/binary, "/", (Cfg#s3_config.region)/binary, "/", ?S3_SERVICE/binary, "/aws4_request"
    >>,
    Credential = <<(Cfg#s3_config.access_key_id)/binary, "/", Scope/binary>>,
    AuthQuery0 = [
        {<<"X-Amz-Algorithm">>, ?SIGV4_ALGORITHM},
        {<<"X-Amz-Credential">>, Credential},
        {<<"X-Amz-Date">>, DateTime},
        {<<"X-Amz-Expires">>, integer_to_binary(Expires)},
        {<<"X-Amz-SignedHeaders">>, <<"host">>}
    ],
    AuthQuery =
        case Cfg#s3_config.session_token of
            undefined -> AuthQuery0;
            Tok -> [{<<"X-Amz-Security-Token">>, Tok} | AuthQuery0]
        end,
    CanonQuery = livery_s3_uri:canonical_query(ExtraQuery ++ AuthQuery),
    {Sig, _SignedHeaders, _Scope} = sign(#{
        method => method_bin(Method),
        path => Path,
        query => CanonQuery,
        headers => [{<<"host">>, Authority}],
        payload_hash => ?UNSIGNED_PAYLOAD,
        secret => Cfg#s3_config.secret_access_key,
        region => Cfg#s3_config.region,
        service => ?S3_SERVICE,
        datetime => DateTime,
        date => Date
    }),
    <<
        (Cfg#s3_config.scheme)/binary,
        "://",
        Authority/binary,
        Path/binary,
        "?",
        CanonQuery/binary,
        "&X-Amz-Signature=",
        Sig/binary
    >>.

%%====================================================================
%% Canonicalization helpers
%%====================================================================

-spec canonical_headers([{binary(), binary()}]) -> {binary(), binary()}.
canonical_headers(Headers) ->
    Normed = [{string:lowercase(N), trimall(V)} || {N, V} <- Headers],
    Names = lists:usort([N || {N, _} <- Normed]),
    Grouped = [{N, join([V || {N1, V} <- Normed, N1 =:= N], <<",">>)} || N <- Names],
    Canon = <<<<N/binary, ":", V/binary, "\n">> || {N, V} <- Grouped>>,
    Signed = join(Names, <<";">>),
    {Canon, Signed}.

%% Trim ends and collapse internal runs of spaces to a single space.
-spec trimall(binary()) -> binary().
trimall(V) ->
    collapse(string:trim(V), false, <<>>).

-spec collapse(binary(), boolean(), binary()) -> binary().
collapse(<<>>, _, Acc) -> Acc;
collapse(<<$\s, Rest/binary>>, true, Acc) -> collapse(Rest, true, Acc);
collapse(<<$\s, Rest/binary>>, false, Acc) -> collapse(Rest, true, <<Acc/binary, $\s>>);
collapse(<<C, Rest/binary>>, _, Acc) -> collapse(Rest, false, <<Acc/binary, C>>).

-spec sign_header(binary()) -> boolean().
sign_header(Name) ->
    L = string:lowercase(Name),
    L =:= <<"host">> orelse match_prefix(L, <<"x-amz-">>).

-spec match_prefix(binary(), binary()) -> boolean().
match_prefix(Bin, Prefix) ->
    PL = byte_size(Prefix),
    byte_size(Bin) >= PL andalso binary:part(Bin, 0, PL) =:= Prefix.

%%====================================================================
%% Crypto + small utilities
%%====================================================================

-spec signing_key(binary(), binary(), binary(), binary()) -> binary().
signing_key(Secret, Date, Region, Service) ->
    KDate = hmac(<<"AWS4", Secret/binary>>, Date),
    KRegion = hmac(KDate, Region),
    KService = hmac(KRegion, Service),
    hmac(KService, <<"aws4_request">>).

-spec hmac(binary(), binary()) -> binary().
hmac(Key, Data) -> crypto:mac(hmac, sha256, Key, Data).

-spec sha256_hex(iodata()) -> binary().
sha256_hex(Data) -> hex_lower(crypto:hash(sha256, Data)).

-spec hex_lower(binary()) -> binary().
hex_lower(Bin) ->
    <<<<(nibble(B bsr 4)), (nibble(B band 16#0F))>> || <<B>> <= Bin>>.

-spec nibble(0..15) -> byte().
nibble(N) when N < 10 -> $0 + N;
nibble(N) -> $a + (N - 10).

-spec payload_hash(empty | {full, iodata()} | {stream, term()}) -> binary().
payload_hash(empty) -> ?EMPTY_SHA256;
payload_hash({full, Data}) -> sha256_hex(Data);
payload_hash({stream, _}) -> ?UNSIGNED_PAYLOAD.

-spec method_bin(atom() | binary()) -> binary().
method_bin(M) when is_atom(M) -> string:uppercase(atom_to_binary(M, utf8));
method_bin(M) when is_binary(M) -> string:uppercase(M).

-doc "Return the current `{amz-datetime, yyyymmdd}` pair in UTC.".
-spec now_timestamps() -> {binary(), binary()}.
now_timestamps() ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:universal_time(),
    DateTime = iolist_to_binary(
        io_lib:format("~4..0w~2..0w~2..0wT~2..0w~2..0w~2..0wZ", [Y, Mo, D, H, Mi, S])
    ),
    {DateTime, binary:part(DateTime, 0, 8)}.

-spec upsert_all([{binary(), binary()}], [{binary(), binary()}]) -> [{binary(), binary()}].
upsert_all(Headers, Adds) ->
    lists:foldl(fun({N, V}, Acc) -> upsert(Acc, N, V) end, Headers, Adds).

-spec upsert([{binary(), binary()}], binary(), binary()) -> [{binary(), binary()}].
upsert(Headers, Name, Value) ->
    L = string:lowercase(Name),
    [{Name, Value} | [KV || {K, _} = KV <- Headers, string:lowercase(K) =/= L]].

-spec join([binary()], binary()) -> binary().
join([], _Sep) -> <<>>;
join([H | T], Sep) -> lists:foldl(fun(P, Acc) -> <<Acc/binary, Sep/binary, P/binary>> end, H, T).
