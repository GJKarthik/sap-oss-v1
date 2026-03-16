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

check_env "S3_ACCESS_KEY_ID"
check_env "S3_SECRET_ACCESS_KEY"
check_env "S3_BUCKET"

# Mirror the model-store S3 env names into the AWS CLI env names expected by
# `aws s3` so the script works with a single set of credentials.
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-$S3_ACCESS_KEY_ID}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-$S3_SECRET_ACCESS_KEY}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${S3_REGION:-us-east-1}}"
export AWS_REGION="${AWS_REGION:-$AWS_DEFAULT_REGION}"

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
    shift 2
    local include_patterns=("$@")
    local output_dir="$HF_CACHE_DIR/$repo_id"
    
    echo "Downloading $repo_id (revision: $revision)..."
    
    # Use huggingface-cli if available, otherwise use curl
    if command -v huggingface-cli &> /dev/null; then
        local cmd=(huggingface-cli download "$repo_id" --revision "$revision" --local-dir "$output_dir")
        if [ -n "${HF_TOKEN:-}" ]; then
            cmd+=(--token "$HF_TOKEN")
        fi
        if [ ${#include_patterns[@]} -gt 0 ]; then
            for pattern in "${include_patterns[@]}"; do
                cmd+=(--include "$pattern")
            done
        fi
        "${cmd[@]}"
    else
        if [ ${#include_patterns[@]} -gt 0 ]; then
            mkdir -p "$output_dir"
            local api_url="https://huggingface.co/api/models/$repo_id?blobs=1"
            local hf_headers=()
            if [ -n "${HF_TOKEN:-}" ]; then
                hf_headers=(-H "Authorization: Bearer $HF_TOKEN")
            fi

            local repo_files=()
            while IFS= read -r repo_file; do
                repo_files+=("$repo_file")
            done < <(curl -L --fail --silent "${hf_headers[@]}" "$api_url" | jq -r '.siblings[].rfilename')

            for repo_file in "${repo_files[@]}"; do
                local matched=0
                for pattern in "${include_patterns[@]}"; do
                    case "$repo_file" in
                        $pattern)
                            matched=1
                            break
                            ;;
                    esac
                done

                if [ "$matched" -eq 1 ]; then
                    local local_path="$output_dir/$repo_file"
                    mkdir -p "$(dirname "$local_path")"
                    local file_url="https://huggingface.co/$repo_id/resolve/$revision/$repo_file"
                    curl -L --fail --retry 3 "${hf_headers[@]}" -o "$local_path" "$file_url"
                fi
            done
        else
            if [ ! -d "$output_dir" ]; then
                GIT_LFS_SKIP_SMUDGE=1 git clone "https://huggingface.co/$repo_id" "$output_dir"
            fi
            cd "$output_dir"
            git lfs pull
            git lfs checkout
            cd -
        fi
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

    local curl_args=(-L "https://huggingface.co/$repo_id/resolve/main/$filename" -o "$output_file")
    if [ -n "${HF_TOKEN:-}" ]; then
        curl_args=(-L -H "Authorization: Bearer $HF_TOKEN" "https://huggingface.co/$repo_id/resolve/main/$filename" -o "$output_file")
    fi

    curl "${curl_args[@]}"
    
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
    shift 2
    local s3_prefix="${MODELS_PREFIX}${repo_id}/${revision}/"
    
    echo ""
    echo "========================================"
    echo "Syncing: $repo_id"
    echo "========================================"
    
    # Download from HuggingFace
    download_hf_model "$repo_id" "$revision" "$@"
    
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
            echo "Usage: $0 model <repo_id> [revision] [pattern ...]"
            exit 1
        fi
        sync_model "$2" "${3:-main}" "${@:4}"
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
        echo "  model <repo_id> [revision] [pattern ...]"
        echo "                                 Sync specific model, optionally filtering files"
        echo "  gguf <repo_id> <filename>      Sync specific GGUF file"
        echo "  list                           List models in S3"
        echo ""
        echo "Examples:"
        echo "  $0 all"
        echo "  $0 model microsoft/phi-2"
        echo "  $0 model Qwen/Qwen3.5-0.8B main config.json tokenizer.json model.safetensors"
        echo "  $0 gguf TheBloke/Llama-2-7B-GGUF llama-2-7b.Q4_K_M.gguf"
        echo ""
        echo "Environment Variables:"
        echo "  HF_TOKEN              HuggingFace token (optional for public repos)"
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
