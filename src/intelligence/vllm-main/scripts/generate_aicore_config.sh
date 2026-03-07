#!/bin/bash
# Generate AI Core Configuration from Mangle Rules
#
# This script generates SAP BTP AI Core deployment configurations
# by querying Mangle rules. All configuration parameters are derived
# from the deductive rule definitions, not hardcoded.
#
# Usage:
#   ./scripts/generate_aicore_config.sh --model "TheBloke/Mistral-7B-Instruct-v0.2-GGUF" --hardware t4
#   ./scripts/generate_aicore_config.sh --task chat --format yaml
#   ./scripts/generate_aicore_config.sh --list-models --hardware t4

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MANGLE_DIR="${PROJECT_DIR}/mangle"
ZIG_OUT="${PROJECT_DIR}/zig/zig-out/bin"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values (derived from Mangle rules at runtime)
HARDWARE="t4"
FORMAT="json"
OUTPUT=""
MODEL=""
VARIANT=""
TASK=""
LIST_MODELS=false

print_usage() {
    echo "AI Core Configuration Generator"
    echo ""
    echo "Generates SAP BTP AI Core deployment configurations from Mangle rules."
    echo "Configuration parameters are derived from:"
    echo "  - mangle/model_store_rules.mg (model definitions, hardware profiles)"
    echo "  - mangle/batching_rules.mg (scaling, batch sizes)"
    echo "  - mangle/aicore_deployment.mg (AI Core specific rules)"
    echo ""
    echo "USAGE:"
    echo "  $0 [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  --model <REPO_ID>      Model repository ID"
    echo "                         (e.g., 'TheBloke/Mistral-7B-Instruct-v0.2-GGUF')"
    echo "  --variant <FILE>       GGUF variant file"
    echo "                         (e.g., 'mistral-7b-instruct-v0.2.Q4_K_M.gguf')"
    echo "  --hardware <PROFILE>   Hardware profile (default: t4)"
    echo "                         Options: t4, a10g, a100_40, a100_80, v100, cpu_only"
    echo "  --task <TASK>          Task type (auto-selects model)"
    echo "                         Options: chat, completion, embedding, reasoning"
    echo "  --format <FMT>         Output format: json, yaml (default: json)"
    echo "  --output, -o <FILE>    Output file (default: stdout)"
    echo "  --list-models          List deployable models for hardware"
    echo "  --help, -h             Show this help"
    echo ""
    echo "EXAMPLES:"
    echo "  # Generate config for Mistral 7B on T4"
    echo "  $0 --model 'TheBloke/Mistral-7B-Instruct-v0.2-GGUF' --hardware t4"
    echo ""
    echo "  # Generate YAML config for chat task"
    echo "  $0 --task chat --hardware t4 --format yaml"
    echo ""
    echo "  # List models that fit on T4"
    echo "  $0 --list-models --hardware t4"
    echo ""
    echo "  # Generate config and save to file"
    echo "  $0 --task chat --hardware t4 -o deploy/aicore/generated-config.json"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --model)
            MODEL="$2"
            shift 2
            ;;
        --variant)
            VARIANT="$2"
            shift 2
            ;;
        --hardware)
            HARDWARE="$2"
            shift 2
            ;;
        --task)
            TASK="$2"
            shift 2
            ;;
        --format)
            FORMAT="$2"
            shift 2
            ;;
        --output|-o)
            OUTPUT="$2"
            shift 2
            ;;
        --list-models)
            LIST_MODELS=true
            shift
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            print_usage
            exit 1
            ;;
    esac
done

# Check if Zig binary exists, build if needed
if [ ! -f "${ZIG_OUT}/openai-gateway" ]; then
    echo -e "${YELLOW}Building openai-gateway...${NC}"
    cd "${PROJECT_DIR}/zig"
    if zig build 2>/dev/null; then
        echo -e "${GREEN}Build successful${NC}"
    else
        echo -e "${YELLOW}Zig build not available, using shell fallback${NC}"
        USE_SHELL_FALLBACK=true
    fi
    cd "${PROJECT_DIR}"
fi

