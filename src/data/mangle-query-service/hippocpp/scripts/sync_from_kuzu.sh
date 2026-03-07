#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIPPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$HIPPO_DIR/.." && pwd)"
KUZU_DIR="${1:-"$ROOT_DIR/kuzu"}"
TARGET_DIR="$HIPPO_DIR/upstream/kuzu"

if [[ ! -d "$KUZU_DIR" ]]; then
  echo "error: kuzu directory does not exist: $KUZU_DIR" >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"

rsync -a --delete \
  --exclude '.git/' \
  --exclude 'build/' \
  "$KUZU_DIR/" "$TARGET_DIR/"

echo "synced kuzu -> $TARGET_DIR"
"$SCRIPT_DIR/parity_check.sh" "$KUZU_DIR"
