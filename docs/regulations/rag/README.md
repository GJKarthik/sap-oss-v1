# Regulations RAG Artifacts

This directory now contains machine-readable text, chunked RAG files, and embedding-ready records.

## Files

- `rag_chunks.jsonl` / `rag_chunks.csv`: chunked text records
- `rag_embedding_records.jsonl` / `rag_embedding_records.csv`: same chunks + deterministic `embedding_id`
- `rag_manifest.json`: chunking summary
- `rag_embedding_records_manifest.json`: embedding-record summary

## Scripts

- `scripts/prepare_embedding_records.py`
- `scripts/upsert_qdrant.py`

## 1) Regenerate embedding-ready records

```bash
python3 regulations/machine-readable/scripts/prepare_embedding_records.py
```

## 2) Embed + upsert into Qdrant

Set credentials:

```bash
export OPENAI_API_KEY="YOUR_OPENAI_OR_COMPATIBLE_KEY"
export OPENAI_BASE_URL="https://api.openai.com/v1"   # or your compatible endpoint
export OPENAI_EMBEDDING_MODEL="text-embedding-3-small"
export QDRANT_URL="http://localhost:6333"
export QDRANT_API_KEY=""                              # optional
```

Run import:

```bash
python3 regulations/machine-readable/scripts/upsert_qdrant.py \
  --input ../rag_embedding_records.jsonl \
  --collection regulations_rag
```

Optional: also write a JSONL with vectors:

```bash
python3 regulations/machine-readable/scripts/upsert_qdrant.py \
  --input ../rag_embedding_records.jsonl \
  --collection regulations_rag \
  --write-embedded-jsonl ../rag_embeddings.jsonl
```

Notes:

- `upsert_qdrant.py` is resumable via `qdrant_upsert_state.json`.
- `embedding_id` is stable for identical source chunk text and metadata.
