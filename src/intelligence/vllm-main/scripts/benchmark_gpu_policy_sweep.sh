#!/usr/bin/env bash
# benchmark_gpu_policy_sweep.sh
# Sweep PRIVATELLM_GPU_PREFILL_MIN_TOKENS and report latency + tokens/sec.
#
# This script starts the Zig openai-gateway separately for each threshold value
# so the model dispatch policy is re-read from environment variables.
#
# Example:
#   ./benchmark_gpu_policy_sweep.sh \
#     --gguf-path /absolute/path/model.gguf \
#     --sweep 16,32,64,96,128,192,256 \
#     --runs 4 \
#     --max-tokens 48

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ZIG_DIR="$PROJECT_DIR/zig"

# Defaults
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8080}"
ENDPOINT_PATH="${ENDPOINT_PATH:-/v1/toon/chat/completions}"
MODEL_NAME="${MODEL_NAME:-tiny}"
MAX_TOKENS="${MAX_TOKENS:-48}"
RUNS="${RUNS:-3}"
WARMUP_RUNS="${WARMUP_RUNS:-1}"
SWEEP_VALUES="${SWEEP_VALUES:-16,32,64,96,128,192,256}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-120}"
START_TIMEOUT_SECS="${START_TIMEOUT_SECS:-60}"
GPU_POLICY="${GPU_POLICY:-adaptive}"
DECODE_MIN_BATCH="${DECODE_MIN_BATCH:-4}"
POLICY_LOG="${POLICY_LOG:-0}"
ALLOW_PROXY_FALLBACK="${ALLOW_PROXY_FALLBACK:-0}"
PROMPT_REPEAT="${PROMPT_REPEAT:-40}"
PROMPT_TEXT="${PROMPT_TEXT:-}"
GGUF_PATH="${GGUF_PATH:-}"
GATEWAY_BIN_REL="${GATEWAY_BIN_REL:-./zig-out/bin/openai-gateway}"
LOG_DIR="${LOG_DIR:-${TMPDIR:-/tmp}/privatellm-policy-bench}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_help() {
    cat <<'EOF'
Usage:
  benchmark_gpu_policy_sweep.sh --gguf-path /abs/path/model.gguf [options]

Options:
  --gguf-path PATH         GGUF model path (or set GGUF_PATH env)
  --sweep CSV              Thresholds for PRIVATELLM_GPU_PREFILL_MIN_TOKENS (default: 16,32,64,96,128,192,256)
  --runs N                 Measured requests per threshold (default: 3)
  --warmup N               Warmup requests per threshold (default: 1)
  --max-tokens N           max_tokens for each request (default: 48)
  --model NAME             OpenAI model name in request payload (default: tiny)
  --host HOST              Gateway host (default: 127.0.0.1)
  --port PORT              Gateway port (default: 8080)
  --endpoint-path PATH     Endpoint path (default: /v1/toon/chat/completions)
  --gpu-policy MODE        adaptive|cpu|gpu (default: adaptive)
  --decode-min-batch N     PRIVATELLM_GPU_DECODE_MIN_BATCH (default: 4)
  --policy-log 0|1         PRIVATELLM_GPU_POLICY_LOG (default: 0)
  --allow-proxy-fallback   Do not fail if TOON direct engine is unavailable
  --prompt TEXT            Explicit benchmark prompt (default: auto-generated long prompt)
  --prompt-repeat N        Repetitions for generated prompt (default: 40)
  --gateway-bin RELPATH    Gateway binary relative to zig dir (default: ./zig-out/bin/openai-gateway)
  --request-timeout SEC    curl timeout seconds (default: 120)
  --start-timeout SEC      Server start timeout seconds (default: 60)
  --log-dir PATH           Directory for per-threshold gateway logs
  --help                   Show help

