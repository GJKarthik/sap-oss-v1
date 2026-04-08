# =============================================================================
# spider_formatter.py — Format training pairs into Spider/BIRD dataset format
# =============================================================================
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from .template_expander import TrainingPair


@dataclass
class SpiderEntry:
    db_id: str
    question: str
    query: str


@dataclass
class SpiderSplit:
    train: list[SpiderEntry]
    dev: list[SpiderEntry]
    test_set: list[SpiderEntry]


def format_for_spider(
    pairs: list[TrainingPair],
    db_id: str = "banking_db",
    train_ratio: float = 0.8,
    dev_ratio: float = 0.1,
) -> SpiderSplit:
    """Split training pairs into train/dev/test and convert to Spider format."""
    entries = [SpiderEntry(db_id=db_id, question=p.question, query=p.sql) for p in pairs]

    total = len(entries)
    train_end = int(total * train_ratio)
    dev_end = train_end + int(total * dev_ratio)

    return SpiderSplit(
        train=entries[:train_end],
        dev=entries[train_end:dev_end],
        test_set=entries[dev_end:],
    )


def write_jsonl(entries: list[SpiderEntry], path: str | Path) -> None:
    """Write Spider entries as JSONL (one JSON object per line)."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        for entry in entries:
            line = json.dumps(
                {"db_id": entry.db_id, "question": entry.question, "query": entry.query},
                ensure_ascii=False,
            )
            fh.write(line + "\n")


def write_spider_dataset(split: SpiderSplit, output_dir: str | Path) -> None:
    """Write train/dev/test JSONL files to the output directory."""
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    write_jsonl(split.train, output_dir / "train.jsonl")
    write_jsonl(split.dev, output_dir / "dev.jsonl")
    write_jsonl(split.test_set, output_dir / "test.jsonl")
