#!/usr/bin/env bash
# Validate root and generativeUI docker compose files (no containers started).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

echo "== docker compose (repo root) =="
docker compose -f docker-compose.yml config -q
echo "OK"

echo "== docker compose (generativeUI suite) =="
docker compose -f src/generativeUI/docker-compose.yml config -q
echo "OK"

echo "== docker compose (generativeUI + workspace E2E ports) =="
docker compose -f src/generativeUI/docker-compose.yml \
  -f src/generativeUI/docker-compose.workspace-e2e.yml config -q
echo "OK"
