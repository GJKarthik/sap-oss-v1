#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIPPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <corpus-json-path>" >&2
  exit 2
fi

CORPUS_PATH="$1"
OUT_PATH="${2:-}"
DB_ROOT="${DB_ROOT:-"$HIPPO_DIR/.parity-db/kuzu"}"
PYTHON_BIN="${HIPPOCPP_PYTHON_BIN:-python3}"

if [[ -z "${HIPPOCPP_PYTHON_BIN:-}" && -x "$HIPPO_DIR/.parity-venv/bin/python" ]]; then
  PYTHON_BIN="$HIPPO_DIR/.parity-venv/bin/python"
fi

mkdir -p "$DB_ROOT"

cmd=(
  "$PYTHON_BIN"
  "$SCRIPT_DIR/run_query_corpus.py"
  --module
  "${KUZU_PY_MODULE:-kuzu}"
  --corpus
  "$CORPUS_PATH"
  --db-root
  "$DB_ROOT"
)

if [[ -n "$OUT_PATH" ]]; then
  cmd+=(--output "$OUT_PATH")
fi

exec "${cmd[@]}"
