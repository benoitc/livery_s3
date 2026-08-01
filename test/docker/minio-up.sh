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
IMAGE=minio/minio:RELEASE.2025-04-22T22-12-26Z
ACCESS_KEY=${LIVERY_S3_ACCESS_KEY:-minioadmin}
SECRET_KEY=${LIVERY_S3_SECRET_KEY:-minioadmin}
BUCKET=${LIVERY_S3_BUCKET:-livery-s3-test}

docker rm -f "$NAME" >/dev/null 2>&1 || true

# Pre-pull with retries: Docker Hub registry timeouts are a common CI flake.
for attempt in 1 2 3 4 5; do
  if docker pull "$IMAGE"; then break; fi
  echo "image pull failed (attempt $attempt), retrying in 5s..."
  sleep 5
done

docker run -d --name "$NAME" \
  -p 9000:9000 -p 9001:9001 \
  -e MINIO_ROOT_USER="$ACCESS_KEY" \
  -e MINIO_ROOT_PASSWORD="$SECRET_KEY" \
  "$IMAGE" server /data --console-address ":9001" >/dev/null

echo "Waiting for MinIO S3 API on :9000..."
for _ in $(seq 1 60); do
  if curl -s -o /dev/null "http://127.0.0.1:9000/minio/health/live"; then break; fi
  sleep 1
done

# Create the test bucket with the bundled mc client.
docker exec "$NAME" mc alias set local http://127.0.0.1:9000 "$ACCESS_KEY" "$SECRET_KEY" >/dev/null
docker exec "$NAME" mc mb --ignore-existing "local/$BUCKET" >/dev/null

echo "MinIO ready: endpoint=http://127.0.0.1:9000 region=us-east-1 bucket=$BUCKET key=$ACCESS_KEY"
