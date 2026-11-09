#!/usr/bin/env bash
# Start a single-node RustFS in Docker for the integration suite.
#
# RustFS is the second integration target, next to Garage: it enforces
# conditional writes and implements features Garage lacks (tagging, anonymous
# access through bucket policies, SSE-S3/SSE-KMS). Point the suite at it with:
#
#   LIVERY_S3_BACKEND=rustfs LIVERY_S3_ENDPOINT=http://127.0.0.1:9000 \
#     LIVERY_S3_REGION=us-east-1 LIVERY_S3_ACCESS_KEY=rustfsadmin \
#     LIVERY_S3_SECRET_KEY=rustfsadmin rebar3 ct --suite test/livery_s3_garage_SUITE
set -euo pipefail

NAME=livery-s3-rustfs
IMAGE=rustfs/rustfs:1.0.4
REGION=us-east-1
ACCESS_KEY=${LIVERY_S3_ACCESS_KEY:-rustfsadmin}
SECRET_KEY=${LIVERY_S3_SECRET_KEY:-rustfsadmin}
BUCKET=${LIVERY_S3_BUCKET:-livery-s3-test}
PUBLIC_BUCKET=${LIVERY_S3_PUBLIC_BUCKET:-livery-s3-public}

VOLUME=$NAME-data
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker volume rm "$VOLUME" >/dev/null 2>&1 || true

# Pre-pull with retries: registry timeouts are a common CI flake.
for attempt in 1 2 3 4 5; do
  if docker pull "$IMAGE"; then break; fi
  echo "image pull failed (attempt $attempt), retrying in 5s..."
  sleep 5
done

# The local KMS backend is for development only. It backs SSE-S3 and SSE-KMS
# for the encryption tests; DEFAULT_KEY_ID is the key both modes use.
start() {
  docker run -d --name "$NAME" \
    -p 9000:9000 \
    -v "$VOLUME:/data" \
    -e RUSTFS_ACCESS_KEY="$ACCESS_KEY" \
    -e RUSTFS_SECRET_KEY="$SECRET_KEY" \
    -e RUSTFS_REGION="$REGION" \
    -e RUSTFS_KMS_ENABLE=true \
    -e RUSTFS_KMS_BACKEND=local \
    -e RUSTFS_KMS_KEY_DIR=/data/.kms \
    -e RUSTFS_KMS_ALLOW_INSECURE_DEV_DEFAULTS=true \
    "$@" "$IMAGE" >/dev/null
}

# Signed S3 calls from inside the container, with curl's SigV4 support.
s3() {
  docker exec "$NAME" curl -s --aws-sigv4 "aws:amz:$REGION:s3" \
    --user "$ACCESS_KEY:$SECRET_KEY" "$@"
}
status() { s3 -o /dev/null -w '%{http_code}' "$@"; }

wait_ready() {
  for _ in $(seq 1 60); do
    if [ "$(status http://127.0.0.1:9000/ 2>/dev/null || true)" = "200" ]; then return 0; fi
    sleep 1
  done
  echo "RustFS did not become ready" >&2
  docker logs "$NAME" >&2 || true
  exit 1
}

echo "Waiting for RustFS S3 API on :9000..."
start
wait_ready

# RustFS picks the id of a new key, so create one, then restart on the same
# data with it as the default key.
KEY_ID=$(s3 -X POST -H 'content-type: application/json' \
  --data '{"key_usage":"EncryptDecrypt","description":"livery_s3 tests"}' \
  http://127.0.0.1:9000/rustfs/admin/v3/kms/create-key |
  sed -n 's/.*"key_id":"\([^"]*\)".*/\1/p')
if [ -z "$KEY_ID" ]; then echo "KMS key creation failed" >&2; exit 1; fi
docker rm -f "$NAME" >/dev/null
start -e RUSTFS_KMS_DEFAULT_KEY_ID="$KEY_ID"
wait_ready

create_bucket() {
  code=$(status -X PUT "http://127.0.0.1:9000/$1")
  case "$code" in
    200|409) ;;
    *) echo "create bucket $1 failed: HTTP $code" >&2; exit 1 ;;
  esac
}

create_bucket "$BUCKET"

# A second bucket readable without credentials, for the anonymous-access tests.
create_bucket "$PUBLIC_BUCKET"
POLICY=$(cat <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":["*"]},
"Action":["s3:GetObject","s3:ListBucket","s3:GetBucketLocation"],
"Resource":["arn:aws:s3:::$PUBLIC_BUCKET","arn:aws:s3:::$PUBLIC_BUCKET/*"]}]}
EOF
)
code=$(status -X PUT -H 'content-type: application/json' --data "$POLICY" \
  "http://127.0.0.1:9000/$PUBLIC_BUCKET?policy")
case "$code" in
  200|204) ;;
  *) echo "set public policy failed: HTTP $code" >&2; exit 1 ;;
esac

echo "RustFS ready: endpoint=http://127.0.0.1:9000 region=$REGION bucket=$BUCKET public=$PUBLIC_BUCKET key=$ACCESS_KEY kms=$KEY_ID"
