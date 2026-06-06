# Features

What `livery_s3` supports, and the function behind each capability. Every call
returns `{ok, _}` / `ok` or `{error, Reason}`. S3 error bodies decode to
`{error, {s3, Code, Message, #{status => S, request_id => RId}}}`.

## Objects (CRUD)

| Operation | Function |
|-----------|----------|
| Upload | `put_object/4,5` |
| Download | `get_object/3,4` |
| Metadata only | `head_object/3,4` (missing object yields `not_found`) |
| Delete | `delete_object/3,4` |
| Server-side copy | `copy_object/5,6` |

## Metadata

`put_object/5` and `create_multipart_upload/4` accept a write-options map:
`content_type`, `cache_control`, `content_disposition`, `content_encoding`,
`storage_class`, `acl`, and `metadata` (`#{Name => Value}` mapped to
`x-amz-meta-*`). On `get_object`/`head_object` the `x-amz-meta-*` headers are
returned as a `metadata` map alongside `content_type`, `content_length`,
`etag`, `last_modified`, and `version_id`.

## Ranges and streaming

- `get_object/4` with `range => {Start, End}` | `{Start, eof}` | `{suffix, N}`
  issues a `Range` request and accepts `200` or `206`.
- `get_object/4` with `stream => true` returns `body => {stream, Reader}`;
  drain it with `livery_client:read/2` or `read_body/1`.
- Uploads accept a streaming body: pass `{stream, Producer}` as the body.

## Conditional requests and integrity

- `get_object/4` and `head_object/4` accept `if_match`, `if_none_match`,
  `if_modified_since`, `if_unmodified_since`. A `304` becomes
  `{error, not_modified}` and a `412` becomes `{error, precondition_failed}`.
- `put_object/5` accepts `if_match` / `if_none_match` for conditional writes
  (e.g. `if_none_match => <<"*">>` for create-if-absent); enforcement is
  backend-dependent (AWS and MinIO enforce it, Garage currently does not).
- `put_object/5` with `content_md5 => true` adds a base64 `Content-MD5`
  integrity header (full-body uploads).

## Response-header overrides

`get_object/4` and `presign/6` accept `response_content_type`,
`response_content_disposition`, `response_cache_control`,
`response_content_encoding`, `response_content_language`, `response_expires`
(e.g. force a download filename on a presigned URL).

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

## Multipart upload

`create_multipart_upload/3,4`, `upload_part/6`, `complete_multipart_upload/5`,
`abort_multipart_upload/4`. Pass the `{PartNumber, ETag}` pairs returned by
`upload_part/6` to `complete_multipart_upload/5`.

Also: `upload_part_copy/7,8` (server-side copy a whole object or byte range as a
part), `list_parts/4,5`, and `list_multipart_uploads/2,3`.

## Batch delete

`delete_objects/3` removes up to 1000 keys in one request. Keys are `Key`
binaries or `{Key, VersionId}` tuples; the result is
`#{deleted => [_], errors => [_]}`.

## Presigned URLs

`presign/5,6` returns a time-limited URL (query-string SigV4, `host` the only
signed header). Works for any method; `Opts` may carry `version_id` and the
`response_content_*` overrides.

## Addressing and compatibility

- `addressing => path` (default) keeps the bucket in the URL path; works with
  every S3-compatible store.
- `addressing => virtual` uses `bucket.host`.
- Requests are signed with AWS Signature V4. `session_token` is supported for
  temporary credentials.

## Not in scope (yet)

ACL/policy/CORS/lifecycle/tagging subresources, SSE-C/KMS encryption headers,
SigV2, request-payer, and object lock.
