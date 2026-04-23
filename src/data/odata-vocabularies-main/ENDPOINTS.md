# OData Vocabularies MCP Server — Endpoints & Tools

**Base URL (Kyma):** `https://odata-vocab.c-054c570.kyma.ondemand.com`  
**Internal port:** `9150`  
**Auth:** Bearer token — `Authorization: Bearer <MCP_AUTH_TOKEN>`  
**Protocol:** MCP JSON-RPC 2.0 (Model Context Protocol v2024-11-05)

---

## HTTP Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `GET`  | `/health` | None | Health check — returns status, vocab count, term count, datalog facts |
| `GET`  | `/stats` | None | Detailed statistics — per-vocabulary term/type counts |
| `POST` | `/mcp` | Bearer | MCP JSON-RPC 2.0 — all 14 tools via `tools/call` |
| `POST` | `/mcp/tools/extract_entities` | None | Direct REST endpoint for entity extraction (no JSON-RPC wrapper) |
| `OPTIONS` | `*` | None | CORS preflight |

---

## MCP JSON-RPC Methods

All calls go to `POST /mcp` with body:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "<method>",
  "params": { ... }
}
```

| Method | Description |
|--------|-------------|
| `initialize` | Handshake — returns server name, version, capabilities |
| `tools/list` | List all 14 available tools with their input schemas |
| `tools/call` | Invoke a tool by name with arguments |
| `resources/list` | List all 7 MCP resources |
| `resources/read` | Read a resource by URI |

---

## 14 MCP Tools

### Phase 1 — Core Vocabulary Tools

#### 1. `list_vocabularies`
List all loaded SAP OData vocabularies.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `include_experimental` | boolean | No | Include experimental terms (default: true) |

**Returns:** Array of vocabularies with `name`, `namespace`, `alias`, `term_count`, `stable_terms`, `experimental_terms`, `deprecated_terms`, `complex_types`, `enum_types`

---

#### 2. `get_vocabulary`
Get full details of a specific vocabulary including all terms and types.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `name` | string | **Yes** | Vocabulary name (e.g. `UI`, `Common`, `Analytics`) |
| `include_types` | boolean | No | Include ComplexTypes, EnumTypes, TypeDefinitions (default: true) |

**Returns:** Full vocabulary object with all terms, complex types, enum types

---

#### 3. `search_terms`
Keyword search across all vocabulary terms and descriptions.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `query` | string | **Yes** | Search string (matched against term name and description) |
| `vocabulary` | string | No | Filter to a specific vocabulary |
| `include_deprecated` | boolean | No | Include deprecated terms (default: false) |

**Returns:** Array of matching terms with `vocabulary`, `term`, `type`, `description`, `full_name`, `applies_to`, `experimental`, `deprecated`

---

#### 4. `get_term`
Get full details of a single vocabulary term.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `vocabulary` | string | **Yes** | Vocabulary name (e.g. `UI`) |
| `term` | string | **Yes** | Term name (e.g. `LineItem`) |

**Returns:** Full term object with `name`, `type`, `description`, `applies_to`, `properties`, `experimental`, `deprecated`

---

#### 5. `extract_entities`
Extract OData entity references from a natural language query using regex patterns for 10 SAP business object types.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `query` | string | **Yes** | Natural language text to extract entities from |

**Supported entity types:** SalesOrder, BusinessPartner, Material, PurchaseOrder, CostCenter, Employee, Project, Invoice, WorkOrder, Asset

**Returns:** Array of `{ entity_type, entity_id, namespace, key_property, text_property }`

---

#### 6. `get_vocabulary_facts`
Get auto-generated Datalog-style logical facts from vocabulary definitions (1,479 facts total).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `vocabulary` | string | No | Filter facts for a specific vocabulary |
| `fact_type` | enum | No | Filter by type: `all` \| `vocabulary` \| `term` \| `type` \| `enum` \| `entity_config` |

**Returns:** Array of Datalog predicate strings, e.g. `term(UI, LineItem, Collection(UI.DataField))`

---

#### 7. `validate_annotations`
Validate OData annotations against the loaded vocabulary specifications.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `annotations` | string | **Yes** | Annotations as a JSON string or XML string |

**Returns:** `{ valid: bool, errors: [], warnings: [], validated_count: int }`

---

#### 8. `generate_annotations`
Generate vocabulary-grounded annotation suggestions for a given entity type and its properties.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `entity_type` | string | **Yes** | Entity type name (e.g. `SalesOrder`) |
| `properties` | string | **Yes** | Entity properties as a JSON array string |
| `vocabulary` | string | No | Target vocabulary (`UI`, `Common`, etc.) |

**Returns:** Suggested annotations with term names, descriptions, and example values

---

#### 9. `lookup_term`
Alias for `get_term` — kept for backwards compatibility.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `vocabulary` | string | **Yes** | Vocabulary name |
| `term` | string | **Yes** | Term name |

---

#### 10. `convert_annotations`
Convert annotations between JSON (`$Annotations`) and XML (`<Annotation>`) formats.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `input` | string | **Yes** | Input annotation string |
| `from_format` | string | **Yes** | Source format: `json` or `xml` |
| `to_format` | string | **Yes** | Target format: `json` or `xml` |

**Returns:** Converted annotation string in the target format

---

#### 11. `get_statistics`
Get statistics about all loaded vocabularies.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| _(none)_ | — | — | No parameters required |

**Returns:** `{ vocabularies, total_terms, total_complex_types, total_enum_types, vocabulary_datalog_facts, entity_configs, embeddings_loaded }`

---

### Phase 3 — Semantic / RAG Tools

#### 12. `semantic_search`
Semantic similarity search across all vocabulary terms using vector embeddings.

> ⚠️ Requires `generate_vocab_embeddings.py` to be run first to load embeddings. Falls back to keyword search if embeddings not loaded.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `query` | string | **Yes** | Natural language search query |
| `top_k` | integer | No | Number of results to return (default: 10) |
| `min_similarity` | number | No | Minimum cosine similarity threshold 0–1 (default: 0.3) |
| `vocabulary` | string | No | Filter to a specific vocabulary |

**Returns:** Ranked array of terms with `similarity_score`, `term`, `vocabulary`, `description`

---

#### 13. `get_rag_context`
Get enriched RAG context for injection into an LLM prompt — includes relevant vocabulary terms, Datalog facts, and annotation suggestions.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `query` | string | **Yes** | Natural language query |
| `entity_type` | string | No | Entity type to get context for |
| `include_annotations` | boolean | No | Include annotation suggestions (default: true) |

**Returns:** Structured context block with relevant terms, facts, and suggestions ready for LLM prompt injection

---

#### 14. `suggest_annotations`
Suggest the most relevant OData annotation terms for a given entity and use case.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `entity_type` | string | **Yes** | Entity type name |
| `properties` | string | No | Property names as a JSON array string |
| `use_case` | enum | No | `ui` \| `analytics` \| `personal_data` \| `all` (default: `all`) |

**Returns:** Prioritised list of suggested annotation terms with rationale

---

## MCP Resources

Accessible via `resources/read` with the URI:

| URI | Description |
|-----|-------------|
| `odata://vocabularies` | All vocabularies as JSON |
| `odata://common` | SAP Common vocabulary terms |
| `odata://ui` | SAP UI vocabulary terms |
| `odata://analytics` | SAP Analytics vocabulary terms |
| `odata://vocabulary-datalog` | All 1,479 Datalog-style facts as plain text |
| `odata://entity-configs` | 10 SAP business object entity patterns |
| `embeddings://index` | Vocabulary embedding index metadata |

---

## Direct REST Endpoint

### `POST /mcp/tools/extract_entities`
No auth required. Simplified REST wrapper (no JSON-RPC envelope).

**Request:**
```json
{ "query": "Show me sales order SO-1001" }
```

**Response:**
```json
{ "entity_type": "SalesOrder", "entity_id": "SO-1001" }
```

Returns the first matched entity only. Returns `{ "entity_type": "", "entity_id": "" }` if no entity found.

---

## Example: Call a Tool via `/mcp`

```bash
curl -s -X POST https://odata-vocab.c-054c570.kyma.ondemand.com/mcp \
  -H "Authorization: Bearer $MCP_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
      "name": "search_terms",
      "arguments": { "query": "label", "vocabulary": "Common" }
    }
  }'
```

```bash
# Health check (no auth)
curl https://odata-vocab.c-054c570.kyma.ondemand.com/health
```

---

## Loaded Data (at startup)

| Metric | Value |
|--------|-------|
| Vocabularies | 19 |
| Total Terms | 242 |
| Datalog Facts | 1,479 |
| Entity Configs | 10 SAP business object types |
| Embeddings | Loaded if `vocab_embeddings.json` present |