#!/usr/bin/env bash
# ============================================================================
# SAP AI Fabric - SAP AI Core Deployment Script
# ============================================================================
# Builds, pushes, and deploys services to SAP AI Core
# Usage: ./aicore-deploy.sh [build|push|register|deploy|all] [--service SERVICE]
# ============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$DEPLOY_DIR")"

# Source environment
if [[ -f "$DEPLOY_DIR/.env" ]]; then
    set -a
    source "$DEPLOY_DIR/.env"
    set +a
fi

# ============================================================================
# Configuration
# ============================================================================

REGISTRY="${DOCKER_REGISTRY:-ghcr.io/sap-ai-fabric}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# Service definitions: name -> (context, dockerfile, ai_core_scenario)
declare -A SERVICE_CONTEXTS=(
    ["odata-vocabularies-mcp"]="../src/data/odata-vocabularies-main"
    ["langchain-hana-mcp"]="../src/data/langchain-integration-for-sap-hana-cloud-main"
    ["vllm"]="../src/intelligence/vllm-turboquant"
    ["ai-core-pal"]="../src/intelligence/ai-core-pal"
    ["genai-toolkit"]="../src/data/langchain-integration-for-sap-hana-cloud-main"
    ["modelopt-api"]="../src/training/nvidia-modelopt"
)

declare -A SERVICE_DOCKERFILES=(
    ["odata-vocabularies-mcp"]="Dockerfile"
    ["langchain-hana-mcp"]="Dockerfile"
    ["vllm"]="Dockerfile.vllm-l40s-turboquant"
    ["ai-core-pal"]="Dockerfile"
    ["genai-toolkit"]="Dockerfile"
    ["modelopt-api"]="Dockerfile"
)

declare -A SERVICE_SCENARIOS=(
    ["vllm"]="vllm-inference"
    ["ai-core-pal"]="mesh-gateway"
    ["genai-toolkit"]="genai-toolkit"
)

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${CYAN}==>${NC} $1"
}

