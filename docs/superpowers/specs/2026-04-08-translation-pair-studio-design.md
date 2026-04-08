# Translation Pair Studio — Design Spec

**Date**: 2026-04-08
**Codebase**: training-webcomponents-ngx
**Route**: `/pair-studio` (nav group ID: `ai-lab`, displayed as "Assistants")

## Problem

The Training Console has a glossary with 24 hardcoded IFRS terms and a Translation Memory that grows one override at a time via the chat audit flow. There is no way to bulk-ingest existing translated documents, alias term lists, or database schema mappings to enrich the system's translation intelligence at scale.

## Solution

A new **Translation Pair Studio** page that ingests multilingual document pairs, alias terms, and database schema mappings through a unified upload-review-commit pipeline. Extracted pairs enrich the Translation Memory, Glossary system prompt, and optionally the RAG vector store.

## Scope

### In scope
- Multi-format file ingestion: CSV, JSON, TMX, XLSX, SQL/DDL, PDF (single bilingual + dual document)
- Any-to-any language pairs including same-language (en-en aliases, db field mappings)
- Configurable trust level per upload batch (auto-approve vs review queue)
- Rule-based paragraph alignment for PDF pairs + LLM-powered term extraction
- Client-side DDL parsing for SAP HANA schema files
- Extended system prompt with alias and DB field mapping sections

### Out of scope
- Real-time collaborative editing of pairs (single-user workflow)
- Training/fine-tuning models from extracted pairs (future)
- Automatic re-alignment when source documents change

---

## Architecture

### Data Flow

```
Upload → Detect Format → Pipeline Router
                            ├── Structured Parser (client-side)
                            ├── DDL/Schema Parser (client-side)
                            ├── Single Bilingual PDF (OCR + client split)
                            └── Dual PDF (OCR + backend alignment + LLM extraction)
                                    ↓
                            Review Table (paragraph + term pairs)
                                    ↓
                            Commit → TM + Glossary + RAG Vector Store
```

### Four Pipelines

| Pipeline | Input | Alignment | Term Extraction | Runs Where |
|----------|-------|-----------|-----------------|------------|
| Structured | CSV / TMX / JSON / XLSX | Pre-aligned (columns) | Direct mapping | Client-side |
| Schema Import | SQL / DDL / `.hdbtable` | N/A | Abbreviation expansion | Client-side |
| Single Bilingual PDF | One PDF with mixed langs | Language detection per paragraph | LLM via `/v1/chat/completions` | OCR: backend, split: client, terms: LLM |
| Dual Document | Two PDFs, same content | `POST /api/rag/tm/align` | LLM via `/v1/chat/completions` | Backend alignment + LLM extraction |

---

## Core Types

```typescript
type PairType = 'translation' | 'alias' | 'db_field_mapping';

interface IngestionBatch {
  id: string;
  source: 'structured' | 'bilingual_pdf' | 'dual_pdf' | 'schema';
  fileName: string;
  trustLevel: 'auto_approve' | 'review';
  paragraphPairs: ParagraphPair[];
  termPairs: TermPair[];
  createdAt: string;
}

interface ParagraphPair {
  sourceText: string;
  targetText: string;
  sourceLang: string;              // Any ISO 639-1 code
  targetLang: string;              // Can equal sourceLang
  confidence: number;              // 0-1
  page?: number;
  status: 'pending' | 'approved' | 'rejected';
}

interface TermPair {
  sourceTerm: string;
  targetTerm: string;
  sourceLang: string;
  targetLang: string;
  pairType: PairType;
  category: GlossaryCategory;       // See widened union below
  confidence: number;
  dbContext?: {
    tableName?: string;
    columnName?: string;
    dataType?: string;
  };
  existsInGlossary: boolean;
  status: 'pending' | 'approved' | 'rejected';
}
```

### Type Widening

The existing `GlossaryEntry.category` union type must be widened:

