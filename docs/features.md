# Features

What `livery_s3` supports, and the function behind each capability. Every call
returns `{ok, _}` / `ok` or `{error, Reason}`. S3 error bodies decode to
`{error, {s3, Code, Message, #{status => S, request_id => RId}}}`.

The Erlang examples below assume a client `C` built once with `livery_s3:new/1`
(endpoint, region, credentials, addressing); see the Overview for construction
and options.

## Objects (CRUD)

| Operation | Function |
|-----------|----------|
| Upload | `put_object/4,5` |
| Download | `get_object/3,4` |
| Metadata only | `head_object/3,4` (missing object yields `not_found`) |
| Delete | `delete_object/3,4` |
| Server-side copy | `copy_object/5,6` |

```erlang
%% Upload, then read back.
{ok, #{etag := ETag}}  = livery_s3:put_object(C, <<"photos">>, <<"cat.jpg">>, Bytes),
{ok, #{body := Bytes}} = livery_s3:get_object(C, <<"photos">>, <<"cat.jpg">>),

%% Metadata without the body (missing object -> not_found).
{ok, #{content_length := Len, etag := ETag}} =
    livery_s3:head_object(C, <<"photos">>, <<"cat.jpg">>),
{error, not_found} = livery_s3:head_object(C, <<"photos">>, <<"missing">>),

ok = livery_s3:delete_object(C, <<"photos">>, <<"cat.jpg">>),

%% Server-side copy (the bytes never round-trip through the client).
{ok, #{etag := _}} =
    livery_s3:copy_object(C, <<"photos">>, <<"cat.jpg">>, <<"backup">>, <<"cat.jpg">>).
```

## Metadata

`put_object/5` and `create_multipart_upload/4` accept a write-options map:
`content_type`, `cache_control`, `content_disposition`, `content_encoding`,
`storage_class`, `acl`, and `metadata` (`#{Name => Value}` mapped to
`x-amz-meta-*`). On `get_object`/`head_object` the `x-amz-meta-*` headers are
returned as a `metadata` map alongside `content_type`, `content_length`,
`etag`, `last_modified`, and `version_id`.

```erlang
{ok, _} = livery_s3:put_object(C, <<"photos">>, <<"cat.jpg">>, Bytes, #{
    content_type  => <<"image/jpeg">>,
    cache_control => <<"max-age=3600">>,
    metadata      => #{<<"album">> => <<"holiday">>, <<"owner">> => <<"alice">>}
}),

{ok, #{content_type := <<"image/jpeg">>,
       metadata     := #{<<"album">> := <<"holiday">>}}} =
    livery_s3:head_object(C, <<"photos">>, <<"cat.jpg">>).
```

## Ranges and streaming

- `get_object/4` with `range => {Start, End}` | `{Start, eof}` | `{suffix, N}`
  issues a `Range` request and accepts `200` or `206`.
- `get_object/4` with `stream => true` returns `body => {stream, Reader}`;
  drain it with `livery_client:read/2` or `read_body/1`.
- Uploads accept a streaming body: pass `{stream, Producer}` as the body.

```erlang
%% First 1 KiB. Also {Start, eof} and {suffix, N} (last N bytes).
{ok, #{body := First1k}}  =
    livery_s3:get_object(C, <<"photos">>, <<"cat.jpg">>, #{range => {0, 1023}}),
{ok, #{body := LastByte}} =
    livery_s3:get_object(C, <<"photos">>, <<"cat.jpg">>, #{range => {suffix, 1}}),

%% Streaming download: drain the reader instead of buffering the whole object.
{ok, #{body := {stream, Reader}}} =
    livery_s3:get_object(C, <<"photos">>, <<"big.bin">>, #{stream => true}),
{ok, All} = livery_client:read_body(Reader),

%% Streaming upload: the body fun returns eof | {ok, Chunk, NextFun}.
Emit = fun Loop([H | T]) -> {ok, H, fun() -> Loop(T) end};
           Loop([])      -> eof
       end,
{ok, _} = livery_s3:put_object(C, <<"photos">>, <<"big.bin">>,
                               {stream, fun() -> Emit(Chunks) end}).
```

## Conditional requests and integrity

- `get_object/4` and `head_object/4` accept `if_match`, `if_none_match`,
  `if_modified_since`, `if_unmodified_since`. A `304` becomes
  `{error, not_modified}` and a `412` becomes `{error, precondition_failed}`.
