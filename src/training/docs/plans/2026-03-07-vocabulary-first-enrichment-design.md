# Vocabulary-First Enrichment Design

**Date**: 2026-03-07
**Status**: Draft
**Approach**: A — Vocabulary-First Enrichment
**Target Model**: Qwen 3.5

## Goal

Enrich the existing text-to-SQL training data pipeline with semantic annotations from OData vocabularies, Mangle-based gRPC validation, and LLM-assisted augmentation to produce higher-quality training pairs for Qwen 3.5 fine-tuning on SAP HANA banking schemas.

**Quality dimensions addressed**:
1. **Schema richness** — OData vocabulary annotations (Measure, Dimension, Hierarchy, Currency, PersonalData)
2. **Validation depth** — mangle-query-service gRPC validation with confidence scoring
3. **LLM augmentation** — Prompt paraphrasing, SQL verification, difficulty scoring via cap-llm-plugin

## Integration Model

**Hybrid**: Static vocabulary data embedded at build time (cheap, fast). Live API calls to mangle-query-service (gRPC) and cap-llm-plugin (MCP/JSON-RPC) for validation and augmentation. All external-service stages have passthrough fallbacks — pipeline never blocks on an unavailable service.

## Source Projects

| Project | Role | Integration Point |
|---------|------|-------------------|
| `odata-vocabularies-main` | Schema semantic enrichment | 4 vendored JSON files (Analytics, Hierarchy, Common, PersonalData) |
| `mangle-query-service` | SQL + schema validation | gRPC `mqs.v1.QueryService.Resolve` on `localhost:50051` |
| `cap-llm-plugin-main` | LLM augmentation | MCP server `getChatCompletionWithConfig` on `localhost:9150/mcp` |

## Updated Pipeline Stages

```
 Stage  Name              Language  Change     Description
 -----  ----              --------  ------     -----------
 1      preconvert        Shell     existing   CSV normalization
 2      build             Zig       existing   Compile pipeline
 3      extract           Zig       existing   Schema extraction from CSVs
 4      annotate          Zig       NEW        Enrich schema with OData vocabulary annotations
 5      parse-templates   Zig       modified   Updated for new semantic parameter types
 6      expand            Zig       modified   Vocabulary-aware cartesian expansion
 7      validate-mangle   Python    NEW        gRPC validation via mangle-query-service
 8      validate-local    Mangle    existing   Local Mangle rules (schema, SQL, domain, coverage)
 9      augment-llm       Python    NEW        LLM paraphrasing + verification + scoring
 10     format            Zig       existing   Spider/BIRD JSONL with 80/10/10 split
```

## Section 1: Schema Registry Enrichment

### Problem

The current `schema_registry.zig` Column struct carries structural metadata only (name, data_type, is_key, is_nullable). The template expander has no way to distinguish a measure column (e.g., `TRANSACTION_AMOUNT`) from a dimension column (e.g., `CUSTOMER_SEGMENT`), leading to nonsensical SQL like `SUM(customer_name)`.

### Solution

Add semantic annotation fields to Column and Table, populated from OData vocabulary JSON at build time.

### Column struct additions

```zig
pub const SemanticType = enum {
    MEASURE,
    DIMENSION,
    HIERARCHY_LEVEL,
    KEY,
    LABEL,
    NONE,
};

// New fields on Column:
semantic_type: SemanticType,     // from Analytics.json: Measure/Dimension
is_currency: bool,               // from Common.json: IsCurrency
is_unit: bool,                   // from Common.json: IsUnit
is_personal_data: bool,          // from PersonalData.json: IsPotentiallyPersonal
is_sensitive: bool,              // from PersonalData.json: IsPotentiallySensitive
annotation_source: []const u8,   // traceability, e.g. "Analytics.json:Measure"
```

### Table struct additions

```zig
// New fields on Table:
has_hierarchy: bool,              // from Hierarchy.json: RecursiveHierarchy
hierarchy_type: ?[]const u8,      // e.g. "RecursiveHierarchy"
entity_semantics: ?[]const u8,    // from PersonalData.json: EntitySemantics
```

### New file: `vocab_annotator.zig`

Reads 4 vendored OData vocabulary JSON files from `pipeline/data/vocabularies/`. Applies rule-based mapping from column name patterns to semantic annotations:

