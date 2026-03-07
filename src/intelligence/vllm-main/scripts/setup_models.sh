#!/bin/bash
# setup_models.sh - Set up symlinks to vendor models for local-models service
#
# Usage: ./setup_models.sh [--verify] [--clean]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENDOR_MODELS_DIR="$(cd "$PROJECT_DIR/../../../../vendor/layerModels" 2>/dev/null && pwd || echo "")"

# Target directory for model symlinks
MODELS_DIR="$PROJECT_DIR/models"

echo "=============================================="
echo "Local Models - Model Setup Script"
echo "=============================================="
echo ""
echo "Project Dir: $PROJECT_DIR"
echo "Vendor Models: $VENDOR_MODELS_DIR"
echo "Models Dir: $MODELS_DIR"
echo ""

# Check if vendor models directory exists
if [ -z "$VENDOR_MODELS_DIR" ] || [ ! -d "$VENDOR_MODELS_DIR" ]; then
    echo -e "${RED}ERROR: Vendor models directory not found!${NC}"
    echo "Expected at: $PROJECT_DIR/../../../../vendor/layerModels"
    echo ""
    echo "Please ensure vendor/layerModels exists with DVC-tracked models."
    exit 1
fi

# Parse arguments
VERIFY_ONLY=false
CLEAN=false

for arg in "$@"; do
    case $arg in
        --verify)
            VERIFY_ONLY=true
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        *)
            ;;
    esac
done

# Clean existing symlinks
if [ "$CLEAN" = true ]; then
    echo "Cleaning existing model symlinks..."
    if [ -d "$MODELS_DIR" ]; then
        rm -rf "$MODELS_DIR"
        echo -e "${GREEN}Cleaned models directory${NC}"
    fi
    if [ "$VERIFY_ONLY" = false ]; then
        exit 0
    fi
fi

# Create models directory if it doesn't exist
mkdir -p "$MODELS_DIR"

# Define models to link (from MODEL_REGISTRY.json)
declare -A MODELS=(
    ["google-gemma-3-270m-it"]="google-gemma-3-270m-it"
    ["LFM2.5-1.2B-Instruct-GGUF"]="LFM2.5-1.2B-Instruct-GGUF"
    ["HY-MT1.5-7B"]="HY-MT1.5-7B"
    ["microsoft-phi-2"]="microsoft-phi-2"
    ["deepseek-coder-33b-instruct-q4_k_m"]="deepseek-coder-33b-instruct-q4_k_m"
    ["translategemma-27b-it-GGUF"]="translategemma-27b-it-GGUF"
    ["Kimi-K2.5-GGUF"]="Kimi-K2.5-GGUF"
)

# Testing models (smaller, recommended for quick tests)
TESTING_MODELS=(
    "google-gemma-3-270m-it"
    "LFM2.5-1.2B-Instruct-GGUF"
)

echo "Available models in vendor directory:"
echo "--------------------------------------"

# List available models
for model_name in "${!MODELS[@]}"; do
    model_dir="${MODELS[$model_name]}"
    vendor_path="$VENDOR_MODELS_DIR/$model_dir"
    
    if [ -d "$vendor_path" ]; then
        # Get size
        size=$(du -sh "$vendor_path" 2>/dev/null | cut -f1 || echo "unknown")
        echo -e "${GREEN}✓${NC} $model_name ($size)"
    else
        echo -e "${YELLOW}○${NC} $model_name (not downloaded)"
    fi
done
echo ""

# Verify only mode
if [ "$VERIFY_ONLY" = true ]; then
    echo "Verification complete (--verify mode)"
    exit 0
fi

# Create symlinks
echo "Creating symlinks..."
echo "--------------------------------------"

linked=0
skipped=0

for model_name in "${!MODELS[@]}"; do
    model_dir="${MODELS[$model_name]}"
    vendor_path="$VENDOR_MODELS_DIR/$model_dir"
    link_path="$MODELS_DIR/$model_name"
    
    if [ -d "$vendor_path" ]; then
        # Remove existing link if present
        if [ -L "$link_path" ]; then
            rm "$link_path"
        fi
        
        # Create relative symlink
        ln -sf "$vendor_path" "$link_path"
        echo -e "${GREEN}✓${NC} Linked: $model_name -> $vendor_path"
        ((linked++))
    else
        echo -e "${YELLOW}○${NC} Skipped: $model_name (not downloaded)"
        ((skipped++))
    fi
done

echo ""
echo "=============================================="
echo "Summary"
echo "=============================================="
echo -e "Linked: ${GREEN}$linked${NC} models"
echo -e "Skipped: ${YELLOW}$skipped${NC} models (not downloaded)"
echo ""

# Create a registry file for the service
REGISTRY_FILE="$MODELS_DIR/local_registry.json"
echo "Creating local registry at $REGISTRY_FILE..."

cat > "$REGISTRY_FILE" << EOF
{
  "generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "models_dir": "$MODELS_DIR",
  "vendor_models_dir": "$VENDOR_MODELS_DIR",
  "linked_models": [
EOF

first=true
for model_name in "${!MODELS[@]}"; do
    link_path="$MODELS_DIR/$model_name"
    if [ -L "$link_path" ]; then
        if [ "$first" = true ]; then
            first=false
        else
            echo "," >> "$REGISTRY_FILE"
        fi
        printf '    {"name": "%s", "path": "%s"}' "$model_name" "$link_path" >> "$REGISTRY_FILE"
    fi
done

cat >> "$REGISTRY_FILE" << EOF

  ],
  "testing_models": [
    "google-gemma-3-270m-it",
    "LFM2.5-1.2B-Instruct-GGUF"
  ]
}
EOF

echo -e "${GREEN}✓${NC} Created local registry"
echo ""
echo "Setup complete! Models are available at: $MODELS_DIR"
echo ""
echo "To run tests:"
echo "  ./scripts/test_backends.sh --test-type=smoke"