```typescript
// Current: 'income_statement' | 'balance_sheet' | 'regulatory' | 'general'
// New:
type GlossaryCategory = 'income_statement' | 'balance_sheet' | 'regulatory' | 'general' | 'schema' | 'auto' | 'dialectal';
```

This is a **breaking change** to `GlossaryEntry` — all existing `crossCheck()` and `getSystemPromptSnippet()` callers must handle the new values. The `dialectal` category supports Darija vs MSA alias pairs.

### Commit Mappings

**TermPair → TMEntry mapping** (for Translation Memory commit):

| TermPair field | TMEntry field | Transform |
|---------------|---------------|-----------|
| `sourceTerm` | `source_text` | Direct |
| `targetTerm` | `target_text` | Direct |
| `sourceLang` | `source_lang` | Direct |
| `targetLang` | `target_lang` | Direct |
| `category` | `category` | Direct (requires widened type) |
| `status === 'approved'` | `is_approved` | Boolean conversion |
| `pairType`, `confidence`, `dbContext` | *(not stored in TMEntry)* | Metadata in Glossary only |

**ParagraphPair commit destinations:**
- **Translation Memory**: Each approved paragraph pair is stored as a `TMEntry` (source/target text + langs + category `'auto'`)
- **RAG Vector Store** (optional): Paragraph text chunked and embedded for retrieval-augmented generation
- Paragraph pairs are NOT stored in the Glossary (only term-level entries go there)

---

## Backend: Alignment Endpoint

### `POST /api/rag/tm/align`

**Request:**
```typescript
interface AlignRequest {
  source: {
    pages: OcrPageResult[];
    lang: string;
  };
  target: {
    pages: OcrPageResult[];
    lang: string;
  };
  options: {
    granularity: 'paragraph' | 'sentence';
    extractTerms: boolean;
    existingGlossary?: Array<{
      sourceTerm: string;
      targetTerm: string;
      sourceLang: string;
      targetLang: string;
      category: string;
    }>;  // Client serializes GlossaryEntry[] to this wire format
  };
}
```

**Response:**
```typescript
interface AlignResponse {
  paragraphPairs: Array<{
    sourceText: string;
    targetText: string;
    sourceLang: string;           // Echoed from request
    targetLang: string;           // Echoed from request
    sourcePage: number;
    targetPage: number;
    confidence: number;
    status: 'pending';            // Always pending from backend; client promotes
    alignmentMethod: 'structural' | 'number_anchor' | 'heading_match' | 'length_ratio';
  }>;
  termPairs: Array<{
    sourceTerm: string;
    targetTerm: string;
    sourceLang: string;
    targetLang: string;
    category: string;
    confidence: number;
    extractionMethod: 'glossary_match' | 'llm_extraction' | 'number_cooccurrence';
  }>;
  stats: {
    totalSourceParagraphs: number;
    totalTargetParagraphs: number;
    alignedCount: number;
    unalignedCount: number;
    termsExtracted: number;
    processingTimeMs: number;
  };
}
```

### Alignment Pipeline (Hybrid)

**Step 1 — Structural alignment (rule-based):**

| Heuristic | Signal | Weight |
|-----------|--------|--------|
| Page position | Same page number, same relative position | 0.3 |
| Number anchoring | Shared numeric values in both paragraphs | 0.3 |
| Heading match | Section headers aligned via glossary lookup | 0.25 |
| Length ratio | AR ~1.2x EN, FR ~1.15x EN for same content | 0.15 |

Pairs scoring >= 0.7 pass to Step 2. Below 0.7 flagged as unaligned.

**Step 2 — LLM term extraction:**

Runs on aligned paragraph pairs via existing `/v1/chat/completions`. Specialized system prompt extracts term pairs, aliases, and DB field references. Returns structured JSON array.

**Step 3 — Dedup & merge:**

Cross-reference extracted terms against existing glossary. Mark duplicates. Flag higher-confidence replacements.

