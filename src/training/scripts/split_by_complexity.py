#!/usr/bin/env python3
"""
split_by_complexity.py — Split training data by complexity percentile.

Implements the complexity stratification from Figure 7 of the Simula paper.
The paper shows that complexity splits have domain-dependent downstream effects:
- GSM8k/CTI MCQ: Higher complexity → better performance
- LEXam: Lower complexity → better performance (weak teacher)

Usage:
    python -m src.training.scripts.split_by_complexity \
        --input data/training/training_data.jsonl \
        --scores data/training/complexity_elo_scores.json \
        --low-output data/training/low_complexity.jsonl \
        --high-output data/training/high_complexity.jsonl \
        --low-percentile 40 \
        --high-percentile 60

Reference: Davidson et al. (2026) "Reasoning-Driven Synthetic Data Generation"
           TMLR, Figure 7 (Downstream Impact of Data Complexity)
"""

import argparse
import json
import logging
import sys
from pathlib import Path
from typing import Optional

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)


def load_jsonl(path: Path) -> list[dict]:
    """Load JSONL file."""
    examples = []
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if line:
                examples.append(json.loads(line))
    return examples


def save_jsonl(examples: list[dict], path: Path) -> None:
    """Save examples to JSONL file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        for ex in examples:
            f.write(json.dumps(ex) + "\n")


def load_complexity_scores(path: Path) -> dict[str, float]:
    """Load complexity scores from JSON file."""
    with open(path, "r") as f:
        data = json.load(f)
    
    # Handle both formats: {id: score} or {"scores": {id: {...}}}
    if "scores" in data:
        return {
            ex_id: info.get("elo_rating", info.get("normalized_score", 0.5))
            for ex_id, info in data["scores"].items()
        }
    return data


def split_by_complexity(
    examples: list[dict],
    scores: dict[str, float],
    low_percentile: float = 40,
    high_percentile: float = 60,
) -> tuple[list[dict], list[dict], list[dict]]:
    """
    Split examples into low, mid, and high complexity sets.
    
    From Figure 7:
    "For each data size, we split datasets produced by the full system into
    three subsets. To avoid confounding missing complex concepts with
    complexification per concept, we sample by complexity score per taxonomy node."
    
    Args:
        examples: Training examples with 'id' field
        scores: Mapping of example ID to complexity score
        low_percentile: Percentile cutoff for low complexity (default 40%)
        high_percentile: Percentile cutoff for high complexity (default 60%)
        
    Returns:
        (low_complexity, mid_complexity, high_complexity) lists
    """
    # Get scores for all examples
    scored_examples = []
    for ex in examples:
        ex_id = ex.get("id", "")
        score = scores.get(ex_id)
        if score is not None:
            scored_examples.append((ex, score))
        else:
            # Default to mid-range if no score
            scored_examples.append((ex, 0.5))
    
    # Sort by score
    scored_examples.sort(key=lambda x: x[1])
    
    # Calculate percentile indices
    n = len(scored_examples)
    low_idx = int(n * low_percentile / 100)
    high_idx = int(n * high_percentile / 100)
    
    # Split
    low = [ex for ex, _ in scored_examples[:low_idx]]
    mid = [ex for ex, _ in scored_examples[low_idx:high_idx]]
    high = [ex for ex, _ in scored_examples[high_idx:]]
    
    return low, mid, high


def main():
    parser = argparse.ArgumentParser(
        description="Split training data by complexity percentile (Figure 7)."
    )
    parser.add_argument(
        "--input", "-i",
        type=Path,
        required=True,
        help="Input JSONL file with training examples",
    )
    parser.add_argument(
        "--scores", "-s",
        type=Path,
        required=True,
        help="JSON file with complexity scores (from complexity calibrator)",
    )
    parser.add_argument(
        "--low-output",
        type=Path,
        default=None,
        help="Output path for low complexity examples",
    )
    parser.add_argument(
        "--mid-output",
        type=Path,
        default=None,
        help="Output path for mid complexity examples",
    )
    parser.add_argument(
        "--high-output",
        type=Path,
        default=None,
        help="Output path for high complexity examples",
    )
    parser.add_argument(
        "--output-dir", "-o",
        type=Path,
        default=None,
        help="Output directory (alternative to individual paths)",
    )
    parser.add_argument(
        "--low-percentile",
        type=float,
        default=40,
        help="Percentile cutoff for low complexity (default: 40)",
    )
    parser.add_argument(
        "--high-percentile",
        type=float,
        default=60,
        help="Percentile cutoff for high complexity (default: 60)",
    )
    parser.add_argument(
        "--include-mid",
        action="store_true",
        help="Include mid-complexity split in output",
    )
    parser.add_argument(
        "--stats-only",
        action="store_true",
        help="Only print statistics, don't write files",
    )
    
    args = parser.parse_args()
    
    # Validate inputs
    if not args.input.exists():
        logger.error(f"Input file not found: {args.input}")
        sys.exit(1)
    
    if not args.scores.exists():
        logger.error(f"Scores file not found: {args.scores}")
        sys.exit(1)
    
    # Determine output paths
    if args.output_dir:
        args.output_dir.mkdir(parents=True, exist_ok=True)
        low_output = args.low_output or args.output_dir / "low_complexity.jsonl"
        mid_output = args.mid_output or args.output_dir / "mid_complexity.jsonl"
        high_output = args.high_output or args.output_dir / "high_complexity.jsonl"
    else:
        low_output = args.low_output or args.input.parent / "low_complexity.jsonl"
        mid_output = args.mid_output or args.input.parent / "mid_complexity.jsonl"
        high_output = args.high_output or args.input.parent / "high_complexity.jsonl"
    
    # Load data
    logger.info(f"Loading examples from {args.input}")
    examples = load_jsonl(args.input)
    logger.info(f"Loaded {len(examples)} examples")
    
    logger.info(f"Loading complexity scores from {args.scores}")
    scores = load_complexity_scores(args.scores)
    logger.info(f"Loaded scores for {len(scores)} examples")
    
    # Split
    logger.info(
        f"Splitting by complexity: low<{args.low_percentile}%, "
        f"high>{args.high_percentile}%"
    )
    low, mid, high = split_by_complexity(
        examples,
        scores,
        low_percentile=args.low_percentile,
        high_percentile=args.high_percentile,
    )
    
    # Report statistics
    logger.info(f"Split results:")
    logger.info(f"  Low complexity:  {len(low):,} examples ({100*len(low)/len(examples):.1f}%)")
    logger.info(f"  Mid complexity:  {len(mid):,} examples ({100*len(mid)/len(examples):.1f}%)")
    logger.info(f"  High complexity: {len(high):,} examples ({100*len(high)/len(examples):.1f}%)")
    
    if args.stats_only:
        logger.info("Stats-only mode, not writing files")
        return
    
    # Save outputs
    logger.info(f"Saving low complexity to {low_output}")
    save_jsonl(low, low_output)
    
    if args.include_mid:
        logger.info(f"Saving mid complexity to {mid_output}")
        save_jsonl(mid, mid_output)
    
    logger.info(f"Saving high complexity to {high_output}")
    save_jsonl(high, high_output)
    
    # Write summary
    summary_path = (args.output_dir or args.input.parent) / "complexity_split_summary.json"
    summary = {
        "input_file": str(args.input),
        "scores_file": str(args.scores),
        "total_examples": len(examples),
        "low_percentile": args.low_percentile,
        "high_percentile": args.high_percentile,
        "splits": {
            "low": {
                "count": len(low),
                "percentage": 100 * len(low) / len(examples),
                "output_file": str(low_output),
            },
            "mid": {
                "count": len(mid),
                "percentage": 100 * len(mid) / len(examples),
                "output_file": str(mid_output) if args.include_mid else None,
            },
            "high": {
                "count": len(high),
                "percentage": 100 * len(high) / len(examples),
                "output_file": str(high_output),
            },
        },
    }
    
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
    logger.info(f"Saved split summary to {summary_path}")
    
    logger.info("Done!")


if __name__ == "__main__":
    main()