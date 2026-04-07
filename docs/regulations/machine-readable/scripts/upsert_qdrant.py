#!/usr/bin/env python3
"""
Embed records and upsert them into Qdrant.

Requirements:
- OpenAI-compatible embeddings endpoint
- Qdrant HTTP API
"""

from __future__ import annotations

import argparse
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Embed records and upsert to Qdrant")
    parser.add_argument(
        "--input",
        default="../rag_embedding_records.jsonl",
        help="Input records with embedding_id/text",
    )
    parser.add_argument(
        "--collection",
        default="regulations_rag",
        help="Qdrant collection name",
    )
    parser.add_argument(
        "--qdrant-url",
        default=os.getenv("QDRANT_URL", "http://localhost:6333"),
        help="Qdrant base URL",
    )
    parser.add_argument(
        "--qdrant-api-key",
        default=os.getenv("QDRANT_API_KEY", ""),
        help="Qdrant API key (optional)",
    )
    parser.add_argument(
        "--embedding-model",
        default=os.getenv("OPENAI_EMBEDDING_MODEL", "text-embedding-3-small"),
        help="Embedding model",
    )
    parser.add_argument(
        "--openai-base-url",
        default=os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1"),
        help="OpenAI-compatible base URL",
    )
    parser.add_argument(
        "--openai-api-key",
        default=os.getenv("OPENAI_API_KEY", ""),
        help="OpenAI-compatible API key",
    )
    parser.add_argument(
        "--embed-batch-size",
        type=int,
        default=64,
        help="Number of texts per embeddings request",
    )
    parser.add_argument(
        "--upsert-batch-size",
        type=int,
        default=64,
        help="Number of points per Qdrant upsert request",
    )
    parser.add_argument(
        "--distance",
        choices=["Cosine", "Dot", "Euclid"],
        default="Cosine",
        help="Qdrant distance metric",
    )
    parser.add_argument(
        "--state-file",
        default="../qdrant_upsert_state.json",
        help="Resume state file",
    )
    parser.add_argument(
        "--max-retries",
        type=int,
        default=5,
        help="HTTP retry attempts for transient errors",
    )
    parser.add_argument(
        "--request-timeout-seconds",
        type=int,
        default=60,
        help="HTTP timeout for requests",
    )
    parser.add_argument(
        "--write-embedded-jsonl",
        default="",
        help="Optional output JSONL path for records including embedding vectors",
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


def load_state(path: Path) -> set[str]:
    if not path.exists():
        return set()
    data = json.loads(path.read_text(encoding="utf-8"))
    return set(data.get("completed_embedding_ids", []))


def save_state(path: Path, completed: set[str]) -> None:
    payload = {"completed_embedding_ids": sorted(completed)}
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def http_json_request(
    method: str,
    url: str,
    payload: dict | None,
    headers: dict[str, str],
    timeout: int,
    max_retries: int,
) -> dict[str, Any]:
    body = None
    req_headers = {"Content-Type": "application/json", **headers}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")

    for attempt in range(max_retries + 1):
        request = urllib.request.Request(url, data=body, headers=req_headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                text = response.read().decode("utf-8")
                if not text:
                    return {}
                return json.loads(text)
        except urllib.error.HTTPError as exc:
            status = exc.code
            response_body = exc.read().decode("utf-8", errors="ignore")
            retryable = status == 429 or (500 <= status < 600)
            if retryable and attempt < max_retries:
                time.sleep(min(2 ** attempt, 10))
                continue
            raise RuntimeError(f"HTTP {status} for {url}: {response_body}") from exc
        except urllib.error.URLError as exc:
            if attempt < max_retries:
                time.sleep(min(2 ** attempt, 10))
                continue
            raise RuntimeError(f"Network error for {url}: {exc}") from exc

    raise RuntimeError(f"Failed request: {method} {url}")


def get_embeddings(
    texts: list[str],
    model: str,
    base_url: str,
    api_key: str,
    timeout: int,
    max_retries: int,
) -> list[list[float]]:
    url = urllib.parse.urljoin(base_url.rstrip("/") + "/", "embeddings")
    headers = {"Authorization": f"Bearer {api_key}"}
    payload = {"model": model, "input": texts}
    response = http_json_request("POST", url, payload, headers, timeout, max_retries)
    data = response.get("data", [])
    vectors = [None] * len(texts)
    for item in data:
        idx = int(item.get("index", 0))
        vectors[idx] = item.get("embedding")
    if any(v is None for v in vectors):
        raise RuntimeError("Embedding API response missing vectors")
    return vectors  # type: ignore[return-value]


def ensure_collection(
    qdrant_url: str,
    qdrant_api_key: str,
    collection: str,
    vector_size: int,
    distance: str,
    timeout: int,
    max_retries: int,
) -> None:
    headers = {}
    if qdrant_api_key:
        headers["api-key"] = qdrant_api_key

    collection_url = urllib.parse.urljoin(
        qdrant_url.rstrip("/") + "/", f"collections/{collection}"
    )
    try:
        http_json_request("GET", collection_url, None, headers, timeout, max_retries)
        return
    except RuntimeError as exc:
        if "HTTP 404" not in str(exc):
            raise

    payload = {"vectors": {"size": vector_size, "distance": distance}}
    http_json_request("PUT", collection_url, payload, headers, timeout, max_retries)


def upsert_points(
    qdrant_url: str,
    qdrant_api_key: str,
    collection: str,
    points: list[dict[str, Any]],
    timeout: int,
    max_retries: int,
) -> None:
    headers = {}
    if qdrant_api_key:
        headers["api-key"] = qdrant_api_key
    url = urllib.parse.urljoin(
        qdrant_url.rstrip("/") + "/", f"collections/{collection}/points?wait=true"
    )
    payload = {"points": points}
    http_json_request("PUT", url, payload, headers, timeout, max_retries)


def batched(rows: list[dict], size: int) -> list[list[dict]]:
    return [rows[i : i + size] for i in range(0, len(rows), size)]


def maybe_write_embedded_rows(path: Path, rows: list[dict]) -> None:
    with path.open("a", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def main() -> None:
    args = parse_args()
    if not args.openai_api_key:
        raise SystemExit("OPENAI_API_KEY (or --openai-api-key) is required")

    script_dir = Path(__file__).resolve().parent
    input_path = (script_dir / args.input).resolve()
    state_path = (script_dir / args.state_file).resolve()
    write_embedded_path = (
        (script_dir / args.write_embedded_jsonl).resolve() if args.write_embedded_jsonl else None
    )

    rows = load_jsonl(input_path)
    completed = load_state(state_path)
    pending = [row for row in rows if row.get("embedding_id") not in completed]

    if not pending:
        print("No pending records to upsert.")
        return

    first_batch = pending[: args.embed_batch_size]
    first_vectors = get_embeddings(
        [str(row.get("text", "")) for row in first_batch],
        args.embedding_model,
        args.openai_base_url,
        args.openai_api_key,
        args.request_timeout_seconds,
        args.max_retries,
    )
    vector_size = len(first_vectors[0])
    ensure_collection(
        args.qdrant_url,
        args.qdrant_api_key,
        args.collection,
        vector_size,
        args.distance,
        args.request_timeout_seconds,
        args.max_retries,
    )

    batches = batched(pending, args.embed_batch_size)
    total = len(pending)
    processed = 0

    for batch_index, batch_rows in enumerate(batches):
        if batch_index == 0:
            vectors = first_vectors
        else:
            vectors = get_embeddings(
                [str(row.get("text", "")) for row in batch_rows],
                args.embedding_model,
                args.openai_base_url,
                args.openai_api_key,
                args.request_timeout_seconds,
                args.max_retries,
            )

        points: list[dict[str, Any]] = []
        embedded_rows: list[dict] = []
        for row, vector in zip(batch_rows, vectors):
            payload = {
                "chunk_id": row.get("chunk_id"),
                "source_pdf": row.get("source_pdf"),
                "source_txt": row.get("source_txt"),
                "page_start": row.get("page_start"),
                "page_end": row.get("page_end"),
                "chunk_index_in_page": row.get("chunk_index_in_page"),
                "word_count": row.get("word_count"),
                "text_sha256": row.get("text_sha256"),
                "text": row.get("text"),
                "metadata": row.get("metadata", {}),
            }
            points.append(
                {
                    "id": row.get("embedding_id"),
                    "vector": vector,
                    "payload": payload,
                }
            )
            row_with_embedding = dict(row)
            row_with_embedding["embedding"] = vector
            row_with_embedding["embedding_model"] = args.embedding_model
            embedded_rows.append(row_with_embedding)

        for point_batch in batched(points, args.upsert_batch_size):
            upsert_points(
                args.qdrant_url,
                args.qdrant_api_key,
                args.collection,
                point_batch,
                args.request_timeout_seconds,
                args.max_retries,
            )

        for row in batch_rows:
            completed.add(str(row.get("embedding_id")))
        save_state(state_path, completed)

        if write_embedded_path:
            maybe_write_embedded_rows(write_embedded_path, embedded_rows)

        processed += len(batch_rows)
        print(f"Upserted {processed}/{total}")

    print("Completed embedding + Qdrant upsert.")
    print(f"Collection: {args.collection}")
    print(f"State file: {state_path}")
    if write_embedded_path:
        print(f"Embedded JSONL: {write_embedded_path}")


if __name__ == "__main__":
    main()
