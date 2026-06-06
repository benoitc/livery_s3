#!/usr/bin/env bash
# Stop and remove the integration-test Garage container.
set -euo pipefail
docker rm -f livery-s3-garage >/dev/null 2>&1 || true
echo "Garage stopped."
