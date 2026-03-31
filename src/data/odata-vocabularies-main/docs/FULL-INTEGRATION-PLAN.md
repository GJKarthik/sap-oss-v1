# OData Vocabularies Full Integration Plan

## Service-by-Service Implementation Guide

**Target**: Full bidirectional integration with OData Vocabularies as Universal Dictionary  
**Timeline**: 4 Sprints (8 weeks)  
**Priority**: Services ordered by integration complexity and business value

---

## Sprint 1: Missing Integrations (Week 1-2)

### 1.1 ai-core-pal (Priority: HIGH)

**Current Status**: ❌ No integration  
**Target**: Full Analytics vocabulary integration

#### Component Changes

| Component | File | Change | LOC |
|-----------|------|--------|-----|
| Mangle A2A | `mangle/a2a/mcp.mg` | Add service registry | +10 |
| Agent | `agent/aicore_pal_agent.py` | Add vocab client | +50 |
| Data Product | `data_products/registry.yaml` | Add dependency | +5 |

#### Detailed Implementation

**1. mangle/a2a/mcp.mg**
```mangle
# Add OData Vocabularies service registry
service_registry("odata-vocab", "http://localhost:9150/mcp", "vocabulary-engine").

# Tool routing for vocabulary operations
tool_service("lookup_kpi_annotation", "odata-vocab").
tool_service("get_analytics_terms", "odata-vocab").

# Vocabulary integration for PAL procedures
pal_vocabulary_mapping(PALFunction, VocabularyTerms) :-
    pal_function(PALFunction),
    mcp_call("odata-vocabularies", "search_terms", 
             {"query": PALFunction, "vocabulary": "Analytics"}, VocabularyTerms).
```

**2. agent/aicore_pal_agent.py**
```python
# Add to imports
from typing import Dict, List

class AiCorePalAgent:
    def __init__(self):
        self.vocab_endpoint = "http://localhost:9150"
        
    async def get_analytics_annotations(self, pal_function: str) -> Dict:
        """Get Analytics vocabulary annotations for PAL function."""
        async with aiohttp.ClientSession() as session:
            async with session.post(
                f"{self.vocab_endpoint}/v1/chat/completions",
                json={
                    "model": "odata-vocab-annotator",
                    "messages": [{
                        "role": "user",
                        "content": f"Suggest Analytics annotations for PAL function: {pal_function}"
                    }]
                }
            ) as resp:
                return await resp.json()
    
    async def annotate_kpi(self, kpi_definition: Dict) -> Dict:
        """Annotate KPI with Analytics.Measure vocabulary."""
        return await self._call_vocab_tool("suggest_annotations", {
            "entity_type": "KPI",
            "properties": kpi_definition.get("properties", []),
            "vocabulary": "Analytics"
        })
```

**3. data_products/registry.yaml**
```yaml
dependencies:
  vocabulary_service:
    endpoint: "http://localhost:9150/mcp"
    capabilities:
      - "annotation-lookup"
      - "analytics-vocabulary"
```

---

### 1.2 ai-sdk-js-main (Priority: HIGH)

**Current Status**: ❌ No integration  
**Target**: TypeScript types from vocabulary + SDK methods

#### Component Changes

| Component | File | Change | LOC |
|-----------|------|--------|-----|
| Mangle A2A | `mangle/a2a/mcp.mg` | Add service registry | +15 |
| MCP Server | `packages/mcp-server/src/server.ts` | Add vocab tools | +100 |
| Types | `packages/types/vocabulary.ts` | NEW: Vocab types | +200 |
| Agent | `agent/ai_sdk_agent.py` | Add vocab client | +80 |

#### Detailed Implementation

**1. mangle/a2a/mcp.mg**
```mangle
# OData Vocabularies integration
service_registry("odata-vocab", "http://localhost:9150/mcp", "vocabulary-engine").

# SDK type generation from vocabulary
tool_service("generate_typescript_types", "odata-vocab").
tool_service("get_annotation_schema", "odata-vocab").

# Type inference rules
infer_sdk_types(EntityType, TypeDefinition) :-
    mcp_call("odata-vocabularies", "get_term", 
             {"vocabulary": "Common", "term": EntityType}, TermInfo),
    generate_ts_type(TermInfo, TypeDefinition).
```