Environment overrides:
  GGUF_PATH, HOST, PORT, SWEEP_VALUES, RUNS, WARMUP_RUNS, MAX_TOKENS,
  MODEL_NAME, GPU_POLICY, DECODE_MIN_BATCH, POLICY_LOG, ALLOW_PROXY_FALLBACK,
  PROMPT_TEXT.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gguf-path)
            GGUF_PATH="$2"
            shift 2
            ;;
        --sweep)
            SWEEP_VALUES="$2"
            shift 2
            ;;
        --runs)
            RUNS="$2"
            shift 2
            ;;
        --warmup)
            WARMUP_RUNS="$2"
            shift 2
            ;;
        --max-tokens)
            MAX_TOKENS="$2"
            shift 2
            ;;
        --model)
            MODEL_NAME="$2"
            shift 2
            ;;
        --host)
            HOST="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --endpoint-path)
            ENDPOINT_PATH="$2"
            shift 2
            ;;
        --gpu-policy)
            GPU_POLICY="$2"
            shift 2
            ;;
        --decode-min-batch)
            DECODE_MIN_BATCH="$2"
            shift 2
            ;;
        --policy-log)
            POLICY_LOG="$2"
            shift 2
            ;;
        --allow-proxy-fallback)
            ALLOW_PROXY_FALLBACK=1
            shift 1
            ;;
        --prompt)
            PROMPT_TEXT="$2"
            shift 2
            ;;
        --prompt-repeat)
            PROMPT_REPEAT="$2"
            shift 2
            ;;
        --gateway-bin)
            GATEWAY_BIN_REL="$2"
            shift 2
            ;;
        --request-timeout)
            REQUEST_TIMEOUT="$2"
            shift 2
            ;;
        --start-timeout)
            START_TIMEOUT_SECS="$2"
            shift 2
            ;;
        --log-dir)
            LOG_DIR="$2"
            shift 2
            ;;
        --help)
            print_help
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}" >&2
            print_help
            exit 1
            ;;
    esac
done

if [[ -z "$GGUF_PATH" ]]; then
    echo -e "${RED}GGUF path is required. Use --gguf-path or GGUF_PATH env.${NC}" >&2
    exit 1
fi

if [[ ! -f "$GGUF_PATH" ]]; then
    echo -e "${RED}GGUF file not found: $GGUF_PATH${NC}" >&2
    exit 1
fi

for cmd in curl awk sed grep; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}Missing required command: $cmd${NC}" >&2
        exit 1
    fi
done

mkdir -p "$LOG_DIR"

ENDPOINT_URL="http://${HOST}:${PORT}${ENDPOINT_PATH}"
HEALTH_URL="http://${HOST}:${PORT}/health"
GPU_INFO_URL="http://${HOST}:${PORT}/api/gpu/info"
GATEWAY_BIN="$ZIG_DIR/${GATEWAY_BIN_REL#./}"

if [[ ! -x "$GATEWAY_BIN" ]]; then
    echo -e "${YELLOW}Gateway binary not found, building with zig build...${NC}"
    (cd "$ZIG_DIR" && zig build >/dev/null)
fi

if [[ ! -x "$GATEWAY_BIN" ]]; then
    echo -e "${RED}Gateway binary not executable: $GATEWAY_BIN${NC}" >&2
    exit 1
fi

json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

build_prompt() {
    if [[ -n "$PROMPT_TEXT" ]]; then
        printf '%s' "$PROMPT_TEXT"
        return
    fi

    local chunk
    local out=""
    chunk="Explain Apple Silicon unified-memory tradeoffs for LLM inference, compare AMX vs GPU dispatch overhead, and discuss when prefill should use GPU while decode should stay on CPU."
    for ((i = 0; i < PROMPT_REPEAT; i++)); do
        out+="$chunk "
    done
    printf '%s' "$out"
}

extract_int_field() {
    local response="$1"
    local field="$2"
    printf '%s' "$response" \
        | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p" \
        | head -1
}

GATEWAY_PID=""

stop_gateway() {
    if [[ -n "${GATEWAY_PID}" ]] && kill -0 "${GATEWAY_PID}" >/dev/null 2>&1; then
        kill "${GATEWAY_PID}" >/dev/null 2>&1 || true
        wait "${GATEWAY_PID}" 2>/dev/null || true
    fi
    GATEWAY_PID=""
}

cleanup() {
    stop_gateway
}

trap cleanup EXIT INT TERM