| Pattern | SemanticType | Additional Flags |
|---------|-------------|------------------|
| `*_AMOUNT`, `*_BALANCE`, `*_RATE`, `*_PRICE` | MEASURE | `is_currency = true` |
| `*_COUNT`, `*_QUANTITY`, `*_TOTAL` | MEASURE | |
| `*_ID`, `*_CODE`, `*_KEY` | KEY | |
| `*_NAME`, `*_DESC`, `*_LABEL`, `*_TEXT` | LABEL | |
| `*_SEGMENT`, `*_TYPE`, `*_CATEGORY`, `*_STATUS` | DIMENSION | |
| `HIER_*`, `L0_*` through `L6_*` | HIERARCHY_LEVEL | |
| `*_CURRENCY`, `*_CCY` | DIMENSION | `is_currency = true` |
| `*_UNIT`, `*_UOM` | DIMENSION | `is_unit = true` |
| `CUSTOMER_*`, `CLIENT_*`, `*_EMAIL`, `*_PHONE` | (inherit) | `is_personal_data = true` |
| `*_SSN`, `*_CREDIT_SCORE`, `*_SALARY` | (inherit) | `is_sensitive = true` |

These patterns mirror `infer_annotation_from_column()` in `mangle-query-service/rules/rag_enrichment.mg`.

### Vendored vocabulary files

```
pipeline/data/vocabularies/
  Analytics.json      — Measure, Dimension, AggregatedProperty, AnalyticalContext
  Hierarchy.json      — RecursiveHierarchy, HierarchyType, DrillState
  Common.json         — Label, Text, SemanticKey, IsCurrency, IsUnit
  PersonalData.json   — EntitySemantics, FieldSemantics, IsPotentiallyPersonal
```

Sourced from `odata-vocabularies-main/vocabularies/`. Vendored (copied) rather than referenced at runtime to keep the pipeline self-contained for CI.

### Makefile target

```makefile
annotate: extract
	$(ZIG_BIN) annotate-schema \
		--schema $(BUILD_DIR)/schema.json \
		--vocabularies pipeline/data/vocabularies/ \
		--output $(BUILD_DIR)/schema_annotated.json
```

## Section 2: Template Expander Enrichment

### Problem

The current cartesian expansion binds every column to every parameter slot indiscriminately. With 50 tables averaging 15 columns each and 60 templates, this produces ~45,000 raw pairs — most invalid.

### Solution

Semantic filtering: each template parameter slot declares which `SemanticType` it accepts. The expander only binds columns matching the declared type.

### New parameter types in `template_parser.zig`

```
[select measure]      — binds to SemanticType.MEASURE columns only
[group dimension]     — binds to SemanticType.DIMENSION columns only
[hierarchy level]     — binds to SemanticType.HIERARCHY_LEVEL columns only
[filter safe]         — binds to columns where is_sensitive == false
[currency column]     — binds to columns where is_currency == true
```

Existing parameter types (`[select metric]`, `[input ISIN]`) remain supported for backwards compatibility.

### Impact estimate

- **Before**: ~45,000 raw pairs, ~60-70% invalid (SUM on text columns, GROUP BY on amounts)
- **After**: ~12,000-15,000 raw pairs, <10% invalid
- Net result: fewer but dramatically higher quality pairs entering validation

## Section 3: Mangle Validation Integration

### Problem

Local Mangle rules (`schema_validation.mg`, `sql_validation.mg`) catch structural errors but miss semantic validity. They can verify "column exists in table" but not "this SQL query makes business sense for banking."

### Solution

New Stage 7 — call mangle-query-service gRPC for deeper validation with confidence scoring.

### Architecture

```
expand (Stage 6)
    ↓ JSONL stream (text-SQL pairs)
validate-mangle (Stage 7)      ← NEW
    ↓ validated JSONL with confidence scores
validate-local (Stage 8)       ← existing
    ↓
```

### Implementation: `pipeline/scripts/mangle_validate.py`

```python
# Pseudocode
for pair in read_jsonl(stdin):
    request = ResolveRequest(
        query=pair["sql"],
        metadata={
            "domain": pair["domain"],
            "tables": pair["table_names"],
            "columns": pair["column_names"],
            "annotations": pair["annotations"],  # semantic types
            "natural_language": pair["prompt"]
        }
    )
    response = stub.Resolve(request)

    if response.confidence >= CONFIDENCE_THRESHOLD:  # default 0.7
        pair["validation_confidence"] = response.confidence
        pair["validation_path"] = response.path
        write_jsonl(stdout, pair)
    else:
        write_jsonl(rejected_file, pair)  # for analysis
```

### gRPC contract (from `mangle-query-service/api/proto/query.proto`)

