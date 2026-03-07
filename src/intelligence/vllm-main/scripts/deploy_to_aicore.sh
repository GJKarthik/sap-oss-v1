#!/bin/bash
# Deploy LLM to SAP AI Core
# Creates deployment from existing configuration

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

# Configuration ID from previous script
CONFIG_ID="${1:-83c408c7-95fa-4757-bb2f-9ce6015cde07}"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}  Deploy to SAP BTP AI Core${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo "Configuration ID: ${CONFIG_ID}"
echo ""

# Get OAuth Token
echo -e "${BLUE}[1/4] Getting OAuth token...${NC}"

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

# Verify configuration exists
echo -e "${BLUE}[2/4] Verifying configuration...${NC}"

CONFIG_CHECK=$(curl -s -X GET "${BASE_URL}/v2/lm/configurations/${CONFIG_ID}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "AI-Resource-Group: ${RESOURCE_GROUP}")

CONFIG_NAME=$(echo "$CONFIG_CHECK" | jq -r '.name')
SCENARIO_ID=$(echo "$CONFIG_CHECK" | jq -r '.scenarioId')
EXEC_ID=$(echo "$CONFIG_CHECK" | jq -r '.executableId')

if [ "$CONFIG_NAME" = "null" ] || [ -z "$CONFIG_NAME" ]; then
    echo -e "${RED}Configuration not found: ${CONFIG_ID}${NC}"
    echo "$CONFIG_CHECK" | jq .
    exit 1
fi

echo -e "  Config Name: ${CONFIG_NAME}"
echo -e "  Scenario: ${SCENARIO_ID}"
echo -e "  Executable: ${EXEC_ID}"
echo -e "${GREEN}  ✓ Configuration verified${NC}"
echo ""

# Create deployment
echo -e "${BLUE}[3/4] Creating deployment...${NC}"

DEPLOYMENT_REQUEST=$(cat << EOF
{
    "configurationId": "${CONFIG_ID}"
}
EOF
)

echo "  Request:"
echo "$DEPLOYMENT_REQUEST" | jq .

DEPLOYMENT_RESPONSE=$(curl -s -X POST "${BASE_URL}/v2/lm/deployments" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "AI-Resource-Group: ${RESOURCE_GROUP}" \
    -H "Content-Type: application/json" \
    -d "$DEPLOYMENT_REQUEST")

echo "  Response:"
echo "$DEPLOYMENT_RESPONSE" | jq .

DEPLOYMENT_ID=$(echo "$DEPLOYMENT_RESPONSE" | jq -r '.id')
DEPLOYMENT_STATUS=$(echo "$DEPLOYMENT_RESPONSE" | jq -r '.status')

if [ "$DEPLOYMENT_ID" = "null" ] || [ -z "$DEPLOYMENT_ID" ]; then
    echo -e "${RED}Failed to create deployment${NC}"
    exit 1
fi

echo -e "${GREEN}  ✓ Deployment created: ${DEPLOYMENT_ID}${NC}"
echo ""

# Monitor deployment status
echo -e "${BLUE}[4/4] Monitoring deployment status...${NC}"
echo ""

for i in {1..30}; do
    STATUS_CHECK=$(curl -s -X GET "${BASE_URL}/v2/lm/deployments/${DEPLOYMENT_ID}" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "AI-Resource-Group: ${RESOURCE_GROUP}")
    
    CURRENT_STATUS=$(echo "$STATUS_CHECK" | jq -r '.status')
    DEPLOYMENT_URL=$(echo "$STATUS_CHECK" | jq -r '.deploymentUrl')
    
    echo -e "  [${i}/30] Status: ${CURRENT_STATUS}"
    
    if [ "$CURRENT_STATUS" = "RUNNING" ]; then
        echo ""
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}  Deployment Running!${NC}"
        echo -e "${GREEN}========================================${NC}"
        echo ""
        echo -e "Deployment ID: ${DEPLOYMENT_ID}"
        echo -e "Status: ${CURRENT_STATUS}"
        echo -e "URL: ${DEPLOYMENT_URL}"
        echo ""
        echo -e "To test the deployment:"
        echo -e "${BLUE}curl -X POST '${DEPLOYMENT_URL}/v1/chat/completions' \\${NC}"
        echo -e "${BLUE}  -H 'Authorization: Bearer \${ACCESS_TOKEN}' \\${NC}"
        echo -e "${BLUE}  -H 'AI-Resource-Group: ${RESOURCE_GROUP}' \\${NC}"
        echo -e "${BLUE}  -H 'Content-Type: application/json' \\${NC}"
        echo -e "${BLUE}  -d '{\"model\": \"mistral\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'${NC}"
        break
    elif [ "$CURRENT_STATUS" = "DEAD" ] || [ "$CURRENT_STATUS" = "FAILED" ]; then
        echo ""
        echo -e "${RED}Deployment failed: ${CURRENT_STATUS}${NC}"
        echo "$STATUS_CHECK" | jq '.details'
        exit 1
    fi
    
    sleep 10
done

if [ "$CURRENT_STATUS" != "RUNNING" ]; then
    echo ""
    echo -e "${YELLOW}Deployment not yet running after 5 minutes.${NC}"
    echo -e "Current status: ${CURRENT_STATUS}"
    echo -e "Check AI Launchpad for details."
fi