- `put_object/5` accepts `if_match` / `if_none_match` for conditional writes
  (e.g. `if_none_match => <<"*">>` for create-if-absent); enforcement is
  backend-dependent (AWS and MinIO enforce it, Garage currently does not).
- `put_object/5` with `content_md5 => true` adds a base64 `Content-MD5`
  integrity header (full-body uploads).

```erlang
%% Create only if the object does not already exist.
case livery_s3:put_object(C, <<"photos">>, <<"cat.jpg">>, Bytes,
                          #{if_none_match => <<"*">>}) of
    {ok, _}                      -> created;
    {error, precondition_failed} -> already_exists
end,

%% Conditional GET: unchanged since this ETag -> not_modified.
{error, not_modified} =
    livery_s3:get_object(C, <<"photos">>, <<"cat.jpg">>, #{if_none_match => ETag}),

%% Integrity check on a full-body upload.
{ok, _} = livery_s3:put_object(C, <<"photos">>, <<"cat.jpg">>, Bytes,
                               #{content_md5 => true}).
```

## Response-header overrides

`get_object/4` and `presign/6` accept `response_content_type`,
`response_content_disposition`, `response_cache_control`,
`response_content_encoding`, `response_content_language`, `response_expires`
(e.g. force a download filename on a presigned URL).

```erlang
%% Make the store return this content-type on the GET.
{ok, #{body := _}} =
    livery_s3:get_object(C, <<"docs">>, <<"report">>,
                         #{response_content_type => <<"application/pdf">>}),

%% Force a download filename on a presigned link.
{ok, Url} =
    livery_s3:presign(C, get, <<"docs">>, <<"report">>, 3600,
                      #{response_content_disposition =>
                            <<"attachment; filename=\"report.pdf\"">>}).
```

## Buckets

| Operation | Function |
|-----------|----------|
| List buckets | `list_buckets/1` |
| Create | `create_bucket/2,3` |
| Delete | `delete_bucket/2` |
| Exists | `head_bucket/2` |
| Region | `get_bucket_location/2` |
| List objects (V2) | `list_objects/2,3` |
| List all (paginated) | `list_objects_all/2,3` |

`list_objects/3` options: `prefix`, `delimiter`, `max_keys`,
`continuation_token`, `start_after`. `create_bucket/3` takes `acl` and, for AWS
regions other than `us-east-1`, `location_constraint => Region`.

```erlang
{ok, Buckets} = livery_s3:list_buckets(C),   %% [#{name := _, creation_date := _}]

ok = livery_s3:create_bucket(C, <<"photos">>),
ok = livery_s3:head_bucket(C, <<"photos">>),     %% {error, not_found} if absent
{ok, Region} = livery_s3:get_bucket_location(C, <<"photos">>),

%% AWS regions other than us-east-1 need a location constraint.
ok = livery_s3:create_bucket(C, <<"eu-bucket">>,
                             #{location_constraint => <<"eu-west-1">>}),

%% One page (ListObjectsV2); a delimiter groups keys into "folders".
{ok, #{objects := Objs, common_prefixes := Dirs, is_truncated := More}} =
    livery_s3:list_objects(C, <<"photos">>,
                           #{prefix => <<"2026/">>, delimiter => <<"/">>, max_keys => 100}),

%% Every key, following continuation tokens for you.
{ok, #{objects := AllObjs}} = livery_s3:list_objects_all(C, <<"photos">>),

ok = livery_s3:delete_bucket(C, <<"photos">>).   %% must be empty
```

## Versioning (history)

Available where the backend implements it. Backends that do not (e.g. Garage)
return `{error, {s3, <<"NotImplemented">>, _, _}}` rather than crashing.

| Operation | Function |
|-----------|----------|
| Read state | `get_bucket_versioning/2` (`enabled` / `suspended` / `none`) |
| Set state | `put_bucket_versioning/3` |
| List versions | `list_object_versions/2,3` |
| Read a version | `get_object/4` with `version_id` |
| Delete a version | `delete_object/4` with `version_id` |

