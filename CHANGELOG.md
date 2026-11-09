# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/), and the project aims to follow
semantic versioning.

## Unreleased

### Added
- Anonymous access: a client built with `credentials => anonymous` sends
  requests unsigned, so you can read public buckets without keys.
- Integrity checksums: uploads can carry a CRC32, CRC32C, SHA1 or SHA256
  checksum that the store verifies, including per part on multipart uploads,
  and reads can return the stored checksum.
- Server-side encryption with store-managed keys (SSE-S3), KMS keys (SSE-KMS),
  or your own keys (SSE-C), on uploads, reads, copies and multipart uploads.
- Presigned POST: browser form uploads straight to a bucket, under a signed
  policy that can cap the file size and restrict the key and content type.
- Object tagging: set tags at write time, and replace, read or remove them
  later. Copies keep the source's tags unless you give new ones.
- Listings can ask the store to URL-encode keys, for keys holding characters
  XML cannot carry. The result still holds the original keys.
- Client options for AWS Requester Pays buckets and for rejecting requests to a
  bucket owned by another account.

### Changed
- `make test` and `make test-minio` now fail when the integration suite fails.
  Before, a failing run still exited successfully.

## 0.2.1 - 2026-09-21

Maintenance release: dependency updates.

### Changed
- Bump `livery` to `~> 0.10.2` (tracks 0.10.x) and `hackney` to `~> 4.7`
  (tracks 4.x).

## 0.2.0 - 2026-08-01

### Added
- `complete_multipart_upload/6`: conditional writes on multipart completion via
  `if_match` / `if_none_match`. A multipart object is created at completion, so
  completion is where the guard applies. `complete_multipart_upload/5` is
  unchanged.
- `conditional_request_conflict` reason, for the `409` an `if_none_match`
  completion gets when another operation races it. The upload id is dead and
  the upload has to restart from `create_multipart_upload/4`.
- MinIO as a second integration target (`test/docker/minio-up.sh`,
  `make test-minio`), run alongside Garage in CI. Garage ignores conditional
  writes, so it cannot exercise the enforcing paths.

### Notes
- The `412`/`409`/`404` mappings apply only when a conditional header was
  actually sent. A `404` from a plain completion means `NoSuchUpload`, and that
  keeps its S3 error rather than becoming `not_found`, since the two need
  different recovery.

## 0.1.2 - 2026-06-20

Maintenance release: dependency updates.

### Changed
- Bump `livery` to `~> 0.4.4` and `hackney` to `~> 4.4.5`; both deps now use
  patch-relative version constraints.

## 0.1.1 - 2026-06-09

### Documentation
- Usage examples for every function group in the features reference (object
  CRUD, metadata, ranges/streaming, conditional writes, buckets, versioning,
  multipart, batch delete, presigned URLs, resilience, credentials).

## 0.1.0 - 2026-06-08

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
