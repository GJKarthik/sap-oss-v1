# Regulations RAG - Mangle Facts and Rules

This directory contains machine-readable Mangle representations of regulatory documents for AI governance and agentic AI systems.

## Overview

The RAG chunks from `/regulations/machine-readable/` have been converted into Mangle facts and rules for logical querying and compliance analysis.

## Files

| File | Description |
|------|-------------|
| `facts.mg` | Schema declarations and source document metadata |
| `chunks.mg` | All 282 chunk facts (one fact per RAG chunk) |
| `rules.mg` | Derived predicates for querying and analysis |

## Source Documents

| Document | Type | Chunks | Description |
|----------|------|--------|-------------|
| `2025-AI-Agent-Index.pdf` | Index | 112 | Technical and safety features of 30 AI agents |
| `mgf-for-agentic-ai.pdf` | Framework | 64 | Model AI Governance Framework for Agentic AI |
| `2503.18238v3.pdf` | Research | 106 | Human-AI collaboration field experiment |

**Total: 282 chunks**

## Schema

### Source Document Metadata

```mangle
Decl source_document(
  source_id: string,
  title: string,
  document_type: string,    # index|framework|research
  pages: integer,
  chunk_count: integer,
  publication_date: string,
  publisher: string
).
```

### Chunk Facts

```mangle
Decl chunk(
  chunk_id: string,         # e.g., "2025-AI-Agent-Index_p001_c001"
  source_pdf: string,       # e.g., "2025-AI-Agent-Index.pdf"
  page_start: integer,
  page_end: integer,
  chunk_index: integer,
  word_count: integer,
  text: string
).
```

## Example Queries

### Find all chunks mentioning "safety"

```mangle
?- chunk_mentions_risk_type(ChunkId, "safety").
```

### Find governance requirements

```mangle
?- chunk_has_requirement(ChunkId, ObligationType).
```

### Find MGF governance dimensions

```mangle
?- governance_dimension(ChunkId, Dimension).
```

### Find safety control discussions

```mangle
?- safety_control_chunk(ChunkId, ControlType).
```

### Cross-document analysis

```mangle
?- mgf_for_agent_finding(MgfChunk, IndexChunk, Topic).
```

## Available Rules

### Text Search

- `chunk_contains_keyword(chunk_id, keyword)` - Full-text keyword search
- `chunk_has_requirement(chunk_id, obligation_type)` - Find must/shall/should statements
- `chunk_mentions_risk_type(chunk_id, risk_type)` - Find risk discussions

### Document-Specific

- `governance_dimension(chunk_id, dimension)` - MGF governance dimensions
- `agent_category_chunk(chunk_id, category)` - Agent Index categories
- `collaboration_finding_chunk(chunk_id, finding_type)` - Research findings
- `autonomy_level_chunk(chunk_id, level)` - Autonomy level mentions (L1-L5)

### Safety Analysis

- `safety_control_chunk(chunk_id, control_type)` - Safety control mentions
- `human_oversight_chunk(chunk_id)` - Human oversight discussions

### Aggregation

- `chunk_count_by_source(source_pdf, count)` - Chunks per document
- `document_type_summary(document_type, count)` - Summary by type
- `governance_chunk(chunk_id)` - All governance-related chunks
- `safety_chunk(chunk_id)` - All safety-related chunks

### Cross-Document

- `related_chunks(chunk_id_1, chunk_id_2, topic)` - Related chunks across docs
- `mgf_for_agent_finding(mgf_chunk, index_chunk, topic)` - MGF for agent findings

## Risk Types

The following risk types can be queried via `chunk_mentions_risk_type`:

- `safety`
- `security`
- `accountability`
- `transparency`
- `autonomy`

## Safety Control Types

The following control types can be queried via `safety_control_chunk`:

- `guardrails`
- `sandboxing`
- `approval_gates`
- `monitoring`
- `emergency_stop`

## MGF Governance Dimensions

The following dimensions can be queried via `governance_dimension`:

- `risk_assessment` - "Assess and bound the risks upfront"
- `accountability` - "Make humans meaningfully accountable"
- `technical_controls` - "Implement technical controls and processes"
- `user_responsibility` - "Enable end-user responsibility"

## Usage with Other Mangle Files

These facts and rules can be combined with other Mangle files in the project:

```mangle
# Import from other modules
# @import sdk/mangle-sap-bdc/standard/facts.mg
# @import sdk/mangle-sap-bdc/a2a/rules.mg

# Example: Find regulatory chunks relevant to A2A service capabilities
?- chunk_mentions_risk_type(ChunkId, "safety"),
   service_capability(ServiceName, /chat).
```

## Regeneration

To regenerate these files from the source RAG chunks:

1. Ensure `/regulations/machine-readable/rag_chunks.jsonl` is up to date
2. The chunks can be extracted using:

```bash
cat regulations/machine-readable/rag_chunks.jsonl | jq -r '
"chunk(\n  \"" + .chunk_id + "\",\n  \"" + .source_pdf + "\",\n  " + 
(.page_start|tostring) + ", " + (.page_end|tostring) + ", " + 
(.chunk_index_in_page|tostring) + ", " + (.word_count|tostring) + ",\n  \"" + 
(.text | gsub("\""; "\\\"") | gsub("\n"; "\\n")) + "\"\n).\n"
'
```

## Related Documentation

- `/regulations/machine-readable/README.md` - RAG pipeline documentation
- `/sdk/mangle-sap-bdc/README.md` - Mangle SAP BDC SDK
- `/src/sap_coding_standards.mg` - SAP coding standards in Mangle