**2. packages/mcp-server/src/server.ts**
```typescript
// Add vocabulary tool handlers
const vocabTools = {
  lookup_vocabulary_term: async (args: { vocabulary: string; term: string }) => {
    const response = await fetch('http://localhost:9150/v1/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: 'odata-vocab-search',
        messages: [{ role: 'user', content: `What is ${args.vocabulary}.${args.term}?` }]
      })
    });
    return response.json();
  },
  
  generate_annotation_types: async (args: { entity: string }) => {
    // Generate TypeScript interfaces from vocabulary definitions
    const terms = await this.getVocabularyTerms(args.entity);
    return generateTypeScriptInterface(terms);
  }
};
```

**3. packages/types/vocabulary.ts** (NEW FILE)
```typescript
/**
 * OData Vocabulary Types - Auto-generated from vocabulary definitions
 */

// UI Vocabulary Types
export interface UILineItem {
  Value: string;
  Label?: string;
  Importance?: 'High' | 'Medium' | 'Low';
}

export interface UIHeaderInfo {
  TypeName: string;
  TypeNamePlural: string;
  Title: { Value: string };
  Description?: { Value: string };
}

export interface UISelectionFields {
  PropertyPath: string[];
}

// Analytics Vocabulary Types
export interface AnalyticsMeasure {
  value: boolean;
  aggregationType?: 'sum' | 'avg' | 'count' | 'min' | 'max';
}

export interface AnalyticsDimension {
  value: boolean;
  hierarchy?: string;
}

// PersonalData Vocabulary Types
export interface PersonalDataAnnotation {
  IsPotentiallyPersonal?: boolean;
  IsPotentiallySensitive?: boolean;
  DataSubjectRole?: 'DataSubject' | 'DataController';
}

// Common Vocabulary Types
export interface CommonLabel {
  value: string;
  language?: string;
}

export interface CommonSemanticKey {
  PropertyPath: string[];
}

// Annotation Helper Types
export type AnnotationTarget = 'Entity' | 'Property' | 'NavigationProperty' | 'Action';

export interface AnnotationSuggestion {
  term: string;
  vocabulary: string;
  applicability: AnnotationTarget[];
  example: string;
}
```

---

### 1.3 training-console (Priority: MEDIUM)

**Current Status**: ❌ No integration  
**Target**: GDPR classification during data cleaning

#### Component Changes

| Component | File | Change | LOC |
|-----------|------|--------|-----|
| Mangle A2A | `mangle/a2a/mcp.mg` | Add vocab registry | +10 |
| Agent | `agent/data_cleaning_agent.py` | Add GDPR classifier | +100 |
| MCP Server | `mcp_server/server.py` | Add vocab tools | +50 |

#### Detailed Implementation

**1. mangle/a2a/mcp.mg**
```mangle
service_registry("odata-vocab", "http://localhost:9150/mcp", "vocabulary-engine").

# GDPR classification rules
tool_service("classify_personal_data", "odata-vocab").
tool_service("get_personal_data_terms", "odata-vocab").

# Auto-classify fields during cleaning
auto_classify_field(FieldName, Classification) :-
    mcp_call("odata-vocabularies", "semantic_search",
             {"query": FieldName, "vocabulary": "PersonalData"}, Results),
    Results.results[0].similarity > 0.7,
    Classification = Results.results[0].term.
```

**2. agent/data_cleaning_agent.py**
```python
class DataCleaningAgent:
    async def classify_columns_for_gdpr(self, columns: List[str]) -> Dict[str, str]:
        """Classify columns using PersonalData vocabulary."""
        classifications = {}
        
        for column in columns:
            response = await self._call_vocab_api(
                "odata-vocab-gdpr",
                f"Classify this column for GDPR: {column}"
            )
            classifications[column] = self._parse_gdpr_response(response)
        
        return classifications
    
    async def suggest_masking_strategy(self, entity_def: Dict) -> Dict:
        """Suggest data masking based on PersonalData vocabulary."""
        return await self._call_vocab_tool("suggest_annotations", {
            "entity_type": entity_def.get("name"),
            "properties": entity_def.get("properties", []),
            "vocabulary": "PersonalData"
        })
    
    def _parse_gdpr_response(self, response: Dict) -> str:
        """Parse GDPR classification from response."""
        content = response.get("choices", [{}])[0].get("message", {}).get("content", "")
        
        if "sensitive" in content.lower():
            return "@PersonalData.IsPotentiallySensitive"
        elif "personal" in content.lower():
            return "@PersonalData.IsPotentiallyPersonal"
        return "not_personal"
```

