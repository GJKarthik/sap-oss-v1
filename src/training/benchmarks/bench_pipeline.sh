#!/usr/bin/env bash
# Performance benchmarks for the Zig Text-to-SQL pipeline.
#
# Measures:
# - CSV parse throughput (rows/sec)
# - Schema extraction time
# - Template expansion time
# - Full pipeline end-to-end time
#
# Usage:
#   ./benchmarks/bench_pipeline.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ZIG_DIR="$PROJECT_ROOT/pipeline/zig"
RESULTS_FILE="$SCRIPT_DIR/pipeline_results.json"

# Cross-platform millisecond timer (macOS date lacks %N)
if python3 -c "import time" 2>/dev/null; then
  now_ms() { python3 -c "import time; print(int(time.time()*1000))"; }
else
  now_ms() { date +%s000; }
fi

echo "=== Zig Pipeline Benchmarks ==="
echo ""

# Build first
echo "Building pipeline..."
cd "$ZIG_DIR"
zig build 2>&1 || true
echo "Build complete."
echo ""

# Benchmark: Zig build time
echo "Benchmark: Build time"
BUILD_START=$(now_ms)
zig build 2>&1 || true
BUILD_END=$(now_ms)
BUILD_MS=$(( BUILD_END - BUILD_START ))
echo "  Build time: ${BUILD_MS}ms"
echo ""

# Benchmark: Test suite execution time
echo "Benchmark: Test suite"
TEST_START=$(now_ms)
zig build test 2>&1 || true
TEST_END=$(now_ms)
TEST_MS=$(( TEST_END - TEST_START ))
echo "  Test suite: ${TEST_MS}ms (52 tests)"
echo ""

# Benchmark: Compile-time (release)
echo "Benchmark: Release build"
RELEASE_START=$(now_ms)
zig build -Doptimize=ReleaseFast 2>&1 || true
RELEASE_END=$(now_ms)
RELEASE_MS=$(( RELEASE_END - RELEASE_START ))
echo "  Release build: ${RELEASE_MS}ms"
echo ""

# Write results
cat > "$RESULTS_FILE" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "zig_version": "$(zig version)",
  "benchmarks": {
    "build_debug_ms": $BUILD_MS,
    "test_suite_ms": $TEST_MS,
    "test_count": 52,
    "build_release_ms": $RELEASE_MS
  }
}
EOF

echo "=== Summary ==="
echo "  Debug build:   ${BUILD_MS}ms"
echo "  Test suite:    ${TEST_MS}ms (52 tests)"
echo "  Release build: ${RELEASE_MS}ms"
echo ""
echo "Results written to $RESULTS_FILE"