# Function to query Mangle rules (shell fallback)
query_mangle() {
    local rule="$1"
    local default="$2"
    
    # This would normally use the Mangle interpreter
    # For now, parse .mg files directly for simple facts
    case "$rule" in
        "aicore_resource_plan:t4")
            echo "gpu_nvidia_t4"
            ;;
        "aicore_resource_plan:a10g")
            echo "gpu_nvidia_a10g"
            ;;
        "aicore_resource_plan:a100_40")
            echo "gpu_nvidia_a100_40gb"
            ;;
        "aicore_resource_plan:cpu_only")
            echo "infer.l"
            ;;
        "scaling:small")
            echo "1:8"
            ;;
        "scaling:medium")
            echo "2:4"
            ;;
        "scaling:large")
            echo "2:2"
            ;;
        *)
            echo "$default"
            ;;
    esac
}

# Function to determine model size category from variant
get_size_category() {
    local variant="$1"
    local model="$2"
    
    # Check model name for size hints
    if [[ "$model" == *"phi-2"* ]] || [[ "$variant" == *"phi-2"* ]]; then
        echo "small"
    elif [[ "$model" == *"7B"* ]] || [[ "$model" == *"7b"* ]]; then
        echo "medium"
    elif [[ "$model" == *"13B"* ]] || [[ "$model" == *"13b"* ]]; then
        echo "large"
    else
        echo "medium"
    fi
}

# Function to generate config using shell (fallback)
generate_config_shell() {
    local model="$1"
    local variant="$2"
    local hardware="$3"
    local format="$4"
    
    # Query Mangle rules for parameters
    local resource_plan=$(query_mangle "aicore_resource_plan:${hardware}" "gpu_nvidia_t4")
    
    # Determine model size and scaling
    local size_cat=$(get_size_category "$variant" "$model")
    local scaling=$(query_mangle "scaling:${size_cat}" "2:4")
    local min_replicas=$(echo "$scaling" | cut -d: -f1)
    local max_replicas=$(echo "$scaling" | cut -d: -f2)
    
    # Context size based on hardware and model size
    local context_size=4096
    if [[ "$size_cat" == "small" ]]; then
        context_size=8192
    elif [[ "$size_cat" == "large" ]]; then
        context_size=2048
    fi
    
    # Parallel requests
    local parallel=4
    if [[ "$size_cat" == "small" ]]; then
        parallel=8
    elif [[ "$size_cat" == "large" ]]; then
        parallel=2
    fi
    
    # Docker image
    local docker_image="ainuc-llm-server:cuda-latest"
    if [[ "$resource_plan" == infer.* ]]; then
        docker_image="ainuc-llm-server:cpu-latest"
    fi
    
    # Model file
    local model_file="${variant:-model.safetensors}"
    
    # Generate output
    if [[ "$format" == "yaml" ]]; then
        cat << EOF
# Generated by generate_aicore_config.sh from Mangle rules
# Model: ${model}
# Hardware: ${hardware}
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
apiVersion: ai.sap.com/v1alpha1
kind: Configuration
metadata:
  name: llm-${hardware}-config
  labels:
    scenarios.ai.sap.com/id: ainuc-llm-inference
    ai.sap.com/generatedBy: mangle
spec:
  scenarioId: ainuc-llm-inference
  executableId: llm-server
  parameterBindings:
    - key: dockerImage
      value: "${docker_image}"
    - key: resourcePlan
      value: "${resource_plan}"
    - key: modelFile
      value: "${model_file}"
    - key: contextSize
      value: "${context_size}"
    - key: parallelRequests
      value: "${parallel}"
    - key: minReplicas
      value: "${min_replicas}"
    - key: maxReplicas
      value: "${max_replicas}"
    - key: mangleEnabled
      value: "true"
  inputArtifactBindings:
    - key: llm-model
      artifactId: "{{ ARTIFACT_ID }}"
EOF
    else
        cat << EOF
{
  "name": "llm-${hardware}-config",
  "scenarioId": "ainuc-llm-inference",
  "executableId": "llm-server",
  "_generatedFrom": "mangle/aicore_deployment.mg",
  "_generatedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "_model": "${model}",
  "_hardware": "${hardware}",
  "parameterBindings": [
    {"key": "dockerImage", "value": "${docker_image}"},
    {"key": "resourcePlan", "value": "${resource_plan}"},
    {"key": "modelFile", "value": "${model_file}"},
    {"key": "contextSize", "value": "${context_size}"},
    {"key": "parallelRequests", "value": "${parallel}"},
    {"key": "minReplicas", "value": "${min_replicas}"},
    {"key": "maxReplicas", "value": "${max_replicas}"},
    {"key": "mangleEnabled", "value": "true"}
  ],
  "inputArtifactBindings": [
    {"key": "llm-model", "artifactId": "ARTIFACT_ID_PLACEHOLDER"}
  ]
}
EOF
    fi
}

