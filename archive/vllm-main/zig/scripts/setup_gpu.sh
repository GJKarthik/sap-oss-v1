#!/usr/bin/env bash
# setup_gpu.sh — sync, compile PTX, build, and benchmark on a remote GPU server
# Usage: ./setup_gpu.sh <ssh_alias> <sm_arch> [model_glob]
# Example: ./setup_gpu.sh awesome-gpu-name sm_75 "~/models/Qwen3.5-*.gguf"
set -euo pipefail

SSH_ALIAS="${1:?Usage: $0 <ssh_alias> <sm_arch> [model_glob]}"
SM_ARCH="${2:?Usage: $0 <ssh_alias> <sm_arch>}"
MODEL_GLOB="${3:-~/models/Qwen3.5-0.8B-Q4_0.gguf ~/models/Qwen3.5-9B-Q4_0.gguf}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZIG_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SSH_KEY="$HOME/.brev/brev.pem"
SSH_PORT=2222
SSH_OPTS="-i $SSH_KEY -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30"

# L4 and L40S both use port 22 (ubuntu user)
if ssh -o RequestTTY=no $SSH_OPTS "$SSH_ALIAS" "whoami" 2>/dev/null | grep -q ubuntu; then
    SSH_PORT=22
    SSH_OPTS="-i $SSH_KEY -p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30"
fi

do_ssh() {
    ssh -o RequestTTY=no $SSH_OPTS "$SSH_ALIAS" "$@"
}

log() { echo "[${SSH_ALIAS}/${SM_ARCH}] $*"; }

log "=== Step 1: Sync source ==="
rsync -az -e "ssh $SSH_OPTS" \
    "$ZIG_DIR/src/gpu/" \
    "$SSH_ALIAS:~/vllm-main/zig/src/gpu/"
rsync -az -e "ssh $SSH_OPTS" \
    "$ZIG_DIR/src/toon/" \
    "$SSH_ALIAS:~/vllm-main/zig/src/toon/"
rsync -az -e "ssh $SSH_OPTS" \
    "$ZIG_DIR/src/tests/" \
    "$SSH_ALIAS:~/vllm-main/zig/src/tests/"
rsync -az -e "ssh $SSH_OPTS" \
    "$ZIG_DIR/deps/" \
    "$SSH_ALIAS:~/vllm-main/zig/deps/"
rsync -az -e "ssh $SSH_OPTS" \
    "$ZIG_DIR/build.zig" "$ZIG_DIR/build.zig.zon" \
    "$SSH_ALIAS:~/vllm-main/zig/"
log "Sync complete"

log "=== Step 2: Compile PTX for ${SM_ARCH} ==="
do_ssh "nvcc -O3 -arch=${SM_ARCH} -ptx \
    -o ~/vllm-main/zig/src/gpu/deltanet_kernels.ptx \
    ~/vllm-main/zig/src/gpu/deltanet_kernels.cu 2>&1"
log "PTX compiled"

log "=== Step 3: Build ==="
do_ssh "cd ~/vllm-main/zig && zig build install -Dgpu=true -Doptimize=ReleaseFast 2>&1 | tail -5"
log "Build complete"

log "=== Step 4: Benchmark ==="
for model in $MODEL_GLOB; do
    model_name="$(do_ssh "basename $model" 2>/dev/null || echo "$model")"
    echo ""
    echo "--- ${SSH_ALIAS} / ${model_name} ---"
    do_ssh "cd ~/vllm-main/zig && ./zig-out/bin/e2e-bench $model 2>&1 | grep -E 'Prefill|Decode TPS|Per-token|Generated:|forward (OK|fail)|StreamSync|KernelLaunch'" || echo "BENCH FAILED"
done
