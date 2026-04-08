#!/usr/bin/env bash
# ============================================================================
# SAP AI Fabric - Deployment Script
# ============================================================================
# Deploys services in tiered order with dependency checks
# Usage: ./deploy.sh [tier0|tier1|tier2|tier3|all] [--build] [--no-cache]
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

# Default values
BUILD_FLAG=""
NO_CACHE_FLAG=""
DETACH="-d"

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
    echo "║           SAP AI Fabric - Deployment Orchestrator                 ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_usage() {
    echo "Usage: $0 [TIER] [OPTIONS]"
    echo ""
    echo "Tiers:"
    echo "  tier0     Deploy infrastructure (Redis, Gateway)"
    echo "  tier1     Deploy MCP servers (OData, LangChain HANA MCP)"
    echo "  tier2     Deploy intelligence layer (vLLM, AI-Core-PAL, GenAI Toolkit)"
    echo "  tier3     Deploy training services (ModelOpt)"
    echo "  all       Deploy all tiers in order"
    echo ""
    echo "Options:"
    echo "  --build       Build images before starting"
    echo "  --no-cache    Build without cache (implies --build)"
    echo "  --foreground  Run in foreground (no detach)"
    echo "  -h, --help    Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 tier0              # Deploy infrastructure only"
    echo "  $0 all --build        # Build and deploy everything"
    echo "  $0 tier2 --no-cache   # Rebuild tier2 from scratch"
}

# ============================================================================
# Pre-flight Checks
# ============================================================================

