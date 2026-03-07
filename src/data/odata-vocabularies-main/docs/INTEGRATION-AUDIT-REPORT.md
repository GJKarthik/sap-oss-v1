# OData Vocabularies Bidirectional Integration Audit

## Executive Summary

**Audit Date**: February 26, 2026  
**Anchor Service**: `odata-vocabularies-main` (port 9150)  
**Status**: ✅ **WELL INTEGRATED** with minor gaps

The OData Vocabularies service serves as the **Universal Dictionary** for the SAP OSS platform, providing:
- Vocabulary definitions (19 XML vocabularies, 398 terms)
- Semantic search via embeddings
- GDPR classification via PersonalData vocabulary
- Annotation suggestions for all data models
- Mangle reasoning facts

---

## Integration Summary Matrix

| Service | Port | Direction | Status | Integration Type |
|---------|------|-----------|--------|------------------|
| mangle-query-service | - | → OData | ✅ Complete | MCP calls, RAG enrichment |
| ai-core-streaming | 9100 | ↔ OData | ✅ Complete | Mesh registry, routing |
| langchain-hana | 9140 | → OData | ⚠️ Partial | Registry only |
| elasticsearch | 9130 | ↔ OData | ✅ Complete | Index mapping, search |
| cap-llm-plugin | 9120 | → OData | ⚠️ Partial | OData V4 path |
| generative-ai-toolkit | 9145 | → OData | ⚠️ Minimal | Not direct |
| data-cleaning-copilot | 9155 | → OData | ⚠️ Minimal | Not direct |
| ui5-webcomponents-ngx | 9160 | ← OData | ⚠️ Partial | UI vocabulary |
| world-monitor | 9170 | → OData | ✅ Good | Service registry |
| vllm | 9180 | ↔ OData | ⚠️ Minimal | Vocabulary tokenizer only |
| ai-core-pal | 9190 | → OData | ⚠️ Missing | Not integrated |
| ai-sdk-js | 9110 | → OData | ⚠️ Missing | Not integrated |

---

## Detailed Integration Analysis

### 1. mangle-query-service (✅ FULLY INTEGRATED)

**Integration Points:**

| File | Integration | Description |
|------|-------------|-------------|
| `rules/rag_enrichment.mg` | MCP calls | `mcp_call("odata-vocabularies", "semantic_search", ...)` |
| `rules/rag_enrichment.mg` | Context enrichment | `get_vocabulary_context(EntityType, Context)` |
| `rules/analytics_routing.mg` | Extensional facts | Vocabulary facts loaded at runtime |
| `rules/governance.mg` | PersonalData vocab | GDPR compliance rules |

**Key Predicates:**
```mangle
mcp_call("odata-vocabularies", "semantic_search", {"query": Query}, Results)
mcp_call("odata-vocabularies", "suggest_annotations", {...}, Suggestions)
get_vocabulary_context(EntityType, VocabContext)
semantic_term_match(Query, Term, Vocabulary, Similarity)
```

**Verdict**: ✅ **Complete bidirectional integration**

---

### 2. ai-core-streaming (✅ FULLY INTEGRATED)

**Integration Points:**

| File | Integration | Description |
|------|-------------|-------------|
| `mesh/registry.yaml` | Service registry | `odata-vocabularies` listed with capabilities |
| `mesh/routing_rules.mg` | Routing | `service_routing("odata-vocabularies", "aicore-default")` |
| `mesh/governance_rules.mg` | Autonomy | `service_autonomy("odata-vocabularies", "L3")` |
| `openai/router.py` | Model routing | Routes to `odata-vocabularies` backend |

**Registry Entry:**
```yaml
- id: "odata-vocabularies"
  name: "OData Vocabularies"
  capabilities:
    - "vocabulary-lookup"
    - "annotation-generation"
```

**Verdict**: ✅ **Complete - central mesh integration**

---

### 3. elasticsearch-main (✅ FULLY INTEGRATED)

**Integration Points:**

| Component | Integration | Description |
|-----------|-------------|-------------|
| Connector | `create_vocabulary_index()` | Vocabulary-specific ES index |
| Mapping | `vocabulary_analyzer` | Custom synonym filter |
| Fields | `vocabulary`, `vocabulary_context` | Vocabulary-aware fields |
| Tests | `test_index_vocabulary_term()` | Term indexing tests |

**Index Mapping Features:**
```python
- vocabulary_analyzer with synonym filter
- Fields: vocabulary, namespace, qualified_name
- GDPR classification nested object
```

**Verdict**: ✅ **Complete - vocabulary-optimized search**

---

### 4. world-monitor-main (✅ GOOD INTEGRATION)

**Integration Points:**