```erlang
ok            = livery_s3:put_bucket_versioning(C, <<"photos">>, enabled),
{ok, enabled} = livery_s3:get_bucket_versioning(C, <<"photos">>),

{ok, #{versions := [#{version_id := Vsn} | _] = Versions,
       delete_markers := Markers}} =
    livery_s3:list_object_versions(C, <<"photos">>, #{prefix => <<"cat.jpg">>}),

%% Read and delete one specific version.
{ok, #{body := _}} =
    livery_s3:get_object(C, <<"photos">>, <<"cat.jpg">>, #{version_id => Vsn}),
ok = livery_s3:delete_object(C, <<"photos">>, <<"cat.jpg">>, #{version_id => Vsn}).
```

## Multipart upload

`create_multipart_upload/3,4`, `upload_part/6`, `complete_multipart_upload/5`,
`abort_multipart_upload/4`. Pass the `{PartNumber, ETag}` pairs returned by
`upload_part/6` to `complete_multipart_upload/5`.

Also: `upload_part_copy/7,8` (server-side copy a whole object or byte range as a
part), `list_parts/4,5`, and `list_multipart_uploads/2,3`.

```erlang
{ok, UploadId} = livery_s3:create_multipart_upload(C, <<"videos">>, <<"clip.mp4">>),

%% Each part is at least 5 MiB except the last; number them from 1.
{ok, #{etag := E1}} =
    livery_s3:upload_part(C, <<"videos">>, <<"clip.mp4">>, UploadId, 1, Part1),
{ok, #{etag := E2}} =
    livery_s3:upload_part(C, <<"videos">>, <<"clip.mp4">>, UploadId, 2, Part2),

{ok, #{etag := _, location := _}} =
    livery_s3:complete_multipart_upload(C, <<"videos">>, <<"clip.mp4">>, UploadId,
                                        [{1, E1}, {2, E2}]),

%% On failure, release the staged parts:
%%   ok = livery_s3:abort_multipart_upload(C, <<"videos">>, <<"clip.mp4">>, UploadId).

%% Build a part from a byte range of an existing object (no download).
{ok, #{etag := _E3}} =
    livery_s3:upload_part_copy(C, <<"videos">>, <<"clip.mp4">>, UploadId, 3,
                               <<"videos">>, <<"source.mp4">>, #{range => {0, 5242879}}),

%% Inspect in-flight uploads and their parts.
{ok, #{uploads := _}} = livery_s3:list_multipart_uploads(C, <<"videos">>),
{ok, #{parts   := _}} = livery_s3:list_parts(C, <<"videos">>, <<"clip.mp4">>, UploadId).
```

## Batch delete

`delete_objects/3` removes up to 1000 keys in one request. Keys are `Key`
binaries or `{Key, VersionId}` tuples; the result is
`#{deleted => [_], errors => [_]}`.

```erlang
{ok, #{deleted := Deleted, errors := Errors}} =
    livery_s3:delete_objects(C, <<"photos">>,
                             [<<"a.jpg">>, <<"b.jpg">>, {<<"c.jpg">>, VersionId}]).
```

## Presigned URLs

`presign/5,6` returns a time-limited URL (query-string SigV4, `host` the only
signed header). Works for any method; `Opts` may carry `version_id` and the
`response_content_*` overrides.

```erlang
%% A link any HTTP client or browser can GET for the next hour.
{ok, GetUrl} = livery_s3:presign(C, get, <<"photos">>, <<"cat.jpg">>, 3600),

%% Presign an upload target valid for 15 minutes.
{ok, PutUrl} = livery_s3:presign(C, put, <<"photos">>, <<"new.jpg">>, 900).
```

## Resilience

Built on `livery_client` layers, composed outermost to innermost as
`[concurrency, circuit_breaker, retry, balance, signing]`. Configure via
`new/1`:

- `retry` (default **on**) - `true`, `false`, or an options map merged over the
  S3 defaults `#{max => 3, backoff => {200, 2.0}, statuses => [429,500,502,503,504]}`.
  Retries idempotent ops on those statuses and on connection errors, with
  exponential backoff + jitter, **honoring a `Retry-After` header** (delta-seconds,
  capped by `retry_after_max`) when the server sends one. Streamed request bodies
  and non-idempotent methods (the `POST` ops: create/complete multipart, batch
  delete) are never replayed. Each attempt is re-signed with a fresh `x-amz-date`.
