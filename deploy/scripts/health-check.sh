#!/usr/bin/env bash
# ============================================================================
# SAP AI Fabric - Health Check Script
# ============================================================================
# Verifies the health status of all deployed services
# Usage: ./health-check.sh [tier0|tier1|tier2|tier3|all] [--json] [--watch]
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

# Default values
OUTPUT_JSON=false
WATCH_MODE=false
WATCH_INTERVAL=5

# Source environment if available
if [[ -f "$DEPLOY_DIR/.env" ]]; then
    set -a
    source "$DEPLOY_DIR/.env"
    set +a
fi

# ============================================================================
# Service Definitions
# ============================================================================

declare -A TIER0_SERVICES=(
    ["Elasticsearch"]="http://localhost:${ES_PORT:-9200}/_cluster/health"
    ["Redis"]="redis://localhost:${REDIS_PORT:-6379}"
    ["API Gateway"]="http://localhost:8000"
)

declare -A TIER1_SERVICES=(
    ["OData Vocabularies MCP"]="http://localhost:${ODATA_MCP_PORT:-9150}/health"
    ["OData Schema"]="http://localhost:${ODATA_SCHEMA_PORT:-8003}/health"
    ["Elasticsearch MCP"]="http://localhost:${ES_MCP_PORT:-9120}/health"
    ["LangChain HANA MCP"]="http://localhost:${LANGCHAIN_HANA_MCP_PORT:-9160}/health"
    ["Agent Router"]="http://localhost:${AGENT_ROUTER_PORT:-8010}/health"
)

declare -A TIER2_SERVICES=(
    ["vLLM"]="http://localhost:${VLLM_PORT:-8080}/health"
    ["AI-Core-PAL"]="http://localhost:${AICORE_PAL_PORT:-9881}/health"
    ["GenAI Toolkit"]="http://localhost:${GENAI_TOOLKIT_PORT:-8084}/health"
    ["AI Shared Fabric"]="http://localhost:${AI_SHARED_FABRIC_PORT:-8030}/health"
    ["MCP-PAL"]="http://localhost:${MCP_PAL_PORT:-8020}/health"
    ["Embedded HANA"]="http://localhost:${EMBEDDED_HANA_PORT:-8050}/health"
)

declare -A TIER3_SERVICES=(
    ["ModelOpt API"]="http://localhost:${MODELOPT_API_PORT:-8001}/health"
    ["ModelOpt UI"]="http://localhost:${MODELOPT_UI_PORT:-8082}/health"
    ["Training Pipeline"]="http://localhost:8091/health"
    ["KuzuDB"]="tcp://localhost:7687"
)

# ============================================================================
# Helper Functions
# ============================================================================

log_info() {
    if [[ "$OUTPUT_JSON" == "false" ]]; then
        echo -e "${BLUE}[INFO]${NC} $1"
    fi
}

log_success() {
    if [[ "$OUTPUT_JSON" == "false" ]]; then
        echo -e "${GREEN}[✓]${NC} $1"
    fi
}

log_error() {
    if [[ "$OUTPUT_JSON" == "false" ]]; then
        echo -e "${RED}[✗]${NC} $1"
    fi
}

log_warning() {
    if [[ "$OUTPUT_JSON" == "false" ]]; then
        echo -e "${YELLOW}[!]${NC} $1"
    fi
}

print_banner() {
    if [[ "$OUTPUT_JSON" == "false" ]]; then
        echo -e "${CYAN}"
        echo "╔═══════════════════════════════════════════════════════════════════╗"
        echo "║           SAP AI Fabric - Health Check Monitor                    ║"
        echo "╚═══════════════════════════════════════════════════════════════════╝"
        echo -e "${NC}"
    fi
}

