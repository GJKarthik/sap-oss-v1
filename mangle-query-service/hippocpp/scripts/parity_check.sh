#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HIPPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$HIPPO_DIR/.." && pwd)"
KUZU_DIR="${1:-"$ROOT_DIR/kuzu"}"
OUT_FILE="${OUT_FILE:-"$HIPPO_DIR/PARITY-MATRIX.md"}"
OUT_JSON="${OUT_JSON:-"$HIPPO_DIR/PARITY-SUMMARY.json"}"

if [[ ! -d "$KUZU_DIR/src" ]]; then
  echo "error: kuzu source directory not found at: $KUZU_DIR/src" >&2
  exit 1
fi

if [[ ! -d "$HIPPO_DIR/zig/src" ]]; then
  echo "error: hippocpp Zig source directory not found at: $HIPPO_DIR/zig/src" >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

pct() {
  awk -v n="$1" -v d="$2" 'BEGIN { if (d == 0) { printf "0.0" } else { printf "%.1f", (n / d) * 100 } }'
}

find "$KUZU_DIR/src" -type f -name '*.cpp' | \
  sed "s#^$KUZU_DIR/src/##; s#\\.cpp\$##" | sort > "$tmp_dir/kuzu_cpp_stems.txt"
find "$HIPPO_DIR/zig/src" -type f -name '*.zig' | \
  sed "s#^$HIPPO_DIR/zig/src/##; s#\\.zig\$##" | sort > "$tmp_dir/hippo_zig_stems.txt"

comm -12 "$tmp_dir/kuzu_cpp_stems.txt" "$tmp_dir/hippo_zig_stems.txt" > "$tmp_dir/exact_matches.txt"
comm -23 "$tmp_dir/kuzu_cpp_stems.txt" "$tmp_dir/hippo_zig_stems.txt" > "$tmp_dir/kuzu_only.txt"
comm -13 "$tmp_dir/kuzu_cpp_stems.txt" "$tmp_dir/hippo_zig_stems.txt" > "$tmp_dir/hippo_only.txt"

{
  awk -F/ '{print $1}' "$tmp_dir/kuzu_cpp_stems.txt"
  awk -F/ '{print $1}' "$tmp_dir/hippo_zig_stems.txt"
} | sort -u > "$tmp_dir/modules.txt"

kuzu_total="$(wc -l < "$tmp_dir/kuzu_cpp_stems.txt" | tr -d ' ')"
hippo_total="$(wc -l < "$tmp_dir/hippo_zig_stems.txt" | tr -d ' ')"
exact_total="$(wc -l < "$tmp_dir/exact_matches.txt" | tr -d ' ')"
kuzu_only_total="$(wc -l < "$tmp_dir/kuzu_only.txt" | tr -d ' ')"
hippo_only_total="$(wc -l < "$tmp_dir/hippo_only.txt" | tr -d ' ')"

if [[ -d "$HIPPO_DIR/upstream/kuzu" ]]; then
  mirror_diffs_file="$tmp_dir/mirror_diffs.txt"
  if diff -rq "$HIPPO_DIR/upstream/kuzu" "$KUZU_DIR" > "$mirror_diffs_file"; then
    mirror_status="PASS"
    mirror_detail="hippocpp/upstream/kuzu is byte-for-byte identical to kuzu."
  else
    mirror_status="FAIL"
    mirror_diff_count="$(wc -l < "$mirror_diffs_file" | tr -d ' ')"
    mirror_detail="hippocpp/upstream/kuzu differs from kuzu in ${mirror_diff_count} paths."
  fi
else
  mirror_status="MISSING"
  mirror_detail="hippocpp/upstream/kuzu does not exist yet. Run ./scripts/sync_from_kuzu.sh."
fi

{
  echo "# HippoCPP Parity Matrix"
  echo
  echo "Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
  echo
  echo "## Snapshot"
  echo
  echo "- Kuzu source: \`$KUZU_DIR\`"
  echo "- HippoCPP source: \`$HIPPO_DIR\`"
  echo "- Upstream mirror parity: **$mirror_status**"
  echo "- Mirror detail: $mirror_detail"
  echo
  echo "## Zig Conversion Coverage"
  echo
  echo "- Kuzu implementation files (\`.cpp\`): **$kuzu_total**"
  echo "- HippoCPP Zig implementation files (\`.zig\`): **$hippo_total**"
  echo "- Exact relative path matches: **$exact_total** ($(pct "$exact_total" "$kuzu_total")%)"
  echo "- Kuzu-only paths: **$kuzu_only_total**"
  echo "- HippoCPP-only paths: **$hippo_only_total**"
  echo
  echo "## Module Matrix"
  echo
  echo "| Module | Kuzu C++ | HippoCPP Zig | Delta (Zig-C++) | Exact path matches | Match % |"
  echo "|---|---:|---:|---:|---:|---:|"
  while IFS= read -r module; do
    kuzu_module_count="$(awk -F/ -v m="$module" '$1==m{c++} END{print c+0}' "$tmp_dir/kuzu_cpp_stems.txt")"
    hippo_module_count="$(awk -F/ -v m="$module" '$1==m{c++} END{print c+0}' "$tmp_dir/hippo_zig_stems.txt")"
    module_matches="$(comm -12 \
      <(awk -F/ -v m="$module" '$1==m{print}' "$tmp_dir/kuzu_cpp_stems.txt" | sort) \
      <(awk -F/ -v m="$module" '$1==m{print}' "$tmp_dir/hippo_zig_stems.txt" | sort) | wc -l | tr -d ' ')"
    if [[ "$kuzu_module_count" -gt 0 ]]; then
      module_match_pct="$(pct "$module_matches" "$kuzu_module_count")"
    else
      module_match_pct="n/a"
    fi
    delta=$((hippo_module_count - kuzu_module_count))
    echo "| \`$module\` | $kuzu_module_count | $hippo_module_count | $delta | $module_matches | $module_match_pct |"
  done < "$tmp_dir/modules.txt"
  echo
  echo "## Kuzu-Only Gaps By Module"
  echo
  echo '```text'
  awk -F/ '{print $1}' "$tmp_dir/kuzu_only.txt" | sort | uniq -c | sort -nr
  echo '```'
  echo
  echo "## Sample Missing Kuzu Paths (first 120)"
  echo
  echo '```text'
  head -n 120 "$tmp_dir/kuzu_only.txt"
  echo '```'
} > "$OUT_FILE"

{
  echo "{"
  echo "  \"generated_utc\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\","
  echo "  \"kuzu_dir\": \"$KUZU_DIR\","
  echo "  \"hippocpp_dir\": \"$HIPPO_DIR\","
  echo "  \"mirror_status\": \"$mirror_status\","
  echo "  \"kuzu_cpp_total\": $kuzu_total,"
  echo "  \"hippocpp_zig_total\": $hippo_total,"
  echo "  \"exact_match_total\": $exact_total,"
  echo "  \"kuzu_only_total\": $kuzu_only_total,"
  echo "  \"hippocpp_only_total\": $hippo_only_total"
  echo "}"
} > "$OUT_JSON"

echo "wrote parity report: $OUT_FILE"
echo "wrote parity summary: $OUT_JSON"
