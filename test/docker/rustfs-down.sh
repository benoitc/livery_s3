#!/usr/bin/env bash
# Stop and remove the RustFS test container and its data volume.
set -euo pipefail
docker rm -f livery-s3-rustfs >/dev/null 2>&1 || true
docker volume rm livery-s3-rustfs-data >/dev/null 2>&1 || true
echo "RustFS stopped."
