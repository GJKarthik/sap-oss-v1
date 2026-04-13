#!/usr/bin/env python3
"""
Build RAG chunks from extracted markdown files.

Follows the same chunking pattern as docs/regulations/machine-readable/:
- 220 words per chunk, 40-word overlap
- Outputs JSONL + CSV
- Also runs embedding ID preparation (uuid5-based deterministic IDs)
"""

import csv
import hashlib
import json
import uuid
from datetime import datetime, timezone
from pathlib import Path

EXTRACTED_DIR = Path(__file__).resolve().parent.parent / "extracted"
RAG_DIR = Path(__file__).resolve().parent.parent / "rag"

# Also chunk the structured YAML files for richer RAG context
REQUIREMENTS_DIR = Path(__file__).resolve().parent.parent / "requirements"
PROCESS_DIR = Path(__file__).resolve().parent.parent / "process"

CHUNK_WORDS = 220
OVERLAP_WORDS = 40
STEP = CHUNK_WORDS - OVERLAP_WORDS  # 180


def read_markdown_content(filepath: Path) -> str:
    """Read markdown file, stripping YAML frontmatter."""
    text = filepath.read_text(encoding="utf-8")
    if text.startswith("---"):
        parts = text.split("---", 2)
        if len(parts) >= 3:
            return parts[2].strip()
    return text.strip()


def read_yaml_as_text(filepath: Path) -> str:
    """Read YAML file as plain text for chunking."""
    return filepath.read_text(encoding="utf-8").strip()


def chunk_text(text: str, source_file: str, doc_type: str) -> list:
    """Split text into overlapping word-based chunks."""
    words = text.split()
    if not words:
        return []

    chunks = []
    chunk_idx = 0
    pos = 0

    while pos < len(words):
        chunk_words = words[pos:pos + CHUNK_WORDS]
        chunk_text = " ".join(chunk_words)

        chunk = {
            "chunk_id": f"{Path(source_file).stem}_chunk_{chunk_idx:04d}",
            "source_file": source_file,
            "document_type": doc_type,
            "chunk_index": chunk_idx,
            "word_start": pos,
            "word_end": min(pos + CHUNK_WORDS, len(words)),
            "word_count": len(chunk_words),
            "text": chunk_text,
        }
        chunks.append(chunk)

        chunk_idx += 1
        pos += STEP

    return chunks


def build_embedding_id(chunk: dict) -> str:
    """Generate deterministic embedding ID using uuid5."""
    text_hash = hashlib.sha256(chunk["text"].encode("utf-8")).hexdigest()
    stable_key = "|".join([
        chunk["source_file"],
        str(chunk["chunk_id"]),
        str(chunk["chunk_index"]),
        text_hash,
    ])
    return str(uuid.uuid5(uuid.NAMESPACE_URL, stable_key))


def write_jsonl(filepath: Path, records: list):
    """Write records as JSONL."""
    with open(filepath, "w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")


def write_csv(filepath: Path, records: list):
    """Write records as CSV."""
    if not records:
        return
    fieldnames = ["embedding_id", "chunk_id", "source_file", "document_type",
                  "chunk_index", "word_count", "text_sha256", "text"]
    with open(filepath, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        for r in records:
            writer.writerow({k: r.get(k, "") for k in fieldnames})


def main():
    RAG_DIR.mkdir(parents=True, exist_ok=True)

    print("=" * 60)
    print("RAG Chunk Builder")
    print("=" * 60)

    # Gather all source files
    sources = []

    # Layer 1: Extracted markdown
    if EXTRACTED_DIR.exists():
        for md_file in sorted(EXTRACTED_DIR.glob("*.md")):
            sources.append((md_file, "extracted"))

    # Layer 2: Requirements YAML
    if REQUIREMENTS_DIR.exists():
        for yaml_file in sorted(REQUIREMENTS_DIR.glob("*.yaml")):
            sources.append((yaml_file, "requirements"))

    # Layer 3: Process YAML
    if PROCESS_DIR.exists():
        for yaml_file in sorted(PROCESS_DIR.glob("*.yaml")):
            sources.append((yaml_file, "process"))

    all_chunks = []
    chunks_by_source = {}

    for filepath, doc_type in sources:
        if filepath.suffix == ".md":
            content = read_markdown_content(filepath)
        else:
            content = read_yaml_as_text(filepath)

        chunks = chunk_text(content, filepath.name, doc_type)
        all_chunks.extend(chunks)
        chunks_by_source[filepath.name] = len(chunks)
        print(f"  {filepath.name}: {len(chunks)} chunks")

    print(f"\nTotal chunks: {len(all_chunks)}")

    # Write raw chunks
    chunks_jsonl = RAG_DIR / "rag_chunks.jsonl"
    chunks_csv = RAG_DIR / "rag_chunks.csv"
    write_jsonl(chunks_jsonl, all_chunks)
    print(f"  -> {chunks_jsonl}")

    # Build embedding records
    embedding_records = []
    for chunk in all_chunks:
        text_hash = hashlib.sha256(chunk["text"].encode("utf-8")).hexdigest()
        embedding_id = build_embedding_id(chunk)
        record = {
            "embedding_id": embedding_id,
            "chunk_id": chunk["chunk_id"],
            "source_file": chunk["source_file"],
            "document_type": chunk["document_type"],
            "chunk_index": chunk["chunk_index"],
            "word_count": chunk["word_count"],
            "text_sha256": text_hash,
            "text": chunk["text"],
        }
        embedding_records.append(record)

    # Write embedding records
    emb_jsonl = RAG_DIR / "rag_embedding_records.jsonl"
    emb_csv = RAG_DIR / "rag_embedding_records.csv"
    write_jsonl(emb_jsonl, embedding_records)
    write_csv(emb_csv, embedding_records)
    print(f"  -> {emb_jsonl}")
    print(f"  -> {emb_csv}")

    # Write manifest
    manifest = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "input_directory": str(EXTRACTED_DIR),
        "input_files": [s[0].name for s in sources],
        "outputs": {
            "chunks_jsonl": "rag_chunks.jsonl",
            "chunks_csv": "rag_chunks.csv",
            "embedding_jsonl": "rag_embedding_records.jsonl",
            "embedding_csv": "rag_embedding_records.csv",
        },
        "chunking": {
            "unit": "words",
            "chunk_words": CHUNK_WORDS,
            "overlap_words": OVERLAP_WORDS,
            "step": STEP,
        },
        "total_chunks": len(all_chunks),
        "total_embedding_records": len(embedding_records),
        "chunks_by_source": chunks_by_source,
    }

    manifest_path = RAG_DIR / "rag_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"  -> {manifest_path}")

    print("\nDone.")


if __name__ == "__main__":
    main()
