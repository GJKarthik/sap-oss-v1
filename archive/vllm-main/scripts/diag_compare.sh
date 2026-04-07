#!/bin/bash
# diag_compare.sh — Build & run both llama.cpp and our Zig diagnostic, then diff
#
# Usage: ./diag_compare.sh [model_path] [token_id]
#
set -euo pipefail

MODEL="${1:-/root/models/qwen35/Qwen3.5-0.8B-Q4_0.gguf}"
TOKEN="${2:-9707}"  # "Hello" in Qwen tokenizer

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLLM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ZIG_DIR="$PLLM_DIR/zig"
DIAG_DIR="/tmp/pllm_diag"
LLAMA_DIR="/root/llama.cpp"
LLAMA_BUILD="$LLAMA_DIR/build_cuda/bin"

mkdir -p "$DIAG_DIR"

echo "===== Step 1: Build llama.cpp diagnostic ====="
gcc -O2 -o "$DIAG_DIR/diag_llama_dump" "$SCRIPT_DIR/diag_llama_dump.c" \
    -I"$LLAMA_DIR/include" -I"$LLAMA_DIR/ggml/include" \
    -L"$LLAMA_BUILD" \
    -lllama -lggml -lggml-base -lggml-cuda -lggml-cpu \
    -lstdc++ -lm -lpthread -lcuda -lcudart \
    -Wl,-rpath,"$LLAMA_BUILD"
echo "  -> Built $DIAG_DIR/diag_llama_dump"

echo ""
echo "===== Step 2: Run llama.cpp diagnostic ====="
LD_LIBRARY_PATH="$LLAMA_BUILD" \
    "$DIAG_DIR/diag_llama_dump" "$MODEL" "$TOKEN" 2>&1 | tee "$DIAG_DIR/llama_out.txt"

echo ""
echo "===== Step 3: Build Zig inference (GPU mode) ====="
cd "$ZIG_DIR"
if zig build -Dgpu=true 2>&1 | tee "$DIAG_DIR/zig_build.txt" | tail -5; then
    echo "  -> Zig build OK"
else
    echo "  -> Zig build had errors (may be link-time only, checking binary...)"
fi

ZIG_BIN="$ZIG_DIR/zig-out/bin/openai-gateway"
if [ ! -f "$ZIG_BIN" ]; then
    # Try the standalone forward pass test binary if gateway didn't link
    ZIG_BIN="$ZIG_DIR/zig-out/bin/cuda-forward-test"
    if [ ! -f "$ZIG_BIN" ]; then
        echo "ERROR: No binary built. Check $DIAG_DIR/zig_build.txt"
        echo "  Falling back to llama.cpp-only output."
        echo ""
        echo "===== llama.cpp Layer-0 Intermediates ====="
        grep "LLAMA_DIAG" "$DIAG_DIR/llama_out.txt" | grep -E "\-0\]|embed|logits|argmax"
        exit 0
    fi
fi

echo ""
echo "===== Step 4: Run Zig inference with diagnostics ====="
# Run single-token inference; the [DIAG] lines are printed to stderr
PLLM_MODEL="$MODEL" PLLM_TOKEN="$TOKEN" PLLM_DEBUG_LAYERS=1 \
    "$ZIG_BIN" 2>&1 | tee "$DIAG_DIR/zig_out.txt"

echo ""
echo "===== Step 5: Side-by-side comparison ====="
echo ""

# Extract and align the diagnostics
grep "LLAMA_DIAG" "$DIAG_DIR/llama_out.txt" | grep -E "\-0\]|embed|logits|argmax" \
    > "$DIAG_DIR/llama_vals.txt" || true
grep "\[DIAG\]" "$DIAG_DIR/zig_out.txt" \
    > "$DIAG_DIR/zig_vals.txt" || true

# Mapping table: llama.cpp tensor name → our DIAG label
declare -A MAP=(
    ["attn_norm-0"]="L0 norm_in"
    ["linear_attn_qkv_mixed-0"]="L0 qkv_proj"
    ["conv_output_silu-0"]="L0 conv1d+silu"
    ["q_conv-0"]="L0 Q_pre_l2"
    ["k_conv-0"]="L0 K_pre_l2"
    ["v_conv-0"]="L0 V"
    ["q_conv_predelta-0"]="L0 Q_l2norm"
    ["k_conv_predelta-0"]="L0 K_l2norm"
    ["z-0"]="L0 gate_proj"
    ["alpha-0"]="L0 alpha_raw"
    ["beta-0"]="L0 beta_raw"
    ["attn_output-0"]="L0 y_recur"
    ["final_output-0"]="L0 y_gated"
    ["linear_attn_out-0"]="L0 out_proj"
)

printf "%-30s  %-60s  %-60s\n" "CHECKPOINT" "LLAMA.CPP" "ZIG (OURS)"
printf "%-30s  %-60s  %-60s\n" "----------" "---------" "----------"

for llama_name in "${!MAP[@]}"; do
    zig_name="${MAP[$llama_name]}"
    llama_vals=$(grep "$llama_name" "$DIAG_DIR/llama_vals.txt" 2>/dev/null | head -1 | sed 's/.*\]: //' || echo "N/A")
    zig_vals=$(grep "$zig_name" "$DIAG_DIR/zig_vals.txt" 2>/dev/null | head -1 | sed 's/.*: //' || echo "N/A")
    printf "%-30s  %-60s  %-60s\n" "$llama_name" "$llama_vals" "$zig_vals"
done

echo ""
echo "===== Logits comparison ====="
echo "llama.cpp: $(grep 'logits' "$DIAG_DIR/llama_out.txt" | head -1)"
echo "zig:       $(grep 'logits\|argmax' "$DIAG_DIR/zig_out.txt" | head -1)"

echo ""
echo "Full output saved to: $DIAG_DIR/"
echo "  llama_out.txt  — llama.cpp raw output"
echo "  zig_out.txt    — Zig raw output"