check_prerequisites() {
    log_step "Checking prerequisites..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        log_error "Docker is not installed"
        exit 1
    fi
    
    # Check Docker Compose
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        log_error "Docker Compose is not installed"
        exit 1
    fi
    
    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        log_error "Docker daemon is not running"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

check_env_file() {
    log_step "Checking environment configuration..."
    
    if [[ ! -f "$DEPLOY_DIR/.env" ]]; then
        if [[ -f "$DEPLOY_DIR/.env.example" ]]; then
            log_warning ".env file not found, copying from .env.example"
            cp "$DEPLOY_DIR/.env.example" "$DEPLOY_DIR/.env"
            log_warning "Please edit $DEPLOY_DIR/.env with your configuration"
        else
            log_error "Neither .env nor .env.example found in $DEPLOY_DIR"
            exit 1
        fi
    fi
    
    # Source environment variables
    set -a
    source "$DEPLOY_DIR/.env"
    set +a
    
    log_success "Environment configuration loaded"
}

create_volumes() {
    log_step "Creating volume directories..."
    
    mkdir -p "$DEPLOY_DIR/volumes/redis-data"
    mkdir -p "$DEPLOY_DIR/volumes/model-cache"
    mkdir -p "$DEPLOY_DIR/volumes/modelopt-outputs"
    
    log_success "Volume directories created"
}

create_network() {
    log_step "Creating Docker network..."
    
    NETWORK_NAME="${NETWORK_NAME:-sap-ai-fabric-network}"
    
    if ! docker network inspect "$NETWORK_NAME" &> /dev/null; then
        docker network create "$NETWORK_NAME"
        log_success "Network '$NETWORK_NAME' created"
    else
        log_info "Network '$NETWORK_NAME' already exists"
    fi
}

# ============================================================================
# Deployment Functions
# ============================================================================

wait_for_healthy() {
    local service=$1
    local url=$2
    local max_attempts=${3:-30}
    local attempt=1
    
    log_info "Waiting for $service to be healthy..."
    
    while [[ $attempt -le $max_attempts ]]; do
        if curl -sf "$url" &> /dev/null; then
            log_success "$service is healthy"
            return 0
        fi
        
        echo -n "."
        sleep 2
        ((attempt++))
    done
    
    echo ""
    log_error "$service health check failed after $max_attempts attempts"
    return 1
}

deploy_compose() {
    local compose_file=$1
    local tier_name=$2
    
    log_step "Deploying $tier_name..."
    
    cd "$DEPLOY_DIR"
    
    # Use docker compose (v2) if available, otherwise docker-compose
    if docker compose version &> /dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    else
        COMPOSE_CMD="docker-compose"
    fi
    
    local cmd="$COMPOSE_CMD -f $compose_file --env-file .env up $DETACH $BUILD_FLAG $NO_CACHE_FLAG"
    
    log_info "Running: $cmd"
    eval "$cmd"
    
    log_success "$tier_name deployment initiated"
}

deploy_tier0() {
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "TIER 0: Infrastructure Services"
    log_info "═══════════════════════════════════════════════════════════════"
    
    deploy_compose "docker-compose.tier0.yml" "Tier 0 (Infrastructure)"
    
    # Wait for Redis
    wait_for_healthy "Redis" "http://localhost:${REDIS_PORT:-6379}" 10 || {
        # Redis doesn't have HTTP endpoint, check with redis-cli
        if docker exec sap-ai-redis redis-cli ping | grep -q PONG; then
            log_success "Redis is healthy"
        else
            log_error "Redis health check failed"
            return 1
        fi
    }
    
    log_success "Tier 0 deployment complete"
}

deploy_tier1() {
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "TIER 1: MCP Servers"
    log_info "═══════════════════════════════════════════════════════════════"
    
    deploy_compose "docker-compose.tier1.yml" "Tier 1 (MCP Servers)"
    
    # Wait for services
    sleep 10
    wait_for_healthy "OData Vocabularies MCP" "http://localhost:${ODATA_MCP_PORT:-9150}/health" 30 || true
    wait_for_healthy "OData Schema" "http://localhost:${ODATA_SCHEMA_PORT:-8003}/health" 30 || true
    wait_for_healthy "Agent Router" "http://localhost:${AGENT_ROUTER_PORT:-8010}/health" 30 || true
    
    log_success "Tier 1 deployment complete"
}

deploy_tier2() {
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "TIER 2: Intelligence Layer"
    log_info "═══════════════════════════════════════════════════════════════"
    
    # Check for GPU
    if ! nvidia-smi &> /dev/null; then
        log_warning "NVIDIA GPU not detected. vLLM may not start correctly."
        log_warning "Set CUDA_VISIBLE_DEVICES='' for CPU-only mode (not recommended)"
    fi
    
    deploy_compose "docker-compose.tier2.yml" "Tier 2 (Intelligence Layer)"
    
    # Wait for vLLM (may take longer to load model)
    log_info "Waiting for vLLM to load model (this may take several minutes)..."
    sleep 30
    wait_for_healthy "vLLM" "http://localhost:${VLLM_PORT:-8080}/health" 120 || true
    
    # Wait for other services
    wait_for_healthy "AI-Core-PAL" "http://localhost:${AICORE_PAL_PORT:-9881}/health" 60 || true
    wait_for_healthy "GenAI Toolkit" "http://localhost:${GENAI_TOOLKIT_PORT:-8084}/health" 30 || true
    
    log_success "Tier 2 deployment complete"
}

deploy_tier3() {
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "TIER 3: Training Services (Optional)"
    log_info "═══════════════════════════════════════════════════════════════"
    
    deploy_compose "docker-compose.tier3.yml" "Tier 3 (Training Services)"
    
    # Wait for ModelOpt
    sleep 10
    wait_for_healthy "ModelOpt API" "http://localhost:${MODELOPT_API_PORT:-8001}/health" 60 || true
    
    log_success "Tier 3 deployment complete"
}

deploy_all() {
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "FULL STACK DEPLOYMENT"
    log_info "═══════════════════════════════════════════════════════════════"
    
    deploy_tier0
    echo ""
    deploy_tier1
    echo ""
    deploy_tier2
    echo ""
    
    read -p "Deploy Tier 3 (Training services)? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        deploy_tier3
    else
        log_info "Skipping Tier 3 deployment"
    fi
    
    log_success "Full stack deployment complete!"
}

# ============================================================================
# Main
# ============================================================================

main() {
    print_banner
    
    # Parse arguments
    TIER=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            tier0|tier1|tier2|tier3|all)
                TIER=$1
                shift
                ;;
            --build)
                BUILD_FLAG="--build"
                shift
                ;;
            --no-cache)
                BUILD_FLAG="--build"
                NO_CACHE_FLAG="--no-cache"
                shift
                ;;
            --foreground)
                DETACH=""
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
    
    if [[ -z "$TIER" ]]; then
        log_error "No tier specified"
        print_usage
        exit 1
    fi
    
    # Run pre-flight checks
    check_prerequisites
    check_env_file
    create_volumes
    create_network
    
    # Deploy based on tier
    case $TIER in
        tier0)
            deploy_tier0
            ;;
        tier1)
            deploy_tier1
            ;;
        tier2)
            deploy_tier2
            ;;
        tier3)
            deploy_tier3
            ;;
        all)
            deploy_all
            ;;
    esac
    
    echo ""
    log_info "Run './scripts/health-check.sh' to verify all services"
}

main "$@"