#!/usr/bin/env bash
# Run UI5 workspace Cypress E2E with live training-api + ui5-mcp (host ports 8000 / 9160).
# Prerequisite: docker compose -f src/generativeUI/docker-compose.yml \
#   -f src/generativeUI/docker-compose.workspace-e2e.yml up -d --build training-api ui5-mcp
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export TRAINING_API_URL="${TRAINING_API_URL:-http://localhost:8000}"
export AGENT_URL="${AGENT_URL:-http://localhost:9160}"
export CYPRESS_LIVE_BACKENDS="${CYPRESS_LIVE_BACKENDS:-true}"

cd "$ROOT/src/generativeUI/ui5-webcomponents-ngx-main"
corepack enable 2>/dev/null || true
yarn nx run workspace-e2e:e2e --configuration=ci