wait_for_health() {
    local timeout="$1"
    for ((i = 0; i < timeout; i++)); do
        if curl -sS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

validate_direct_toon_mode() {
    local log_file="$1"
    if [[ "$ALLOW_PROXY_FALLBACK" == "1" ]]; then
        return 0
    fi

    local gpu_info
    gpu_info="$(curl -sS --max-time 5 "$GPU_INFO_URL" || true)"
    if [[ "$gpu_info" != *"\"toon_engine_ready\": true"* ]]; then
        echo -e "${RED}TOON direct engine is not ready; aborting benchmark to avoid proxy-only timings.${NC}" >&2
        echo -e "${YELLOW}Tip: this usually means GGUF load failed (e.g. unsupported quantization).${NC}" >&2
        if [[ -n "$gpu_info" ]]; then
            echo -e "${YELLOW}/api/gpu/info:${NC} $gpu_info" >&2
        fi
        echo -e "${YELLOW}Recent gateway log:${NC}" >&2
        tail -n 40 "$log_file" >&2 || true
        exit 2
    fi
}

if curl -sS --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
    echo -e "${RED}A gateway already appears to be running on ${HOST}:${PORT}. Stop it first.${NC}" >&2
    exit 1
fi

PROMPT_RAW="$(build_prompt)"
PROMPT_ESCAPED="$(json_escape "$PROMPT_RAW")"

IFS=',' read -r -a THRESHOLDS <<<"$SWEEP_VALUES"
if [[ ${#THRESHOLDS[@]} -eq 0 ]]; then
    echo -e "${RED}No sweep values provided.${NC}" >&2
    exit 1
fi

RESULTS_FILE="$(mktemp "${LOG_DIR}/results.XXXXXX.tsv")"
trap 'cleanup; rm -f "$RESULTS_FILE"' EXIT INT TERM

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}GPU Policy Sweep (Prefill Threshold)${NC}"
echo -e "${CYAN}============================================================${NC}"
echo "GGUF_PATH: $GGUF_PATH"
echo "Gateway:   $GATEWAY_BIN"
echo "Endpoint:  $ENDPOINT_URL"
echo "Policy:    $GPU_POLICY"
echo "Sweep:     $SWEEP_VALUES"
echo "Runs:      $RUNS (warmup: $WARMUP_RUNS)"
echo "MaxTokens: $MAX_TOKENS"
echo ""

for threshold in "${THRESHOLDS[@]}"; do
    threshold="$(echo "$threshold" | xargs)"
    if [[ -z "$threshold" ]]; then
        continue
    fi

    echo -e "${BLUE}--- threshold=${threshold} ---${NC}"
    LOG_FILE="${LOG_DIR}/gateway_prefill_${threshold}.log"
    : >"$LOG_FILE"

    (
        cd "$ZIG_DIR"
        export GGUF_PATH="$GGUF_PATH"
        export HOST="$HOST"
        export PORT="$PORT"
        export PRIVATELLM_GPU_POLICY="$GPU_POLICY"
        export PRIVATELLM_GPU_PREFILL_MIN_TOKENS="$threshold"
        export PRIVATELLM_GPU_DECODE_MIN_BATCH="$DECODE_MIN_BATCH"
        export PRIVATELLM_GPU_POLICY_LOG="$POLICY_LOG"
        "$GATEWAY_BIN"
    ) >>"$LOG_FILE" 2>&1 &
    GATEWAY_PID=$!

    if ! wait_for_health "$START_TIMEOUT_SECS"; then
        echo -e "${RED}Gateway failed to become healthy for threshold=${threshold}${NC}" >&2
        tail -n 40 "$LOG_FILE" >&2 || true
        exit 1
    fi

    validate_direct_toon_mode "$LOG_FILE"

    sum_ns=0
    sum_completion=0
    sum_prompt=0
    success_count=0

    total_requests=$((WARMUP_RUNS + RUNS))
    for ((r = 1; r <= total_requests; r++)); do
        payload="{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"${PROMPT_ESCAPED}\"}],\"max_tokens\":${MAX_TOKENS},\"stream\":false}"

        start_ns="$(date +%s%N)"
        raw="$(curl -sS --max-time "$REQUEST_TIMEOUT" -w '\n%{http_code}' \
            -X POST "$ENDPOINT_URL" \
            -H "Content-Type: application/json" \
            -d "$payload")"
        end_ns="$(date +%s%N)"

        http_code="${raw##*$'\n'}"
        response="${raw%$'\n'*}"
        elapsed_ns=$((end_ns - start_ns))

        if [[ "$http_code" != "200" ]]; then
            echo -e "${RED}Request failed (HTTP ${http_code}) at threshold=${threshold}${NC}" >&2
            printf '%s\n' "$response" >&2
            exit 1
        fi

        completion_tokens="$(extract_int_field "$response" "completion_tokens")"
        prompt_tokens="$(extract_int_field "$response" "prompt_tokens")"

        if [[ -z "$completion_tokens" ]]; then
            completion_tokens="$MAX_TOKENS"
        fi
        if [[ -z "$prompt_tokens" ]]; then
            prompt_tokens=0
        fi

        if ((r <= WARMUP_RUNS)); then
            echo "  warmup #$r done (${elapsed_ns} ns)"
            continue
        fi

        success_count=$((success_count + 1))
        sum_ns=$((sum_ns + elapsed_ns))
        sum_completion=$((sum_completion + completion_tokens))
        sum_prompt=$((sum_prompt + prompt_tokens))
        echo "  run #$((r - WARMUP_RUNS)): ${elapsed_ns} ns, completion_tokens=${completion_tokens}, prompt_tokens=${prompt_tokens}"
    done

    if ((success_count == 0)); then
        echo -e "${RED}No successful benchmark runs for threshold=${threshold}${NC}" >&2
        exit 1
    fi

    avg_latency_ms="$(awk -v ns="$sum_ns" -v n="$success_count" 'BEGIN { printf "%.2f", (ns / 1000000.0) / n }')"
    avg_prompt_tokens="$(awk -v t="$sum_prompt" -v n="$success_count" 'BEGIN { printf "%.2f", t / n }')"
    avg_completion_tokens="$(awk -v t="$sum_completion" -v n="$success_count" 'BEGIN { printf "%.2f", t / n }')"
    tps="$(awk -v tok="$sum_completion" -v ns="$sum_ns" 'BEGIN { if (ns <= 0) printf "0.00"; else printf "%.2f", tok / (ns / 1000000000.0) }')"

    printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$threshold" "$avg_latency_ms" "$tps" "$avg_prompt_tokens" "$avg_completion_tokens" "$LOG_FILE" \
        >>"$RESULTS_FILE"

    stop_gateway
done

echo ""
echo -e "${CYAN}Results (sorted by tokens/sec):${NC}"
printf "%-12s %-16s %-14s %-16s %-18s\n" \
    "Threshold" "AvgLatencyMs" "TokensPerSec" "AvgPromptTok" "AvgCompletionTok"
echo "--------------------------------------------------------------------------------"

sort -t$'\t' -k3,3nr "$RESULTS_FILE" | while IFS=$'\t' read -r th lat tps ptk ctk logfile; do
    printf "%-12s %-16s %-14s %-16s %-18s\n" "$th" "$lat" "$tps" "$ptk" "$ctk"
done

best_line="$(sort -t$'\t' -k3,3nr "$RESULTS_FILE" | head -1)"
best_th="$(printf '%s' "$best_line" | cut -f1)"
best_lat="$(printf '%s' "$best_line" | cut -f2)"
best_tps="$(printf '%s' "$best_line" | cut -f3)"
best_log="$(printf '%s' "$best_line" | cut -f6)"

echo ""
echo -e "${GREEN}Best threshold: ${best_th}${NC}"
echo "  tokens/sec: $best_tps"
echo "  avg latency ms: $best_lat"
echo "  log: $best_log"
echo ""
echo "Recommended env:"
echo "  export PRIVATELLM_GPU_POLICY=$GPU_POLICY"
echo "  export PRIVATELLM_GPU_PREFILL_MIN_TOKENS=$best_th"
echo "  export PRIVATELLM_GPU_DECODE_MIN_BATCH=$DECODE_MIN_BATCH"