```protobuf
service QueryService {
  rpc Resolve(ResolveRequest) returns (ResolveResponse);
}
message ResolveRequest {
  string query = 1;
  repeated float query_embedding = 2;
  string correlation_id = 3;
  map<string, string> metadata = 4;
}
message ResolveResponse {
  string answer = 1;
  string path = 2;        // "cache" | "factual" | "rag" | "llm" | "llm_fallback"
  float confidence = 3;
  repeated string sources = 4;
  int64 latency_ms = 5;
}
```

### Fallback

If mangle-query-service is unreachable (connection refused, timeout > 5s):
- All pairs pass through unmodified
- `validation_path` set to `"skipped"`
- Warning logged to stderr
- Pipeline continues

### Proto generation

```
pipeline/proto/query.proto    — copied from mangle-query-service/api/proto/
pipeline/scripts/gen_proto.sh — runs grpc_tools.protoc to generate Python stubs
```

## Section 4: LLM Augmentation Stage

### Problem

Template expansion produces syntactically correct but linguistically monotonous prompts. Real user queries are diverse in phrasing. Additionally, there's no automated difficulty stratification for balanced train/dev/test splits.

### Solution

New Stage 9 — call cap-llm-plugin MCP server for three augmentation operations.

### Architecture

```
validate-local (Stage 8)
    ↓ validated JSONL
augment-llm (Stage 9)         ← NEW
    ↓ augmented JSONL (3x size from paraphrasing)
format (Stage 10)
```

### Three operations via `getChatCompletionWithConfig`

#### 1. Prompt Paraphrasing

For each text-SQL pair, generate 2 additional natural-language phrasings:

```json
{
  "method": "getChatCompletionWithConfig",
  "params": {
    "messages": [
      {"role": "system", "content": "You are a banking analyst. Rephrase the following question in 2 different ways while preserving the exact same meaning. Return JSON array of 2 strings."},
      {"role": "user", "content": "What is the total transaction amount by customer segment?"}
    ],
    "model": "qwen-3.5"
  }
}
```

**Impact**: Triples dataset from ~12K to ~36K pairs with linguistic diversity.

#### 2. SQL Verification

For each pair, ask the LLM to verify correctness:

```json
{
  "messages": [
    {"role": "system", "content": "Given a banking database schema and a question, verify if the SQL correctly answers the question. Respond with {\"valid\": true/false, \"reason\": \"...\"}"},
    {"role": "user", "content": "Schema: ... Question: ... SQL: ..."}
  ]
}
```

Pairs flagged `valid: false` are written to a review file, not auto-deleted (false negatives are expensive).

#### 3. Difficulty Scoring

Rate each pair 1-5 on complexity:

```
1 = Single table, no aggregation (SELECT col FROM table WHERE ...)
2 = Single table with aggregation (SELECT SUM(col) FROM table GROUP BY ...)
3 = Single join with aggregation
4 = Multi-join or subquery
5 = Multi-join with subquery, window functions, or hierarchy traversal
```

This feeds into `spider_formatter.zig` for stratified 80/10/10 splits ensuring each difficulty level is proportionally represented.

### Implementation: `pipeline/scripts/llm_augment.py`

Calls the MCP server at `localhost:9150/mcp` using HTTP POST with JSON-RPC 2.0.

**Rate limiting**:
- Batch size: 10 pairs (configurable via `LLM_BATCH_SIZE`)
- Delay between batches: 500ms (configurable via `LLM_DELAY_MS`)
- Total time estimate for 12K pairs: ~10 minutes

### Fallback

If cap-llm-plugin is unreachable:
- Skip paraphrasing (no duplicate generation, dataset stays at 1x size)
- Skip verification (trust Mangle validation from Stage 7)
- Assign `difficulty = 3` to all pairs (uniform instead of stratified)
- Pipeline always completes

## Section 5: Pipeline Orchestration

### Updated Makefile

```makefile
# New stages interleaved with existing ones
STAGES = preconvert build extract annotate parse-templates expand \
         validate-mangle validate-local augment-llm format

annotate: extract
	$(ZIG_BIN) annotate-schema \
		--schema $(BUILD_DIR)/schema.json \
		--vocabularies pipeline/data/vocabularies/ \
		--output $(BUILD_DIR)/schema_annotated.json

validate-mangle: expand
	python3 pipeline/scripts/mangle_validate.py \
		--input $(BUILD_DIR)/expanded.jsonl \
		--output $(BUILD_DIR)/validated_mangle.jsonl \
		--rejected $(BUILD_DIR)/rejected_mangle.jsonl \
		--host localhost --port 50051 \
		--confidence-threshold 0.7

augment-llm: validate-local
	python3 pipeline/scripts/llm_augment.py \
		--input $(BUILD_DIR)/validated.jsonl \
		--output $(BUILD_DIR)/augmented.jsonl \
		--flagged $(BUILD_DIR)/flagged_verification.jsonl \
		--mcp-url http://localhost:9150/mcp \
		--batch-size $(LLM_BATCH_SIZE) \
		--delay-ms $(LLM_DELAY_MS)
```

