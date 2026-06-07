%% SPDX-License-Identifier: Apache-2.0
%% Copyright 2026 Benoit Chesneau
-module(livery_s3).
-moduledoc """
An S3-compatible object storage client built on the livery client.

Build a client once with `new/1` (endpoint, region, credentials, addressing
style), then call the operations: object CRUD with metadata and byte ranges,
bucket management, versioning, multipart upload, copy, batch delete, and
presigned URLs. Works against AWS S3 and S3-compatible stores (Garage, MinIO,
Ceph, …); use `addressing => path` (the default) for the widest compatibility.

```erlang
C = livery_s3:new(#{
    endpoint => <<"http://127.0.0.1:3900">>,
    region   => <<"garage">>,
    access_key_id     => <<"GK...">>,
    secret_access_key => <<"...">>
}),
ok = livery_s3:create_bucket(C, <<"photos">>),
{ok, _} = livery_s3:put_object(C, <<"photos">>, <<"cat.jpg">>, Bytes,
                               #{content_type => <<"image/jpeg">>,
                                 metadata => #{<<"album">> => <<"holiday">>}}),
{ok, #{body := Bytes}} = livery_s3:get_object(C, <<"photos">>, <<"cat.jpg">>).
```

Transport, retries, and timeouts come from the underlying `livery_client`
layer stack; request signing is AWS Signature V4 (`livery_s3_sigv4`). All
operations return `{ok, _}`/`ok` or `{error, Reason}`; S3 error bodies surface
as `{error, {s3, Code, Message, #{status => S, request_id => RId}}}`.
""".

-include("livery_s3.hrl").

%% Construction.
-export([new/1, presign/5, presign/6]).
%% Objects.
-export([put_object/4, put_object/5]).
-export([get_object/3, get_object/4]).
-export([head_object/3, head_object/4]).
-export([delete_object/3, delete_object/4]).
-export([copy_object/5, copy_object/6]).
%% Buckets.
-export([list_buckets/1]).
-export([create_bucket/2, create_bucket/3]).
-export([delete_bucket/2, head_bucket/2, get_bucket_location/2]).
-export([list_objects/2, list_objects/3, list_objects_all/2, list_objects_all/3]).
%% Versioning.
-export([
    get_bucket_versioning/2,
    put_bucket_versioning/3,
    list_object_versions/2,
    list_object_versions/3
]).
%% Multipart.
-export([create_multipart_upload/3, create_multipart_upload/4]).
-export([upload_part/6, complete_multipart_upload/5, abort_multipart_upload/4]).
-export([upload_part_copy/7, upload_part_copy/8]).
-export([list_parts/4, list_parts/5, list_multipart_uploads/2, list_multipart_uploads/3]).
%% Batch delete.
-export([delete_objects/3]).

-export_type([client/0, reason/0]).

-record(s3_client, {
    config :: #s3_config{},
    http :: livery_client:client(),
    timeout :: timeout()
}).

-opaque client() :: #s3_client{}.
-type reason() ::
    not_found
    | not_modified
    | precondition_failed
    | overloaded
    | circuit_open
    | timeout
    | {s3, binary(), binary(), map()}
    | term().
-type bucket() :: binary().
-type key() :: binary().
-type body() :: iodata() | {full, iodata()} | {stream, fun(() -> eof | {ok, binary(), fun()})}.

-define(XML_DECL, <<"<?xml version=\"1.0\" encoding=\"UTF-8\"?>">>).
%% S3-tuned retry defaults: transient server statuses + throttling, idempotent
%% ops only (livery_client_retry never replays streamed bodies or POST).
-define(DEFAULT_RETRY, #{max => 3, backoff => {200, 2.0}, statuses => [429, 500, 502, 503, 504]}).

%%====================================================================
%% Construction
%%====================================================================

-doc """
Build a client. Options:

* `endpoint` (required) - base URL, e.g. `<<"https://s3.eu-west-1.amazonaws.com">>`
  or `<<"http://127.0.0.1:3900">>`.
* `access_key_id`, `secret_access_key` (required).
* `region` - default `<<"us-east-1">>`.
* `addressing` - `path` (default) or `virtual` (`bucket.host`).
* `session_token` - for temporary credentials.
* `timeout` - per-request timeout in ms (default 30000), applied by the
  transport (hackney `recv_timeout`).

Resilience (built on `livery_client` layers, outermost to innermost
`[concurrency, circuit_breaker, retry, balance, signing]`):

* `retry` - `true` (default), `false`, or an options map merged over the S3
  defaults `#{max => 3, backoff => {200, 2.0}, statuses => [429,500,502,503,504]}`.
  Retries idempotent ops on transient statuses and connection errors; streamed
  request bodies and non-idempotent methods are never replayed.
* `circuit_breaker` - `true`, `false` (default), or an options map (`name`
  defaults to the endpoint authority). Trips on connection-level failures.
* `concurrency` - a positive integer cap on in-flight requests, or `false`
  (default); over the cap returns `{error, overloaded}`.
* `endpoints` - a list of base URLs to spread/fail over (path-style only, same
  region and credentials), or pass `balance => Map` for full control.

`circuit_breaker` and `endpoints`/`balance` are ETS-backed and require the
`livery` application to be started. `retry` and `concurrency` need nothing.

* `stack` - a full `livery_client` layer stack that bypasses the builders above
  (signing is still appended innermost). The spawn-based `livery_client:timeout/1`
  layer is incompatible with streamed downloads, so it is never added by default.
* `adapter`, `adapter_opts` - forwarded to `livery_client:new/1`.
""".
-spec new(map()) -> client().
new(Opts) ->
    Endpoint = maps:get(endpoint, Opts),
    #{scheme := Scheme, host := Host, port := Port} = livery_s3_uri:parse_endpoint(Endpoint),
    Cfg = #s3_config{
        scheme = Scheme,
        host = Host,
        port = Port,
        region = maps:get(region, Opts, <<"us-east-1">>),
        access_key_id = maps:get(access_key_id, Opts),
        secret_access_key = maps:get(secret_access_key, Opts),
        session_token = maps:get(session_token, Opts, undefined),
        addressing = maps:get(addressing, Opts, path)
    },
    Http = livery_client:new(#{
        base_url => <<>>,
        adapter => maps:get(adapter, Opts, livery_client_hackney),
        adapter_opts => maps:get(adapter_opts, Opts, #{}),
        stack => build_stack(Cfg, Opts)
    }),
    #s3_client{config = Cfg, http = Http, timeout = maps:get(timeout, Opts, 30000)}.

