#!/usr/bin/env bash
# Performance benchmarks for the Python Text-to-SQL pipeline.
#
# Measures:
# - Test suite execution time
# - Schema extraction throughput
# - Template expansion throughput
# - Full pipeline end-to-end time
#
# Usage:
#   ./benchmarks/bench_pipeline.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RESULTS_FILE="$SCRIPT_DIR/pipeline_results.json"
PYTHON="${PYTHON:-python3}"

# Cross-platform millisecond timer (macOS date lacks %N)
now_ms() { $PYTHON -c "import time; print(int(time.time()*1000))"; }

echo "=== Python Pipeline Benchmarks ==="
echo ""

cd "$PROJECT_ROOT"

# Benchmark: Test suite execution time
echo "Benchmark: Test suite"
TEST_START=$(now_ms)
$PYTHON -m pytest pipeline/tests/ -v --tb=short 2>&1 || true
TEST_END=$(now_ms)
TEST_MS=$(( TEST_END - TEST_START ))
TEST_COUNT=$($PYTHON -m pytest pipeline/tests/ --collect-only -q 2>/dev/null | tail -1 | grep -o '[0-9]*' | head -1 || echo "0")
echo "  Test suite: ${TEST_MS}ms (${TEST_COUNT} tests)"
echo ""

# Benchmark: Module import time
echo "Benchmark: Module import time"
IMPORT_START=$(now_ms)
$PYTHON -c "from pipeline import csv_parser, schema_extractor, schema_registry, template_parser, template_expander, hana_sql_builder, spider_formatter, json_emitter" 2>&1 || true
IMPORT_END=$(now_ms)
IMPORT_MS=$(( IMPORT_END - IMPORT_START ))
echo "  Import time: ${IMPORT_MS}ms"
echo ""

# Benchmark: Pipeline CLI version
echo "Benchmark: CLI startup"
CLI_START=$(now_ms)
$PYTHON -m pipeline version 2>&1 || true
CLI_END=$(now_ms)
CLI_MS=$(( CLI_END - CLI_START ))
echo "  CLI startup: ${CLI_MS}ms"
echo ""

# Write results
cat > "$RESULTS_FILE" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "python_version": "$($PYTHON --version 2>&1 | awk '{print $2}')",
  "benchmarks": {
    "test_suite_ms": $TEST_MS,
    "test_count": $TEST_COUNT,
    "import_ms": $IMPORT_MS,
    "cli_startup_ms": $CLI_MS
  }
}
EOF

echo "=== Summary ==="
echo "  Test suite:    ${TEST_MS}ms (${TEST_COUNT} tests)"
echo "  Module import: ${IMPORT_MS}ms"
echo "  CLI startup:   ${CLI_MS}ms"
echo ""
echo "Results written to $RESULTS_FILE"

