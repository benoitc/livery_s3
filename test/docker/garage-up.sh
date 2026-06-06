#!/usr/bin/env bash
# Start a single-node Garage in Docker for the integration suite.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME=livery-s3-garage
IMAGE=dxflrs/garage:v2.3.0
ACCESS_KEY=${LIVERY_S3_ACCESS_KEY:-GKtestaccesskey1234567890}
SECRET_KEY=${LIVERY_S3_SECRET_KEY:-testsecretkey00000000000000000000000000000000000}
BUCKET=${LIVERY_S3_BUCKET:-livery-s3-test}

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" \
  -p 3900:3900 -p 3901:3901 -p 3903:3903 \
  -v "$HERE/garage.toml:/etc/garage.toml" \
  -e GARAGE_DEFAULT_ACCESS_KEY="$ACCESS_KEY" \
  -e GARAGE_DEFAULT_SECRET_KEY="$SECRET_KEY" \
  -e GARAGE_DEFAULT_BUCKET="$BUCKET" \
  "$IMAGE" /garage server --single-node --default-bucket >/dev/null

echo "Waiting for Garage S3 API on :3900..."
for _ in $(seq 1 60); do
  if curl -s -o /dev/null "http://127.0.0.1:3900"; then break; fi
  sleep 1
done

# Let the default key create buckets (needed by the bucket-lifecycle test).
docker exec "$NAME" /garage key allow --create-bucket "$ACCESS_KEY" >/dev/null 2>&1 || true

echo "Garage ready: endpoint=http://127.0.0.1:3900 region=garage bucket=$BUCKET key=$ACCESS_KEY"
