#!/bin/bash
# Create AI Core Scenario and Deploy LLM Server
# Uses credentials from .vscode/sap_config.local.mg
#
# This script:
# 1. Creates the ainuc-llm-inference scenario
# 2. Registers the serving template
# 3. Creates configuration
# 4. Triggers deployment

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

# Parse Mangle config
parse_mangle_fact() {
    local key="$1"
    local type="$2"
    grep "^${type}(\"${key}\"" "$CONFIG_FILE" | head -1 | sed 's/.*"'"$key"'", "\([^"]*\)").*/\1/'
}

# Load credentials
CLIENT_ID=$(parse_mangle_fact "client_id" "aicore_credential")
CLIENT_SECRET=$(parse_mangle_fact "client_secret" "aicore_credential")
AUTH_URL=$(parse_mangle_fact "auth_url" "aicore_credential")
BASE_URL=$(parse_mangle_fact "base_url" "aicore_credential")
RESOURCE_GROUP=$(parse_mangle_fact "resource_group" "aicore_credential")

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  AI Core Scenario & Deployment Setup${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# =============================================================================
# Get OAuth Token
# =============================================================================

echo -e "${BLUE}[1/7] Getting OAuth token...${NC}"

TOKEN_RESPONSE=$(curl -s -X POST "${AUTH_URL}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials" \
    -d "client_id=${CLIENT_ID}" \
    -d "client_secret=${CLIENT_SECRET}")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')

if [ "$ACCESS_TOKEN" = "null" ] || [ -z "$ACCESS_TOKEN" ]; then
    echo -e "${RED}Failed to get access token${NC}"
    exit 1
fi
echo -e "${GREEN}  ✓ Got access token${NC}"
echo ""

# =============================================================================
# Get Docker Registry Info
# =============================================================================

echo -e "${BLUE}[2/7] Checking Docker registry configuration...${NC}"

DOCKER_SECRETS=$(curl -s -X GET "${BASE_URL}/v2/admin/dockerRegistrySecrets" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "AI-Resource-Group: ${RESOURCE_GROUP}")

echo -e "  Docker registry secrets:"
echo "$DOCKER_SECRETS" | jq -r '.resources[]? | "    - \(.name): \(.data.server // "no server")"' 2>/dev/null || echo "    (none)"

# Get first available registry
DOCKER_REGISTRY=$(echo "$DOCKER_SECRETS" | jq -r '.resources[0]?.name' 2>/dev/null)
if [ -z "$DOCKER_REGISTRY" ] || [ "$DOCKER_REGISTRY" = "null" ]; then
    echo -e "${YELLOW}  ⚠ No Docker registry configured${NC}"
    echo -e "${YELLOW}    Will need to create one for the Docker image${NC}"
else
    echo -e "${GREEN}  ✓ Using registry: ${DOCKER_REGISTRY}${NC}"
fi
echo ""

# =============================================================================
# Check/Get Existing Scenario Details
# =============================================================================

echo -e "${BLUE}[3/7] Examining existing vllm scenario for reference...${NC}"

# Get details of an existing working deployment
DEPLOYMENT_DETAILS=$(curl -s -X GET "${BASE_URL}/v2/lm/deployments" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "AI-Resource-Group: ${RESOURCE_GROUP}")

echo -e "  Existing deployments:"
echo "$DEPLOYMENT_DETAILS" | jq -r '.resources[]? | "    - \(.id): \(.scenarioId) / \(.executableId) / \(.status)"' 2>/dev/null | head -5

# Get a running deployment's configuration
RUNNING_DEPLOYMENT_ID=$(echo "$DEPLOYMENT_DETAILS" | jq -r '.resources[] | select(.status == "RUNNING") | .id' | head -1)

if [ -n "$RUNNING_DEPLOYMENT_ID" ] && [ "$RUNNING_DEPLOYMENT_ID" != "null" ]; then
    echo -e "  Getting config from deployment: ${RUNNING_DEPLOYMENT_ID}"
    
    CONFIG_ID=$(echo "$DEPLOYMENT_DETAILS" | jq -r ".resources[] | select(.id == \"$RUNNING_DEPLOYMENT_ID\") | .configurationId")
    
    if [ -n "$CONFIG_ID" ] && [ "$CONFIG_ID" != "null" ]; then
        CONFIG_DETAILS=$(curl -s -X GET "${BASE_URL}/v2/lm/configurations/${CONFIG_ID}" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "AI-Resource-Group: ${RESOURCE_GROUP}")
        
        echo -e "  Configuration details:"
        echo "$CONFIG_DETAILS" | jq '{name, scenarioId, executableId, parameterBindings: [.parameterBindings[]? | {key, value}]}' 2>/dev/null || echo "    (could not parse)"
    fi
fi
echo ""

# =============================================================================
# Check Executables (Serving Templates)
# =============================================================================

echo -e "${BLUE}[4/7] Checking executables (serving templates)...${NC}"

EXECUTABLES=$(curl -s -X GET "${BASE_URL}/v2/lm/scenarios/vllm/executables" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "AI-Resource-Group: ${RESOURCE_GROUP}" 2>/dev/null)

echo -e "  vllm executables:"
echo "$EXECUTABLES" | jq -r '.resources[]? | "    - \(.id): \(.description // "no desc")"' 2>/dev/null || echo "    (none or error)"
echo ""

# =============================================================================
# Create ainuc-llm-inference Scenario
# =============================================================================

echo -e "${BLUE}[5/7] Creating ainuc-llm-inference scenario...${NC}"

# Note: Scenarios are typically created via Git sync or AI Launchpad
# The API method is to onboard a Git repository with the serving template

# Check if scenario exists first
SCENARIO_CHECK=$(curl -s -X GET "${BASE_URL}/v2/lm/scenarios/ainuc-llm-inference" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "AI-Resource-Group: ${RESOURCE_GROUP}")

if echo "$SCENARIO_CHECK" | jq -e '.id' > /dev/null 2>&1; then
    echo -e "${GREEN}  ✓ Scenario already exists${NC}"
else
    echo -e "${YELLOW}  Scenario not found - needs Git onboarding${NC}"
    echo ""
    echo -e "  ${YELLOW}AI Core scenarios are created via Git repository sync.${NC}"
    echo -e "  ${YELLOW}You need to:${NC}"
    echo -e "    1. Push serving-template.yaml to a Git repo"
    echo -e "    2. Onboard the repo in AI Launchpad"
    echo -e "    3. The scenario/executable will be auto-created"
    echo ""
    echo -e "  Alternative: Use existing 'vllm' scenario with compatible config"
fi
echo ""

# =============================================================================
# Create Configuration for Deployment
# =============================================================================

echo -e "${BLUE}[6/7] Creating deployment configuration...${NC}"

# Use existing vllm scenario as base (since it's already set up)
SCENARIO_ID="vllm"
EXECUTABLE_ID="vllm"

# Check if we already have a llama.cpp config
EXISTING_CONFIGS=$(curl -s -X GET "${BASE_URL}/v2/lm/configurations" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "AI-Resource-Group: ${RESOURCE_GROUP}")

AINUC_CONFIG=$(echo "$EXISTING_CONFIGS" | jq -r '.resources[]? | select(.name | contains("ainuc")) | .id')

if [ -n "$AINUC_CONFIG" ] && [ "$AINUC_CONFIG" != "null" ]; then
    echo -e "${GREEN}  ✓ Found existing ainuc config: ${AINUC_CONFIG}${NC}"
else
    echo -e "  Creating new configuration..."
    
    # Create configuration based on Mangle rules
    CONFIG_JSON=$(cat << 'EOF'
{
    "name": "ainuc-llm-mistral-config",
    "scenarioId": "vllm",
    "executableId": "vllm",
    "parameterBindings": [
        {"key": "model", "value": "mistralai/Mistral-7B-Instruct-v0.2"},
        {"key": "maxModelLen", "value": "4096"},
        {"key": "tensorParallelSize", "value": "1"}
    ]
}
EOF
)

    echo "  Config to create:"
    echo "$CONFIG_JSON" | jq .
    
    CREATE_RESPONSE=$(curl -s -X POST "${BASE_URL}/v2/lm/configurations" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "AI-Resource-Group: ${RESOURCE_GROUP}" \
        -H "Content-Type: application/json" \
        -d "$CONFIG_JSON")
    
    echo "  Response:"
    echo "$CREATE_RESPONSE" | jq . 2>/dev/null || echo "$CREATE_RESPONSE"
    
    CONFIG_ID=$(echo "$CREATE_RESPONSE" | jq -r '.id')
fi
echo ""

# =============================================================================
# Summary
# =============================================================================

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  Summary${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo -e "BASE_URL: ${BASE_URL}"
echo -e "RESOURCE_GROUP: ${RESOURCE_GROUP}"
echo -e "Docker Registry: ${DOCKER_REGISTRY:-'needs setup'}"
echo ""
echo -e "${YELLOW}Key Findings:${NC}"
echo -e "  - vllm-poc-artifactory is a Docker registry secret"
echo -e "  - It contains credentials for pushing Docker images"
echo -e "  - Existing vLLM deployments use the 'vllm' scenario"
echo ""
echo -e "${YELLOW}To deploy llama.cpp/GGUF models, you can either:${NC}"
echo -e "  1. Use existing vllm scenario (if compatible)"
echo -e "  2. Create new scenario via Git onboarding"
echo ""
echo -e "Run: ${BLUE}./scripts/test_aicore_deployment.sh${NC} to check status"