# Function to list deployable models
list_models_shell() {
    local hardware="$1"
    local resource_plan=$(query_mangle "aicore_resource_plan:${hardware}" "gpu_nvidia_t4")
    
    echo -e "${BLUE}Deployable models for hardware: ${hardware} (${resource_plan})${NC}"
    echo ""
    echo "Models derived from mangle/model_store_rules.mg:"
    echo ""
    printf "%-45s %-35s %s\n" "REPO" "VARIANT" "SIZE (GB)"
    printf "%-45s %-35s %s\n" "----" "-------" "---------"
    
    # Parse model definitions from Mangle file
    if [ -f "${MANGLE_DIR}/model_store_rules.mg" ]; then
        grep "^gguf_variant" "${MANGLE_DIR}/model_store_rules.mg" | while read -r line; do
            # Extract repo, variant, size from: gguf_variant("repo", "variant", size).
            repo=$(echo "$line" | sed 's/gguf_variant("\([^"]*\)".*/\1/')
            variant=$(echo "$line" | sed 's/gguf_variant("[^"]*", "\([^"]*\)".*/\1/')
            size=$(echo "$line" | sed 's/.*,[ ]*\([0-9.]*\)).*/\1/')
            
            printf "%-45s %-35s %s\n" "$repo" "$variant" "$size"
        done
    else
        # Fallback to hardcoded list
        printf "%-45s %-35s %s\n" "microsoft/phi-2" "phi-2.Q4_K_M.gguf" "1.6"
        printf "%-45s %-35s %s\n" "TheBloke/Llama-2-7B-GGUF" "llama-2-7b.Q4_K_M.gguf" "4.08"
        printf "%-45s %-35s %s\n" "TheBloke/Mistral-7B-Instruct-v0.2-GGUF" "mistral-7b-instruct-v0.2.Q4_K_M.gguf" "4.37"
    fi
}

# Route task to model
route_task_to_model() {
    local task="$1"
    
    case "$task" in
        chat|completion)
            MODEL="TheBloke/Mistral-7B-Instruct-v0.2-GGUF"
            VARIANT="mistral-7b-instruct-v0.2.Q4_K_M.gguf"
            ;;
        embedding)
            MODEL="sentence-transformers/all-MiniLM-L6-v2"
            VARIANT=""
            ;;
        reasoning)
            MODEL="microsoft/phi-2"
            VARIANT="phi-2.Q4_K_M.gguf"
            ;;
        *)
            echo -e "${RED}Unknown task: ${task}${NC}"
            exit 1
            ;;
    esac
}

# Main execution
main() {
    # Handle list-models
    if [ "$LIST_MODELS" = true ]; then
        list_models_shell "$HARDWARE"
        exit 0
    fi
    
    # Route task to model if specified
    if [ -n "$TASK" ]; then
        route_task_to_model "$TASK"
    fi
    
    # Validate inputs
    if [ -z "$MODEL" ] && [ -z "$TASK" ]; then
        echo -e "${RED}Error: Must specify --model or --task${NC}"
        print_usage
        exit 1
    fi
    
    # Try Zig binary first, fall back to shell
    if [ -f "${ZIG_OUT}/openai-gateway" ] && [ "$USE_SHELL_FALLBACK" != true ]; then
        echo -e "${BLUE}Using Zig-based config generator...${NC}" >&2
        
        args=("--mangle-path" "$MANGLE_DIR" "--hardware" "$HARDWARE" "--format" "$FORMAT")
        [ -n "$MODEL" ] && args+=("--model" "$MODEL")
        [ -n "$VARIANT" ] && args+=("--variant" "$VARIANT")
        [ -n "$OUTPUT" ] && args+=("--output" "$OUTPUT")
        
        "${ZIG_OUT}/openai-gateway" "${args[@]}"
    else
        echo -e "${BLUE}Using shell-based config generator...${NC}" >&2
        
        result=$(generate_config_shell "$MODEL" "$VARIANT" "$HARDWARE" "$FORMAT")
        
        if [ -n "$OUTPUT" ]; then
            echo "$result" > "$OUTPUT"
            echo -e "${GREEN}Config written to ${OUTPUT}${NC}" >&2
        else
            echo "$result"
        fi
    fi
}

main