---

### 1.4 generative-ai-toolkit-for-sap-hana-cloud (Priority: MEDIUM)

**Current Status**: ❌ No integration  
**Target**: HANACloud vocabulary + PersonalData classification

#### Component Changes

| Component | File | Change | LOC |
|-----------|------|--------|-----|
| Mangle A2A | `mangle/a2a/mcp.mg` | Add vocab registry | +15 |
| Agent | `agent/gen_ai_toolkit_agent.py` | Add vocab client | +80 |
| MCP Server | `mcp_server/server.py` | Add vocab tools | +60 |

#### Detailed Implementation

**1. mangle/a2a/mcp.mg**
```mangle
service_registry("odata-vocab", "http://localhost:9150/mcp", "vocabulary-engine").

# HANACloud vocabulary integration
tool_service("get_hana_annotations", "odata-vocab").
tool_service("annotate_calculation_view", "odata-vocab").

# Vector store annotation rules
vector_store_annotation(Column, "@HANACloud.VectorStore") :-
    column_type(Column, "REAL_VECTOR"),
    mcp_call("odata-vocabularies", "get_term",
             {"vocabulary": "HANACloud", "term": "VectorStore"}, _).
```

**2. agent/gen_ai_toolkit_agent.py**
```python
class GenAIToolkitAgent:
    async def annotate_hana_artifacts(self, schema: str, table: str) -> Dict:
        """Annotate HANA artifacts with HANACloud vocabulary."""
        metadata = await self._get_hana_metadata(schema, table)
        
        return await self._call_vocab_api("odata-vocab-annotator", 
            f"""Suggest HANACloud vocabulary annotations for this HANA table:
            Schema: {schema}
            Table: {table}
            Columns: {metadata.get('columns', [])}
            """
        )
    
    async def classify_for_rag(self, entity_def: Dict) -> Dict:
        """Classify entity for RAG pipeline using vocabulary."""
        return await self._call_vocab_tool("semantic_search", {
            "query": entity_def.get("description", entity_def.get("name")),
            "vocabulary": "HANACloud"
        })
```

---

## Sprint 2: Enhance Partial Integrations (Week 3-4)

### 2.1 cap-llm-plugin-main (Priority: HIGH)

**Current Status**: ⚠️ OData V4 path only  
**Target**: Full vocabulary integration

#### Component Changes

| Component | File | Change | LOC |
|-----------|------|--------|-----|
| Mangle A2A | `mangle/a2a/mcp.mg` | Add vocab tools | +20 |
| MCP Server | `mcp-server/src/server.ts` | Add vocab integration | +80 |
| Agent | `agent/cap_llm_agent.py` | Add annotation suggester | +60 |

#### Detailed Implementation

**1. mangle/a2a/mcp.mg**
```mangle
# OData Vocabularies service registration
service_registry("odata-vocab", "http://localhost:9150/mcp", "vocabulary-engine").

# CAP-specific vocabulary tools
tool_service("suggest_cds_annotations", "odata-vocab").
tool_service("validate_fiori_elements", "odata-vocab").

# CDS annotation inference
suggest_cds_annotation(Property, Annotation) :-
    property_type(Property, Type),
    mcp_call("odata-vocabularies", "suggest_annotations",
             {"entity_type": "Property", "properties": [Property], "vocabulary": "UI"},
             Suggestions),
    member(Annotation, Suggestions.annotations).
```

**2. mcp-server/src/server.ts**
```typescript
// Add vocabulary integration
import { VocabularyClient } from './vocabulary-client';

const vocabClient = new VocabularyClient('http://localhost:9150');

const tools = {
  ...existingTools,
  
  suggest_cds_annotations: {
    description: 'Suggest CDS annotations for entity definition',
    inputSchema: {
      type: 'object',
      properties: {
        entity: { type: 'string' },
        properties: { type: 'array', items: { type: 'object' } }
      }
    },
    handler: async (args: any) => {
      const response = await vocabClient.chatCompletion(
        'odata-vocab-annotator',
        `Suggest CDS annotations for entity: ${JSON.stringify(args)}`
      );
      return response.choices[0].message.content;
    }
  },
  
  validate_fiori_elements: {
    description: 'Validate Fiori Elements annotations',
    handler: async (args: any) => {
      return vocabClient.validateAnnotations(args);
    }
  }
};
```

