# OData Vocabularies MCP Tools - Detailed Test Results

**Service URL:** https://odata-vocab.c-9323c0b.kyma.ondemand.com  
**Namespace:** kube-scb  
**Image:** docker.io/gjkarthik/odata-vocab:v3.0.0

---

## Tool 1: `list_vocabularies`

### Purpose
Returns all available SAP OData vocabularies with comprehensive metadata.

### Use Case
Discover what annotation vocabularies are available when starting a new CAP/Fiori project. Essential for understanding the annotation landscape.

### Request
```bash
curl -X POST https://odata-vocab.c-9323c0b.kyma.ondemand.com/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer CHANGE_ME_GENERATE_SECURE_TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_vocabularies","arguments":{}}}'
```

### Response (Sample)
```json
{
  "vocabularies": [
    {
      "name": "Common",
      "namespace": "com.sap.vocabularies.Common.v1",
      "alias": "Common",
      "term_count": 108,
      "stable_terms": 78,
      "experimental_terms": 27,
      "deprecated_terms": 3,
      "complex_types": 24,
      "enum_types": 4
    },
    {
      "name": "UI",
      "namespace": "com.sap.vocabularies.UI.v1",
      "alias": "UI",
      "term_count": 60,
      "stable_terms": 46,
      "experimental_terms": 14,
      "deprecated_terms": 0,
      "complex_types": 55,
      "enum_types": 15
    }
  ],
  "count": 19
}
```

### Explanation
- **19 SAP OData vocabularies** are loaded
- Each vocabulary shows term counts split by stability (stable vs experimental)
- **Common** (108 terms) - General-purpose annotations like Label, Text, ValueList
- **UI** (60 terms) - Fiori/UI5 specific annotations like LineItem, HeaderInfo, SelectionFields

---

## Tool 3: `search_terms`

### Purpose
Search across ALL vocabularies for terms matching a query string.

### Use Case
Find the right annotation for a concept. E.g., "How do I annotate a table?" → search for "LineItem"

### Request
```bash
curl -X POST https://odata-vocab.c-9323c0b.kyma.ondemand.com/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer CHANGE_ME_GENERATE_SECURE_TOKEN" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_terms","arguments":{"query":"LineItem"}}}'
```

### Response
```json
{
  "query": "lineitem",
  "results": [
    {
      "vocabulary": "UI",
      "term": "LineItem",
      "type": "Collection(UI.DataFieldAbstract)",
      "description": "Collection of data fields for representation in a table or list",
      "namespace": "com.sap.vocabularies.UI.v1",
      "full_name": "com.sap.vocabularies.UI.v1.LineItem",
      "applies_to": ["EntityType"],
      "experimental": false,
      "deprecated": false
    }
  ],
  "count": 1
}
```

### Explanation
- **Case-insensitive search** ("LineItem" finds "lineitem")
- Returns **full metadata** for each match
- **applies_to** tells you WHERE to use the annotation (EntityType, Property, etc.)
- **experimental/deprecated** flags help you choose stable APIs

---

## Tool 4: `get_term`

### Purpose
Get complete details for a specific term including all properties and constraints.

### Use Case
Deep-dive into a term to understand its structure before writing annotations.

### Request
```bash
curl -X POST https://odata-vocab.c-9323c0b.kyma.ondemand.com/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer CHANGE_ME_GENERATE_SECURE_TOKEN" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_term","arguments":{"vocabulary":"UI","term":"LineItem"}}}'
```

### Response
```json
{
  "vocabulary": "UI",
  "namespace": "com.sap.vocabularies.UI.v1",
  "name": "LineItem",
  "type": "Collection(UI.DataFieldAbstract)",
  "nullable": false,
  "applies_to": ["EntityType"],
  "default_value": null,
  "base_term": null,
  "description": "Collection of data fields for representation in a table or list",
  "long_description": "",
  "experimental": false,
  "deprecated": false,
  "is_instance_annotation": false,
  "requires_type": "",
  "full_name": "com.sap.vocabularies.UI.v1.LineItem"
}
```

### Explanation
- **type**: `Collection(UI.DataFieldAbstract)` means it's an array of DataField items
- **nullable: false** means the annotation value is required
- **applies_to: EntityType** means you use this on entity types, not properties
- Use this to understand how to structure your annotation value

