#!/bin/bash
# ===----------------------------------------------------------------------=== #
# Sync Models from HuggingFace to S3
# Downloads models and uploads to configured S3 bucket
# ===----------------------------------------------------------------------=== #

set -e

# Load environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/../../../../.env}"

if [ -f "$ENV_FILE" ]; then
    echo "Loading environment from: $ENV_FILE"
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    echo "Warning: .env file not found at $ENV_FILE"
    echo "Run: .vscode/generate_env.sh first"
fi

# Verify required environment variables
check_env() {
    local var_name=$1
    if [ -z "${!var_name}" ]; then
        echo "Error: $var_name not set"
        exit 1
    fi
}

check_env "HF_TOKEN"
check_env "S3_ACCESS_KEY_ID"
check_env "S3_SECRET_ACCESS_KEY"
check_env "S3_BUCKET"

# Configuration
MODELS_PREFIX="${MODELS_PREFIX:-models/}"
HF_CACHE_DIR="${HF_CACHE_DIR:-/tmp/hf_cache}"
mkdir -p "$HF_CACHE_DIR"

# Default models to sync (can be overridden)
DEFAULT_MODELS=(
    "sentence-transformers/all-MiniLM-L6-v2"
    "BAAI/bge-large-en-v1.5"
)

# GGUF models with specific files
GGUF_MODELS=(
    "TheBloke/Mistral-7B-Instruct-v0.2-GGUF:mistral-7b-instruct-v0.2.Q4_K_M.gguf"
    "TheBloke/Llama-2-7B-GGUF:llama-2-7b.Q4_K_M.gguf"
)

# Function to check if model exists in S3
check_s3_exists() {
    local s3_path=$1
    aws s3 ls "s3://${S3_BUCKET}/${s3_path}" --no-sign-request 2>/dev/null && return 0 || return 1
}

# Function to download model from HuggingFace
download_hf_model() {
    local repo_id=$1
    local revision=${2:-main}
    local output_dir="$HF_CACHE_DIR/$repo_id"
    
    echo "Downloading $repo_id (revision: $revision)..."
    
    # Use huggingface-cli if available, otherwise use curl
    if command -v huggingface-cli &> /dev/null; then
        huggingface-cli download "$repo_id" \
            --revision "$revision" \
            --local-dir "$output_dir" \
            --token "$HF_TOKEN"
    else
        # Fallback to git lfs
        if [ ! -d "$output_dir" ]; then
            GIT_LFS_SKIP_SMUDGE=1 git clone "https://huggingface.co/$repo_id" "$output_dir"
        fi
        cd "$output_dir"
        git lfs pull
        cd -
    fi
    
    echo "Downloaded to: $output_dir"
}

# Function to download specific GGUF file
download_gguf_file() {
    local repo_id=$1
    local filename=$2
    local output_dir="$HF_CACHE_DIR/$repo_id"
    local output_file="$output_dir/$filename"
    
    mkdir -p "$output_dir"
    
    if [ -f "$output_file" ]; then
        echo "GGUF file already exists: $output_file"
        return 0
    fi
    
    echo "Downloading GGUF: $repo_id/$filename..."
    
    curl -L \
        -H "Authorization: Bearer $HF_TOKEN" \
        "https://huggingface.co/$repo_id/resolve/main/$filename" \
        -o "$output_file"
    
    echo "Downloaded: $output_file"
}

# Function to upload to S3
upload_to_s3() {
    local local_path=$1
    local s3_key=$2
    
    echo "Uploading to S3: s3://${S3_BUCKET}/${s3_key}"
    
    aws s3 cp "$local_path" "s3://${S3_BUCKET}/${s3_key}" \
        --storage-class STANDARD_IA
}

# Function to sync directory to S3
sync_dir_to_s3() {
    local local_dir=$1
    local s3_prefix=$2
    
    echo "Syncing directory to S3: $local_dir -> s3://${S3_BUCKET}/${s3_prefix}"
    
    aws s3 sync "$local_dir" "s3://${S3_BUCKET}/${s3_prefix}" \
        --storage-class STANDARD_IA \
        --exclude "*.git*" \
        --exclude "*.gitattributes"
}

# Main sync function
sync_model() {
    local repo_id=$1
    local revision=${2:-main}
    local s3_prefix="${MODELS_PREFIX}${repo_id}/${revision}/"
    
    echo ""
    echo "========================================"
    echo "Syncing: $repo_id"
    echo "========================================"
    
    # Download from HuggingFace
    download_hf_model "$repo_id" "$revision"
    
    # Upload to S3
    sync_dir_to_s3 "$HF_CACHE_DIR/$repo_id" "$s3_prefix"
    
    echo "Synced: $repo_id -> s3://${S3_BUCKET}/${s3_prefix}"
}

# Sync GGUF model
sync_gguf() {
    local repo_id=$1
    local filename=$2
    local s3_key="${MODELS_PREFIX}${repo_id}/main/${filename}"
    
    echo ""
    echo "========================================"
    echo "Syncing GGUF: $repo_id/$filename"
    echo "========================================"
    
    # Download specific file
    download_gguf_file "$repo_id" "$filename"
    
    # Upload to S3
    upload_to_s3 "$HF_CACHE_DIR/$repo_id/$filename" "$s3_key"
    
    echo "Synced: $repo_id/$filename -> s3://${S3_BUCKET}/${s3_key}"
}

# Parse command line arguments
case "${1:-all}" in
    "all")
        echo "Syncing all default models..."
        
        # Sync regular models
        for model in "${DEFAULT_MODELS[@]}"; do
            sync_model "$model"
        done
        
        # Sync GGUF models
        for gguf in "${GGUF_MODELS[@]}"; do
            repo_id="${gguf%%:*}"
            filename="${gguf#*:}"
            sync_gguf "$repo_id" "$filename"
        done
        ;;
        
    "model")
        if [ -z "$2" ]; then
            echo "Usage: $0 model <repo_id> [revision]"
            exit 1
        fi
        sync_model "$2" "${3:-main}"
        ;;
        
    "gguf")
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "Usage: $0 gguf <repo_id> <filename.gguf>"
            exit 1
        fi
        sync_gguf "$2" "$3"
        ;;
        
    "list")
        echo "Models in S3:"
        aws s3 ls "s3://${S3_BUCKET}/${MODELS_PREFIX}" --recursive
        ;;
        
    "help"|"-h"|"--help")
        echo "Usage: $0 <command> [args]"
        echo ""
        echo "Commands:"
        echo "  all                            Sync all default models"
        echo "  model <repo_id> [revision]     Sync specific model"
        echo "  gguf <repo_id> <filename>      Sync specific GGUF file"
        echo "  list                           List models in S3"
        echo ""
        echo "Examples:"
        echo "  $0 all"
        echo "  $0 model microsoft/phi-2"
        echo "  $0 gguf TheBloke/Llama-2-7B-GGUF llama-2-7b.Q4_K_M.gguf"
        echo ""
        echo "Environment Variables:"
        echo "  HF_TOKEN              HuggingFace token (required)"
        echo "  S3_ACCESS_KEY_ID      S3 access key"
        echo "  S3_SECRET_ACCESS_KEY  S3 secret key"
        echo "  S3_BUCKET             S3 bucket name"
        echo "  MODELS_PREFIX         S3 prefix for models (default: models/)"
        echo "  HF_CACHE_DIR          Local cache directory"
        ;;
        
    *)
        echo "Unknown command: $1"
        echo "Run '$0 help' for usage"
        exit 1
        ;;
esac

echo ""
echo "Done!"