---

## Backend: Bulk Commit Endpoint

### `POST /api/rag/tm/batch`

**Request:**
```typescript
interface TMBatchRequest {
  entries: Array<{
    source_text: string;
    target_text: string;
    source_lang: string;
    target_lang: string;
    category: string;
    is_approved: boolean;
  }>;
}
```

**Response:**
```typescript
interface TMBatchResponse {
  saved: number;
  failed: number;
  errors: Array<{ index: number; message: string }>;
}
```

The `TranslationMemoryService.saveBatch()` method POSTs to this new endpoint. On partial failure, the UI shows "X of Y saved. Z failed (retry?)" per the error handling table.

---

## UI Layout

### Panel 1: Upload Zone

Left side: upload configuration (pair type dropdown, source/target language with auto-detect, trust level radio). Right side: multi-file drop zone accepting PDF, CSV, JSON, TMX, XLSX, SQL, DDL.

- Pair type auto-switches to "DB Field Mapping" when `.sql`/`.hdbtable` detected
- Two PDFs auto-detected as dual document pipeline
- Process Files button with progress bar

### Panel 2: Review Table

Two tabs: **Term Pairs** (primary) and **Paragraph Pairs**.

Term pairs table columns: checkbox, Source, Target, Type, Category, Confidence (colored badge), Status, Actions (approve/reject/edit).

Batch actions toolbar: Approve Selected, Reject Selected, Approve All Pending.

Filterable by pair type, category, confidence range, status, language pair.

### Panel 3: Commit Summary

Shows counts of approved/rejected pairs, new vs updated entries. Destination checkboxes: Translation Memory, Glossary Service, RAG Vector Store (optional). Commit button + Discard button.

---

## Schema Import (DDL Parser)

Client-side regex parser for SQL/HANA DDL files:

1. Parse `CREATE TABLE` / `CREATE COLUMN TABLE` statements
2. Extract column names + data types
3. Expand abbreviations via lookup table: `ACCT` -> Account, `BAL` -> Balance, `AMT` -> Amount, `NM` -> Name, `DT` -> Date, `DESC` -> Description, `QTY` -> Quantity, `CURR` -> Currency, etc.
4. Strip SAP namespace prefixes: `/BIC/`, `/BI0/`, leading `0`
5. Unresolved abbreviations get confidence 0.6 and land in review queue

---

## System Prompt Extension

`getSystemPromptSnippet()` now generates four sections:

```
[STRICT LINGUISTIC CONSTRAINTS - IFRS/CPA BANKING STANDARDS]
- Special Commission Income <-> ... (income_statement)

[CORRECTION OVERRIDES - HUMAN-APPROVED TRANSLATIONS]
- source_text -> target_text (en to ar)

[ALIAS TERMS - USE INTERCHANGEABLY]
- Revenue = Turnover = Net Sales (en)
- ... (ar)

[DATABASE FIELD MAPPINGS - USE NATURAL LANGUAGE IN RESPONSES]
- ACCT_BAL_AMT -> "Account Balance Amount" (CUSTOMER_ACCOUNTS.ACCT_BAL_AMT, DECIMAL(15,2))
```

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `pair-studio.component.ts` | Page | Main page with three panels |
| `pair-studio.component.html` | Template | Upload + review + commit layout |
| `pair-studio.component.scss` | Styles | SAP Fiori design tokens |
| `ingestion.service.ts` | Service | Pipeline orchestration, batch state |
| `structured-parser.ts` | Utility | CSV/JSON/TMX/XLSX -> normalized pairs |
| `ddl-parser.ts` | Utility | SQL/DDL -> db_field_mapping pairs |
| `abbreviation-expander.ts` | Utility | Column name -> natural language |
| `language-detector.ts` | Utility | Per-paragraph language detection via Unicode script ranges (Arabic U+0600-U+06FF, Latin, CJK) + word frequency heuristics |
| `pair-studio.types.ts` | Types | All interfaces and type definitions |

