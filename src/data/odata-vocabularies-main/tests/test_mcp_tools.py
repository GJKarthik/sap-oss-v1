#!/usr/bin/env python3
"""
Comprehensive MCP tool tests for OData Vocabularies MCP Server.
Tests all 14 tools against the live Kyma deployment.
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error
from datetime import datetime, timezone

# ── Config ────────────────────────────────────────────────────────────────────
MCP_URL   = os.getenv("MCP_URL",   "https://odata-vocab.c-054c570.kyma.ondemand.com/mcp")
MCP_TOKEN = os.getenv("MCP_AUTH_TOKEN", "")

if not MCP_TOKEN:
    env_file = os.path.join(os.path.dirname(__file__), "..", ".env")
    if os.path.exists(env_file):
        for line in open(env_file):
            line = line.strip()
            if line.startswith("MCP_AUTH_TOKEN="):
                MCP_TOKEN = line.split("=", 1)[1]
            elif line.startswith("MCP_URL="):
                MCP_URL = line.split("=", 1)[1]

# ── Helpers ───────────────────────────────────────────────────────────────────
_req_id = 0

def call(method: str, params: dict = None) -> dict:
    global _req_id
    _req_id += 1
    payload = json.dumps({
        "jsonrpc": "2.0",
        "id": _req_id,
        "method": method,
        "params": params or {},
    }).encode()
    req = urllib.request.Request(
        MCP_URL,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {MCP_TOKEN}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())

def tool_call(name: str, args: dict = None) -> dict:
    return call("tools/call", {"name": name, "arguments": args or {}})

# ── Test runner ───────────────────────────────────────────────────────────────
results = []

def run(test_name: str, tool: str, args: dict, validator=None):
    start = time.time()
    status = "PASS"
    error  = None
    response = None
    try:
        response = tool_call(tool, args)
        if "error" in response:
            status = "FAIL"
            error  = response["error"]
        elif validator:
            ok, msg = validator(response)
            if not ok:
                status = "FAIL"
                error  = msg
    except Exception as exc:
        status = "ERROR"
        error  = str(exc)
    elapsed = round((time.time() - start) * 1000)
    results.append({
        "test":     test_name,
        "tool":     tool,
        "args":     args,
        "status":   status,
        "error":    error,
        "elapsed_ms": elapsed,
        "response": response,
    })
    icon = "✅" if status == "PASS" else "❌"
    print(f"  {icon} [{elapsed:4d}ms] {test_name}")
    if error:
        print(f"         ERROR: {error}")
    return response

# ── Validators ────────────────────────────────────────────────────────────────
def has_content(resp):
    content = resp.get("result", {}).get("content", [])
    if not content:
        return False, "empty content"
    text = content[0].get("text", "")
    if not text:
        return False, "empty text"
    return True, None

def json_content(resp):
    ok, msg = has_content(resp)
    if not ok:
        return ok, msg
    text = resp["result"]["content"][0]["text"]
    try:
        json.loads(text)
        return True, None
    except Exception as e:
        return False, f"not valid JSON: {e}"

def contains_key(key):
    def v(resp):
        ok, msg = has_content(resp)
        if not ok:
            return ok, msg
        text = resp["result"]["content"][0]["text"]
        if key.lower() not in text.lower():
            return False, f"expected '{key}' in response"
        return True, None
    return v

# ── Tests ─────────────────────────────────────────────────────────────────────
print(f"\n{'='*60}")
print(f"OData Vocabularies MCP — Tool Test Suite")
print(f"Endpoint : {MCP_URL}")
print(f"Started  : {datetime.now(timezone.utc).isoformat()}")
print(f"{'='*60}\n")

# 1. list_vocabularies
print("1. list_vocabularies")
run("List all vocabularies",
    "list_vocabularies", {},
    lambda r: (len(r.get("result",{}).get("content",[])) > 0
               and "Common" in r["result"]["content"][0]["text"],
               "expected Common vocabulary"))

# 2. get_vocabulary
print("\n2. get_vocabulary")
run("Get Common vocabulary",
    "get_vocabulary", {"name": "Common"},
    contains_key("Label"))

run("Get UI vocabulary",
    "get_vocabulary", {"name": "UI"},
    contains_key("LineItem"))

run("Get unknown vocabulary (error expected)",
    "get_vocabulary", {"name": "NonExistentVocab"},
    lambda r: (True, None))  # any response is acceptable

# 3. search_terms
print("\n3. search_terms")
run("Search for 'filter'",
    "search_terms", {"query": "filter"},
    contains_key("Filter"))

run("Search for 'navigation'",
    "search_terms", {"query": "navigation"},
    has_content)

run("Search with vocabulary filter",
    "search_terms", {"query": "label", "vocabulary": "UI"},
    has_content)

# 4. get_term
print("\n4. get_term")
run("Get Common.Label term",
    "get_term", {"vocabulary": "Common", "term": "Label"},
    contains_key("Label"))

run("Get UI.LineItem term",
    "get_term", {"vocabulary": "UI", "term": "LineItem"},
    has_content)

# 5. extract_entities
print("\n5. extract_entities")
run("Extract entities from NL query",
    "extract_entities", {"query": "Show me all sales orders with their line items and customer details"},
    has_content)

run("Extract entities — simple query",
    "extract_entities", {"query": "List products with price and category"},
    has_content)

# 6. get_vocabulary_facts
print("\n6. get_vocabulary_facts")
run("Get Capabilities vocabulary facts",
    "get_vocabulary_facts", {"vocabulary": "Capabilities"},
    has_content)

run("Get Core vocabulary facts",
    "get_vocabulary_facts", {"vocabulary": "Core"},
    has_content)

# 7. validate_annotations
print("\n7. validate_annotations")
run("Validate Common.Label annotation",
    "validate_annotations", {
        "annotations": json.dumps({"@Common.Label": "Sales Order"}),
        "entity": "SalesOrder"
    },
    has_content)

run("Validate UI.LineItem annotation",
    "validate_annotations", {
        "annotations": json.dumps({"@UI.LineItem": [{"$Type": "UI.DataField", "Value": {"$Path": "Name"}}]}),
        "entity": "SalesOrder"
    },
    has_content)

# 8. generate_annotations
print("\n8. generate_annotations")
run("Generate annotations for SalesOrder",
    "generate_annotations", {
        "entity": "SalesOrder",
        "properties": ["ID", "CustomerName", "OrderDate", "TotalAmount", "Status"]
    },
    has_content)

run("Generate annotations for Product",
    "generate_annotations", {
        "entity": "Product",
        "properties": ["ProductID", "Name", "Price", "Category", "Stock"]
    },
    has_content)

# 9. lookup_term (alias for get_term)
print("\n9. lookup_term")
run("Lookup Common.Text term",
    "lookup_term", {"vocabulary": "Common", "term": "Text"},
    has_content)

# 10. convert_annotations
print("\n10. convert_annotations")
run("Convert JSON annotations to XML",
    "convert_annotations", {
        "annotations": {"@UI.LineItem": [{"$Type": "UI.DataField", "Value": {"$Path": "Name"}}]},
        "format": "xml"
    },
    has_content)

run("Convert XML annotations to JSON",
    "convert_annotations", {
        "annotations": '<Annotation Term="UI.LineItem"><Collection><Record Type="UI.DataField"><PropertyValue Property="Value" Path="Name"/></Record></Collection></Annotation>',
        "format": "json"
    },
    has_content)

# 11. get_statistics
print("\n11. get_statistics")
run("Get vocabulary statistics",
    "get_statistics", {},
    lambda r: (
        has_content(r)[0] and "19" in r["result"]["content"][0]["text"],
        "expected 19 vocabularies in stats"
    ))

# 12. semantic_search
print("\n12. semantic_search")
run("Semantic search for 'read-only fields'",
    "semantic_search", {"query": "read-only fields that cannot be modified"},
    has_content)

run("Semantic search for 'pagination'",
    "semantic_search", {"query": "pagination and top skip query options"},
    has_content)

# 13. get_rag_context
print("\n13. get_rag_context")
run("RAG context for filter restrictions",
    "get_rag_context", {"query": "How do I define filter restrictions for an OData entity?"},
    has_content)

run("RAG context for UI annotations",
    "get_rag_context", {"query": "What UI annotations should I use for a list page?"},
    has_content)

# 14. suggest_annotations
print("\n14. suggest_annotations")
run("Suggest annotations for e-commerce product",
    "suggest_annotations", {
        "context": "E-commerce product catalog entity with name, price, category, and stock level",
        "entity": "Product"
    },
    has_content)

run("Suggest annotations for HR employee",
    "suggest_annotations", {
        "context": "HR system employee entity with personal and employment details",
        "entity": "Employee"
    },
    has_content)

# ── Summary ───────────────────────────────────────────────────────────────────
total  = len(results)
passed = sum(1 for r in results if r["status"] == "PASS")
failed = sum(1 for r in results if r["status"] == "FAIL")
errors = sum(1 for r in results if r["status"] == "ERROR")
avg_ms = round(sum(r["elapsed_ms"] for r in results) / total) if total else 0

print(f"\n{'='*60}")
print(f"RESULTS: {passed}/{total} passed  |  {failed} failed  |  {errors} errors")
print(f"Avg latency: {avg_ms}ms")
print(f"{'='*60}\n")

# ── Save results ──────────────────────────────────────────────────────────────
output = {
    "suite":     "OData Vocabularies MCP Tool Tests",
    "endpoint":  MCP_URL,
    "timestamp": datetime.now(timezone.utc).isoformat(),
    "summary": {
        "total":   total,
        "passed":  passed,
        "failed":  failed,
        "errors":  errors,
        "avg_latency_ms": avg_ms,
    },
    "results": results,
}

out_path = os.path.join(os.path.dirname(__file__), "test_results.json")
with open(out_path, "w") as f:
    json.dump(output, f, indent=2, default=str)
print(f"Results saved to: {out_path}")

sys.exit(0 if failed == 0 and errors == 0 else 1)