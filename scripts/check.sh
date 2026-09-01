#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$root/server"
python3 -m ruff check .
python3 -m pytest
cd "$root/server/web"
npm ci
npm run typecheck
npm test
npm run build
