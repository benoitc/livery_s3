# TODO

Remaining S3 features, by tier. Checked items are implemented; see
[docs/features.md](docs/features.md) for the supported surface.

## Done: commonly used, available across S3-compatible stores

- [x] Conditional GET/HEAD (`if_match`, `if_none_match`, `if_modified_since`,
      `if_unmodified_since`); map `304 not_modified` / `412 precondition_failed`
- [x] Conditional PUT (`if_match`, `if_none_match`) - sent as headers; enforcement
      is backend-dependent (AWS/MinIO enforce, Garage ignores)
- [x] `Content-MD5` on PUT (integrity)
- [x] GET response-header overrides (`response-content-type`, ... ) on
      `get_object` and `presign`
- [x] `get_bucket_location`
- [x] Multipart `list_parts`
- [x] Multipart `list_multipart_uploads`
- [x] Multipart `upload_part_copy`

## Planned: AWS / not universal across S3-compatible stores

- [ ] Object tagging (`PutObjectTagging` / `GetObjectTagging` /
      `DeleteObjectTagging`, `x-amz-tagging` on put)
- [ ] Object ACL get/set (`GetObjectAcl` / `PutObjectAcl`)
- [ ] Server-side encryption (SSE-S3, SSE-KMS, SSE-C)
- [ ] Integrity checksums (`x-amz-checksum-crc32/crc32c/sha1/sha256`)
- [ ] `GetObjectAttributes`
- [ ] Object Lock / legal hold / retention
- [ ] Glacier `RestoreObject`

## Planned: bucket configuration subresources (admin)

- [ ] Lifecycle (`Get/Put/DeleteBucketLifecycleConfiguration`)
- [ ] Bucket policy (`Get/Put/DeleteBucketPolicy`)
- [ ] Bucket CORS (`Get/Put/DeleteBucketCors`)
- [ ] Bucket tagging
- [ ] Bucket ACL
- [ ] Default bucket encryption
- [ ] Public access block
- [ ] Website / logging / notification / replication / request-payment /
      accelerate / object-lock config

## Planned: convenience and robustness (not raw API)

- [ ] High-level "upload a large file/stream as multipart" helper
- [ ] Presigned POST (browser form-upload policy)
- [ ] Automatic retries/backoff on transient 5xx / connection errors
- [ ] Region-redirect handling (AWS `301` with the correct region)
- [ ] Anonymous / unsigned requests for public objects
