# Text-to-SQL Training Data Pipeline Design

**Date**: 2026-03-06
**Status**: Approved

## Goal

Build a training data pipeline that processes banking data platform files (CSVs, Excel data dictionaries, prompt templates, dimension tables) into **Spider/BIRD benchmark format** training data for a **text-to-SQL** model targeting **SAP HANA** SQL dialect. Target scale: **5K-20K** question/SQL pairs.

## Approach

**Template Expansion + LLM Augmentation** using the existing ZIG/Mojo/Mangle stack from HippoCPP, with NVIDIA ModelOpt as the deployment target for the fine-tuned model.

## Data Domains

1. **Treasury/Capital** - Bonds, Issuances, IRS, derivatives (from `DATA_DICTIONARY.xlsx` + staging schema)
2. **ESG** - Net Zero, Integrated Client, Sustainable Finance (from `ESG_DATA_DICTIONARY.xlsx`)
3. **Performance/BPC** - P&L, costs, segments, products, locations (from NFRP tables + Performance CRD fact table)

## Input Files

| File | Purpose |
|------|---------|
| `1_register.csv` | Data ingestion register (source systems, SLAs, refresh metadata) |
| `2_stagingschema.csv` | Field-level source-to-BTP staging mappings with data types |
| `2_stagingschema_logs.csv` | Staging schema change logs |
| `2_stagingschema_nonstagingschema.csv` | Non-staging schema mappings |
| `3_validations.csv` | Validation rules / dropdown values for register fields |
| `DATA_DICTIONARY.xlsx` | Treasury domain: column descriptions, business meanings, valid filter values |
| `ESG_DATA_DICTIONARY.xlsx` | ESG domain: Net Zero, Client, Sustainable Finance field dictionaries |
| `Prompt_samples.xlsx` | ~20+ parameterized Treasury question templates |
| `ESG_Prompt_samples.xlsx` | ~20+ parameterized ESG question templates |
| `Performance (BPC) - sample prompts.xlsx` | ~20+ Performance/BPC question templates |
| `NFRP_Account_AM.xlsx` | Account dimension hierarchy (L0-L5), ~1090 rows |
| `NFRP_Cost_AM.xlsx` | Cost cluster dimension hierarchy (L0-L5), ~1509 rows |
| `NFRP_Location_AM.xlsx` | Location dimension hierarchy (L0-L6), ~1605 rows |
| `NFRP_Product_AM.xlsx` | Product dimension hierarchy (L0-L4), ~877 rows |
| `NFRP_Segment_AM.xlsx` | Segment dimension hierarchy (L0-L4), ~44 rows |
| `Performance CRD - Fact table.xlsx` | Fact table definitions (period, version, books, etc.) |

## Architecture

```
                          Training Data Pipeline
                          =====================

  [Input Data Files]          [HippoCPP]              [NVIDIA ModelOpt]
  CSVs + Excel files    Graph DB for schema &     Model quantization for
                        relationship modeling      deployment of fine-tuned
         |                       |                  text-to-SQL model
         v                       v                         ^
  +----------------+    +--------------------+             |
  | ZIG: Schema    |--->| ZIG: Load schema   |   +---------+----------+
  |  Extraction    |    | into HippoCPP      |   | Quantize fine-     |
  +--------+-------+    | as a graph         |   | tuned model for    |
           |            +--------+-----------+   | T4 deployment      |
           v                     v               +--------------------+
  +----------------+    +--------------------+            ^
  | ZIG: Template  |    | HippoCPP Graph     |            |
  |  Expansion     |--->| queries to find    |   +---------+----------+
  +--------+-------+    | join paths, FK     |   | Fine-tune Qwen     |
           |            | relationships,     |   | on generated       |
           v            | valid traversals   |   | Spider/BIRD data   |
  +----------------+    +--------+-----------+   +--------------------+
  | Mojo: LLM      |            |                        ^
  | Augmentation   |<-----------+                        |
  +--------+-------+                                     |
           |                                             |
           v                                             |
  +----------------+                                     |
  | Mangle:        |                                     |
  | Validation     |-------- Spider/BIRD output ---------+
  +----------------+
```

## Component Design

### 1. Schema Extraction (ZIG)

Parse all input files into a unified schema registry.

**Schema Registry** contains:
- **Tables**: From `2_stagingschema.csv` (BTP staging tables like `BSI_REM_FACT`, `BSI_REM_CONTROL_TABLE`) and NFRP dimension tables
- **Columns**: Field names, data types (from staging schema), business descriptions (from data dictionaries)
- **Hierarchies**: L0-L5/L6 hierarchical structures in each NFRP dimension (Account, Product, Location, Cost, Segment)
- **Valid values**: Country names, product types, asset classes, coupon types, etc. from Filters sheets and dimension data

**Domain registry** with three domains: Treasury/Capital, ESG, Performance/BPC.

**Output**: JSON schema files for downstream components.

### 2. HippoCPP Graph Loading (ZIG)