---

### 2.2 langchain-integration-for-sap-hana-cloud (Priority: HIGH)

**Current Status**: ⚠️ Registry reference only  
**Target**: Vocabulary embeddings integration

#### Component Changes

| Component | File | Change | LOC |
|-----------|------|--------|-----|
| Mangle A2A | `mangle/a2a/mcp.mg` | Add embedding routing | +15 |
| Agent | `agent/langchain_hana_agent.py` | Add vocab embeddings | +100 |
| MCP Server | `mcp_server/server.py` | Add vocab search | +50 |

#### Detailed Implementation

**1. agent/langchain_hana_agent.py**
```python
class LangchainHanaAgent:
    def __init__(self):
        self.vocab_embeddings_url = "http://localhost:9150/v1/embeddings"
        self.vocab_chat_url = "http://localhost:9150/v1/chat/completions"
    
    async def enrich_rag_context(self, query: str, documents: List[str]) -> Dict:
        """Enrich RAG context with vocabulary semantics."""
        # Get vocabulary embedding for query
        vocab_embedding = await self._get_vocab_embedding(query)
        
        # Get relevant vocabulary terms
        vocab_terms = await self._get_relevant_vocab_terms(query)
        
        return {
            "query": query,
            "documents": documents,
            "vocabulary_context": vocab_terms,
            "semantic_enrichment": {
                "embedding_source": "odata-vocabularies",
                "relevant_terms": vocab_terms.get("results", [])[:5]
            }
        }
    
    async def _get_vocab_embedding(self, text: str) -> List[float]:
        """Get vocabulary-aware embedding."""
        async with aiohttp.ClientSession() as session:
            async with session.post(self.vocab_embeddings_url, json={
                "model": "text-embedding-odata",
                "input": text
            }) as resp:
                data = await resp.json()
                return data["data"][0]["embedding"]
    
    async def get_hana_schema_annotations(self, schema: str) -> Dict:
        """Get vocabulary annotations for HANA schema."""
        return await self._call_vocab_chat(
            "odata-vocab-annotator",
            f"Suggest annotations for HANA schema: {schema}"
        )
```

---

### 2.3 ui5-webcomponents-ngx-main (Priority: MEDIUM)

**Current Status**: ⚠️ Should use UI vocabulary  
**Target**: Full UI vocabulary mapping

#### Component Changes

| Component | File | Change | LOC |
|-----------|------|--------|-----|
| Mangle A2A | `mangle/a2a/mcp.mg` | Add UI vocab routing | +20 |
| MCP Server | `mcp-server/src/server.ts` | Add UI vocab tools | +100 |
| Agent | `agent/ui5_ngx_agent.py` | Add component mapper | +80 |

#### Detailed Implementation

**1. mangle/a2a/mcp.mg**
```mangle
service_registry("odata-vocab", "http://localhost:9150/mcp", "vocabulary-engine").

# UI vocabulary to component mapping
tool_service("map_ui_annotation_to_component", "odata-vocab").
tool_service("get_ui_terms", "odata-vocab").

# Component generation rules
generate_component(UIAnnotation, AngularComponent) :-
    mcp_call("odata-vocabularies", "get_term",
             {"vocabulary": "UI", "term": UIAnnotation}, TermInfo),
    map_to_ui5_component(TermInfo, AngularComponent).

# Mapping rules
map_to_ui5_component({"term": "LineItem"}, "ui5-table").
map_to_ui5_component({"term": "DataField"}, "ui5-input").
map_to_ui5_component({"term": "Chart"}, "ui5-chart").
map_to_ui5_component({"term": "FieldGroup"}, "ui5-form-item").
```

