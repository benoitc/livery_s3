#!/usr/bin/env bash
# Start a single-node MinIO in Docker for the integration suite.
#
# MinIO is the second integration target: unlike Garage it enforces conditional
# writes, so it is what exercises the If-Match/If-None-Match branches of the
# suite. Point the suite at it with:
#
#   LIVERY_S3_ENDPOINT=http://127.0.0.1:9000 LIVERY_S3_REGION=us-east-1 \
#     rebar3 ct --suite test/livery_s3_garage_SUITE
set -euo pipefail

NAME=livery-s3-minio
# quay.io: the minio/minio repository is no longer pullable from Docker Hub.
IMAGE=quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z
ACCESS_KEY=${LIVERY_S3_ACCESS_KEY:-minioadmin}
SECRET_KEY=${LIVERY_S3_SECRET_KEY:-minioadmin}
BUCKET=${LIVERY_S3_BUCKET:-livery-s3-test}

docker rm -f "$NAME" >/dev/null 2>&1 || true

# MINIO_KMS_SECRET_KEY is a static test key: it enables SSE-S3 and SSE-KMS
# (key id `livery-s3-key`) for the encryption tests.

# Pre-pull with retries: registry timeouts are a common CI flake.
for attempt in 1 2 3 4 5; do
  if docker pull "$IMAGE"; then break; fi
  echo "image pull failed (attempt $attempt), retrying in 5s..."
  sleep 5
done

docker run -d --name "$NAME" \
  -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER="$ACCESS_KEY" \
  -e MINIO_ROOT_PASSWORD="$SECRET_KEY" \
  -e MINIO_KMS_SECRET_KEY="livery-s3-key:MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=" \
  "$IMAGE" server /data --console-address ":9001" >/dev/null

echo "Waiting for MinIO S3 API on :9000..."
for _ in $(seq 1 60); do
  if curl -s -o /dev/null "http://127.0.0.1:9000/minio/health/live"; then break; fi
  sleep 1
done

# Create the test bucket with the bundled mc client.
docker exec "$NAME" mc alias set local http://127.0.0.1:9000 "$ACCESS_KEY" "$SECRET_KEY" >/dev/null
docker exec "$NAME" mc mb --ignore-existing "local/$BUCKET" >/dev/null

# A second bucket readable without credentials, for the anonymous-access tests.
PUBLIC_BUCKET=${LIVERY_S3_PUBLIC_BUCKET:-livery-s3-public}
docker exec "$NAME" mc mb --ignore-existing "local/$PUBLIC_BUCKET" >/dev/null
docker exec "$NAME" mc anonymous set download "local/$PUBLIC_BUCKET" >/dev/null

echo "MinIO ready: endpoint=http://127.0.0.1:9000 region=us-east-1 bucket=$BUCKET public=$PUBLIC_BUCKET key=$ACCESS_KEY"
