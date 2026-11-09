%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(livery_s3_checksum).
-moduledoc """
S3 additional checksums: CRC32, CRC32C, SHA1, and SHA256.

S3 carries these as base64 values in `x-amz-checksum-<alg>` headers. The store
recomputes the checksum on upload and rejects the request when it does not
match, and returns it on GET/HEAD when asked with `x-amz-checksum-mode`.

`compute/2` gives the base64 value for a body, so a caller can also verify a
download against the `checksum` map the facade returns.
""".

-export([compute/2, headers/2, algorithm_header/1, from_headers/1, part_xml/1]).
-export_type([algorithm/0]).

-type algorithm() :: crc32 | crc32c | sha1 | sha256.

-define(CRC32C_POLY, 16#82F63B78).
-define(CRC32C_TABLE_KEY, {?MODULE, crc32c_table}).

-doc "Base64 checksum of `Data` with `Alg`.".
-spec compute(algorithm(), iodata()) -> binary().
compute(crc32, Data) -> base64:encode(<<(erlang:crc32(Data)):32>>);
compute(crc32c, Data) -> base64:encode(<<(crc32c(Data)):32>>);
compute(sha1, Data) -> base64:encode(crypto:hash(sha, Data));
compute(sha256, Data) -> base64:encode(crypto:hash(sha256, Data)).

-doc """
Checksum request headers for `Opts` and the request body:

* `checksum => Alg` computes the value over a full body.
* `checksum => {Alg, Base64}` sends a value computed by the caller. This is the
  only form a `{stream, _}` body accepts, since the body is not in memory.
""".
-spec headers(map(), {full, iodata()} | {stream, term()} | empty) ->
    {ok, [{binary(), binary()}]} | {error, term()}.
headers(Opts, Body) ->
    case {maps:get(checksum, Opts, undefined), Body} of
        {undefined, _} ->
            {ok, []};
        {{Alg, Value}, _} when is_binary(Value) ->
            with_valid_alg(Alg, fun() -> {ok, [{header_name(Alg), Value}]} end);
        {Alg, {full, Data}} ->
            with_valid_alg(Alg, fun() -> {ok, [{header_name(Alg), compute(Alg, Data)}]} end);
        {Alg, empty} ->
            with_valid_alg(Alg, fun() -> {ok, [{header_name(Alg), compute(Alg, <<>>)}]} end);
        {Alg, {stream, _}} ->
            {error, {checksum_requires_full_body, Alg}}
    end.

-doc """
The `x-amz-checksum-algorithm` header announcing `checksum_algorithm` on
`CreateMultipartUpload`; empty when the option is unset.
""".
-spec algorithm_header(map()) -> [{binary(), binary()}].
algorithm_header(Opts) ->
    case maps:get(checksum_algorithm, Opts, undefined) of
        undefined -> [];
        Alg -> [{<<"x-amz-checksum-algorithm">>, upper(Alg)}]
    end.

-doc "Collect `x-amz-checksum-<alg>` response headers into `#{Alg => Base64}`.".
-spec from_headers([{binary(), binary()}]) -> #{algorithm() => binary()}.
from_headers(Headers) ->
    lists:foldl(
        fun({Name, Value}, Acc) ->
            case alg_of_header(string:lowercase(Name)) of
                undefined -> Acc;
                Alg -> Acc#{Alg => Value}
            end
        end,
        #{},
        Headers
    ).

-doc "`<ChecksumCRC32>`-style elements for a completed part's checksum map.".
-spec part_xml(#{algorithm() => binary()}) -> binary().
part_xml(Checksums) ->
    <<
        <<"<", (element_name(Alg))/binary, ">", V/binary, "</", (element_name(Alg))/binary, ">">>
     || {Alg, V} <- lists:sort(maps:to_list(Checksums))
    >>.

%%====================================================================
%% Internal
%%====================================================================

-spec with_valid_alg(term(), fun(() -> Ret)) -> Ret | {error, term()}.
with_valid_alg(Alg, Fun) when Alg =:= crc32; Alg =:= crc32c; Alg =:= sha1; Alg =:= sha256 ->
    Fun();
with_valid_alg(Alg, _Fun) ->
    {error, {invalid_checksum_algorithm, Alg}}.

-spec header_name(algorithm()) -> binary().
header_name(Alg) -> <<"x-amz-checksum-", (atom_to_binary(Alg))/binary>>.

-spec element_name(algorithm()) -> binary().
element_name(crc32) -> <<"ChecksumCRC32">>;
element_name(crc32c) -> <<"ChecksumCRC32C">>;
element_name(sha1) -> <<"ChecksumSHA1">>;
element_name(sha256) -> <<"ChecksumSHA256">>.

-spec alg_of_header(binary()) -> algorithm() | undefined.
alg_of_header(<<"x-amz-checksum-crc32">>) -> crc32;
alg_of_header(<<"x-amz-checksum-crc32c">>) -> crc32c;
alg_of_header(<<"x-amz-checksum-sha1">>) -> sha1;
alg_of_header(<<"x-amz-checksum-sha256">>) -> sha256;
alg_of_header(_) -> undefined.

-spec upper(algorithm()) -> binary().
upper(Alg) -> string:uppercase(atom_to_binary(Alg)).

%% CRC32C (Castagnoli), reflected, table-driven. OTP has no built-in for it.
-spec crc32c(iodata()) -> non_neg_integer().
crc32c(Data) ->
    Table = crc32c_table(),
    crc32c(iolist_to_binary(Data), Table, 16#FFFFFFFF) bxor 16#FFFFFFFF.

-spec crc32c(binary(), tuple(), non_neg_integer()) -> non_neg_integer().
crc32c(<<B, Rest/binary>>, Table, Crc) ->
    Idx = (Crc bxor B) band 16#FF,
    crc32c(Rest, Table, (Crc bsr 8) bxor element(Idx + 1, Table));
crc32c(<<>>, _Table, Crc) ->
    Crc.

-spec crc32c_table() -> tuple().
crc32c_table() ->
    case persistent_term:get(?CRC32C_TABLE_KEY, undefined) of
        undefined ->
            Table = list_to_tuple([crc32c_entry(N, 8) || N <- lists:seq(0, 255)]),
            persistent_term:put(?CRC32C_TABLE_KEY, Table),
            Table;
        Table ->
            Table
    end.

-spec crc32c_entry(non_neg_integer(), non_neg_integer()) -> non_neg_integer().
crc32c_entry(C, 0) ->
    C;
crc32c_entry(C, K) when C band 1 =:= 1 ->
    crc32c_entry((C bsr 1) bxor ?CRC32C_POLY, K - 1);
crc32c_entry(C, K) ->
    crc32c_entry(C bsr 1, K - 1).
