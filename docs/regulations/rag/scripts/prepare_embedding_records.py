#!/usr/bin/env python3
"""
Prepare embedding-ready records from rag_chunks.jsonl.

This script adds deterministic embedding IDs and metadata that can be used for
downstream embedding generation and vector DB ingestion.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import uuid
from datetime import UTC, datetime
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Prepare embedding-ready records")
    parser.add_argument(
        "--input",
        default="../rag_chunks.jsonl",
        help="Input JSONL produced by chunking step",
    )
    parser.add_argument(
        "--output-jsonl",
        default="../rag_embedding_records.jsonl",
        help="Output JSONL with embedding_id",
    )
    parser.add_argument(
        "--output-csv",
        default="../rag_embedding_records.csv",
        help="Output CSV with embedding_id",
    )
    parser.add_argument(
        "--output-manifest",
        default="../rag_embedding_records_manifest.json",
        help="Output manifest JSON",
    )
    return parser.parse_args()


def load_jsonl(path: Path) -> list[dict]:
    rows: list[dict] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            rows.append(json.loads(line))
    return rows


def build_embedding_id(row: dict, text_hash: str) -> str:
    stable_key = "|".join(
        [
            str(row.get("source_pdf", "")),
            str(row.get("chunk_id", "")),
            str(row.get("page_start", "")),
            str(row.get("page_end", "")),
            text_hash,
        ]
    )
    return str(uuid.uuid5(uuid.NAMESPACE_URL, stable_key))


def transform_rows(rows: list[dict]) -> list[dict]:
    out: list[dict] = []
    for row in rows:
        text = str(row.get("text", "")).strip()
        text_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()
        embedding_id = build_embedding_id(row, text_hash)

        record = {
            "embedding_id": embedding_id,
            "chunk_id": row.get("chunk_id"),
            "source_pdf": row.get("source_pdf"),
            "source_txt": row.get("source_txt"),
            "page_start": row.get("page_start"),
            "page_end": row.get("page_end"),
            "chunk_index_in_page": row.get("chunk_index_in_page"),
            "word_count": row.get("word_count"),
            "text_sha256": text_hash,
            "text": text,
            "metadata": {
                "chunk_id": row.get("chunk_id"),
                "source_pdf": row.get("source_pdf"),
                "source_txt": row.get("source_txt"),
                "page_start": row.get("page_start"),
                "page_end": row.get("page_end"),
                "chunk_index_in_page": row.get("chunk_index_in_page"),
                "word_count": row.get("word_count"),
                "text_sha256": text_hash,
            },
        }
        out.append(record)
    return out


def write_jsonl(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def write_csv(path: Path, rows: list[dict]) -> None:
    fieldnames = [
        "embedding_id",
        "chunk_id",
        "source_pdf",
        "source_txt",
        "page_start",
        "page_end",
        "chunk_index_in_page",
        "word_count",
        "text_sha256",
        "text",
    ]
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k) for k in fieldnames})


def write_manifest(path: Path, input_path: Path, rows: list[dict]) -> None:
    by_source: dict[str, int] = {}
    for row in rows:
        source = str(row.get("source_pdf") or "unknown")
        by_source[source] = by_source.get(source, 0) + 1

    manifest = {
        "generated_at": datetime.now(UTC).isoformat(),
        "input_jsonl": str(input_path.resolve()),
        "total_records": len(rows),
        "sources": by_source,
        "fields": [
            "embedding_id",
            "chunk_id",
            "source_pdf",
            "source_txt",
            "page_start",
            "page_end",
            "chunk_index_in_page",
            "word_count",
            "text_sha256",
            "text",
            "metadata",
        ],
    }
    path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")


def main() -> None:
    args = parse_args()
    script_dir = Path(__file__).resolve().parent

    input_path = (script_dir / args.input).resolve()
    output_jsonl = (script_dir / args.output_jsonl).resolve()
    output_csv = (script_dir / args.output_csv).resolve()
    output_manifest = (script_dir / args.output_manifest).resolve()

    rows = load_jsonl(input_path)
    out = transform_rows(rows)

    write_jsonl(output_jsonl, out)
    write_csv(output_csv, out)
    write_manifest(output_manifest, input_path, out)

    print(f"Wrote {output_jsonl}")
    print(f"Wrote {output_csv}")
    print(f"Wrote {output_manifest}")
    print(f"Total records: {len(out)}")


if __name__ == "__main__":
    main()