| File | Integration | Description |
|------|-------------|-------------|
| `mangle/a2a/mcp.mg` | Service registry | `service_registry("odata-vocab", ...)` |

**Registry Entry:**
```mangle
service_registry("odata-vocab", "http://localhost:9150/mcp", "odata").
```

**Verdict**: ✅ **Good - can invoke vocabulary services**

---

### 5. cap-llm-plugin (⚠️ PARTIAL)

**Integration Points:**

| File | Integration | Description |
|------|-------------|-------------|
| `docs/api/openapi.yaml` | OData path | `/odata/v4/cap-llm-plugin` |

**Gap Analysis:**
- Uses OData V4 protocol for API design
- Missing: Direct vocabulary lookup integration
- Missing: Annotation suggestion usage
- Missing: Service registry entry for odata-vocab

**Verdict**: ⚠️ **Partial - OData protocol only, no vocabulary integration**

---

### 6. langchain-integration-for-sap-hana-cloud (⚠️ PARTIAL)

**Integration Points:**

| File | Integration | Description |
|------|-------------|-------------|
| `mangle/a2a/mcp.mg` | Registry reference | Likely references odata-vocab |

**Gap Analysis:**
- HANA vector store could use vocabulary embeddings
- Missing: Vocabulary term embedding integration
- Missing: Semantic search delegation

**Verdict**: ⚠️ **Partial - should leverage vocabulary embeddings**

---

### 7. generative-ai-toolkit-for-sap-hana-cloud (⚠️ MINIMAL)

**Gap Analysis:**
- No direct vocabulary integration found
- Missing: PersonalData classification for HANA entities
- Missing: Annotation suggestions for HANA artifacts

**Verdict**: ⚠️ **Minimal - needs vocabulary integration**

---

### 8. data-cleaning-copilot (⚠️ MINIMAL)

**Gap Analysis:**
- No direct vocabulary integration found
- Missing: GDPR classification during data cleaning
- Missing: Field semantic classification

**Verdict**: ⚠️ **Minimal - should use PersonalData vocabulary**

---

### 9. ui5-webcomponents-ngx (⚠️ PARTIAL)

**Integration Points:**

| Expected | Status | Notes |
|----------|--------|-------|
| UI vocabulary | ⚠️ Not found | Should use UI.* terms |
| Component annotations | ⚠️ Missing | Could use @UI.DataField |

**Gap Analysis:**
- Should be primary consumer of UI vocabulary
- Missing: @UI.LineItem integration
- Missing: @UI.FieldGroup integration

**Verdict**: ⚠️ **Partial - prime candidate for UI vocabulary**

---

### 10. vllm-main (⚠️ MINIMAL)

**Integration Points:**

| Component | Integration | Description |
|-----------|-------------|-------------|
| Tokenizer | vocabulary variable | Internal tokenizer vocab |

**Gap Analysis:**
- `vocabulary` references are tokenizer-related, not OData
- Missing: Vocabulary-aware model selection
- Could benefit from vocabulary embeddings for semantic understanding

**Verdict**: ⚠️ **Minimal - different vocabulary concept**

---

### 11. ai-core-pal (⚠️ MISSING)

**Gap Analysis:**
- No vocabulary integration found
- Missing: PAL procedure annotation mapping
- Missing: Analytics vocabulary for KPIs

**Verdict**: ❌ **Missing - needs Analytics vocabulary integration**

---

### 12. ai-sdk-js (⚠️ MISSING)

**Gap Analysis:**
- No vocabulary integration found
- Missing: TypeScript type generation from vocabulary
- Missing: SDK method annotations

**Verdict**: ❌ **Missing - could benefit from vocabulary types**

---

## Integration Flow Diagram

```
                    ┌─────────────────────────────┐
                    │   OData Vocabularies        │
                    │   (Universal Dictionary)    │
                    │   Port: 9150                │
                    └─────────────┬───────────────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
        ▼                         ▼                         ▼
┌───────────────┐     ┌───────────────────┐     ┌───────────────┐
│ mangle-query  │◄────│  ai-core-streaming│────►│  elasticsearch│
│ (RAG enrichment)    │  (mesh routing)   │     │  (index mapping)
└───────────────┘     └───────────────────┘     └───────────────┘
        │                         │                         │
        ▼                         ▼                         ▼
┌───────────────┐     ┌───────────────────┐     ┌───────────────┐
│ world-monitor │     │  cap-llm-plugin   │     │ ui5-ngx       │
│ (registry)    │     │  (OData V4 path)  │     │ (UI vocab)    │
└───────────────┘     └───────────────────┘     └───────────────┘
        │                                                   │
        └─────────────────────┬─────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────────────┐
        │                     │                             │
        ▼                     ▼                             ▼
┌───────────────┐     ┌───────────────────┐     ┌───────────────┐
│ langchain-hana│     │ generative-ai-hana│     │ data-cleaning │
│ (partial)     │     │ (minimal)         │     │ (minimal)     │
└───────────────┘     └───────────────────┘     └───────────────┘
        │                                                   │
        └─────────────────────┬─────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────────────┐
        │                     │                             │
        ▼                     ▼                             ▼
┌───────────────┐     ┌───────────────────┐     ┌───────────────┐
│ vllm          │     │ ai-core-pal       │     │ ai-sdk-js     │
│ (minimal)     │     │ (missing)         │     │ (missing)     │
└───────────────┘     └───────────────────┘     └───────────────┘
```

