#!/bin/bash
# Test SAP BTP AI Core Deployment
# Reads credentials from .vscode/sap_config.local.mg
#
# This script:
# 1. Gets OAuth token from AI Core
# 2. Lists available resource plans (verify GPU availability)
# 3. Creates/updates scenario and executable
# 4. Creates deployment configuration
# 5. Triggers deployment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ROOT_DIR="$(dirname "$(dirname "$(dirname "$PROJECT_DIR")")")"
CONFIG_FILE="${ROOT_DIR}/.vscode/sap_config.local.mg"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  SAP BTP AI Core Deployment Test${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# =============================================================================
# Parse Mangle config file for credentials
# =============================================================================

parse_mangle_fact() {
    local key="$1"
    local type="$2"
    # Match: type("key", "value").
    grep "^${type}(\"${key}\"" "$CONFIG_FILE" | head -1 | sed 's/.*"'"$key"'", "\([^"]*\)").*/\1/'
}

echo -e "${BLUE}[1/6] Reading credentials from Mangle config...${NC}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}Error: Config file not found: $CONFIG_FILE${NC}"
    exit 1
fi

# AI Core credentials
CLIENT_ID=$(parse_mangle_fact "client_id" "aicore_credential")
CLIENT_SECRET=$(parse_mangle_fact "client_secret" "aicore_credential")
AUTH_URL=$(parse_mangle_fact "auth_url" "aicore_credential")
BASE_URL=$(parse_mangle_fact "base_url" "aicore_credential")
RESOURCE_GROUP=$(parse_mangle_fact "resource_group" "aicore_credential")

# S3 credentials for model storage
S3_ACCESS_KEY=$(parse_mangle_fact "access_key_id" "s3_credential")
S3_SECRET_KEY=$(parse_mangle_fact "secret_access_key" "s3_credential")
S3_BUCKET=$(parse_mangle_fact "bucket" "s3_credential")
S3_REGION=$(parse_mangle_fact "region" "s3_credential")

echo -e "  AUTH_URL: ${AUTH_URL}"
echo -e "  BASE_URL: ${BASE_URL}"
echo -e "  RESOURCE_GROUP: ${RESOURCE_GROUP}"
echo -e "  S3_BUCKET: ${S3_BUCKET}"
echo ""

# =============================================================================
# Get OAuth Token
# =============================================================================

echo -e "${BLUE}[2/6] Getting OAuth token...${NC}"

TOKEN_RESPONSE=$(curl -s -X POST "${AUTH_URL}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials" \
    -d "client_id=${CLIENT_ID}" \
    -d "client_secret=${CLIENT_SECRET}")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')

if [ "$ACCESS_TOKEN" = "null" ] || [ -z "$ACCESS_TOKEN" ]; then
    echo -e "${RED}Failed to get access token${NC}"
    echo "$TOKEN_RESPONSE" | jq .
    exit 1
fi

echo -e "${GREEN}  ✓ Got access token (${#ACCESS_TOKEN} chars)${NC}"
echo ""

# =============================================================================
# Check AI Core Status and Resource Plans
# =============================================================================

echo -e "${BLUE}[3/6] Checking AI Core status and resource plans...${NC}"

# Get resource plans (includes GPU availability)
RESOURCE_PLANS=$(curl -s -X GET "${BASE_URL}/v2/lm/resourcePlans" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "AI-Resource-Group: ${RESOURCE_GROUP}")

echo -e "  Available resource plans:"
echo "$RESOURCE_PLANS" | jq -r '.resources[]? | "    - \(.id): \(.description // "no description")"' 2>/dev/null || echo "    (no plans returned)"

# Check if T4 is available
if echo "$RESOURCE_PLANS" | grep -q "gpu_nvidia_t4"; then
    echo -e "${GREEN}  ✓ T4 GPU is available${NC}"
    GPU_PLAN="gpu_nvidia_t4"
else
    echo -e "${YELLOW}  ⚠ T4 GPU not found, checking other options...${NC}"
    GPU_PLAN=$(echo "$RESOURCE_PLANS" | jq -r '.resources[]? | select(.id | contains("gpu")) | .id' | head -1)
    if [ -z "$GPU_PLAN" ]; then
        echo -e "${YELLOW}  Using CPU plan: infer.l${NC}"
        GPU_PLAN="infer.l"
    fi
fi
echo ""

# =============================================================================
# List Existing Scenarios and Executables
# =============================================================================

echo -e "${BLUE}[4/6] Checking existing scenarios...${NC}"

SCENARIOS=$(curl -s -X GET "${BASE_URL}/v2/lm/scenarios" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "AI-Resource-Group: ${RESOURCE_GROUP}")

echo -e "  Existing scenarios:"
echo "$SCENARIOS" | jq -r '.resources[]? | "    - \(.id): \(.name)"' 2>/dev/null || echo "    (no scenarios)"

# Check for our scenario
if echo "$SCENARIOS" | jq -e '.resources[]? | select(.id == "ainuc-llm-inference")' > /dev/null 2>&1; then
    echo -e "${GREEN}  ✓ ainuc-llm-inference scenario exists${NC}"
    SCENARIO_EXISTS=true
else
    echo -e "${YELLOW}  → ainuc-llm-inference scenario needs to be created${NC}"
    SCENARIO_EXISTS=false
fi
echo ""

# =============================================================================
# List Docker Registries and Artifacts
# =============================================================================

echo -e "${BLUE}[5/6] Checking Docker registries and artifacts...${NC}"

# Check Docker registry secrets
DOCKER_SECRETS=$(curl -s -X GET "${BASE_URL}/v2/admin/dockerRegistrySecrets" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "AI-Resource-Group: ${RESOURCE_GROUP}")

echo -e "  Docker registry secrets:"
echo "$DOCKER_SECRETS" | jq -r '.resources[]? | "    - \(.name)"' 2>/dev/null || echo "    (no secrets configured)"

# Check existing artifacts
ARTIFACTS=$(curl -s -X GET "${BASE_URL}/v2/lm/artifacts" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "AI-Resource-Group: ${RESOURCE_GROUP}")

echo -e "  Existing artifacts:"
echo "$ARTIFACTS" | jq -r '.resources[]? | "    - \(.name): \(.kind) (\(.scenarioId // "no scenario"))"' 2>/dev/null | head -10 || echo "    (no artifacts)"
echo ""

# =============================================================================
# List Existing Deployments
# =============================================================================

echo -e "${BLUE}[6/6] Checking existing deployments...${NC}"

DEPLOYMENTS=$(curl -s -X GET "${BASE_URL}/v2/lm/deployments" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "AI-Resource-Group: ${RESOURCE_GROUP}")

echo -e "  Existing deployments:"
echo "$DEPLOYMENTS" | jq -r '.resources[]? | "    - \(.id): \(.status) (\(.configurationName // "unnamed"))"' 2>/dev/null || echo "    (no deployments)"
echo ""

# =============================================================================
# Summary and Next Steps
# =============================================================================

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  Summary${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo -e "AI Core Connection: ${GREEN}✓ Connected${NC}"
echo -e "Resource Plan: ${GPU_PLAN}"
echo -e "Scenario Exists: $([ "$SCENARIO_EXISTS" = true ] && echo "${GREEN}✓${NC}" || echo "${YELLOW}No${NC}")"
echo ""

if [ "$SCENARIO_EXISTS" = false ]; then
    echo -e "${YELLOW}Next Steps:${NC}"
    echo -e "  1. Create scenario 'ainuc-llm-inference' via AI Launchpad or API"
    echo -e "  2. Upload Docker image to AI Core registry"
    echo -e "  3. Upload models to S3 bucket: ${S3_BUCKET}"
    echo -e "  4. Register model artifacts"
    echo -e "  5. Create serving template"
    echo -e "  6. Create deployment"
    echo ""
    echo -e "To create scenario via API, run:"
    echo -e "${BLUE}./scripts/create_aicore_scenario.sh${NC}"
else
    echo -e "${GREEN}Ready to deploy!${NC}"
    echo -e "  Run: ${BLUE}./scripts/deploy_to_aicore.sh${NC}"
fi
echo ""

# Export variables for other scripts
cat > "${PROJECT_DIR}/deploy/aicore/.env.aicore" << EOF
# Generated by test_aicore_deployment.sh
# $(date -u +"%Y-%m-%dT%H:%M:%SZ")
AICORE_BASE_URL=${BASE_URL}
AICORE_RESOURCE_GROUP=${RESOURCE_GROUP}
AICORE_GPU_PLAN=${GPU_PLAN}
S3_BUCKET=${S3_BUCKET}
S3_REGION=${S3_REGION}
EOF

echo -e "Environment saved to: ${PROJECT_DIR}/deploy/aicore/.env.aicore"