print_banner() {
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║           SAP AI Fabric - AI Core Deployment                      ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_usage() {
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  build       Build Docker images"
    echo "  push        Push images to registry"
    echo "  register    Register scenarios with AI Core"
    echo "  deploy      Create/update deployments"
    echo "  status      Check deployment status"
    echo "  all         Run build, push, register, and deploy"
    echo ""
    echo "Options:"
    echo "  --service SERVICE   Only process specific service"
    echo "  --tag TAG           Image tag (default: latest)"
    echo "  --registry REG      Docker registry (default: from .env)"
    echo "  --dry-run           Show commands without executing"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 build --service vllm"
    echo "  $0 all --tag v1.0.0"
    echo "  $0 deploy --service ai-core-pal"
}

check_prerequisites() {
    log_step "Checking prerequisites..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        exit 1
    fi
    
    # Check AI Core credentials
    if [[ -z "${AICORE_CLIENT_ID:-}" ]] || [[ -z "${AICORE_CLIENT_SECRET:-}" ]]; then
        log_error "AI Core credentials not configured"
        log_error "Set AICORE_CLIENT_ID and AICORE_CLIENT_SECRET in .env"
        exit 1
    fi
    
    if [[ -z "${AICORE_AUTH_URL:-}" ]] || [[ -z "${AICORE_BASE_URL:-}" ]]; then
        log_error "AI Core URLs not configured"
        log_error "Set AICORE_AUTH_URL and AICORE_BASE_URL in .env"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

get_aicore_token() {
    log_step "Getting AI Core access token..."
    
    local response
    response=$(curl -sf -X POST "${AICORE_AUTH_URL}" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials" \
        -d "client_id=${AICORE_CLIENT_ID}" \
        -d "client_secret=${AICORE_CLIENT_SECRET}" 2>/dev/null)
    
    if [[ -z "$response" ]]; then
        log_error "Failed to get AI Core token"
        exit 1
    fi
    
    AICORE_TOKEN=$(echo "$response" | jq -r '.access_token')
    
    if [[ -z "$AICORE_TOKEN" ]] || [[ "$AICORE_TOKEN" == "null" ]]; then
        log_error "Invalid token response"
        exit 1
    fi
    
    log_success "Token obtained"
}

# ============================================================================
# Build Functions
# ============================================================================

build_image() {
    local service=$1
    local context="${SERVICE_CONTEXTS[$service]}"
    local dockerfile="${SERVICE_DOCKERFILES[$service]}"
    local image="${REGISTRY}/${service}:${IMAGE_TAG}"
    
    log_step "Building $service..."
    log_info "Context: $context"
    log_info "Dockerfile: $dockerfile"
    log_info "Image: $image"
    
    cd "$PROJECT_ROOT"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "docker build -t $image -f $context/$dockerfile $context"
    else
        docker build \
            -t "$image" \
            -f "$context/$dockerfile" \
            --label "sap.ai.service=$service" \
            --label "sap.ai.version=$IMAGE_TAG" \
            "$context"
        
        log_success "Built $image"
    fi
}

build_all() {
    log_info "Building all services..."
    
    for service in "${!SERVICE_CONTEXTS[@]}"; do
        if [[ -n "$TARGET_SERVICE" ]] && [[ "$TARGET_SERVICE" != "$service" ]]; then
            continue
        fi
        
        echo ""
        build_image "$service"
    done
    
    log_success "All builds complete"
}

# ============================================================================
# Push Functions
# ============================================================================

push_image() {
    local service=$1
    local image="${REGISTRY}/${service}:${IMAGE_TAG}"
    
    log_step "Pushing $service..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "docker push $image"
    else
        docker push "$image"
        log_success "Pushed $image"
    fi
}

push_all() {
    log_info "Pushing all images..."
    
    # Login to registry if credentials provided
    if [[ -n "${DOCKER_REGISTRY_USERNAME:-}" ]] && [[ -n "${DOCKER_REGISTRY_PASSWORD:-}" ]]; then
        log_step "Logging into registry..."
        echo "${DOCKER_REGISTRY_PASSWORD}" | docker login "${REGISTRY%%/*}" -u "${DOCKER_REGISTRY_USERNAME}" --password-stdin
    fi
    
    for service in "${!SERVICE_CONTEXTS[@]}"; do
        if [[ -n "$TARGET_SERVICE" ]] && [[ "$TARGET_SERVICE" != "$service" ]]; then
            continue
        fi
        
        echo ""
        push_image "$service"
    done
    
    log_success "All pushes complete"
}

# ============================================================================
# AI Core Registration Functions
# ============================================================================

register_scenario() {
    local service=$1
    local scenario="${SERVICE_SCENARIOS[$service]:-}"
    
    if [[ -z "$scenario" ]]; then
        log_info "No AI Core scenario defined for $service, skipping"
        return 0
    fi
    
    log_step "Registering scenario for $service..."
    
    # Check if scenario config exists
    local config_file="$PROJECT_ROOT/${SERVICE_CONTEXTS[$service]}/deploy/aicore/scenario.json"
    
    if [[ ! -f "$config_file" ]]; then
        # Create default scenario config
        config_file=$(create_default_scenario "$service" "$scenario")
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "curl -X POST ${AICORE_BASE_URL}/v2/lm/scenarios -d @$config_file"
    else
        local response
        response=$(curl -sf -X POST "${AICORE_BASE_URL}/v2/lm/scenarios" \
            -H "Authorization: Bearer ${AICORE_TOKEN}" \
            -H "Content-Type: application/json" \
            -H "AI-Resource-Group: ${AICORE_RESOURCE_GROUP:-default}" \
            -d @"$config_file" 2>/dev/null) || {
            log_warning "Scenario may already exist, trying to update..."
            response=$(curl -sf -X PATCH "${AICORE_BASE_URL}/v2/lm/scenarios/${scenario}" \
                -H "Authorization: Bearer ${AICORE_TOKEN}" \
                -H "Content-Type: application/json" \
                -H "AI-Resource-Group: ${AICORE_RESOURCE_GROUP:-default}" \
                -d @"$config_file" 2>/dev/null) || true
        }
        
        log_success "Scenario registered for $service"
    fi
}

create_default_scenario() {
    local service=$1
    local scenario=$2
    local temp_file="/tmp/scenario-${service}.json"
    
    cat > "$temp_file" << EOF
{
    "name": "${scenario}",
    "description": "SAP AI Fabric - ${service}",
    "labels": [
        {"key": "sap.ai.service", "value": "${service}"},
        {"key": "sap.ai.fabric", "value": "true"}
    ]
}
EOF
    
    echo "$temp_file"
}

register_all_scenarios() {
    log_info "Registering AI Core scenarios..."
    
    get_aicore_token
    
    for service in "${!SERVICE_SCENARIOS[@]}"; do
        if [[ -n "$TARGET_SERVICE" ]] && [[ "$TARGET_SERVICE" != "$service" ]]; then
            continue
        fi
        
        echo ""
        register_scenario "$service"
    done
    
    log_success "Scenario registration complete"
}

# ============================================================================
# Deployment Functions
# ============================================================================

create_configuration() {
    local service=$1
    local scenario="${SERVICE_SCENARIOS[$service]:-}"
    local image="${REGISTRY}/${service}:${IMAGE_TAG}"
    
    if [[ -z "$scenario" ]]; then
        return 0
    fi
    
    log_step "Creating configuration for $service..."
    
    local config_name="${service}-config-${IMAGE_TAG//\./-}"
    
    # Check for existing config file
    local config_file="$PROJECT_ROOT/${SERVICE_CONTEXTS[$service]}/deploy/aicore/configuration.json"
    
    if [[ ! -f "$config_file" ]]; then
        config_file=$(create_default_configuration "$service" "$scenario" "$image" "$config_name")
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "curl -X POST ${AICORE_BASE_URL}/v2/lm/configurations -d @$config_file"
    else
        local response
        response=$(curl -sf -X POST "${AICORE_BASE_URL}/v2/lm/configurations" \
            -H "Authorization: Bearer ${AICORE_TOKEN}" \
            -H "Content-Type: application/json" \
            -H "AI-Resource-Group: ${AICORE_RESOURCE_GROUP:-default}" \
            -d @"$config_file" 2>/dev/null) || {
            log_warning "Configuration may already exist"
        }
        
        # Extract configuration ID
        CONFIG_ID=$(echo "$response" | jq -r '.id // empty')
        
        if [[ -n "$CONFIG_ID" ]]; then
            log_success "Configuration created: $CONFIG_ID"
        fi
    fi
}

create_default_configuration() {
    local service=$1
    local scenario=$2
    local image=$3
    local config_name=$4
    local temp_file="/tmp/config-${service}.json"
    
    cat > "$temp_file" << EOF
{
    "name": "${config_name}",
    "scenarioId": "${scenario}",
    "executableId": "${service}",
    "parameterBindings": [],
    "inputArtifactBindings": []
}
EOF
    
    echo "$temp_file"
}

create_deployment() {
    local service=$1
    local scenario="${SERVICE_SCENARIOS[$service]:-}"
    
    if [[ -z "$scenario" ]]; then
        log_info "No AI Core scenario for $service, skipping deployment"
        return 0
    fi
    
    log_step "Creating deployment for $service..."
    
    # First create configuration
    create_configuration "$service"
    
    if [[ -z "${CONFIG_ID:-}" ]]; then
        log_warning "No configuration ID, looking up existing..."
        # Try to find existing configuration
        local configs
        configs=$(curl -sf "${AICORE_BASE_URL}/v2/lm/configurations" \
            -H "Authorization: Bearer ${AICORE_TOKEN}" \
            -H "AI-Resource-Group: ${AICORE_RESOURCE_GROUP:-default}" 2>/dev/null)
        
        CONFIG_ID=$(echo "$configs" | jq -r ".resources[] | select(.scenarioId==\"$scenario\") | .id" | head -1)
    fi
    
    if [[ -z "${CONFIG_ID:-}" ]]; then
        log_error "Could not find or create configuration for $service"
        return 1
    fi
    
    local deploy_file="/tmp/deploy-${service}.json"
    cat > "$deploy_file" << EOF
{
    "configurationId": "${CONFIG_ID}"
}
EOF
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "curl -X POST ${AICORE_BASE_URL}/v2/lm/deployments -d @$deploy_file"
    else
        local response
        response=$(curl -sf -X POST "${AICORE_BASE_URL}/v2/lm/deployments" \
            -H "Authorization: Bearer ${AICORE_TOKEN}" \
            -H "Content-Type: application/json" \
            -H "AI-Resource-Group: ${AICORE_RESOURCE_GROUP:-default}" \
            -d @"$deploy_file" 2>/dev/null)
        
        local deploy_id
        deploy_id=$(echo "$response" | jq -r '.id // empty')
        
        if [[ -n "$deploy_id" ]]; then
            log_success "Deployment created: $deploy_id"
            echo "$deploy_id" >> "$DEPLOY_DIR/.deployments"
        else
            log_warning "Deployment may have failed or already exists"
            echo "$response" | jq . 2>/dev/null || echo "$response"
        fi
    fi
}

deploy_all() {
    log_info "Deploying to AI Core..."
    
    get_aicore_token
    
    for service in "${!SERVICE_SCENARIOS[@]}"; do
        if [[ -n "$TARGET_SERVICE" ]] && [[ "$TARGET_SERVICE" != "$service" ]]; then
            continue
        fi
        
        echo ""
        create_deployment "$service"
    done
    
    log_success "Deployment complete"
}

# ============================================================================
# Status Functions
# ============================================================================

check_status() {
    log_info "Checking AI Core deployment status..."
    
    get_aicore_token
    
    log_step "Fetching deployments..."
    
    local response
    response=$(curl -sf "${AICORE_BASE_URL}/v2/lm/deployments" \
        -H "Authorization: Bearer ${AICORE_TOKEN}" \
        -H "AI-Resource-Group: ${AICORE_RESOURCE_GROUP:-default}" 2>/dev/null)
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  AI Core Deployments${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    echo "$response" | jq -r '.resources[] | "\(.id)\t\(.scenarioId)\t\(.status)\t\(.deploymentUrl // "N/A")"' 2>/dev/null | \
        while IFS=$'\t' read -r id scenario status url; do
            case "$status" in
                RUNNING)
                    echo -e "${GREEN}●${NC} $scenario ($id)"
                    echo "  URL: $url"
                    ;;
                PENDING|STARTING)
                    echo -e "${YELLOW}●${NC} $scenario ($id) - $status"
                    ;;
                *)
                    echo -e "${RED}●${NC} $scenario ($id) - $status"
                    ;;
            esac
        done
    
    echo ""
}

# ============================================================================
# Main
# ============================================================================

main() {
    print_banner
    
    # Default values
    COMMAND=""
    TARGET_SERVICE=""
    DRY_RUN=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            build|push|register|deploy|status|all)
                COMMAND=$1
                shift
                ;;
            --service)
                TARGET_SERVICE=$2
                shift 2
                ;;
            --tag)
                IMAGE_TAG=$2
                shift 2
                ;;
            --registry)
                REGISTRY=$2
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
    
    if [[ -z "$COMMAND" ]]; then
        log_error "No command specified"
        print_usage
        exit 1
    fi
    
    # Validate target service if specified
    if [[ -n "$TARGET_SERVICE" ]] && [[ ! -v "SERVICE_CONTEXTS[$TARGET_SERVICE]" ]]; then
        log_error "Unknown service: $TARGET_SERVICE"
        log_info "Available services: ${!SERVICE_CONTEXTS[*]}"
        exit 1
    fi
    
    check_prerequisites
    
    # Execute command
    case $COMMAND in
        build)
            build_all
            ;;
        push)
            push_all
            ;;
        register)
            register_all_scenarios
            ;;
        deploy)
            deploy_all
            ;;
        status)
            check_status
            ;;
        all)
            build_all
            echo ""
            push_all
            echo ""
            register_all_scenarios
            echo ""
            deploy_all
            echo ""
            check_status
            ;;
    esac
}

main "$@"