**2. agent/ui5_ngx_agent.py**
```python
class UI5NgxAgent:
    # UI vocabulary to UI5 web component mapping
    UI_VOCAB_COMPONENT_MAP = {
        "UI.LineItem": "ui5-table",
        "UI.DataField": "ui5-input",
        "UI.Chart": "ui5-viz-chart",
        "UI.FieldGroup": "ui5-form-item",
        "UI.HeaderInfo": "ui5-object-page-header",
        "UI.Facets": "ui5-object-page-section",
        "UI.SelectionFields": "ui5-filter-bar",
        "UI.PresentationVariant": "ui5-variant-management"
    }
    
    async def generate_component_from_annotation(self, annotation: str) -> str:
        """Generate Angular component from UI vocabulary annotation."""
        # Get term details from vocabulary
        term_info = await self._call_vocab_tool("get_term", {
            "vocabulary": "UI",
            "term": annotation.replace("@UI.", "")
        })
        
        component = self.UI_VOCAB_COMPONENT_MAP.get(annotation, "ui5-label")
        return self._generate_angular_template(component, term_info)
    
    async def suggest_ui_annotations(self, entity_def: Dict) -> Dict:
        """Suggest UI vocabulary annotations for entity."""
        return await self._call_vocab_api("odata-vocab-annotator",
            f"Suggest UI vocabulary annotations for Angular components: {entity_def}"
        )
```

---

## Sprint 3: Deepen Existing Integrations (Week 5-6)

### 3.1 mangle-query-service (Enhance)

#### Additional Integration Points

| Component | File | Change | LOC |
|-----------|------|--------|-----|
| Rules | `rules/vocabulary_cache.mg` | NEW: Caching rules | +50 |
| Rules | `rules/vocabulary_validation.mg` | NEW: Validation | +40 |

**rules/vocabulary_cache.mg**
```mangle
# Vocabulary Term Caching
Decl cached_term(Vocabulary, Term, Data, Timestamp) descr [extensional()].

# Cache lookup with TTL (5 minutes)
get_cached_term(Vocabulary, Term, Data) :-
    cached_term(Vocabulary, Term, Data, Timestamp),
    current_time(Now),
    (Now - Timestamp) < 300.

# Cache miss - fetch from MCP
get_term_with_cache(Vocabulary, Term, Data) :-
    !get_cached_term(Vocabulary, Term, _),
    mcp_call("odata-vocabularies", "get_term",
             {"vocabulary": Vocabulary, "term": Term}, Data),
    current_time(Now),
    assert(cached_term(Vocabulary, Term, Data, Now)).
```

---

### 3.2 ai-core-streaming (Enhance)

#### Additional Integration Points

| Component | File | Change | LOC |
|-----------|------|--------|-----|
| Mesh | `mesh/vocabulary_routing.mg` | NEW: Vocab-aware routing | +60 |
| OpenAI | `openai/chat_completions.py` | Add vocab delegation | +40 |

**mesh/vocabulary_routing.mg**
```mangle
# Vocabulary-aware model routing
route_to_vocab_model(Request, "odata-vocab-search") :-
    request_contains(Request, "vocabulary"),
    request_intent(Request, "search").

route_to_vocab_model(Request, "odata-vocab-annotator") :-
    request_contains(Request, "annotation"),
    request_intent(Request, "generate").

route_to_vocab_model(Request, "odata-vocab-gdpr") :-
    request_contains(Request, "personal"),
    request_intent(Request, "classify").
```

---

### 3.3 elasticsearch-main (Enhance)

#### Additional Integration Points

| Component | File | Change | LOC |
|-----------|------|--------|-----|
| Mappings | `es_mappings/vocabulary_terms.json` | Dedicated vocab index | +80 |
| Agent | `agent/elasticsearch_agent.py` | Vocab sync | +60 |

**es_mappings/vocabulary_terms.json**
```json
{
  "mappings": {
    "properties": {
      "term_id": { "type": "keyword" },
      "vocabulary": { "type": "keyword" },
      "namespace": { "type": "keyword" },
      "qualified_name": { "type": "keyword" },
      "term_name": { "type": "keyword" },
      "description": {
        "type": "text",
        "analyzer": "vocabulary_analyzer"
      },
      "type": { "type": "keyword" },
      "base_type": { "type": "keyword" },
      "applicable_to": { "type": "keyword" },
      "deprecation_status": { "type": "keyword" },
      "embedding": {
        "type": "dense_vector",
        "dims": 1536,
        "index": true,
        "similarity": "cosine"
      },
      "examples": { "type": "text" },
      "related_terms": { "type": "keyword" }
    }
  }
}
```