- `follow_region_redirects` (default **on**) - follows AWS region redirects
  (`301 PermanentRedirect` and `400 AuthorizationHeaderMalformed`) by re-signing
  for the corrected region (and host, from the `<Endpoint>` / `x-amz-bucket-region`
  signal) and retrying once. Single-region S3-compatible stores never emit these,
  so it is a no-op there; set `false` to disable. Targets virtual-hosted
  addressing for host moves.
- `circuit_breaker` (default off) - `true`, `false`, or a map (`name`, `window`,
  `trip`, `cooldown`; `name` defaults to the endpoint authority). Opens on
  connection-level failures and then fails fast with `{error, circuit_open}`. It
  does not react to 5xx responses (that is retry's job).
- `concurrency` (default off) - an integer cap on in-flight requests; over the
  cap returns `{error, overloaded}`.
- `endpoints` (default off) - a list of base URLs to spread/fail over across
  gateways (path-style only, same region/credentials), or `balance => Map` for
  full control. A retry above the balancer lands on a healthy endpoint.

```erlang
%% circuit_breaker and endpoints/balance need the livery app started.
{ok, _} = application:ensure_all_started(livery_s3),
C = livery_s3:new(#{
    endpoint => <<"https://s3.eu-west-1.amazonaws.com">>,
    region   => <<"eu-west-1">>,
    access_key_id => <<"AKIA...">>, secret_access_key => <<"...">>,
    retry           => #{max => 5},   %% or false to disable
    circuit_breaker => true,
    concurrency     => 50,
    endpoints       => [<<"https://gw1.example">>, <<"https://gw2.example">>]
}).
```

Caveats: `circuit_breaker` and `endpoints`/`balance` are ETS-backed and require
the `livery` application to be started (`application:ensure_all_started(livery_s3)`);
`retry` and `concurrency` need nothing. There is no overall hard-deadline layer
by default (the spawn-based `livery_client:timeout/1` would break streamed
downloads); the `timeout` option bounds each receive via hackney `recv_timeout`,
so total wall-clock grows with retries.

## Credentials

Pass static keys (`access_key_id` + `secret_access_key`, optional
`session_token`) or a provider via `credentials => Provider`:

- `env` - `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`.
- `{file, Profile}` - `~/.aws/credentials` (path via `AWS_SHARED_CREDENTIALS_FILE`,
  profile via `AWS_PROFILE`).
- `imds` - EC2/ECS instance metadata (IMDSv2), with refresh.
- `{web_identity, Opts}` - STS `AssumeRoleWithWebIdentity` from
  `AWS_WEB_IDENTITY_TOKEN_FILE` + `AWS_ROLE_ARN`, with refresh.
- `default` - the env -> web-identity -> file -> imds chain.
- A `fun/0` or `{Module, Function, Args}` returning `{ok, creds()} | {error, _}`.

```erlang
%% Static keys.
livery_s3:new(#{endpoint => E, region => R,
                access_key_id => <<"AKIA...">>, secret_access_key => <<"...">>}),

%% A provider, with no hardcoded secret.
livery_s3:new(#{endpoint => E, region => R, credentials => env}),
livery_s3:new(#{endpoint => E, region => R, credentials => {file, <<"default">>}}),
livery_s3:new(#{endpoint => E, region => R, credentials => default}),

%% Refreshing providers (imds, web_identity) need the application started.
{ok, _} = application:ensure_all_started(livery_s3),
livery_s3:new(#{endpoint => E, region => R, credentials => imds}).
```

Static/env/file are resolved once at `new/1`. Refreshing providers (`imds`,
`web_identity`, custom funs that set `expires_at`) are cached and refreshed
before expiry by `livery_s3_credentials_store`, so **they require the `livery_s3`
application to be started** (`application:ensure_all_started(livery_s3)`). The
resolved credentials feed SigV4 and work on any store; the providers are
environment-specific (env/file/static everywhere, IMDS on AWS, web-identity on
AWS or MinIO STS).

## Addressing and compatibility

- `addressing => path` (default) keeps the bucket in the URL path; works with
  every S3-compatible store.
- `addressing => virtual` uses `bucket.host`.
- Requests are signed with AWS Signature V4; `session_token` and rotating
  temporary credentials are supported.

## Not in scope (yet)

ACL/policy/CORS/lifecycle/tagging subresources, SSE-C/KMS encryption headers,
SigV2, request-payer, and object lock.
