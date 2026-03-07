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
MODE="${HIPPOCPP_BACKEND_MODE:-auto}"
cleanup_db_root=false
if [[ -n "${DB_ROOT:-}" ]]; then
  DB_ROOT="$DB_ROOT"
else
  DB_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hippocpp-native-db-XXXXXX")"
  cleanup_db_root=true
fi
PYTHON_BIN="${HIPPOCPP_PYTHON_BIN:-python3}"

mkdir -p "$DB_ROOT"
if [[ "$cleanup_db_root" == true ]]; then
  trap 'rm -rf "$DB_ROOT"' EXIT
fi

if [[ -z "${HIPPOCPP_PYTHON_BIN:-}" && -x "$HIPPO_DIR/.parity-venv/bin/python" ]]; then
  PYTHON_BIN="$HIPPO_DIR/.parity-venv/bin/python"
fi

# Ensure the in-repo HippoCPP Python package is importable.
if [[ -n "${PYTHONPATH:-}" ]]; then
  export PYTHONPATH="$HIPPO_DIR/python:$HIPPO_DIR:$PYTHONPATH"
else
  export PYTHONPATH="$HIPPO_DIR/python:$HIPPO_DIR"
fi

is_module_importable() {
  local module_name="$1"
  "$PYTHON_BIN" - "$module_name" <<'PY'
import importlib.util
import sys

module = sys.argv[1]
sys.exit(0 if importlib.util.find_spec(module) is not None else 1)
PY
}

case "$MODE" in
  auto)
    native_module="${HIPPOCPP_PY_MODULE:-hippocpp}"
    if is_module_importable "$native_module"; then
      module="$native_module"
      echo "[hippocpp-backend] auto mode selected native module: $module" >&2
    else
      module="${HIPPOCPP_UPSTREAM_PY_MODULE:-kuzu}"
      echo "[hippocpp-backend] auto mode falling back to upstream module: $module" >&2
    fi
    ;;
  upstream-kuzu)
    # Operational parity mode: HippoCPP delegates execution to mirrored Kuzu backend.
    module="${HIPPOCPP_UPSTREAM_PY_MODULE:-kuzu}"
    ;;
  native-python)
    # Native mode once a HippoCPP Python module exists.
    module="${HIPPOCPP_PY_MODULE:-hippocpp}"
    ;;
  *)
    echo "error: unsupported HIPPOCPP_BACKEND_MODE '$MODE'." >&2
    echo "supported modes: auto, upstream-kuzu, native-python" >&2
    exit 2
    ;;
esac

cmd=(
  "$PYTHON_BIN"
  "$SCRIPT_DIR/run_query_corpus.py"
  --module
  "$module"
  --corpus
  "$CORPUS_PATH"
  --db-root
  "$DB_ROOT"
)

if [[ -n "$OUT_PATH" ]]; then
  cmd+=(--output "$OUT_PATH")
fi

exec "${cmd[@]}"
