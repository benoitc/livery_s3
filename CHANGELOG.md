# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
semantic versioning.

## 0.1.0 - unreleased

Initial release.

### Objects
- `put_object`, `get_object`, `head_object`, `delete_object`, `copy_object`.
- User metadata (`x-amz-meta-*`) and system headers (content-type,
  cache-control, content-disposition, content-encoding, storage-class, acl).
- Byte ranges (`{Start,End}` / `{Start,eof}` / `{suffix,N}`) and streaming
  up/downloads.
- Conditional requests (`if_match`, `if_none_match`, `if_modified_since`,
  `if_unmodified_since`) mapping `304`/`412` to `not_modified` /
  `precondition_failed`; `Content-MD5`; GET/presign response-header overrides.

### Buckets
- `list_buckets`, `create_bucket`, `delete_bucket`, `head_bucket`,
  `get_bucket_location`, `list_objects` (V2) with `list_objects_all` pagination.

### Versioning
- `get_bucket_versioning`, `put_bucket_versioning`, `list_object_versions`, and
  versioned get/delete. Degrades to a clean `NotImplemented` error on backends
  without versioning (e.g. Garage).

### Multipart, copy, batch
- `create_multipart_upload`, `upload_part`, `complete_multipart_upload`,
  `abort_multipart_upload`, `upload_part_copy`, `list_parts`,
  `list_multipart_uploads`; `delete_objects` (batch).

### Presigned URLs
- `presign` (query-string SigV4), with `version_id` and response-header
  overrides.

### Resilience
- Retries on by default (transient 5xx + connection errors, idempotent ops,
  re-signed per attempt), honoring a `Retry-After` header; opt-in circuit
  breaker, concurrency cap, and multi-endpoint balancing, all via `livery_client`
  layers.
- Region-redirect following (`301 PermanentRedirect` / `400
  AuthorizationHeaderMalformed`): re-sign for the corrected region/host and retry
  once (on by default, `follow_region_redirects => false` to disable).

### Credentials
- Providers via `credentials => Provider`: `static`, `env`, `{file, Profile}`,
  `imds` (EC2/ECS instance metadata), `{web_identity, _}` (STS
  AssumeRoleWithWebIdentity), a `default` chain, and `fun`/`{M,F,A}`. Refreshing
  providers cache and rotate temporary credentials
  (`livery_s3_credentials_store`, started by the `livery_s3` application).

### Transport and signing
- AWS Signature V4 (validated against AWS's published S3 examples), path-style
  (default) and virtual-hosted addressing, session tokens.
