#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIPPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$HIPPO_DIR/.." && pwd)"
KUZU_DIR="${KUZU_DIR:-"$ROOT_DIR/kuzu"}"
BASELINE_FILE="${BASELINE_FILE:-"$HIPPO_DIR/parity/baseline.json"}"
SUMMARY_FILE="${SUMMARY_FILE:-"$HIPPO_DIR/PARITY-SUMMARY.json"}"
CORPUS_FILE="${HIPPOCPP_DIFF_CORPUS:-"$HIPPO_DIR/parity/corpus/smoke.json"}"
DIFF_OUTPUT="${DIFF_OUTPUT:-"$HIPPO_DIR/PARITY-DIFF.json"}"
LEFT_CMD_DEFAULT="bash $SCRIPT_DIR/run_backend_kuzu.sh {corpus}"
RIGHT_CMD_DEFAULT="bash $SCRIPT_DIR/run_backend_hippocpp.sh {corpus}"

# Semantic parity gate should run the HippoCPP module directly by default.
: "${HIPPOCPP_BACKEND_MODE:=native-python}"
export HIPPOCPP_BACKEND_MODE

echo "[parity] generating parity matrix + summary"
"$SCRIPT_DIR/parity_check.sh" "$KUZU_DIR"

echo "[parity] evaluating baseline thresholds"
python3 "$SCRIPT_DIR/parity_gate.py" \
  --summary "$SUMMARY_FILE" \
  --baseline "$BASELINE_FILE" \
  --zig-src "$HIPPO_DIR/zig/src"

LEFT_CMD="${HIPPOCPP_DIFF_LEFT_CMD:-$LEFT_CMD_DEFAULT}"
RIGHT_CMD="${HIPPOCPP_DIFF_RIGHT_CMD:-$RIGHT_CMD_DEFAULT}"
ENABLE_DIFF="${HIPPOCPP_ENABLE_DIFF:-1}"

if [[ "$ENABLE_DIFF" == "1" ]]; then
  echo "[parity] running differential harness"
  python3 "$SCRIPT_DIR/differential_harness.py" \
    --left-name "${HIPPOCPP_DIFF_LEFT_NAME:-kuzu}" \
    --right-name "${HIPPOCPP_DIFF_RIGHT_NAME:-hippocpp}" \
    --left-cmd "$LEFT_CMD" \
    --right-cmd "$RIGHT_CMD" \
    --corpus "$CORPUS_FILE" \
    --output "$DIFF_OUTPUT"
else
  echo "[parity] skipping differential harness (HIPPOCPP_ENABLE_DIFF=0)"
fi