%% Compose the layer stack outermost-first; signing is always innermost. A
%% user-supplied `stack` bypasses the resilience builders.
-spec build_stack(#s3_config{}, map()) -> livery_client:stack().
build_stack(Cfg, Opts) ->
    Layers =
        case maps:find(stack, Opts) of
            {ok, Custom} ->
                Custom;
            error ->
                lists:append([
                    concurrency_layer(Opts),
                    circuit_layer(Cfg, Opts),
                    retry_layer(Opts),
                    balance_layer(Opts)
                ])
        end,
    Layers ++ [{livery_s3_sigv4, Cfg}].

-spec retry_layer(map()) -> livery_client:stack().
retry_layer(Opts) ->
    case maps:get(retry, Opts, true) of
        false -> [];
        true -> [livery_client:retry(?DEFAULT_RETRY)];
        Map when is_map(Map) -> [livery_client:retry(maps:merge(?DEFAULT_RETRY, Map))]
    end.

-spec circuit_layer(#s3_config{}, map()) -> livery_client:stack().
circuit_layer(Cfg, Opts) ->
    case maps:get(circuit_breaker, Opts, false) of
        false -> [];
        true -> [livery_client:circuit_breaker(circuit_opts(Cfg, #{}))];
        Map when is_map(Map) -> [livery_client:circuit_breaker(circuit_opts(Cfg, Map))]
    end.

-spec circuit_opts(#s3_config{}, map()) -> map().
circuit_opts(Cfg, Map) ->
    {_Url, Authority} = livery_s3_uri:request_target(Cfg, undefined, undefined, []),
    maps:merge(#{name => Authority, window => 20, trip => 0.5, cooldown => 5000}, Map).

-spec concurrency_layer(map()) -> livery_client:stack().
concurrency_layer(Opts) ->
    case maps:get(concurrency, Opts, false) of
        false -> [];
        N when is_integer(N), N > 0 -> [livery_client:concurrency(N)]
    end.

-spec balance_layer(map()) -> livery_client:stack().
balance_layer(Opts) ->
    case {maps:get(endpoints, Opts, undefined), maps:get(balance, Opts, undefined)} of
        {undefined, undefined} ->
            [];
        {_, Map} when is_map(Map) ->
            [livery_client:balance(Map)];
        {Endpoints, undefined} when is_list(Endpoints) ->
            [
                livery_client:balance(#{
                    name => {livery_s3_balance, Endpoints},
                    endpoints => Endpoints,
                    policy => p2c
                })
            ]
    end.

-doc "Generate a presigned URL valid for `Expires` seconds. See `presign/6`.".
-spec presign(client(), atom() | binary(), bucket(), key(), pos_integer()) -> {ok, binary()}.
presign(Client, Method, Bucket, Key, Expires) ->
    presign(Client, Method, Bucket, Key, Expires, #{}).

-doc """
Generate a presigned URL. `Opts` may carry `version_id` and the
`response_content_*` overrides (e.g. force a download filename). The URL signs
only the `host` header with an `UNSIGNED-PAYLOAD`, so it can be used directly by
a browser or any HTTP client.
""".
-spec presign(client(), atom() | binary(), bucket(), key(), pos_integer(), map()) ->
    {ok, binary()}.
presign(#s3_client{config = Cfg}, Method, Bucket, Key, Expires, Opts) ->
    {DateTime, Date} = livery_s3_sigv4:now_timestamps(),
    Extra = version_query(Opts) ++ response_query(Opts),
    {ok, livery_s3_sigv4:presigned_url(Cfg, Method, Bucket, Key, Expires, Extra, DateTime, Date)}.

%%====================================================================
%% Objects
%%====================================================================

-doc "Upload an object. `Body` is `iodata()` or a `{stream, Producer}` body.".
-spec put_object(client(), bucket(), key(), body()) -> {ok, map()} | {error, reason()}.
put_object(Client, Bucket, Key, Body) ->
    put_object(Client, Bucket, Key, Body, #{}).

-doc """
Upload an object with options: `content_type`, `cache_control`,
`content_disposition`, `content_encoding`, `storage_class`, `acl`, and
`metadata` (`#{Name => Value}` mapped to `x-amz-meta-*`).

Conditional writes (backend-dependent): `if_none_match => <<"*">>` puts only if
the object does not exist, `if_match => ETag` only if it matches; a failed
precondition yields `{error, precondition_failed}`. `content_md5 => true` adds a
base64 `Content-MD5` integrity header (full-body uploads only).
""".
-spec put_object(client(), bucket(), key(), body(), map()) -> {ok, map()} | {error, reason()}.
put_object(Client, Bucket, Key, Body, Opts) ->
    Body1 = to_body(Body),
    Headers = object_write_headers(Opts) ++ conditional_headers(Opts) ++ md5_headers(Opts, Body1),
    case request(Client, put, Bucket, Key, [], Headers, Body1, #{}) of
        {ok, Resp} ->
            case livery_client:status(Resp) of
                S when S >= 200, S < 300 -> {ok, write_result(Resp)};
                412 -> {error, precondition_failed};
                _ -> decode_error(Resp)
            end;
        {error, _} = E ->
            E
    end.

-doc "Download an object. See `get_object/4`.".
-spec get_object(client(), bucket(), key()) -> {ok, map()} | {error, reason()}.
get_object(Client, Bucket, Key) ->
    get_object(Client, Bucket, Key, #{}).

-doc """
Download an object. `Opts`:

* `range` - `{Start, End}`, `{Start, eof}`, or `{suffix, N}` (last N bytes).
* `version_id` - read a specific version.
* `stream` - when `true`, the result's `body` is a `{stream, Reader}` to drain
  with `livery_client:read/2`; otherwise it is the full binary.
* conditional headers `if_match`, `if_none_match`, `if_modified_since`,
  `if_unmodified_since`; a `304` yields `{error, not_modified}` and a `412`
  yields `{error, precondition_failed}`.
* response-header overrides `response_content_type`, `response_content_disposition`,
  `response_cache_control`, `response_content_encoding`, `response_content_language`,
  `response_expires`.

The result map carries `body`, `metadata`, and (when present) `content_type`,
`content_length`, `etag`, `last_modified`, `version_id`.
""".
-spec get_object(client(), bucket(), key(), map()) -> {ok, map()} | {error, reason()}.
get_object(Client, Bucket, Key, Opts) ->
    Stream = maps:get(stream, Opts, false),
    Headers = range_headers(Opts) ++ conditional_headers(Opts),
    Query = version_query(Opts) ++ response_query(Opts),
    case request(Client, get, Bucket, Key, Query, Headers, empty, #{stream => Stream}) of
        {ok, Resp} ->
            case livery_client:status(Resp) of
                S when S =:= 200; S =:= 206 -> {ok, read_result(Resp, Stream)};
                304 -> {error, not_modified};
                412 -> {error, precondition_failed};
                _ -> decode_error(Resp)
            end;
        {error, _} = E ->
            E
    end.

-doc "Fetch object metadata without the body. Missing object yields `not_found`.".
-spec head_object(client(), bucket(), key()) -> {ok, map()} | {error, reason()}.
head_object(Client, Bucket, Key) ->
    head_object(Client, Bucket, Key, #{}).

-doc """
Fetch object metadata. `Opts` may carry `version_id` and the same conditional
headers as `get_object/4` (`304` -> `not_modified`, `412` ->
`precondition_failed`).
""".
-spec head_object(client(), bucket(), key(), map()) -> {ok, map()} | {error, reason()}.
head_object(Client, Bucket, Key, Opts) ->
    Query = version_query(Opts),
    Headers = conditional_headers(Opts),
    case request(Client, head, Bucket, Key, Query, Headers, empty, #{}) of
        {ok, Resp} ->
            case livery_client:status(Resp) of
                200 -> {ok, object_meta(Resp)};
                304 -> {error, not_modified};
                412 -> {error, precondition_failed};
                404 -> {error, not_found};
                _ -> decode_error(Resp)
            end;
        {error, _} = E ->
            E
    end.

-doc "Delete an object. `Opts` may carry `version_id` to delete a version.".
-spec delete_object(client(), bucket(), key()) -> ok | {error, reason()}.
delete_object(Client, Bucket, Key) ->
    delete_object(Client, Bucket, Key, #{}).

-spec delete_object(client(), bucket(), key(), map()) -> ok | {error, reason()}.
delete_object(Client, Bucket, Key, Opts) ->
    Query = version_query(Opts),
    expect_ok(request(Client, delete, Bucket, Key, Query, [], empty, #{})).

-doc "Server-side copy. See `copy_object/6`.".
-spec copy_object(client(), bucket(), key(), bucket(), key()) -> {ok, map()} | {error, reason()}.
copy_object(Client, SrcBucket, SrcKey, DstBucket, DstKey) ->
    copy_object(Client, SrcBucket, SrcKey, DstBucket, DstKey, #{}).

-doc """
Server-side copy of `SrcBucket/SrcKey` to `DstBucket/DstKey`. `Opts` accepts the
same write options as `put_object/5`; supplying `metadata` switches the metadata
directive to `REPLACE`.
""".
-spec copy_object(client(), bucket(), key(), bucket(), key(), map()) ->
    {ok, map()} | {error, reason()}.
copy_object(Client, SrcBucket, SrcKey, DstBucket, DstKey, Opts) ->
    Headers0 = [
        {<<"x-amz-copy-source">>, copy_source(SrcBucket, SrcKey, Opts)}
        | object_write_headers(Opts)
    ],
    Headers =
        case maps:is_key(metadata, Opts) of
            true -> [{<<"x-amz-metadata-directive">>, <<"REPLACE">>} | Headers0];
            false -> Headers0
        end,
    case request(Client, put, DstBucket, DstKey, [], Headers, empty, #{}) of
        {ok, Resp} -> on_result_xml(Resp, <<"CopyObjectResult">>, fun copy_result/2);
        {error, _} = E -> E
    end.

%%====================================================================
%% Buckets
%%====================================================================

-doc "List all buckets owned by the caller.".
-spec list_buckets(client()) -> {ok, [map()]} | {error, reason()}.
list_buckets(Client) ->
    case request(Client, get, undefined, undefined, [], [], empty, #{}) of
        {ok, Resp} -> on_2xx(Resp, fun parse_list_buckets/1);
        {error, _} = E -> E
    end.

-doc "Create a bucket. See `create_bucket/3`.".
-spec create_bucket(client(), bucket()) -> ok | {error, reason()}.
create_bucket(Client, Bucket) ->
    create_bucket(Client, Bucket, #{}).

-doc """
Create a bucket. `Opts`: `acl` and, for AWS regions other than `us-east-1`,
`location_constraint => Region` (sent as a `CreateBucketConfiguration`). Most
S3-compatible stores need no body.
""".
-spec create_bucket(client(), bucket(), map()) -> ok | {error, reason()}.
create_bucket(Client, Bucket, Opts) ->
    Body = create_bucket_body(Opts),
    Headers = opt_header(<<"x-amz-acl">>, acl, Opts),
    expect_ok(request(Client, put, Bucket, undefined, [], Headers, to_body(Body), #{})).

-doc "Delete an (empty) bucket.".
-spec delete_bucket(client(), bucket()) -> ok | {error, reason()}.
delete_bucket(Client, Bucket) ->
    expect_ok(request(Client, delete, Bucket, undefined, [], [], empty, #{})).

-doc "Check a bucket exists and is accessible. Missing bucket yields `not_found`.".
-spec head_bucket(client(), bucket()) -> ok | {error, reason()}.
head_bucket(Client, Bucket) ->
    case request(Client, head, Bucket, undefined, [], [], empty, #{}) of
        {ok, Resp} ->
            case livery_client:status(Resp) of
                S when S >= 200, S < 300 -> ok;
                404 -> {error, not_found};
                _ -> decode_error(Resp)
            end;
        {error, _} = E ->
            E
    end.

-doc "Return the bucket's region. An empty `LocationConstraint` maps to `us-east-1`.".
-spec get_bucket_location(client(), bucket()) -> {ok, binary()} | {error, reason()}.
get_bucket_location(Client, Bucket) ->
    case request(Client, get, Bucket, undefined, [{<<"location">>, <<>>}], [], empty, #{}) of
        {ok, Resp} ->
            on_2xx(Resp, fun(R) ->
                {ok, Tree} = parse_body(R),
                {ok, location_region(livery_s3_xml:node_text(Tree))}
            end);
        {error, _} = E ->
            E
    end.

-doc "List objects (ListObjectsV2), one page. See `list_objects/3`.".
-spec list_objects(client(), bucket()) -> {ok, map()} | {error, reason()}.
list_objects(Client, Bucket) ->
    list_objects(Client, Bucket, #{}).

-doc """
List objects (ListObjectsV2). `Opts`: `prefix`, `delimiter`, `max_keys`,
`continuation_token`, `start_after`. Result: `objects`, `common_prefixes`,
`is_truncated`, `next_continuation_token`.
""".
-spec list_objects(client(), bucket(), map()) -> {ok, map()} | {error, reason()}.
list_objects(Client, Bucket, Opts) ->
    Query = [{<<"list-type">>, <<"2">>} | list_query(Opts)],
    case request(Client, get, Bucket, undefined, Query, [], empty, #{}) of
        {ok, Resp} -> on_2xx(Resp, fun(R) -> {ok, parse_list_objects(R)} end);
        {error, _} = E -> E
    end.

-doc "List every object, following continuation tokens. See `list_objects/3`.".
-spec list_objects_all(client(), bucket()) -> {ok, map()} | {error, reason()}.
list_objects_all(Client, Bucket) ->
    list_objects_all(Client, Bucket, #{}).

-spec list_objects_all(client(), bucket(), map()) -> {ok, map()} | {error, reason()}.
list_objects_all(Client, Bucket, Opts) ->
    list_all_loop(Client, Bucket, Opts, [], []).

-spec list_all_loop(client(), bucket(), map(), [map()], [binary()]) ->
    {ok, map()} | {error, reason()}.
list_all_loop(Client, Bucket, Opts, AccObjects, AccPrefixes) ->
    case list_objects(Client, Bucket, Opts) of
        {ok, #{
            objects := O,
            common_prefixes := P,
            is_truncated := true,
            next_continuation_token := Tok
        }} when Tok =/= undefined ->
            list_all_loop(
                Client, Bucket, Opts#{continuation_token => Tok}, AccObjects ++ O, AccPrefixes ++ P
            );
        {ok, #{objects := O, common_prefixes := P}} ->
            {ok, #{objects => AccObjects ++ O, common_prefixes => AccPrefixes ++ P}};
        {error, _} = E ->
            E
    end.

%%====================================================================
%% Versioning
%%====================================================================

-doc "Read a bucket's versioning state: `enabled`, `suspended`, or `none`.".
-spec get_bucket_versioning(client(), bucket()) ->
    {ok, enabled | suspended | none} | {error, reason()}.
get_bucket_versioning(Client, Bucket) ->
    case request(Client, get, Bucket, undefined, [{<<"versioning">>, <<>>}], [], empty, #{}) of
        {ok, Resp} ->
            on_2xx(Resp, fun(R) ->
                {ok, Tree} = parse_body(R),
                {ok, versioning_status(livery_s3_xml:text(Tree, <<"Status">>))}
            end);
        {error, _} = E ->
            E
    end.

-doc "Enable or suspend versioning on a bucket.".
-spec put_bucket_versioning(client(), bucket(), enabled | suspended) -> ok | {error, reason()}.
put_bucket_versioning(Client, Bucket, State) ->
    Status =
        case State of
            enabled -> <<"Enabled">>;
            suspended -> <<"Suspended">>
        end,
    Body = <<
        ?XML_DECL/binary,
        "<VersioningConfiguration><Status>",
        Status/binary,
        "</Status></VersioningConfiguration>"
    >>,
    Query = [{<<"versioning">>, <<>>}],
    expect_ok(request(Client, put, Bucket, undefined, Query, [], {full, Body}, #{})).

-doc "List object versions. See `list_object_versions/3`.".
-spec list_object_versions(client(), bucket()) -> {ok, map()} | {error, reason()}.
list_object_versions(Client, Bucket) ->
    list_object_versions(Client, Bucket, #{}).

-doc """
List object versions and delete markers. `Opts`: `prefix`, `delimiter`,
`max_keys`, `key_marker`, `version_id_marker`. Result: `versions`,
`delete_markers`, `is_truncated`, `next_key_marker`, `next_version_id_marker`.
""".
-spec list_object_versions(client(), bucket(), map()) -> {ok, map()} | {error, reason()}.
list_object_versions(Client, Bucket, Opts) ->
    Query = [{<<"versions">>, <<>>} | versions_query(Opts)],
    case request(Client, get, Bucket, undefined, Query, [], empty, #{}) of
        {ok, Resp} -> on_2xx(Resp, fun(R) -> {ok, parse_versions(R)} end);
        {error, _} = E -> E
    end.

%%====================================================================
%% Multipart
%%====================================================================

-doc "Begin a multipart upload, returning an upload id. See `create_multipart_upload/4`.".
-spec create_multipart_upload(client(), bucket(), key()) -> {ok, binary()} | {error, reason()}.
create_multipart_upload(Client, Bucket, Key) ->
    create_multipart_upload(Client, Bucket, Key, #{}).

-doc "Begin a multipart upload. `Opts` accepts the `put_object/5` write options.".
-spec create_multipart_upload(client(), bucket(), key(), map()) ->
    {ok, binary()} | {error, reason()}.
create_multipart_upload(Client, Bucket, Key, Opts) ->
    Headers = object_write_headers(Opts),
    case request(Client, post, Bucket, Key, [{<<"uploads">>, <<>>}], Headers, empty, #{}) of
        {ok, Resp} ->
            on_2xx(Resp, fun(R) ->
                {ok, Tree} = parse_body(R),
                {ok, livery_s3_xml:text(Tree, <<"UploadId">>)}
            end);
        {error, _} = E ->
            E
    end.

-doc "Upload one part (1-based `PartNumber`). Returns `#{etag => _}`.".
-spec upload_part(client(), bucket(), key(), binary(), pos_integer(), body()) ->
    {ok, map()} | {error, reason()}.
upload_part(Client, Bucket, Key, UploadId, PartNumber, Body) ->
    Query = [{<<"partNumber">>, integer_to_binary(PartNumber)}, {<<"uploadId">>, UploadId}],
    case request(Client, put, Bucket, Key, Query, [], to_body(Body), #{}) of
        {ok, Resp} ->
            on_2xx(Resp, fun(R) ->
                {ok, #{etag => unquote(livery_client:header(<<"etag">>, R, <<>>))}}
            end);
        {error, _} = E ->
            E
    end.

-doc """
Complete a multipart upload. `Parts` is `[{PartNumber, ETag}]` in order (the
ETags returned by `upload_part/6`).
""".
-spec complete_multipart_upload(client(), bucket(), key(), binary(), [{pos_integer(), binary()}]) ->
    {ok, map()} | {error, reason()}.
complete_multipart_upload(Client, Bucket, Key, UploadId, Parts) ->
    Body = build_complete_xml(Parts),
    Query = [{<<"uploadId">>, UploadId}],
    case request(Client, post, Bucket, Key, Query, [], {full, Body}, #{}) of
        {ok, Resp} ->
            on_result_xml(Resp, <<"CompleteMultipartUploadResult">>, fun complete_result/2);
        {error, _} = E ->
            E
    end.

-doc "Abort a multipart upload and discard its parts.".
-spec abort_multipart_upload(client(), bucket(), key(), binary()) -> ok | {error, reason()}.
abort_multipart_upload(Client, Bucket, Key, UploadId) ->
    Query = [{<<"uploadId">>, UploadId}],
    expect_ok(request(Client, delete, Bucket, Key, Query, [], empty, #{})).

-doc "Upload a part by copying from an existing object. See `upload_part_copy/8`.".
-spec upload_part_copy(client(), bucket(), key(), binary(), pos_integer(), bucket(), key()) ->
    {ok, map()} | {error, reason()}.
upload_part_copy(Client, Bucket, Key, UploadId, PartNumber, SrcBucket, SrcKey) ->
    upload_part_copy(Client, Bucket, Key, UploadId, PartNumber, SrcBucket, SrcKey, #{}).

-doc """
Upload a part by server-side copy from `SrcBucket/SrcKey`. `Opts`: `range =>
{Start, End}` copies a byte range of the source; `version_id` selects a source
version. Returns `#{etag => _}`.
""".
-spec upload_part_copy(
    client(), bucket(), key(), binary(), pos_integer(), bucket(), key(), map()
) -> {ok, map()} | {error, reason()}.
upload_part_copy(Client, Bucket, Key, UploadId, PartNumber, SrcBucket, SrcKey, Opts) ->
    Headers0 = [{<<"x-amz-copy-source">>, copy_source(SrcBucket, SrcKey, Opts)}],
    Headers =
        case maps:get(range, Opts, undefined) of
            undefined -> Headers0;
            {Start, End} -> [{<<"x-amz-copy-source-range">>, range_value(Start, End)} | Headers0]
        end,
    Query = [{<<"partNumber">>, integer_to_binary(PartNumber)}, {<<"uploadId">>, UploadId}],
    case request(Client, put, Bucket, Key, Query, Headers, empty, #{}) of
        {ok, Resp} -> on_result_xml(Resp, <<"CopyPartResult">>, fun copy_part_result/2);
        {error, _} = E -> E
    end.

-doc "List the parts uploaded so far for a multipart upload. See `list_parts/5`.".
-spec list_parts(client(), bucket(), key(), binary()) -> {ok, map()} | {error, reason()}.
list_parts(Client, Bucket, Key, UploadId) ->
    list_parts(Client, Bucket, Key, UploadId, #{}).

-doc """
List uploaded parts. `Opts`: `max_parts`, `part_number_marker`. Result: `parts`
(`#{part_number, etag, size, last_modified}`), `is_truncated`,
`next_part_number_marker`.
""".
-spec list_parts(client(), bucket(), key(), binary(), map()) -> {ok, map()} | {error, reason()}.
list_parts(Client, Bucket, Key, UploadId, Opts) ->
    Query = [{<<"uploadId">>, UploadId} | parts_query(Opts)],
    case request(Client, get, Bucket, Key, Query, [], empty, #{}) of
        {ok, Resp} -> on_2xx(Resp, fun(R) -> {ok, parse_parts(R)} end);
        {error, _} = E -> E
    end.

-doc "List in-progress multipart uploads in a bucket. See `list_multipart_uploads/3`.".
-spec list_multipart_uploads(client(), bucket()) -> {ok, map()} | {error, reason()}.
list_multipart_uploads(Client, Bucket) ->
    list_multipart_uploads(Client, Bucket, #{}).

-doc """
List in-progress multipart uploads. `Opts`: `prefix`, `delimiter`, `max_uploads`,
`key_marker`, `upload_id_marker`. Result: `uploads`
(`#{key, upload_id, initiated}`), `common_prefixes`, `is_truncated`,
`next_key_marker`, `next_upload_id_marker`.
""".
-spec list_multipart_uploads(client(), bucket(), map()) -> {ok, map()} | {error, reason()}.
list_multipart_uploads(Client, Bucket, Opts) ->
    Query = [{<<"uploads">>, <<>>} | uploads_query(Opts)],
    case request(Client, get, Bucket, undefined, Query, [], empty, #{}) of
        {ok, Resp} -> on_2xx(Resp, fun(R) -> {ok, parse_multipart_uploads(R)} end);
        {error, _} = E -> E
    end.

%%====================================================================
%% Batch delete
%%====================================================================

-doc """
Delete up to 1000 objects in one request. `Keys` is a list of `Key` binaries or
`{Key, VersionId}` tuples. Result: `#{deleted => [_], errors => [_]}`.
""".
-spec delete_objects(client(), bucket(), [key() | {key(), binary()}]) ->
    {ok, map()} | {error, reason()}.
delete_objects(Client, Bucket, Keys) ->
    Body = build_delete_xml(Keys),
    Headers = [{<<"content-md5">>, base64:encode(crypto:hash(md5, Body))}],
    case
        request(Client, post, Bucket, undefined, [{<<"delete">>, <<>>}], Headers, {full, Body}, #{})
    of
        {ok, Resp} -> on_2xx(Resp, fun(R) -> {ok, parse_delete_result(R)} end);
        {error, _} = E -> E
    end.

%%====================================================================
%% Request plumbing
%%====================================================================

-spec request(
    client(),
    atom(),
    undefined | bucket(),
    undefined | key(),
    [{binary(), binary()}],
    [{binary(), binary()}],
    empty | {full, iodata()} | {stream, fun()},
    map()
) -> livery_client:result().
request(Client, Method, Bucket, Key, Query, Headers, Body, ReqOpts) ->
    #s3_client{config = Cfg, http = Http, timeout = Timeout} = Client,
    {Url, _Authority} = livery_s3_uri:request_target(Cfg, Bucket, Key, Query),
    Opts = ReqOpts#{headers => Headers, body => Body, timeout => Timeout},
    livery_client:request(Http, Method, Url, Opts).

-spec on_2xx(livery_client:response(), fun((livery_client:response()) -> Ret)) ->
    Ret | {error, reason()}.
on_2xx(Resp, Fun) ->
    case ok_status(livery_client:status(Resp)) of
        true -> Fun(Resp);
        false -> decode_error(Resp)
    end.

%% Operations whose 2xx body may still carry an <Error> (copy, complete-upload):
%% succeed only when the body parses to the expected root element.
-spec on_result_xml(livery_client:response(), binary(), fun(
    (
        livery_s3_xml:tree(),
        livery_client:response()
    ) -> map()
)) -> {ok, map()} | {error, reason()}.
on_result_xml(Resp, Root, Fun) ->
    on_2xx(Resp, fun(R) ->
        case parse_body(R) of
            {ok, {Root, _, _} = Tree} -> {ok, Fun(Tree, R)};
            _ -> decode_error(R)
        end
    end).

-spec expect_ok(livery_client:result()) -> ok | {error, reason()}.
expect_ok({ok, Resp}) ->
    case ok_status(livery_client:status(Resp)) of
        true -> ok;
        false -> decode_error(Resp)
    end;
expect_ok({error, _} = E) ->
    E.

-spec ok_status(100..599) -> boolean().
ok_status(S) -> S >= 200 andalso S < 300.

-spec decode_error(livery_client:response()) -> {error, reason()}.
decode_error(Resp) ->
    Status = livery_client:status(Resp),
    Body = body_binary(Resp),
    case Body =/= <<>> andalso livery_s3_xml:parse(Body) of
        {ok, Tree} ->
            Code = default(livery_s3_xml:text(Tree, <<"Code">>), integer_to_binary(Status)),
            Msg = default(livery_s3_xml:text(Tree, <<"Message">>), <<>>),
            ReqId = livery_s3_xml:text(Tree, <<"RequestId">>),
            {error, {s3, Code, Msg, #{status => Status, request_id => ReqId}}};
        _ ->
            {error, {s3, integer_to_binary(Status), Body, #{status => Status}}}
    end.

-spec body_binary(livery_client:response()) -> binary().
body_binary(Resp) ->
    case livery_client:body(Resp) of
        {full, B} ->
            B;
        {stream, Reader} ->
            case livery_client:read_body(Reader) of
                {ok, B} -> B;
                {error, _} -> <<>>
            end
    end.

-spec parse_body(livery_client:response()) -> {ok, livery_s3_xml:tree()} | {error, term()}.
parse_body(Resp) ->
    livery_s3_xml:parse(body_binary(Resp)).

%%====================================================================
%% Response decoding
%%====================================================================

-spec write_result(livery_client:response()) -> map().
write_result(Resp) ->
    add_version(#{etag => unquote(livery_client:header(<<"etag">>, Resp, <<>>))}, Resp).

-spec read_result(livery_client:response(), boolean()) -> map().
read_result(Resp, true) ->
    (object_meta(Resp))#{body => livery_client:body(Resp)};
read_result(Resp, false) ->
    {full, Bin} = livery_client:body(Resp),
    (object_meta(Resp))#{body => Bin}.

-spec object_meta(livery_client:response()) -> map().
object_meta(Resp) ->
    Base = #{metadata => meta_from_headers(Resp)},
    With = [
        {content_type, <<"content-type">>},
        {last_modified, <<"last-modified">>}
    ],
    M1 = lists:foldl(
        fun({Field, Header}, Acc) ->
            case livery_client:header(Header, Resp, undefined) of
                undefined -> Acc;
                V -> Acc#{Field => V}
            end
        end,
        Base,
        With
    ),
    M2 =
        case livery_client:header(<<"content-length">>, Resp, undefined) of
            undefined -> M1;
            Len -> M1#{content_length => binary_to_integer(Len)}
        end,
    M3 =
        case livery_client:header(<<"etag">>, Resp, undefined) of
            undefined -> M2;
            ETag -> M2#{etag => unquote(ETag)}
        end,
    add_version(M3, Resp).

-spec add_version(map(), livery_client:response()) -> map().
add_version(Map, Resp) ->
    case livery_client:header(<<"x-amz-version-id">>, Resp, undefined) of
        undefined -> Map;
        V -> Map#{version_id => V}
    end.

-spec meta_from_headers(livery_client:response()) -> #{binary() => binary()}.
meta_from_headers(Resp) ->
    Prefix = <<"x-amz-meta-">>,
    PL = byte_size(Prefix),
    lists:foldl(
        fun({Name, Value}, Acc) ->
            Lower = string:lowercase(Name),
            case is_prefix(Prefix, Lower) of
                true -> Acc#{binary:part(Lower, PL, byte_size(Lower) - PL) => Value};
                false -> Acc
            end
        end,
        #{},
        livery_client:headers(Resp)
    ).

-spec parse_list_buckets(livery_client:response()) -> {ok, [map()]} | {error, reason()}.
parse_list_buckets(Resp) ->
    {ok, Tree} = parse_body(Resp),
    Buckets =
        case livery_s3_xml:child(Tree, <<"Buckets">>) of
            undefined ->
                [];
            Node ->
                [
                    #{
                        name => livery_s3_xml:text(B, <<"Name">>),
                        creation_date => livery_s3_xml:text(B, <<"CreationDate">>)
                    }
                 || B <- livery_s3_xml:children(Node, <<"Bucket">>)
                ]
        end,
    {ok, Buckets}.

-spec parse_list_objects(livery_client:response()) -> map().
parse_list_objects(Resp) ->
    {ok, Tree} = parse_body(Resp),
    Objects = [
        #{
            key => livery_s3_xml:text(N, <<"Key">>),
            size => to_int(livery_s3_xml:text(N, <<"Size">>)),
            etag => unquote(default(livery_s3_xml:text(N, <<"ETag">>), <<>>)),
            last_modified => livery_s3_xml:text(N, <<"LastModified">>)
        }
     || N <- livery_s3_xml:children(Tree, <<"Contents">>)
    ],
    Prefixes = [
        livery_s3_xml:text(N, <<"Prefix">>)
     || N <- livery_s3_xml:children(Tree, <<"CommonPrefixes">>)
    ],
    #{
        objects => Objects,
        common_prefixes => Prefixes,
        is_truncated => to_bool(livery_s3_xml:text(Tree, <<"IsTruncated">>)),
        next_continuation_token => livery_s3_xml:text(Tree, <<"NextContinuationToken">>)
    }.

-spec parse_versions(livery_client:response()) -> map().
parse_versions(Resp) ->
    {ok, Tree} = parse_body(Resp),
    Versions = [
        #{
            key => livery_s3_xml:text(N, <<"Key">>),
            version_id => livery_s3_xml:text(N, <<"VersionId">>),
            is_latest => to_bool(livery_s3_xml:text(N, <<"IsLatest">>)),
            etag => unquote(default(livery_s3_xml:text(N, <<"ETag">>), <<>>)),
            size => to_int(livery_s3_xml:text(N, <<"Size">>)),
            last_modified => livery_s3_xml:text(N, <<"LastModified">>)
        }
     || N <- livery_s3_xml:children(Tree, <<"Version">>)
    ],
    DeleteMarkers = [
        #{
            key => livery_s3_xml:text(N, <<"Key">>),
            version_id => livery_s3_xml:text(N, <<"VersionId">>),
            is_latest => to_bool(livery_s3_xml:text(N, <<"IsLatest">>)),
            last_modified => livery_s3_xml:text(N, <<"LastModified">>)
        }
     || N <- livery_s3_xml:children(Tree, <<"DeleteMarker">>)
    ],
    #{
        versions => Versions,
        delete_markers => DeleteMarkers,
        is_truncated => to_bool(livery_s3_xml:text(Tree, <<"IsTruncated">>)),
        next_key_marker => livery_s3_xml:text(Tree, <<"NextKeyMarker">>),
        next_version_id_marker => livery_s3_xml:text(Tree, <<"NextVersionIdMarker">>)
    }.

-spec parse_delete_result(livery_client:response()) -> map().
parse_delete_result(Resp) ->
    {ok, Tree} = parse_body(Resp),
    Deleted = [
        add_marker(#{key => livery_s3_xml:text(N, <<"Key">>)}, N)
     || N <- livery_s3_xml:children(Tree, <<"Deleted">>)
    ],
    Errors = [
        #{
            key => livery_s3_xml:text(N, <<"Key">>),
            code => livery_s3_xml:text(N, <<"Code">>),
            message => livery_s3_xml:text(N, <<"Message">>)
        }
     || N <- livery_s3_xml:children(Tree, <<"Error">>)
    ],
    #{deleted => Deleted, errors => Errors}.

-spec add_marker(map(), livery_s3_xml:tree()) -> map().
add_marker(Map, Node) ->
    case livery_s3_xml:text(Node, <<"VersionId">>) of
        undefined -> Map;
        V -> Map#{version_id => V}
    end.

-spec copy_result(livery_s3_xml:tree(), livery_client:response()) -> map().
copy_result(Tree, Resp) ->
    add_version(#{etag => unquote(default(livery_s3_xml:text(Tree, <<"ETag">>), <<>>))}, Resp).

-spec complete_result(livery_s3_xml:tree(), livery_client:response()) -> map().
complete_result(Tree, Resp) ->
    Base = #{
        etag => unquote(default(livery_s3_xml:text(Tree, <<"ETag">>), <<>>)),
        location => livery_s3_xml:text(Tree, <<"Location">>)
    },
    add_version(Base, Resp).

-spec copy_part_result(livery_s3_xml:tree(), livery_client:response()) -> map().
copy_part_result(Tree, _Resp) ->
    #{etag => unquote(default(livery_s3_xml:text(Tree, <<"ETag">>), <<>>))}.

-spec parse_parts(livery_client:response()) -> map().
parse_parts(Resp) ->
    {ok, Tree} = parse_body(Resp),
    Parts = [
        #{
            part_number => to_int(livery_s3_xml:text(N, <<"PartNumber">>)),
            etag => unquote(default(livery_s3_xml:text(N, <<"ETag">>), <<>>)),
            size => to_int(livery_s3_xml:text(N, <<"Size">>)),
            last_modified => livery_s3_xml:text(N, <<"LastModified">>)
        }
     || N <- livery_s3_xml:children(Tree, <<"Part">>)
    ],
    #{
        parts => Parts,
        is_truncated => to_bool(livery_s3_xml:text(Tree, <<"IsTruncated">>)),
        next_part_number_marker => livery_s3_xml:text(Tree, <<"NextPartNumberMarker">>)
    }.

-spec parse_multipart_uploads(livery_client:response()) -> map().
parse_multipart_uploads(Resp) ->
    {ok, Tree} = parse_body(Resp),
    Uploads = [
        #{
            key => livery_s3_xml:text(N, <<"Key">>),
            upload_id => livery_s3_xml:text(N, <<"UploadId">>),
            initiated => livery_s3_xml:text(N, <<"Initiated">>)
        }
     || N <- livery_s3_xml:children(Tree, <<"Upload">>)
    ],
    Prefixes = [
        livery_s3_xml:text(N, <<"Prefix">>)
     || N <- livery_s3_xml:children(Tree, <<"CommonPrefixes">>)
    ],
    #{
        uploads => Uploads,
        common_prefixes => Prefixes,
        is_truncated => to_bool(livery_s3_xml:text(Tree, <<"IsTruncated">>)),
        next_key_marker => livery_s3_xml:text(Tree, <<"NextKeyMarker">>),
        next_upload_id_marker => livery_s3_xml:text(Tree, <<"NextUploadIdMarker">>)
    }.

-spec location_region(binary()) -> binary().
location_region(<<>>) -> <<"us-east-1">>;
location_region(Region) -> Region.

-spec versioning_status(undefined | binary()) -> enabled | suspended | none.
versioning_status(<<"Enabled">>) -> enabled;
versioning_status(<<"Suspended">>) -> suspended;
versioning_status(_) -> none.

%%====================================================================
%% Request construction helpers
%%====================================================================

-spec to_body(body() | binary()) -> {full, iodata()} | {stream, fun()}.
to_body({stream, _} = B) -> B;
to_body({full, _} = B) -> B;
to_body(IoData) -> {full, IoData}.

-spec object_write_headers(map()) -> [{binary(), binary()}].
object_write_headers(Opts) ->
    lists:append([
        opt_header(<<"content-type">>, content_type, Opts),
        opt_header(<<"cache-control">>, cache_control, Opts),
        opt_header(<<"content-disposition">>, content_disposition, Opts),
        opt_header(<<"content-encoding">>, content_encoding, Opts),
        opt_header(<<"x-amz-storage-class">>, storage_class, Opts),
        opt_header(<<"x-amz-acl">>, acl, Opts),
        meta_headers(Opts)
    ]).

-spec opt_header(binary(), atom(), map()) -> [{binary(), binary()}].
opt_header(Name, Key, Opts) ->
    case maps:get(Key, Opts, undefined) of
        undefined -> [];
        Value -> [{Name, Value}]
    end.

-spec meta_headers(map()) -> [{binary(), binary()}].
meta_headers(Opts) ->
    Meta = maps:get(metadata, Opts, #{}),
    [{<<"x-amz-meta-", K/binary>>, V} || {K, V} <- maps:to_list(Meta)].

-spec range_headers(map()) -> [{binary(), binary()}].
range_headers(Opts) ->
    case maps:get(range, Opts, undefined) of
        undefined -> [];
        {Start, eof} -> [{<<"range">>, <<"bytes=", (integer_to_binary(Start))/binary, "-">>}];
        {suffix, N} -> [{<<"range">>, <<"bytes=-", (integer_to_binary(N))/binary>>}];
        {Start, End} -> [{<<"range">>, range_value(Start, End)}]
    end.

-spec range_value(non_neg_integer(), non_neg_integer()) -> binary().
range_value(Start, End) ->
    <<"bytes=", (integer_to_binary(Start))/binary, "-", (integer_to_binary(End))/binary>>.

-spec version_query(map()) -> [{binary(), binary()}].
version_query(Opts) ->
    case maps:get(version_id, Opts, undefined) of
        undefined -> [];
        V -> [{<<"versionId">>, V}]
    end.

-spec conditional_headers(map()) -> [{binary(), binary()}].
conditional_headers(Opts) ->
    lists:append([
        opt_header(<<"if-match">>, if_match, Opts),
        opt_header(<<"if-none-match">>, if_none_match, Opts),
        opt_header(<<"if-modified-since">>, if_modified_since, Opts),
        opt_header(<<"if-unmodified-since">>, if_unmodified_since, Opts)
    ]).

-spec response_query(map()) -> [{binary(), binary()}].
response_query(Opts) ->
    lists:append([
        opt_query(<<"response-content-type">>, response_content_type, Opts),
        opt_query(<<"response-content-disposition">>, response_content_disposition, Opts),
        opt_query(<<"response-cache-control">>, response_cache_control, Opts),
        opt_query(<<"response-content-encoding">>, response_content_encoding, Opts),
        opt_query(<<"response-content-language">>, response_content_language, Opts),
        opt_query(<<"response-expires">>, response_expires, Opts)
    ]).

-spec md5_headers(map(), {full, iodata()} | {stream, fun()}) -> [{binary(), binary()}].
md5_headers(Opts, {full, Data}) ->
    case maps:get(content_md5, Opts, false) of
        true -> [{<<"content-md5">>, base64:encode(crypto:hash(md5, Data))}];
        _ -> []
    end;
md5_headers(_Opts, _Body) ->
    [].

-spec copy_source(bucket(), key(), map()) -> binary().
copy_source(SrcBucket, SrcKey, Opts) ->
    Base = <<"/", SrcBucket/binary, "/", (livery_s3_uri:encode_path(SrcKey))/binary>>,
    case maps:get(version_id, Opts, undefined) of
        undefined -> Base;
        V -> <<Base/binary, "?versionId=", V/binary>>
    end.

-spec uploads_query(map()) -> [{binary(), binary()}].
uploads_query(Opts) ->
    lists:append([
        opt_query(<<"prefix">>, prefix, Opts),
        opt_query(<<"delimiter">>, delimiter, Opts),
        opt_query(<<"key-marker">>, key_marker, Opts),
        opt_query(<<"upload-id-marker">>, upload_id_marker, Opts),
        int_query(<<"max-uploads">>, max_uploads, Opts)
    ]).

-spec parts_query(map()) -> [{binary(), binary()}].
parts_query(Opts) ->
    lists:append([
        int_query(<<"max-parts">>, max_parts, Opts),
        int_query(<<"part-number-marker">>, part_number_marker, Opts)
    ]).

-spec list_query(map()) -> [{binary(), binary()}].
list_query(Opts) ->
    lists:append([
        opt_query(<<"prefix">>, prefix, Opts),
        opt_query(<<"delimiter">>, delimiter, Opts),
        opt_query(<<"start-after">>, start_after, Opts),
        opt_query(<<"continuation-token">>, continuation_token, Opts),
        int_query(<<"max-keys">>, max_keys, Opts)
    ]).

-spec versions_query(map()) -> [{binary(), binary()}].
versions_query(Opts) ->
    lists:append([
        opt_query(<<"prefix">>, prefix, Opts),
        opt_query(<<"delimiter">>, delimiter, Opts),
        opt_query(<<"key-marker">>, key_marker, Opts),
        opt_query(<<"version-id-marker">>, version_id_marker, Opts),
        int_query(<<"max-keys">>, max_keys, Opts)
    ]).

-spec opt_query(binary(), atom(), map()) -> [{binary(), binary()}].
opt_query(Name, Key, Opts) ->
    case maps:get(Key, Opts, undefined) of
        undefined -> [];
        Value -> [{Name, Value}]
    end.

-spec int_query(binary(), atom(), map()) -> [{binary(), binary()}].
int_query(Name, Key, Opts) ->
    case maps:get(Key, Opts, undefined) of
        undefined -> [];
        N -> [{Name, integer_to_binary(N)}]
    end.

-spec create_bucket_body(map()) -> binary().
create_bucket_body(Opts) ->
    case maps:get(location_constraint, Opts, undefined) of
        undefined ->
            <<>>;
        Region ->
            <<
                ?XML_DECL/binary,
                "<CreateBucketConfiguration><LocationConstraint>",
                Region/binary,
                "</LocationConstraint></CreateBucketConfiguration>"
            >>
    end.

-spec build_delete_xml([key() | {key(), binary()}]) -> binary().
build_delete_xml(Keys) ->
    Objects = <<<<(delete_object_xml(K))/binary>> || K <- Keys>>,
    <<?XML_DECL/binary, "<Delete>", Objects/binary, "<Quiet>false</Quiet></Delete>">>.

-spec delete_object_xml(key() | {key(), binary()}) -> binary().
delete_object_xml({Key, VersionId}) ->
    <<
        "<Object><Key>",
        (xml_escape(Key))/binary,
        "</Key><VersionId>",
        (xml_escape(VersionId))/binary,
        "</VersionId></Object>"
    >>;
delete_object_xml(Key) when is_binary(Key) ->
    <<"<Object><Key>", (xml_escape(Key))/binary, "</Key></Object>">>.

-spec build_complete_xml([{pos_integer(), binary()}]) -> binary().
build_complete_xml(Parts) ->
    Items = <<<<(part_xml(P))/binary>> || P <- Parts>>,
    <<?XML_DECL/binary, "<CompleteMultipartUpload>", Items/binary, "</CompleteMultipartUpload>">>.

-spec part_xml({pos_integer(), binary()}) -> binary().
part_xml({Num, ETag}) ->
    <<
        "<Part><PartNumber>",
        (integer_to_binary(Num))/binary,
        "</PartNumber><ETag>",
        (ensure_quoted(ETag))/binary,
        "</ETag></Part>"
    >>.

%%====================================================================
%% Small utilities
%%====================================================================

-spec unquote(binary()) -> binary().
unquote(<<$", Rest/binary>>) when byte_size(Rest) >= 1 ->
    N = byte_size(Rest) - 1,
    case Rest of
        <<Inner:N/binary, $">> -> Inner;
        _ -> <<$", Rest/binary>>
    end;
unquote(B) ->
    B.

-spec ensure_quoted(binary()) -> binary().
ensure_quoted(<<$", _/binary>> = B) -> B;
ensure_quoted(B) -> <<$", B/binary, $">>.

-spec default(undefined | T, T) -> T.
default(undefined, D) -> D;
default(V, _) -> V.

-spec to_int(undefined | binary()) -> undefined | integer().
to_int(undefined) -> undefined;
to_int(B) -> binary_to_integer(B).

-spec to_bool(undefined | binary()) -> boolean().
to_bool(<<"true">>) -> true;
to_bool(_) -> false.

-spec is_prefix(binary(), binary()) -> boolean().
is_prefix(Prefix, Bin) ->
    PL = byte_size(Prefix),
    byte_size(Bin) >= PL andalso binary:part(Bin, 0, PL) =:= Prefix.

-spec xml_escape(binary()) -> binary().
xml_escape(B) ->
    <<<<(escape_char(C))/binary>> || <<C>> <= B>>.

-spec escape_char(byte()) -> binary().
escape_char($&) -> <<"&amp;">>;
escape_char($<) -> <<"&lt;">>;
escape_char($>) -> <<"&gt;">>;
escape_char($") -> <<"&quot;">>;
escape_char($') -> <<"&apos;">>;
escape_char(C) -> <<C>>.
