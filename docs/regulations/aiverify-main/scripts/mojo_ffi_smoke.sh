#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOJO_LIB="${AIVERIFY_MOJO_FFI_LIB:-}"

if [ -z "$MOJO_LIB" ]; then
  echo "[mojo-ffi] AIVERIFY_MOJO_FFI_LIB is not set"
  echo "[mojo-ffi] Example: AIVERIFY_MOJO_FFI_LIB=/abs/path/libaiverify_mojo_ffi.dylib ./scripts/mojo_ffi_smoke.sh"
  exit 2
fi

if [ ! -f "$MOJO_LIB" ]; then
  echo "[mojo-ffi] Shared library not found: $MOJO_LIB"
  exit 2
fi

echo "[mojo-ffi] Building Zig runtime..."
(
  cd "$ROOT_DIR/zig"
  zig build >/dev/null
)

run_zig() {
  (
    cd "$ROOT_DIR/zig"
    AIVERIFY_MOJO_FFI_LIB="$MOJO_LIB" zig build run -- "$@"
  )
}

metrics_output="$(run_zig metrics-gap 0.88 0.81)"
echo "[mojo-ffi] metrics-gap output: $metrics_output"
if ! echo "$metrics_output" | grep -q "source=mojo_ffi"; then
  echo "[mojo-ffi] Expected metrics-gap to use mojo_ffi source"
  exit 1
fi
metrics_canonical="$(echo "$metrics_output" | sed -E 's/ \(source=[^)]+\)//')"
if [ "$metrics_canonical" != "Metric parity gap: 0.0700000000" ]; then
  echo "[mojo-ffi] Unexpected metrics-gap canonical output: $metrics_canonical"
  exit 1
fi

normalize_output="$(run_zig normalize-plugin-gid "AIVERIFY.Stock   Reports ")"
echo "[mojo-ffi] normalize-plugin-gid output: $normalize_output"
if ! echo "$normalize_output" | grep -q "source=mojo_ffi"; then
  echo "[mojo-ffi] Expected normalize-plugin-gid to use mojo_ffi source"
  exit 1
fi
normalize_canonical="$(echo "$normalize_output" | sed -E 's/ \(source=[^)]+\)//')"
if [ "$normalize_canonical" != "Normalized plugin gid: aiverify.stock reports" ]; then
  echo "[mojo-ffi] Unexpected normalize-plugin-gid canonical output: $normalize_canonical"
  exit 1
fi

echo "[mojo-ffi] Running parity smoke checks with Mojo FFI path..."
(
  cd "$ROOT_DIR"
  AIVERIFY_MOJO_FFI_LIB="$MOJO_LIB" ./scripts/parity_smoke.sh metrics-gap
  AIVERIFY_MOJO_FFI_LIB="$MOJO_LIB" ./scripts/parity_smoke.sh normalize-plugin-gid
)

echo "[mojo-ffi] PASS"