---

## Tool 6: `get_mangle_facts`

### Purpose
Export vocabulary knowledge as Prolog-style facts for reasoning/knowledge graph.

### Use Case
- Feed to a Datalog/Prolog engine for logical inference
- Build relationship graphs between vocabularies
- Power semantic queries about annotation relationships

### Request
```bash
curl -X POST https://odata-vocab.c-9323c0b.kyma.ondemand.com/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer CHANGE_ME_GENERATE_SECURE_TOKEN" \
  -d '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_mangle_facts","arguments":{"predicate":"term"}}}'
```

### Response (Sample)
```prolog
vocabulary("Graph", "com.sap.vocabularies.Graph.v1").
term("Graph", "traceId", "Edm.String", "The traceId contains a unique string...").
term_experimental("Graph", "traceId").
term("UI", "HeaderInfo", "UI.HeaderInfoType", "Information for the header area...").
term_applies_to("UI", "HeaderInfo", "EntityType").
term("UI", "LineItem", "Collection(UI.DataFieldAbstract)", "Collection of data fields...").
term_applies_to("UI", "LineItem", "EntityType").
complex_type("Graph", "DetailsType").
type_property("Graph", "DetailsType", "url", "Edm.String").
```

### Explanation
- **1479 total facts** available
- Facts represent: vocabularies, terms, applies_to relationships, complex types, properties
- Can query: "What terms apply to Property?" → `term_applies_to(_, _, "Property")`
- Powers the Mangle knowledge graph for semantic queries

---

## Tool 12: `get_statistics`

### Purpose
Get aggregate statistics about all loaded vocabularies.

### Use Case
Dashboard/monitoring, understanding vocabulary coverage, planning annotation strategy.

### Request
```bash
curl -X POST https://odata-vocab.c-9323c0b.kyma.ondemand.com/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer CHANGE_ME_GENERATE_SECURE_TOKEN" \
  -d '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"get_statistics","arguments":{}}}'
```

### Response
```json
{
  "vocabularies": 19,
  "total_terms": 242,
  "total_complex_types": 125,
  "total_enum_types": 31,
  "mangle_facts": 1479,
  "entity_configs": 10,
  "embeddings_loaded": 0,
  "vocabulary_details": {
    "UI": {
      "namespace": "com.sap.vocabularies.UI.v1",
      "terms": 60,
      "experimental": 14,
      "deprecated": 0,
      "complex_types": 55,
      "enum_types": 15
    },
    "Common": {
      "namespace": "com.sap.vocabularies.Common.v1",
      "terms": 108,
      "experimental": 27,
      "deprecated": 3,
      "complex_types": 24,
      "enum_types": 4
    }
  }
}
```

### Explanation
- **19 vocabularies** with **242 terms** total
- **125 complex types** (structured annotation values like HeaderInfoType)
- **31 enum types** (constrained values like CriticalityType)
- **1479 mangle facts** for knowledge graph queries
- Per-vocabulary breakdown shows which are most feature-rich

---

## Summary Table

| Tool | Working | Key Output |
|------|---------|------------|
| `list_vocabularies` | ✅ | 19 vocabularies with term counts |
| `search_terms` | ✅ | Full-text search across all terms |
| `get_term` | ✅ | Detailed term metadata |
| `get_mangle_facts` | ✅ | 1479 Prolog facts for reasoning |
| `get_statistics` | ✅ | Aggregate counts and breakdown |

## Tools Needing Configuration

| Tool | Status | Requirement |
|------|--------|-------------|
| `semantic_search` | ⚠️ | Needs AI Core embedding service |
| `get_rag_context` | ⚠️ | Needs vector embeddings |
| `kuzu_index` | ⚠️ | Needs Kuzu graph database |

---

## Quick Test Commands

```bash
# Health check
curl https://odata-vocab.c-9323c0b.kyma.ondemand.com/health

# Stats
curl https://odata-vocab.c-9323c0b.kyma.ondemand.com/stats

# MCP tools list
curl -X POST https://odata-vocab.c-9323c0b.kyma.ondemand.com/mcp \
  -H "Authorization: Bearer CHANGE_ME_GENERATE_SECURE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'