---

## Vocabulary Usage by Category

### UI Vocabulary Users

| Service | Terms Used | Status |
|---------|------------|--------|
| ui5-webcomponents-ngx | @UI.LineItem, @UI.HeaderInfo | ⚠️ Should use |
| cap-llm-plugin | @UI.SelectionFields | ⚠️ Could use |
| mangle-query-service | All UI terms | ✅ Uses |

### Analytics Vocabulary Users

| Service | Terms Used | Status |
|---------|------------|--------|
| ai-core-pal | @Analytics.Measure | ⚠️ Should use |
| generative-ai-toolkit | @Analytics.Dimension | ⚠️ Could use |
| mangle-query-service | All Analytics terms | ✅ Uses |

### PersonalData Vocabulary Users

| Service | Terms Used | Status |
|---------|------------|--------|
| data-cleaning-copilot | @PersonalData.* | ⚠️ Should use |
| langchain-hana | @PersonalData.IsPotentiallySensitive | ⚠️ Could use |
| mangle-query-service | All PersonalData terms | ✅ Uses |

### HANACloud Vocabulary Users

| Service | Terms Used | Status |
|---------|------------|--------|
| langchain-hana | @HANACloud.* | ⚠️ Should use |
| generative-ai-toolkit | @HANACloud.VectorStore | ⚠️ Should use |

---

## Recommendations

### Priority 1: Missing Integrations

1. **ai-core-pal**
   - Add Analytics vocabulary for KPI annotations
   - Add HANACloud vocabulary for PAL procedures
   - Register in mesh with vocabulary capability

2. **ai-sdk-js**
   - Generate TypeScript types from vocabulary terms
   - Add vocabulary lookup methods to SDK
   - Document annotation usage patterns

### Priority 2: Enhance Partial Integrations

3. **cap-llm-plugin**
   - Add service registry entry for odata-vocab
   - Use suggest_annotations tool for entity design
   - Leverage PersonalData for GDPR compliance

4. **langchain-hana**
   - Integrate vocabulary embeddings with HANA vector store
   - Use HANACloud vocabulary for HANA-specific features
   - Add vocabulary context to RAG pipeline

5. **ui5-webcomponents-ngx**
   - Map UI vocabulary to component annotations
   - Use @UI.DataField for form generation
   - Leverage @UI.LineItem for table components

### Priority 3: Deepen Existing Integrations

6. **generative-ai-toolkit**
   - Add PersonalData classification
   - Use Analytics vocabulary for KPI definitions
   - Integrate annotation validation

7. **data-cleaning-copilot**
   - Add PersonalData vocabulary classification
   - Flag sensitive fields during cleaning
   - Generate GDPR audit reports

---

## Integration Patterns to Implement

### Pattern 1: MCP Call Integration
```mangle
mcp_call("odata-vocabularies", "semantic_search", {"query": Query}, Results).
mcp_call("odata-vocabularies", "suggest_annotations", {...}, Suggestions).
```

### Pattern 2: Service Registry
```mangle
service_registry("odata-vocab", "http://localhost:9150/mcp", "vocabulary-engine").
```

### Pattern 3: Mesh Registration
```yaml
- id: "service-name"
  dependencies:
    - "odata-vocabularies"
  vocabulary_capabilities:
    - "annotation-lookup"
```

### Pattern 4: Embedding Integration
```python
from odata_vocabularies.openai import create_embedding
embedding = create_embedding(input="UI.LineItem", model="text-embedding-odata")
```

---

## Conclusion

The OData Vocabularies service is **well-positioned as the Universal Dictionary** with:

- ✅ **4 fully integrated services** (mangle-query, ai-core-streaming, elasticsearch, world-monitor)
- ⚠️ **4 partially integrated services** (cap-llm, langchain-hana, ui5-ngx, vllm)
- ❌ **4 services needing integration** (ai-core-pal, ai-sdk-js, generative-ai-toolkit, data-cleaning)

**Next Steps:**
1. Add missing service registry entries
2. Implement vocabulary capability in missing services
3. Document integration patterns in service READMEs
4. Add integration tests for bidirectional communication