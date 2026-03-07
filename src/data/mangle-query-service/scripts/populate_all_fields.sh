#!/bin/bash
# =============================================================================
# Master Script: Populate All S/4HANA Field Mappings into Elasticsearch
# =============================================================================
# 
# Runs all population scripts in order:
# 1. ACDOCA (I_JournalEntryItem) - Finance Universal Journal
# 2. Master Data (Cost Center, Profit Center, Material, GL Account)
# 3. MM/SD (Purchase Order, Sales Order, Delivery)
#
# Usage: ./populate_all_fields.sh
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ES_ENDPOINT="${ES_ENDPOINT:-http://localhost:9200}"

echo "=============================================================="
echo "OData Vocabularies - Elasticsearch Field Population"
echo "=============================================================="
echo "Elasticsearch endpoint: $ES_ENDPOINT"
echo ""

# Check Elasticsearch is available
echo "Checking Elasticsearch connectivity..."
if curl -s "$ES_ENDPOINT/_cluster/health" > /dev/null 2>&1; then
    echo "✓ Elasticsearch is available"
else
    echo "✗ Elasticsearch is not available at $ES_ENDPOINT"
    echo "  Start Elasticsearch or set ES_ENDPOINT environment variable"
    exit 1
fi

echo ""

# Step 1: ACDOCA fields
echo "=============================================================="
echo "Step 1/3: Populating ACDOCA (I_JournalEntryItem) fields"
echo "=============================================================="
python3 "$SCRIPT_DIR/populate_acdoca_fields.py"

echo ""

# Step 2: Master Data fields
echo "=============================================================="
echo "Step 2/3: Populating Master Data fields"
echo "=============================================================="
python3 "$SCRIPT_DIR/populate_master_data_fields.py"

echo ""

# Step 3: MM/SD fields
echo "=============================================================="
echo "Step 3/3: Populating MM (Procurement) and SD (Sales) fields"
echo "=============================================================="
python3 "$SCRIPT_DIR/populate_mm_sd_fields.py"

echo ""

# Summary
echo "=============================================================="
echo "COMPLETE - Field Population Summary"
echo "=============================================================="

# Count documents
TOTAL=$(curl -s "$ES_ENDPOINT/odata_entity_index/_count" | python3 -c "import json,sys; print(json.load(sys.stdin).get('count', 0))")
echo "Total documents in odata_entity_index: $TOTAL"

# List entities
echo ""
echo "Entities indexed:"
curl -s "$ES_ENDPOINT/odata_entity_index/_search" -H "Content-Type: application/json" -d '{
  "size": 0,
  "aggs": {
    "entities": {
      "terms": {"field": "entity", "size": 100}
    }
  }
}' | python3 -c "
import json, sys
data = json.load(sys.stdin)
buckets = data.get('aggregations', {}).get('entities', {}).get('buckets', [])
for b in buckets:
    print(f\"  {b['key']}: {b['doc_count']} fields\")
"

echo ""
echo "Modules indexed:"
curl -s "$ES_ENDPOINT/odata_entity_index/_search" -H "Content-Type: application/json" -d '{
  "size": 0,
  "aggs": {
    "modules": {
      "terms": {"field": "module", "size": 100}
    }
  }
}' | python3 -c "
import json, sys
data = json.load(sys.stdin)
buckets = data.get('aggregations', {}).get('modules', {}).get('buckets', [])
for b in buckets:
    print(f\"  {b['key']}: {b['doc_count']} fields\")
"

echo ""
echo "=============================================================="
echo "Field population complete!"
echo "=============================================================="