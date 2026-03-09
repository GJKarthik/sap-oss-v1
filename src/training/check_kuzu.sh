#!/bin/bash
cd /Users/user/Documents/training-main

echo "=== Command 1: find . -path \"*/upstream/kuzu*\" -type d ==="
find . -path "*/upstream/kuzu*" -type d 2>/dev/null | head -10

echo ""
echo "=== Command 2: find . -name \"kuzu\" -type d ==="
find . -name "kuzu" -type d 2>/dev/null | head -10

echo ""
echo "=== Command 3: ls -la hippocpp/upstream/ ==="
ls -la hippocpp/upstream/ 2>/dev/null

echo ""
echo "=== Command 4: find hippocpp/upstream/kuzu/src -type d | sort | head -40 ==="
find hippocpp/upstream/kuzu/src -type d | sort | head -40

echo ""
echo "=== Command 5: find hippocpp/upstream/kuzu/src -name \"*.cpp\" | wc -l ==="
find hippocpp/upstream/kuzu/src -name "*.cpp" | wc -l

echo ""
echo "=== Command 6: find hippocpp/upstream/kuzu/src -name \"*.h\" -o -name \"*.hpp\" | wc -l ==="
find hippocpp/upstream/kuzu/src -name "*.h" -o -name "*.hpp" | wc -l

echo ""
echo "=== Command 7: ls hippocpp/upstream/kuzu/src/ ==="
ls hippocpp/upstream/kuzu/src/

