%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(livery_s3_sse).
-moduledoc """
Server-side encryption request headers and response fields.

Three modes, chosen per request:

* SSE-S3 (`sse => aes256`): the store encrypts with keys it manages.
* SSE-KMS (`sse => {kms, KeyId | undefined}`): the store encrypts with a KMS
  key; `undefined` uses the account default. `sse_kms_context => Map` adds an
  encryption context and `bucket_key_enabled => true` an S3 Bucket Key.
* SSE-C (`sse_customer_key => <<_:256>>`): you supply the 256-bit key on every
  request that writes or reads the object. The store keeps only its MD5.

Copies and part copies of an SSE-C source also take
`copy_source_sse_customer_key`.
""".

-export([write_headers/1, customer_headers/1, copy_source_headers/1, from_headers/1]).

-define(SSE, <<"x-amz-server-side-encryption">>).
-define(CUSTOMER, <<"x-amz-server-side-encryption-customer-">>).
-define(COPY_CUSTOMER, <<"x-amz-copy-source-server-side-encryption-customer-">>).

-doc """
Headers for a write that may choose SSE-S3/SSE-KMS and SSE-C: `sse`,
`sse_kms_context`, `bucket_key_enabled`, and `sse_customer_key`.
""".
-spec write_headers(map()) -> {ok, [{binary(), binary()}]} | {error, term()}.
write_headers(Opts) ->
    maybe
        {ok, Managed} ?= managed_headers(Opts),
        {ok, Customer} ?= customer_headers(Opts),
        {ok, Managed ++ Customer}
    end.

-doc "SSE-C headers for `sse_customer_key`; empty when unset.".
-spec customer_headers(map()) -> {ok, [{binary(), binary()}]} | {error, term()}.
customer_headers(Opts) ->
    key_headers(?CUSTOMER, maps:get(sse_customer_key, Opts, undefined)).

-doc "SSE-C headers for a copy source, from `copy_source_sse_customer_key`.".
-spec copy_source_headers(map()) -> {ok, [{binary(), binary()}]} | {error, term()}.
copy_source_headers(Opts) ->
    key_headers(?COPY_CUSTOMER, maps:get(copy_source_sse_customer_key, Opts, undefined)).

-doc """
Encryption fields from response headers: `sse` (the algorithm, e.g.
`<<"AES256">>` or `<<"aws:kms">>`), `sse_kms_key_id`, `sse_customer_algorithm`,
and `bucket_key_enabled`.
""".
-spec from_headers([{binary(), binary()}]) -> map().
from_headers(Headers) ->
    Lower = [{string:lowercase(N), V} || {N, V} <- Headers],
    Fields = [
        {sse, ?SSE},
        {sse_kms_key_id, <<?SSE/binary, "-aws-kms-key-id">>},
        {sse_customer_algorithm, <<?CUSTOMER/binary, "algorithm">>},
        {bucket_key_enabled, <<?SSE/binary, "-bucket-key-enabled">>}
    ],
    maps:from_list([
        {Field, field_value(Field, V)}
     || {Field, Name} <- Fields, {N, V} <- Lower, N =:= Name
    ]).

%%====================================================================
%% Internal
%%====================================================================

-spec managed_headers(map()) -> {ok, [{binary(), binary()}]} | {error, term()}.
managed_headers(Opts) ->
    Extra = context_header(Opts) ++ bucket_key_header(Opts),
    case maps:get(sse, Opts, undefined) of
        undefined when Extra =:= [] -> {ok, []};
        undefined ->
            {error, {sse_option_requires_kms, Extra}};
        aes256 when Extra =:= [] -> {ok, [{?SSE, <<"AES256">>}]};
        aes256 ->
            {error, {sse_option_requires_kms, Extra}};
        {kms, undefined} ->
            {ok, [{?SSE, <<"aws:kms">>} | Extra]};
        {kms, KeyId} when is_binary(KeyId) ->
            {ok, [{?SSE, <<"aws:kms">>}, {<<?SSE/binary, "-aws-kms-key-id">>, KeyId} | Extra]};
        Other ->
            {error, {invalid_sse, Other}}
    end.

-spec context_header(map()) -> [{binary(), binary()}].
context_header(Opts) ->
    case maps:get(sse_kms_context, Opts, undefined) of
        undefined ->
            [];
        Ctx when is_map(Ctx) ->
            Json = iolist_to_binary(json:encode(Ctx)),
            [{<<"x-amz-server-side-encryption-context">>, base64:encode(Json)}]
    end.

-spec bucket_key_header(map()) -> [{binary(), binary()}].
bucket_key_header(Opts) ->
    case maps:get(bucket_key_enabled, Opts, undefined) of
        undefined -> [];
        true -> [{<<?SSE/binary, "-bucket-key-enabled">>, <<"true">>}];
        false -> [{<<?SSE/binary, "-bucket-key-enabled">>, <<"false">>}]
    end.

-spec key_headers(binary(), undefined | term()) ->
    {ok, [{binary(), binary()}]} | {error, term()}.
key_headers(_Prefix, undefined) ->
    {ok, []};
key_headers(Prefix, Key) when is_binary(Key), byte_size(Key) =:= 32 ->
    {ok, [
        {<<Prefix/binary, "algorithm">>, <<"AES256">>},
        {<<Prefix/binary, "key">>, base64:encode(Key)},
        {<<Prefix/binary, "key-md5">>, base64:encode(crypto:hash(md5, Key))}
    ]};
key_headers(_Prefix, _Key) ->
    {error, invalid_sse_customer_key}.

-spec field_value(atom(), binary()) -> binary() | boolean().
field_value(bucket_key_enabled, V) -> string:lowercase(V) =:= <<"true">>;
field_value(_, V) -> V.
