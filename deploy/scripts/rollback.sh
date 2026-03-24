#!/usr/bin/env bash
# ============================================================================
# SAP AI Fabric - Rollback Script
# ============================================================================
# Stops and removes services by tier (reverse deployment order)
# Usage: ./rollback.sh [tier0|tier1|tier2|tier3|all] [--volumes] [--force]
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
REMOVE_VOLUMES=false
FORCE_REMOVE=false

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
    echo -e "${RED}"
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║           SAP AI Fabric - Rollback / Teardown                     ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_usage() {
    echo "Usage: $0 [TIER] [OPTIONS]"
    echo ""
    echo "Tiers:"
    echo "  tier3     Stop training services"
    echo "  tier2     Stop intelligence layer"
    echo "  tier1     Stop MCP servers"
    echo "  tier0     Stop infrastructure"
    echo "  all       Stop all services (in reverse order)"
    echo ""
    echo "Options:"
    echo "  --volumes   Also remove associated volumes (DATA LOSS WARNING)"
    echo "  --force     Don't prompt for confirmation"
    echo "  -h, --help  Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 tier3              # Stop training services only"
    echo "  $0 all                # Stop all services"
    echo "  $0 all --volumes      # Stop all and remove data"
}

confirm_action() {
    local message=$1
    
    if [[ "$FORCE_REMOVE" == "true" ]]; then
        return 0
    fi
    
    echo -e "${YELLOW}$message${NC}"
    read -p "Continue? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Cancelled"
        exit 0
    fi
}

# ============================================================================
# Rollback Functions
# ============================================================================

get_compose_cmd() {
    if docker compose version &> /dev/null 2>&1; then
        echo "docker compose"
    else
        echo "docker-compose"
    fi
}

rollback_compose() {
    local compose_file=$1
    local tier_name=$2
    
    log_step "Stopping $tier_name..."
    
    cd "$DEPLOY_DIR"
    
    local compose_cmd=$(get_compose_cmd)
    local down_flags=""
    
    if [[ "$REMOVE_VOLUMES" == "true" ]]; then
        down_flags="--volumes"
        log_warning "Removing volumes (data will be lost)"
    fi
    
    # Check if compose file exists
    if [[ ! -f "$compose_file" ]]; then
        log_warning "Compose file $compose_file not found, skipping"
        return 0
    fi
    
    # Stop services
    if [[ -f ".env" ]]; then
        $compose_cmd -f "$compose_file" --env-file .env down $down_flags --remove-orphans 2>/dev/null || {
            log_warning "Some services may not have been running"
        }
    else
        $compose_cmd -f "$compose_file" down $down_flags --remove-orphans 2>/dev/null || {
            log_warning "Some services may not have been running"
        }
    fi
    
    log_success "$tier_name stopped"
}

stop_containers_by_label() {
    local tier_label=$1
    local tier_name=$2
    
    log_step "Stopping containers for $tier_name..."
    
    # Find containers by label
    local containers=$(docker ps -q --filter "label=sap.ai.tier=$tier_label" 2>/dev/null)
    
    if [[ -n "$containers" ]]; then
        echo "$containers" | xargs docker stop 2>/dev/null || true
        echo "$containers" | xargs docker rm 2>/dev/null || true
        log_success "Containers stopped for $tier_name"
    else
        log_info "No running containers found for $tier_name"
    fi
}

rollback_tier3() {
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "Rolling back TIER 3: Training Services"
    log_info "═══════════════════════════════════════════════════════════════"
    
    rollback_compose "docker-compose.tier3.yml" "Tier 3 (Training Services)"
    stop_containers_by_label "tier3-training" "Tier 3"
    
    log_success "Tier 3 rollback complete"
}

rollback_tier2() {
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "Rolling back TIER 2: Intelligence Layer"
    log_info "═══════════════════════════════════════════════════════════════"
    
    rollback_compose "docker-compose.tier2.yml" "Tier 2 (Intelligence Layer)"
    stop_containers_by_label "tier2-intelligence" "Tier 2"
    
    log_success "Tier 2 rollback complete"
}