print_usage() {
    echo "Usage: $0 [TIER] [OPTIONS]"
    echo ""
    echo "Tiers:"
    echo "  tier0     Check infrastructure services"
    echo "  tier1     Check MCP servers"
    echo "  tier2     Check intelligence layer"
    echo "  tier3     Check training services"
    echo "  all       Check all services (default)"
    echo ""
    echo "Options:"
    echo "  --json      Output results as JSON"
    echo "  --watch     Continuously monitor (Ctrl+C to stop)"
    echo "  --interval  Watch interval in seconds (default: 5)"
    echo "  -h, --help  Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                    # Check all services"
    echo "  $0 tier2 --json       # Check tier2 as JSON"
    echo "  $0 all --watch        # Continuously monitor all"
}

# ============================================================================
# Health Check Functions
# ============================================================================

check_http_health() {
    local url=$1
    local timeout=${2:-5}
    
    if curl -sf --max-time "$timeout" "$url" &> /dev/null; then
        echo "healthy"
        return 0
    else
        echo "unhealthy"
        return 1
    fi
}

check_redis_health() {
    local host=${1:-localhost}
    local port=${2:-6379}
    
    if command -v redis-cli &> /dev/null; then
        if redis-cli -h "$host" -p "$port" ping 2>/dev/null | grep -q PONG; then
            echo "healthy"
            return 0
        fi
    fi
    
    # Fallback to nc
    if nc -z "$host" "$port" 2>/dev/null; then
        echo "healthy"
        return 0
    fi
    
    echo "unhealthy"
    return 1
}

check_tcp_health() {
    local host=$1
    local port=$2
    
    if nc -z "$host" "$port" 2>/dev/null; then
        echo "healthy"
        return 0
    else
        echo "unhealthy"
        return 1
    fi
}

check_service() {
    local name=$1
    local url=$2
    local status
    local response_time
    local start_time
    local end_time
    
    start_time=$(date +%s%N)
    
    case "$url" in
        redis://*)
            # Extract host and port from redis URL
            local redis_host=$(echo "$url" | sed 's|redis://||' | cut -d: -f1)
            local redis_port=$(echo "$url" | sed 's|redis://||' | cut -d: -f2)
            status=$(check_redis_health "$redis_host" "$redis_port")
            ;;
        tcp://*)
            # Extract host and port from TCP URL
            local tcp_host=$(echo "$url" | sed 's|tcp://||' | cut -d: -f1)
            local tcp_port=$(echo "$url" | sed 's|tcp://||' | cut -d: -f2)
            status=$(check_tcp_health "$tcp_host" "$tcp_port")
            ;;
        http://*|https://*)
            status=$(check_http_health "$url")
            ;;
        *)
            status="unknown"
            ;;
    esac
    
    end_time=$(date +%s%N)
    response_time=$(( (end_time - start_time) / 1000000 ))  # Convert to ms
    
    if [[ "$OUTPUT_JSON" == "true" ]]; then
        echo "{\"name\": \"$name\", \"url\": \"$url\", \"status\": \"$status\", \"response_time_ms\": $response_time}"
    else
        if [[ "$status" == "healthy" ]]; then
            log_success "$name: ${GREEN}healthy${NC} (${response_time}ms)"
        else
            log_error "$name: ${RED}unhealthy${NC}"
        fi
    fi
    
    [[ "$status" == "healthy" ]]
}

check_tier() {
    local tier_name=$1
    shift
    local -n services=$1
    local healthy_count=0
    local total_count=0
    local results=()
    
    if [[ "$OUTPUT_JSON" == "false" ]]; then
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}  $tier_name${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    fi
    
    for service in "${!services[@]}"; do
        ((total_count++))
        local result
        result=$(check_service "$service" "${services[$service]}")
        if [[ "$OUTPUT_JSON" == "true" ]]; then
            results+=("$result")
        fi
        if check_service "$service" "${services[$service]}" &>/dev/null; then
            ((healthy_count++))
        fi
    done
    
    if [[ "$OUTPUT_JSON" == "true" ]]; then
        local json_array
        json_array=$(printf '%s,' "${results[@]}" | sed 's/,$//')
        echo "{\"tier\": \"$tier_name\", \"healthy\": $healthy_count, \"total\": $total_count, \"services\": [$json_array]}"
    else
        echo ""
        if [[ $healthy_count -eq $total_count ]]; then
            log_success "Summary: $healthy_count/$total_count services healthy"
        else
            log_warning "Summary: $healthy_count/$total_count services healthy"
        fi
    fi
    
    return $((total_count - healthy_count))
}