## Files to Modify

| File | Change |
|------|--------|
| `app.navigation.ts` | Add pair-studio link to `ai-lab` group (displayed as "Assistants") in `TRAINING_ROUTE_LINKS` |
| `app.routes.ts` | Lazy-load PairStudioComponent at `/pair-studio` |
| `en.json` / `ar.json` / `fr.json` | Add ~40 `pairStudio.*` i18n keys |
| `glossary.service.ts` | Widen `GlossaryCategory` union; extend `getSystemPromptSnippet()` for alias + DB sections; add `pairType` awareness in `crossCheck()` |
| `translation-memory.service.ts` | Add `saveBatch(entries: TMEntry[]): Observable<TMBatchResponse>` calling `POST /api/rag/tm/batch` |
| `glossary-manager.component.ts` | Add pair type filter chips |

## New Dependencies

| Package | Purpose | Size |
|---------|---------|------|
| `xlsx` (SheetJS) | XLSX parsing | ~300 KB, tree-shakeable |

TMX files (XML-based) are parsed using the browser's built-in `DOMParser` — no additional XML library needed.

---

## Error Handling

| Scenario | Handling |
|----------|----------|
| OCR fails on PDF | Toast error, drop zone resets, other batch files unaffected |
| 0 aligned pairs | Info banner: documents may not be translations of each other |
| LLM extraction timeout (60s) | Paragraph pairs still available, terms show "extraction timed out" |
| Duplicate entries | Dimmed in review table with "(already in TM)" badge |
| Malformed structured file | Specific error: "Missing required column: target_text" |
| DDL parse failure | Fallback: raw column names with confidence 0.5 |
| Mixed language paragraph | Flag as ambiguous, inline language dropdown for manual assignment |
| Large file (>100 pages) | Chunk into 20-page batches with 1-page overlap, one `POST /api/rag/tm/align` call per chunk pair, progress bar per chunk. Cross-chunk paragraphs are deduped by text similarity in the merge step. |
| Backend unreachable | Structured parsers work offline; PDF pipeline shows connection error |
| Partial commit failure | Summary: "18 of 20 saved. 2 failed (retry?)" |

### Arabic/Moroccan Edge Cases

| Case | Handling |
|------|----------|
| Tashkeel (diacritics) | Strip for matching, store original |
| Darija vs MSA | Same-language alias pairs with `dialectal` category |
| Arabic-Indic numerals | Number anchoring handles both Western and Arabic-Indic |
| RTL/LTR mixed content | Per-paragraph detection, tagged by dominant language |
| SAP BW namespace prefixes | Strip `/BIC/`, `/BI0/`, leading `0` |

---

## Testing

### Unit tests (Vitest)

| Test file | Coverage |
|-----------|----------|
| `ddl-parser.spec.ts` | 10+ DDL variants: standard SQL, HANA column store, `.hdbtable` JSON |
| `structured-parser.spec.ts` | CSV, JSON, TMX, XLSX: valid, missing columns, empty, encoding (UTF-8 BOM, Windows-1256) |
| `abbreviation-expander.spec.ts` | Known abbreviations expand correctly, unknown flagged at 0.6 |
| `language-detector.spec.ts` | Arabic, English, French classification + mixed content |
| `alignment-scoring.spec.ts` | Tests run against mocked alignment response data — verifies score thresholds and method labels (heuristics execute server-side) |
| `ingestion-batch.spec.ts` | Full pipeline: files -> review -> commit with dedup and status transitions |

### Integration tests

| Test | Scope |
|------|-------|
| `POST /api/rag/tm/align` | Two small OcrResults, verify alignment + term extraction |
| Round-trip | Upload -> align -> commit -> verify `getSystemPromptSnippet()` includes new entries |
| Structured -> Glossary Manager | CSV import -> entries appear in TM table with correct status |
