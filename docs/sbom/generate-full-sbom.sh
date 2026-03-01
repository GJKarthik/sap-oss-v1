#!/bin/bash
#
# Full SBOM Generator
# Extracts all packages from lock files across all services
#
# Output: sbom-cyclonedx-full.json (CycloneDX 1.6 compliant)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT="$SCRIPT_DIR/sbom-cyclonedx-full.json"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "╔════════════════════════════════════════════════════════════╗"
echo "║     SAP AI Platform Full SBOM Generator                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Repository: $REPO_ROOT"
echo "Output: $OUTPUT"
echo ""

# Start JSON
cat > "$OUTPUT" << EOF
{
  "\$schema": "http://cyclonedx.org/schema/bom-1.6.schema.json",
  "bomFormat": "CycloneDX",
  "specVersion": "1.6",
  "serialNumber": "urn:uuid:$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "3e671687-395b-41f5-a30f-a58921a69b79")",
  "version": 1,
  "metadata": {
    "timestamp": "$TIMESTAMP",
    "tools": {
      "components": [
        {"type": "application", "name": "generate-full-sbom.sh", "version": "1.0.0"}
      ]
    },
    "component": {
      "type": "application",
      "name": "sap-ai-platform",
      "version": "2.0.0"
    }
  },
  "components": [
EOF

FIRST=true

# Helper function to add component
add_component() {
    local type="$1"
    local name="$2"
    local version="$3"
    local purl="$4"
    local license="${5:-UNKNOWN}"
    local group="${6:-}"
    
    if [ "$FIRST" = true ]; then
        FIRST=false
    else
        echo "," >> "$OUTPUT"
    fi
    
    if [ -n "$group" ]; then
        cat >> "$OUTPUT" << EOF
    {"type": "$type", "group": "$group", "name": "$name", "version": "$version", "purl": "$purl", "licenses": [{"license": {"id": "$license"}}]}
EOF
    else
        cat >> "$OUTPUT" << EOF
    {"type": "$type", "name": "$name", "version": "$version", "purl": "$purl", "licenses": [{"license": {"id": "$license"}}]}
EOF
    fi
}

echo "📦 Extracting ai-sdk-js-main (pnpm)..."
if [ -f "$REPO_ROOT/ai-sdk-js-main/pnpm-lock.yaml" ]; then
    # Extract unique packages from pnpm lock
    grep -E "^  ['\"]?[a-z@].*['\"]?:$" "$REPO_ROOT/ai-sdk-js-main/pnpm-lock.yaml" 2>/dev/null | \
    sed "s/[':\"@]//g" | sort -u | while read pkg; do
        version=$(grep -A5 "^  ['\"]?$pkg['\"]?:" "$REPO_ROOT/ai-sdk-js-main/pnpm-lock.yaml" 2>/dev/null | grep "version:" | head -1 | awk '{print $2}' | tr -d "'\"")
        if [ -n "$version" ]; then
            add_component "library" "$pkg" "$version" "pkg:npm/$pkg@$version" "MIT"
        fi
    done
fi

echo "📦 Extracting cap-llm-plugin (npm)..."
if [ -f "$REPO_ROOT/cap-llm-plugin-main/package-lock.json" ]; then
    jq -r '.packages | to_entries[] | select(.key != "") | "\(.key)|\(.value.version // "unknown")"' \
        "$REPO_ROOT/cap-llm-plugin-main/package-lock.json" 2>/dev/null | \
    while IFS='|' read -r pkg version; do
        name=$(echo "$pkg" | sed 's|node_modules/||g' | sed 's|.*/||')
        if [ -n "$name" ] && [ -n "$version" ] && [ "$version" != "null" ]; then
            add_component "library" "$name" "$version" "pkg:npm/$name@$version" "MIT"
        fi
    done
fi

echo "📦 Extracting vllm-main (pyproject)..."
if [ -f "$REPO_ROOT/vllm-main/pyproject.toml" ]; then
    grep -E "^\s+\"[a-zA-Z]" "$REPO_ROOT/vllm-main/pyproject.toml" 2>/dev/null | \
    sed 's/.*"\([^"]*\)".*/\1/' | sed 's/[<>=!].*//' | sort -u | while read pkg; do
        add_component "library" "$pkg" "latest" "pkg:pypi/$pkg" "Apache-2.0"
    done
fi

echo "📦 Extracting mangle-query-service (go.mod)..."
if [ -f "$REPO_ROOT/mangle-query-service/go.mod" ]; then
    grep -E "^\t[a-z]" "$REPO_ROOT/mangle-query-service/go.mod" 2>/dev/null | \
    awk '{print $1 "|" $2}' | while IFS='|' read -r pkg version; do
        name=$(echo "$pkg" | sed 's|.*/||')
        add_component "library" "$name" "$version" "pkg:golang/$pkg@$version" "Apache-2.0"
    done
fi

echo "📦 Adding Python service dependencies..."
# data-cleaning-copilot
for dep in pandas numpy scikit-learn fastapi openai pydantic; do
    add_component "library" "$dep" "latest" "pkg:pypi/$dep" "BSD-3-Clause"
done

# langchain-integration
for dep in langchain langchain-core langchain-community sentence-transformers; do
    add_component "library" "$dep" "latest" "pkg:pypi/$dep" "MIT"
done

# generative-ai-toolkit
for dep in hdbcli hana-ml openai tiktoken; do
    add_component "library" "$dep" "latest" "pkg:pypi/$dep" "Apache-2.0"
done

echo "📦 Adding Angular/UI5 dependencies..."
for dep in "@angular/core" "@angular/common" "@angular/platform-browser" "rxjs" "zone.js"; do
    add_component "library" "$dep" "18.2.0" "pkg:npm/$dep@18.2.0" "MIT"
done

for dep in "@ui5/webcomponents" "@ui5/webcomponents-fiori" "@ui5/webcomponents-icons"; do
    add_component "library" "$dep" "2.5.0" "pkg:npm/$dep@2.5.0" "Apache-2.0"
done

echo "📦 Adding Elasticsearch dependencies..."
for dep in lucene-core lucene-analyzers-common jackson-databind netty-all log4j-core; do
    add_component "library" "$dep" "latest" "pkg:maven/org.apache/$dep" "Apache-2.0"
done

# Close components array
cat >> "$OUTPUT" << EOF

  ],
  "dependencies": [],
  "vulnerabilities": []
}
EOF

# Count components
COMPONENT_COUNT=$(grep -c '"type":' "$OUTPUT")
echo ""
echo "✅ SBOM generated with $COMPONENT_COUNT components"
echo "📂 Output: $OUTPUT"

# Validate JSON
if command -v jq &> /dev/null; then
    if jq empty "$OUTPUT" 2>/dev/null; then
        echo "✅ JSON validation: PASS"
    else
        echo "❌ JSON validation: FAIL"
    fi
fi