rollback_tier1() {
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "Rolling back TIER 1: MCP Servers"
    log_info "═══════════════════════════════════════════════════════════════"
    
    rollback_compose "docker-compose.tier1.yml" "Tier 1 (MCP Servers)"
    stop_containers_by_label "tier1-mcp-servers" "Tier 1"
    
    log_success "Tier 1 rollback complete"
}

rollback_tier0() {
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "Rolling back TIER 0: Infrastructure"
    log_info "═══════════════════════════════════════════════════════════════"
    
    if [[ "$REMOVE_VOLUMES" == "true" ]]; then
        confirm_action "WARNING: This will delete Elasticsearch and Redis data!"
    fi
    
    rollback_compose "docker-compose.tier0.yml" "Tier 0 (Infrastructure)"
    stop_containers_by_label "tier0-infrastructure" "Tier 0"
    
    log_success "Tier 0 rollback complete"
}

rollback_all() {
    log_info "═══════════════════════════════════════════════════════════════"
    log_info "FULL STACK ROLLBACK"
    log_info "═══════════════════════════════════════════════════════════════"
    
    if [[ "$REMOVE_VOLUMES" == "true" ]]; then
        confirm_action "WARNING: This will stop ALL services and DELETE ALL DATA!"
    else
        confirm_action "This will stop ALL SAP AI Fabric services."
    fi
    
    # Roll back in reverse order (Tier 3 -> Tier 0)
    echo ""
    rollback_tier3
    echo ""
    rollback_tier2
    echo ""
    rollback_tier1
    echo ""
    rollback_tier0
    
    # Also try to stop the full stack compose
    rollback_compose "docker-compose.full.yml" "Full Stack"
    
    # Clean up orphaned containers
    log_step "Cleaning up orphaned containers..."
    docker ps -aq --filter "label=sap.ai.tier" | xargs -r docker rm -f 2>/dev/null || true
    
    # Optionally remove network
    local network_name="${NETWORK_NAME:-sap-ai-fabric-network}"
    if docker network inspect "$network_name" &> /dev/null; then
        log_step "Removing network $network_name..."
        docker network rm "$network_name" 2>/dev/null || {
            log_warning "Could not remove network (may still have connected containers)"
        }
    fi
    
    log_success "Full stack rollback complete!"
}

cleanup_images() {
    log_step "Cleaning up SAP AI Fabric images..."
    
    # Find images by label
    docker images --filter "label=sap.ai.tier" -q | xargs -r docker rmi -f 2>/dev/null || true
    
    # Clean up dangling images
    docker image prune -f 2>/dev/null || true
    
    log_success "Image cleanup complete"
}

cleanup_volumes() {
    log_step "Cleaning up volumes..."
    
    # Remove named volumes
    docker volume ls -q --filter "name=sap-ai" | xargs -r docker volume rm 2>/dev/null || true
    
    # Remove anonymous volumes
    docker volume prune -f 2>/dev/null || true
    
    log_success "Volume cleanup complete"
}

show_status() {
    echo ""
    log_info "Current status after rollback:"
    echo ""
    
    # Show remaining containers
    local remaining=$(docker ps --filter "label=sap.ai.tier" --format "{{.Names}}" 2>/dev/null)
    
    if [[ -n "$remaining" ]]; then
        log_warning "Some containers are still running:"
        echo "$remaining"
    else
        log_success "No SAP AI Fabric containers running"
    fi
    
    # Show remaining volumes
    local volumes=$(docker volume ls -q --filter "name=sap-ai" 2>/dev/null)
    
    if [[ -n "$volumes" ]]; then
        log_info "Remaining volumes:"
        echo "$volumes"
    fi
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
            --volumes)
                REMOVE_VOLUMES=true
                shift
                ;;
            --force)
                FORCE_REMOVE=true
                shift
                ;;
            --cleanup-images)
                cleanup_images
                exit 0
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
    
    # Source environment if available
    if [[ -f "$DEPLOY_DIR/.env" ]]; then
        set -a
        source "$DEPLOY_DIR/.env"
        set +a
    fi
    
    # Roll back based on tier
    case $TIER in
        tier3)
            rollback_tier3
            ;;
        tier2)
            rollback_tier2
            ;;
        tier1)
            rollback_tier1
            ;;
        tier0)
            rollback_tier0
            ;;
        all)
            rollback_all
            ;;
    esac
    
    show_status
}

main "$@"