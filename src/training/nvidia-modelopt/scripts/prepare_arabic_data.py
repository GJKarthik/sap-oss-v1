#!/usr/bin/env python3
"""
prepare_arabic_data.py — Data adapter for Arabic text-to-SQL fine-tuning with Gemma 4.

Converts our JSONL format (question/sql/domain/system_prompt) into Gemma 4
chat template format (system/user/assistant roles) for SFT training.

Reads:
  - Arabic training pairs:  src/training/data/arabic_training/arabic_training_pairs.jsonl
  - English specialist data: src/training/data/specialist_training/train_*.json

Outputs:
  - prepared_arabic_train.jsonl  (95% of data)
  - prepared_arabic_eval.jsonl   (5% of data)

Usage:
    python prepare_arabic_data.py --max-samples 100 --output-dir /tmp/test_data
    python prepare_arabic_data.py --arabic-ratio 0.7 --max-samples 50000 --output-dir ./data/prepared
"""

import argparse
import json
import random
import sys
from pathlib import Path

# Default paths relative to repo root
REPO_ROOT = Path(__file__).resolve().parents[4]  # sap-oss-v1/
DEFAULT_ARABIC_PATH = REPO_ROOT / "src/training/data/arabic_training/arabic_training_pairs.jsonl"
DEFAULT_ENGLISH_DIR = REPO_ROOT / "src/training/data/specialist_training"

DEFAULT_SYSTEM_PROMPT = (
    "You are a financial analytics SQL assistant for SAP HANA. "
    "Generate precise SQL queries for the user's request."
)


def load_arabic_data(path: Path, max_samples: int | None = None) -> list[dict]:
    """Load Arabic training pairs from JSONL."""
    data = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            question = item.get("question", "").strip()
            sql = item.get("sql", "").strip()
            if not question or not sql:
                continue
            data.append({
                "messages": [
                    {"role": "system", "content": item.get("system_prompt", DEFAULT_SYSTEM_PROMPT)},
                    {"role": "user", "content": question},
                    {"role": "assistant", "content": sql},
                ],
                "language": "ar",
                "domain": item.get("domain", "unknown"),
            })
            if max_samples and len(data) >= max_samples:
                break
    return data


def load_english_data(directory: Path, max_samples: int | None = None) -> list[dict]:
    """Load English specialist training data from JSON files."""
    data = []
    for json_file in sorted(directory.glob("train_*.json")):
        if "router" in json_file.name:
            continue  # Skip router data — different format (question/label, no SQL)
        try:
            with open(json_file, encoding="utf-8") as f:
                items = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue
        for item in items:
            question = item.get("question", "").strip()
            sql = item.get("sql", "").strip()
            if not question or not sql:
                continue
            data.append({
                "messages": [
                    {"role": "system", "content": DEFAULT_SYSTEM_PROMPT},
                    {"role": "user", "content": question},
                    {"role": "assistant", "content": sql},
                ],
                "language": "en",
                "domain": item.get("domain", "unknown"),
            })
    if max_samples and len(data) > max_samples:
        random.shuffle(data)
        data = data[:max_samples]
    return data


def mix_and_split(
    arabic: list[dict],
    english: list[dict],
    arabic_ratio: float = 0.7,
    eval_ratio: float = 0.05,
    seed: int = 42,
) -> tuple[list[dict], list[dict]]:
    """Mix Arabic/English data at the desired ratio and split train/eval."""
    rng = random.Random(seed)

    # Determine target counts based on ratio
    if arabic_ratio >= 1.0:
        combined = arabic
    elif arabic_ratio <= 0.0:
        combined = english
    else:
        # Size the English portion relative to Arabic
        target_english = int(len(arabic) * (1 - arabic_ratio) / arabic_ratio)
        if target_english > len(english):
            # Not enough English data — use all of it and reduce Arabic
            target_arabic = int(len(english) * arabic_ratio / (1 - arabic_ratio))
            combined = rng.sample(arabic, min(target_arabic, len(arabic))) + english
        else:
            combined = arabic + rng.sample(english, target_english)

    rng.shuffle(combined)

    split_idx = max(1, int(len(combined) * (1 - eval_ratio)))
    return combined[:split_idx], combined[split_idx:]


def write_jsonl(data: list[dict], path: Path) -> None:
    """Write list of dicts as JSONL, preserving Unicode (Arabic text)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for item in data:
            f.write(json.dumps(item, ensure_ascii=False) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description="Prepare Arabic+English data for Gemma 4 fine-tuning")
    parser.add_argument("--arabic-path", type=Path, default=DEFAULT_ARABIC_PATH,
                        help="Path to arabic_training_pairs.jsonl")
    parser.add_argument("--english-dir", type=Path, default=DEFAULT_ENGLISH_DIR,
                        help="Directory with English train_*.json files")
    parser.add_argument("--arabic-ratio", type=float, default=0.7,
                        help="Fraction of Arabic data in the mix (default: 0.7)")
    parser.add_argument("--max-samples", type=int, default=None,
                        help="Max total samples (applied per-language before mixing)")
    parser.add_argument("--output-dir", type=Path, default=Path("./data/prepared"),
                        help="Output directory for prepared JSONL files")
    parser.add_argument("--seed", type=int, default=42, help="Random seed")
    args = parser.parse_args()

    print(f"Loading Arabic data from {args.arabic_path} ...")
    ar_max = int(args.max_samples * args.arabic_ratio) if args.max_samples else None
    arabic = load_arabic_data(args.arabic_path, ar_max)
    print(f"  Loaded {len(arabic):,} Arabic examples")

    print(f"Loading English data from {args.english_dir} ...")
    en_max = int(args.max_samples * (1 - args.arabic_ratio)) if args.max_samples else None
    english = load_english_data(args.english_dir, en_max)
    print(f"  Loaded {len(english):,} English examples")

    train, eval_set = mix_and_split(arabic, english, args.arabic_ratio, seed=args.seed)

    train_path = args.output_dir / "prepared_arabic_train.jsonl"
    eval_path = args.output_dir / "prepared_arabic_eval.jsonl"

    write_jsonl(train, train_path)
    write_jsonl(eval_set, eval_path)

    # Summary
    ar_train = sum(1 for x in train if x["language"] == "ar")
    en_train = sum(1 for x in train if x["language"] == "en")
    print(f"\n{'='*50}")
    print(f"Train: {len(train):,} examples  (Arabic: {ar_train:,}, English: {en_train:,})")
    print(f"Eval:  {len(eval_set):,} examples")
    print(f"Arabic ratio: {ar_train / max(len(train), 1):.1%}")
    print(f"Output: {train_path}")
    print(f"        {eval_path}")

    # Verify first example
    if train:
        sample = train[0]
        print(f"\nSample message roles: {[m['role'] for m in sample['messages']]}")
        print(f"Sample user content:  {sample['messages'][1]['content'][:80]}")


if __name__ == "__main__":
    main()
