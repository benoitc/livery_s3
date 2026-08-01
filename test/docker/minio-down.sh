#!/usr/bin/env bash
# Stop and remove the integration-test MinIO container.
set -euo pipefail
docker rm -f livery-s3-minio >/dev/null 2>&1 || true
echo "MinIO stopped."
