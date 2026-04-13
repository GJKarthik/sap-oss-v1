#!/usr/bin/env bash
# Smoke-test suite gateway public paths. Default GATEWAY_URL=http://localhost:8080
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec bash "$ROOT/src/generativeUI/gateway/scripts/smoke-public-paths.sh"
