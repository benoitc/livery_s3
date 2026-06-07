# livery_s3

An S3-compatible object storage client for Erlang, built on the
[livery](https://github.com/benoitc/livery) HTTP client. Works with AWS S3 and
S3-compatible stores (Garage, MinIO, Ceph, Wasabi, …). Signs every request with
AWS Signature V4.

## Features

- Object CRUD: `put_object`, `get_object`, `head_object`, `delete_object`,
  server-side `copy_object`
- User + system metadata (`x-amz-meta-*`, content-type, cache-control, …)
- Byte ranges and streaming up/downloads
- Conditional requests (`if_match`/`if_none_match`/`if_modified_since`),
  `Content-MD5`, and GET/presign response-header overrides
- Bucket management: `list_buckets`, `create_bucket`, `delete_bucket`,
  `head_bucket`, `get_bucket_location`, `list_objects` (V2, with pagination via
  `list_objects_all`)
- Versioning (where the backend supports it): `get_bucket_versioning`,
  `put_bucket_versioning`, `list_object_versions`, versioned get/delete
- Multipart upload (`create`/`upload_part`/`complete`/`abort`,
  `upload_part_copy`, `list_parts`, `list_multipart_uploads`)
- Batch delete and presigned URLs (`presign`)
- Resilience via livery_client layers: retries (on by default), circuit breaker,
  concurrency cap, multi-endpoint balancing
- Path-style (default) and virtual-hosted addressing; AWS SigV4 signing with
  session-token support

See [docs/features.md](docs/features.md) for the full reference.

## Usage

```erlang
C = livery_s3:new(#{
    endpoint => <<"https://s3.eu-west-1.amazonaws.com">>,  % or http://127.0.0.1:3900
    region   => <<"eu-west-1">>,
    access_key_id     => <<"AKIA...">>,
    secret_access_key => <<"...">>
    %% addressing => path | virtual   (default path)
    %% session_token => <<"...">>     (temporary credentials)
    %% timeout => 30000               (per-request, ms)
}),

ok = livery_s3:create_bucket(C, <<"photos">>),

{ok, _} = livery_s3:put_object(C, <<"photos">>, <<"cat.jpg">>, Bytes,
                               #{content_type => <<"image/jpeg">>,
                                 metadata => #{<<"album">> => <<"holiday">>}}),

{ok, #{body := Bytes, metadata := #{<<"album">> := <<"holiday">>}}} =
    livery_s3:get_object(C, <<"photos">>, <<"cat.jpg">>),

%% Range request
{ok, #{body := First1k}} =
    livery_s3:get_object(C, <<"photos">>, <<"cat.jpg">>, #{range => {0, 1023}}),

%% Streaming download
{ok, #{body := {stream, Reader}}} =
    livery_s3:get_object(C, <<"photos">>, <<"cat.jpg">>, #{stream => true}),
{ok, All} = livery_client:read_body(Reader),

%% Presigned URL
{ok, Url} = livery_s3:presign(C, get, <<"photos">>, <<"cat.jpg">>, 3600).
```

Every call returns `{ok, _}` / `ok` or `{error, Reason}`. S3 error bodies surface
as `{error, {s3, Code, Message, #{status => S, request_id => RId}}}`; a missing
object/bucket on a HEAD is `{error, not_found}`.

## Resilience

Retries are on by default (transient `5xx` + connection errors, idempotent ops,
exponential backoff). Circuit breaking, a concurrency cap, and multi-endpoint
balancing are opt-in:

```erlang
C = livery_s3:new(#{
    endpoint => <<"https://s3.eu-west-1.amazonaws.com">>,
    region   => <<"eu-west-1">>,
    access_key_id => <<"AKIA...">>, secret_access_key => <<"...">>,
    retry           => #{max => 5},   % or false to disable
    circuit_breaker => true,          % needs the livery app started
    concurrency     => 50
}).
```

Streamed uploads and non-idempotent `POST` operations are never retried. See
[docs/features.md](docs/features.md#resilience) for ordering and caveats.

## Compatibility

`addressing => path` (the default) keeps the bucket in the URL path, which every
S3-compatible store accepts. Use `virtual` for AWS-native
`bucket.host` addressing. Features the backend does not implement (e.g.
versioning on Garage) return a clean `{error, {s3, <<"NotImplemented">>, _, _}}`
rather than crashing.

## Testing

Offline unit tests (SigV4 against AWS's published worked examples, URI encoding,
XML parsing, and request/response round-trips through a fake adapter):

```
rebar3 eunit
```

Integration tests run against a real [Garage](https://garagehq.deuxfleurs.fr/)
in Docker:

```
make test            # garage-up -> rebar3 ct -> garage-down
```

or manually:

```
./test/docker/garage-up.sh
rebar3 ct --suite test/livery_s3_garage_SUITE
./test/docker/garage-down.sh
```

The suite skips itself if no S3 endpoint is reachable. Override the target with
`LIVERY_S3_ENDPOINT`, `LIVERY_S3_REGION`, `LIVERY_S3_ACCESS_KEY`,
`LIVERY_S3_SECRET_KEY`, `LIVERY_S3_BUCKET`.

Full offline gate (compile, xref, dialyzer, lint, fmt, eunit):

```
make check
```

## Documentation

API docs are generated with ex_doc; [docs/features.md](docs/features.md) lists
every capability and the function behind it.

```
rebar3 ex_doc      # writes HTML to doc/
```

## License

Apache-2.0. Copyright 2026 Benoit Chesneau. See [LICENSE](LICENSE).