---

## Sprint 4: Testing & Documentation (Week 7-8)

### 4.1 Integration Tests

| Service | Test File | Tests |
|---------|-----------|-------|
| ai-core-pal | `tests/integration/test_vocab_integration.py` | 10 |
| ai-sdk-js | `tests/integration/vocab.test.ts` | 15 |
| data-cleaning | `tests/integration/test_gdpr_vocab.py` | 12 |
| gen-ai-toolkit | `tests/integration/test_hana_vocab.py` | 10 |
| cap-llm | `tests/integration/vocab.test.ts` | 12 |
| langchain-hana | `tests/integration/test_vocab_embeddings.py` | 10 |
| ui5-ngx | `tests/integration/vocab.test.ts` | 10 |
| **Total** | | **79** |

### 4.2 Documentation Updates

| Service | Doc File | Content |
|---------|----------|---------|
| All services | `README.md` | Add vocabulary integration section |
| All services | `docs/vocabulary-integration.md` | Integration guide |
| odata-vocabularies | `docs/client-integration.md` | Client SDK guide |

---

## Summary

### Files to Create/Modify

| Service | New Files | Modified Files | Total LOC |
|---------|-----------|----------------|-----------|
| ai-core-pal | 0 | 3 | ~60 |
| ai-sdk-js | 1 | 3 | ~400 |
| data-cleaning | 0 | 3 | ~160 |
| gen-ai-toolkit | 0 | 3 | ~155 |
| cap-llm-plugin | 0 | 3 | ~160 |
| langchain-hana | 0 | 3 | ~165 |
| ui5-ngx | 0 | 3 | ~200 |
| mangle-query | 2 | 0 | ~90 |
| ai-core-streaming | 1 | 1 | ~100 |
| elasticsearch | 1 | 1 | ~140 |
| **Total** | **5** | **26** | **~1,630** |

### Integration Checklist

```
□ Sprint 1: Missing Integrations
  □ ai-core-pal
    □ mangle/a2a/mcp.mg
    □ agent/aicore_pal_agent.py
    □ data_products/registry.yaml
  □ ai-sdk-js
    □ mangle/a2a/mcp.mg
    □ packages/mcp-server/src/server.ts
    □ packages/types/vocabulary.ts (NEW)
    □ agent/ai_sdk_agent.py
  □ data-cleaning-copilot
    □ mangle/a2a/mcp.mg
    □ agent/data_cleaning_agent.py
    □ mcp_server/server.py
  □ generative-ai-toolkit
    □ mangle/a2a/mcp.mg
    □ agent/gen_ai_toolkit_agent.py
    □ mcp_server/server.py

□ Sprint 2: Enhance Partial
  □ cap-llm-plugin
    □ mangle/a2a/mcp.mg
    □ mcp-server/src/server.ts
    □ agent/cap_llm_agent.py
  □ langchain-hana
    □ mangle/a2a/mcp.mg
    □ agent/langchain_hana_agent.py
    □ mcp_server/server.py
  □ ui5-webcomponents-ngx
    □ mangle/a2a/mcp.mg
    □ mcp-server/src/server.ts
    □ agent/ui5_ngx_agent.py

□ Sprint 3: Deepen Existing
  □ mangle-query-service
    □ rules/vocabulary_cache.mg (NEW)
    □ rules/vocabulary_validation.mg (NEW)
  □ ai-core-streaming
    □ mesh/vocabulary_routing.mg (NEW)
    □ openai/chat_completions.py
  □ elasticsearch
    □ es_mappings/vocabulary_terms.json (NEW)
    □ agent/elasticsearch_agent.py

□ Sprint 4: Testing & Docs
  □ Integration tests (79 tests)
  □ Documentation updates
  □ Client SDK guide
```

---

## Success Metrics

| Metric | Current | Target |
|--------|---------|--------|
| Fully Integrated Services | 4 | 12 |
| Vocabulary API Calls/Day | 0 | 10,000+ |
| Annotation Coverage | ~20% | 80%+ |
| GDPR Classification | Manual | Automated |
| Test Coverage | ~60% | 90%+ |