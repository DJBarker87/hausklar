#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
docker compose down --volumes
printf 'Demo data volume removed. Run make demo to recreate fictional data.\n'
