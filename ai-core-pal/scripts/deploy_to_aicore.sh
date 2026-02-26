#!/bin/bash
# Deploy mesh-gateway to SAP AI Core
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SERVICE_NAME="${SERVICE_NAME:-mesh-gateway}"
VERSION="${VERSION:-1.0.0}"
DOCKER_REGISTRY="${DOCKER_REGISTRY:-ghcr.io/turrellcraigjohn-alt}"

echo "=== Deploying $SERVICE_NAME to SAP AI Core ==="
cd "$PROJECT_ROOT"
docker build -t "$DOCKER_REGISTRY/$SERVICE_NAME:$VERSION" -f Dockerfile .
docker push "$DOCKER_REGISTRY/$SERVICE_NAME:$VERSION"

if [ -n "$AI_CORE_TOKEN" ]; then
    curl -X POST "$AI_CORE_URL/v2/lm/scenarios" \
        -H "Authorization: Bearer $AI_CORE_TOKEN" \
        -H "Content-Type: application/json" \
        -d @"$PROJECT_ROOT/deploy/aicore/deployment-config.json"
fi

echo "=== Done: $DOCKER_REGISTRY/$SERVICE_NAME:$VERSION ==="