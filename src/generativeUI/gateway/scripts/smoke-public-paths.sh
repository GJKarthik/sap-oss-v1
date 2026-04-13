#!/usr/bin/env bash
# Smoke-check public paths behind the suite gateway (or any reverse proxy with the same routes).
# Usage: GATEWAY_URL=http://localhost:8080 ./smoke-public-paths.sh
set -euo pipefail
BASE="${GATEWAY_URL:-http://localhost:8080}"
BASE="${BASE%/}"

echo "Smoke: BASE=$BASE"

curl -sfS -o /dev/null "$BASE/api/v1/training/health" && echo "OK  GET /api/v1/training/health"
curl -sfS "$BASE/api/v1/training/capabilities" | head -c 200 && echo "... OK GET /api/v1/training/capabilities"
curl -sfS -o /dev/null "$BASE/api/training/health" && echo "OK  GET /api/training/health (legacy alias)"

curl -sfS -o /dev/null "$BASE/api/v1/ui5/openai/health" && echo "OK  GET /api/v1/ui5/openai/health"

code=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE/api/v1/ui5/mcp/health" || true)
echo "GET /api/v1/ui5/mcp/health -> HTTP $code (2xx/401 acceptable if upstream reachable)"

echo "Done."