### Service dependencies (optional docker-compose.yml)

```yaml
version: "3.8"
services:
  mangle-query-service:
    build: ../../mangle-query-service
    ports: ["50051:50051"]
    healthcheck:
      test: ["CMD", "grpc_health_probe", "-addr=:50051"]
      interval: 10s

  cap-llm-plugin:
    build: ../../cap-llm-plugin-main
    ports: ["9150:9150"]
    environment:
      - AI_CORE_URL=${AI_CORE_URL}
      - AI_CORE_CLIENT_ID=${AI_CORE_CLIENT_ID}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9150/health"]
      interval: 10s
```

### Error handling philosophy

| Scenario | Behavior |
|----------|----------|
| mangle-query-service down | Stage 7 passes all pairs through with `validation_path: "skipped"` |
| cap-llm-plugin down | Stage 9 skips paraphrasing/verification, assigns difficulty=3 |
| Both services down | Pipeline produces valid output at lower quality (equivalent to current pipeline) |
| gRPC timeout > 5s | Per-pair retry once, then skip that pair's validation |
| MCP rate limit hit | Exponential backoff, max 3 retries per batch |

### CI modes

```makefile
# Fast mode (CI, no external services)
make all MODE=offline

# Full mode (production, requires docker-compose up)
make all MODE=full
```

`MODE=offline` skips stages 7 and 9, equivalent to current pipeline behavior.

## New Files Summary

| File | Language | Purpose |
|------|----------|---------|
| `pipeline/zig/src/vocab_annotator.zig` | Zig | Parse OData JSON, annotate schema registry |
| `pipeline/zig/src/vocab_types.zig` | Zig | SemanticType enum, annotation structs |
| `pipeline/data/vocabularies/Analytics.json` | JSON | Vendored OData vocabulary |
| `pipeline/data/vocabularies/Hierarchy.json` | JSON | Vendored OData vocabulary |
| `pipeline/data/vocabularies/Common.json` | JSON | Vendored OData vocabulary |
| `pipeline/data/vocabularies/PersonalData.json` | JSON | Vendored OData vocabulary |
| `pipeline/scripts/mangle_validate.py` | Python | gRPC client for mangle-query-service |
| `pipeline/scripts/llm_augment.py` | Python | MCP client for cap-llm-plugin |
| `pipeline/scripts/gen_proto.sh` | Shell | Generates Python gRPC stubs from proto |
| `pipeline/scripts/requirements.txt` | Text | grpcio, grpcio-tools, requests |
| `pipeline/proto/query.proto` | Proto | Copied from mangle-query-service |
| `pipeline/docker-compose.yml` | YAML | Optional service dependencies |

## Data Flow

```
CSVs ──→ [extract] ──→ SchemaRegistry (structural only)
                              │
OData JSONs ──→ [annotate] ──→ SchemaRegistry + semantic annotations
                                       │
Templates ──→ [parse] ──→ [expand] ──→ TextSqlPairs (filtered by SemanticType)
                                            │
                                   [validate-mangle] ──→ gRPC ──→ confidence filter
                                            │
                                   [validate-local] ──→ Mangle rules
                                            │
                                   [augment-llm] ──→ paraphrase + verify + score
                                            │
                                   [format-spider] ──→ train.jsonl / dev.jsonl / test.jsonl
```

## Expected Output Quality

| Metric | Current Pipeline | With Enrichment |
|--------|-----------------|-----------------|
| Raw pairs generated | ~45,000 | ~12,000-15,000 |
| Invalid pairs (semantic) | ~60-70% | <10% |
| Validation coverage | Structural only | Structural + semantic + confidence |
| Linguistic diversity | 1 phrasing per SQL | 3 phrasings per SQL |
| Difficulty stratification | None | 5-level scoring |
| Final training pairs | ~15,000 (many low quality) | ~36,000-45,000 (high quality) |
| PersonalData awareness | None | Sensitive columns excluded from filter params |