check_all_tiers() {
    local overall_healthy=0
    local overall_total=0
    local tier_results=()
    
    # Check Tier 0
    if check_tier "TIER 0: Infrastructure" TIER0_SERVICES; then
        ((overall_healthy++))
    fi
    ((overall_total++))
    
    # Check Tier 1
    if check_tier "TIER 1: MCP Servers" TIER1_SERVICES; then
        ((overall_healthy++))
    fi
    ((overall_total++))
    
    # Check Tier 2
    if check_tier "TIER 2: Intelligence Layer" TIER2_SERVICES; then
        ((overall_healthy++))
    fi
    ((overall_total++))
    
    # Check Tier 3
    if check_tier "TIER 3: Training Services" TIER3_SERVICES; then
        ((overall_healthy++))
    fi
    ((overall_total++))
    
    if [[ "$OUTPUT_JSON" == "false" ]]; then
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
        if [[ $overall_healthy -eq $overall_total ]]; then
            echo -e "${GREEN}  All tiers healthy!${NC}"
        else
            echo -e "${YELLOW}  $overall_healthy/$overall_total tiers fully healthy${NC}"
        fi
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════════${NC}"
    fi
}

watch_health() {
    local tier=$1
    
    while true; do
        clear
        print_banner
        echo -e "${YELLOW}Watch mode - refreshing every ${WATCH_INTERVAL}s (Ctrl+C to stop)${NC}"
        echo -e "${BLUE}Last check: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
        
        case $tier in
            tier0)
                check_tier "TIER 0: Infrastructure" TIER0_SERVICES
                ;;
            tier1)
                check_tier "TIER 1: MCP Servers" TIER1_SERVICES
                ;;
            tier2)
                check_tier "TIER 2: Intelligence Layer" TIER2_SERVICES
                ;;
            tier3)
                check_tier "TIER 3: Training Services" TIER3_SERVICES
                ;;
            all)
                check_all_tiers
                ;;
        esac
        
        sleep "$WATCH_INTERVAL"
    done
}

# ============================================================================
# Docker Status Check
# ============================================================================

check_docker_status() {
    if [[ "$OUTPUT_JSON" == "false" ]]; then
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}  Docker Container Status${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        
        # List all SAP AI Fabric containers
        docker ps --filter "label=sap.ai.tier" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || {
            log_warning "No SAP AI Fabric containers found"
        }
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    local tier="all"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            tier0|tier1|tier2|tier3|all)
                tier=$1
                shift
                ;;
            --json)
                OUTPUT_JSON=true
                shift
                ;;
            --watch)
                WATCH_MODE=true
                shift
                ;;
            --interval)
                WATCH_INTERVAL=$2
                shift 2
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
    
    # Watch mode
    if [[ "$WATCH_MODE" == "true" ]]; then
        watch_health "$tier"
        exit 0
    fi
    
    # Normal mode
    print_banner
    
    case $tier in
        tier0)
            check_tier "TIER 0: Infrastructure" TIER0_SERVICES
            ;;
        tier1)
            check_tier "TIER 1: MCP Servers" TIER1_SERVICES
            ;;
        tier2)
            check_tier "TIER 2: Intelligence Layer" TIER2_SERVICES
            ;;
        tier3)
            check_tier "TIER 3: Training Services" TIER3_SERVICES
            ;;
        all)
            check_all_tiers
            check_docker_status
            ;;
    esac
}

main "$@"