#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/mojo/build}"
SRC_FILE="$ROOT_DIR/mojo/src/ffi_exports.mojo"

if ! command -v mojo >/dev/null 2>&1; then
  echo "[mojo-build] mojo CLI not found in PATH"
  exit 2
fi

case "$(uname -s)" in
  Darwin)
    LIB_NAME="libaiverify_mojo_ffi.dylib"
    ;;
  MINGW*|MSYS*|CYGWIN*|Windows_NT)
    LIB_NAME="aiverify_mojo_ffi.dll"
    ;;
  *)
    LIB_NAME="libaiverify_mojo_ffi.so"
    ;;
esac

mkdir -p "$OUT_DIR"
OUT_LIB="$OUT_DIR/$LIB_NAME"

echo "[mojo-build] Using mojo: $(mojo --version)"
echo "[mojo-build] Building shared library from $SRC_FILE"
mojo build --emit shared-lib -o "$OUT_LIB" "$SRC_FILE"

if [ ! -f "$OUT_LIB" ]; then
  echo "[mojo-build] Expected output not found: $OUT_LIB"
  exit 1
fi

echo "[mojo-build] Built Mojo FFI library: $OUT_LIB"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "mojo_ffi_lib=$OUT_LIB" >> "$GITHUB_OUTPUT"
fi

echo "$OUT_LIB"