Load the schema registry into HippoCPP as a graph database:
- Tables as nodes, columns as nodes, relationships (foreign keys, joins) as edges
- Hierarchy levels as graph edges (L0->L1->L2->...->L5)
- Enables Cypher queries to discover valid join paths, reachable columns, and relationship-aware SQL generation

### 3. Template Expansion Engine (ZIG)

Process existing prompt templates into concrete question/SQL pairs.

**Process**:
1. Parse parameterized templates from 3 prompt sample Excel files (~60+ templates)
2. Map parameter slots (`[select metric]`, `[select country]`, `<select measure>`) to valid value sets from Schema Registry
3. Generate Cartesian product with intelligent pruning (skip nonsensical combinations, apply domain constraints, sample high-cardinality slots)
4. For each expanded question, generate corresponding SAP HANA SQL using rule-based query builder

**HANA SQL specifics**:
- `TO_DATE()`, `ADD_MONTHS()`, `WEEKDAY()` functions
- Hierarchical queries via self-joins on L0-L5 columns
- Weighted averages, YoY/QoQ comparisons, ratios
- Proper schema qualification (`STG_BCRS.BSI_REM_FACT`)

**Estimated yield**: ~3,000-6,000 base pairs.

### 4. LLM Augmentation Layer (Mojo)

Scale from ~5K base pairs to 10K-20K via three strategies:

1. **Question paraphrasing** - 2-3 natural language rephrasings per base question, mapping to the same SQL
2. **Complexity scaling** - Multi-table joins, subqueries, window functions, multi-condition filters
3. **Gap filling** - Generate questions for underrepresented tables/columns/query patterns

**Implementation**:
- HTTP client calling LLM API (Claude/GPT) with schema context and few-shot examples
- Parallel request batching
- Response parsing and deduplication
- SQL post-processing for HANA syntax compliance
- Confidence scoring; low-confidence pairs discarded or flagged for review

### 5. Validation Rules (Google Mangle)

Declarative validation rules extending HippoCPP's existing Mangle infrastructure (`rules.mg`, `aggregations.mg`, `functions.mg`).

**Validation categories**:
1. **Schema consistency** - SQL references only valid tables/columns
2. **SQL syntax** - HANA compliance (correct functions, GROUP BY, JOIN conditions, aliases)
3. **Domain constraints** - Metric/product compatibility, hierarchy level consistency, valid value ranges
4. **Output format** - Spider/BIRD spec compliance (required fields, parseable SQL, no duplicates, difficulty labels)
5. **Coverage** - Minimum representation per domain, query complexity distribution, table/column coverage

Failed rules produce structured error reports feeding back into generation for correction.

### 6. Output Format

Spider/BIRD benchmark directory structure:

```
output/
+-- database/
|   +-- banking_btp/
|       +-- schema.sql          # CREATE TABLE statements (HANA DDL)
|       +-- banking_btp.sqlite  # Optional SQLite mirror for tooling
+-- train.json                  # Training set (~80%)
+-- dev.json                    # Validation set (~10%)
+-- test.json                   # Test set (~10%)
+-- tables.json                 # Schema metadata in Spider format
```

Each entry:
```json
{
  "db_id": "banking_btp",
  "query": "SELECT ... FROM STG_TREASURY.BOND_POSITIONS ...",
  "question": "What are the top 5 countries by mark-to-market value for FVOCI bonds?",
  "difficulty": "moderate",
  "domain": "treasury",
  "source": "template_expansion"
}
```

Train/dev/test split: stratified by domain and difficulty.

## Pipeline Stages

| Stage | Tool | Input | Output |
|-------|------|-------|--------|
| 1. Extract schemas | ZIG | CSV/XLSX files | `schema_registry.json` |
| 2. Load graph | ZIG + HippoCPP | Schema registry | Graph database |
| 3. Parse templates | ZIG | Prompt XLSX files | `templates.json` |
| 4. Expand templates | ZIG + HippoCPP | Registry + templates + graph | `base_pairs.json` (~5K) |
| 5. Augment with LLM | Mojo | Base pairs + schema | `augmented_pairs.json` (~15K) |
| 6. Validate | Mangle | All pairs + schema | `validated_pairs.json` + `errors.json` |
| 7. Split & format | ZIG | Validated pairs | `train/dev/test.json` |

## NVIDIA ModelOpt Integration

After the pipeline generates Spider/BIRD training data:
1. Fine-tune a model (e.g., Qwen3.5-4B) on the generated training data
2. Use ModelOpt to quantize to INT8 for T4 GPU deployment (16GB VRAM)
3. Deploy quantized text-to-SQL model for inference

Existing `configs/qwen_int8.yaml` and `scripts/quantize_qwen.py` support this workflow.

## Key Risks

1. **ZIG Excel parsing** - Limited library support; may need FFI to a C library (libxlsxwriter/xlsxio) or pre-convert to CSV
2. **Google Mangle ecosystem** - Experimental language with minimal tooling; may need custom interpreter integration
3. **LLM SQL correctness** - Generated SQL needs robust validation; Mangle rules are the safety net
4. **HANA syntax coverage** - Need comprehensive HANA function/syntax reference for the rule-based query builder
