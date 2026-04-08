#!/usr/bin/env python3
"""
Training Data Preparation Pipeline.

This script:
1. Loads all training data sources (massive generator, specialist generator, CSVs)
2. Validates and deduplicates data
3. Creates stratified train/val/test splits by domain × type
4. Exports in formats ready for nvidia-modelopt training configs
5. Updates config files with correct paths and batch sizes
6. Optionally scopes data to a team context (Country × Domain)

Usage:
    python prepare_training_data.py [--output-dir OUTPUT_DIR] [--team AE:treasury]
"""

import json
import random
import os
import argparse
import logging
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple
from collections import defaultdict
import hashlib
from dataclasses import dataclass

import sys
sys.path.insert(0, str(Path(__file__).parent.parent))
from pipeline.team_context import TeamContext, GLOBAL_CONTEXT

logger = logging.getLogger(__name__)


@dataclass
class SplitConfig:
    """Configuration for train/val/test split."""
    train_ratio: float = 0.8
    val_ratio: float = 0.1
    test_ratio: float = 0.1
    seed: int = 42
    stratify_by: Tuple[str, ...] = ("domain", "type")


class TrainingDataPreparer:
    """Prepares training data with stratified splits."""
    
    def __init__(self, output_dir: Path, team_context: Optional[TeamContext] = None):
        self.output_dir = output_dir
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.team_context = team_context or GLOBAL_CONTEXT
        
        self.all_examples: List[Dict] = []
        self.seen_hashes: Set[str] = set()
        self.stats = defaultdict(int)
    
    def _hash_example(self, example: Dict) -> str:
        """Create hash for deduplication."""
        q = example.get("question", example.get("instruction", "")) or ""
        sql = example.get("sql", example.get("output", "")) or ""
        return hashlib.md5(f"{q.lower()}|{sql.lower()}".encode()).hexdigest()
    
    def load_massive_generator_data(self, path: Path) -> int:
        """Load data from massive term generator."""
        if not path.exists():
            print(f"Warning: {path} not found")
            return 0
        
        count = 0
        with open(path) as f:
            for line in f:
                if not line.strip():
                    continue
                try:
                    ex = json.loads(line)
                    h = self._hash_example(ex)
                    if h not in self.seen_hashes:
                        self.seen_hashes.add(h)
                        # Normalize format
                        self.all_examples.append({
                            "instruction": "Generate SAP HANA SQL for the following question:",
                            "input": ex.get("question", ""),
                            "output": ex.get("sql", ""),
                            "domain": ex.get("domain", "unknown"),
                            "type": ex.get("type", "unknown"),
                            "source": "massive_generator"
                        })
                        count += 1
                except json.JSONDecodeError:
                    continue
        
        print(f"Loaded {count} examples from massive generator")
        self.stats["massive_generator"] = count
        return count
    
    def load_specialist_data(self, path: Path) -> int:
        """Load data from specialist data generator."""
        if not path.exists():
            print(f"Warning: {path} not found")
            return 0
        
        count = 0
        try:
            with open(path) as f:
                data = json.load(f)
            
            for ex in data:
                h = self._hash_example(ex)
                if h not in self.seen_hashes:
                    self.seen_hashes.add(h)
                    # Normalize format
                    self.all_examples.append({
                        "instruction": "Generate SAP HANA SQL for the following question:",
                        "input": ex.get("question", ex.get("instruction", "")),
                        "output": ex.get("sql", ex.get("output", "")),
                        "domain": ex.get("domain", "specialist"),
                        "type": ex.get("type", "specialist"),
                        "source": "specialist_generator"
                    })
                    count += 1
        except Exception as e:
            print(f"Error loading specialist data: {e}")
        
        print(f"Loaded {count} examples from specialist generator")
        self.stats["specialist_generator"] = count
        return count
    
    def load_existing_alpaca_data(self, path: Path) -> int:
        """Load existing Alpaca-format training data."""
        if not path.exists():
            print(f"Warning: {path} not found")
            return 0
        
        count = 0
        try:
            with open(path) as f:
                for line in f:
                    if not line.strip():
                        continue
                    try:
                        ex = json.loads(line)
                        h = self._hash_example(ex)
                        if h not in self.seen_hashes:
                            self.seen_hashes.add(h)
                            ex["source"] = "existing_alpaca"
                            if "domain" not in ex:
                                ex["domain"] = "general"
                            if "type" not in ex:
                                ex["type"] = "general"
                            self.all_examples.append(ex)
                            count += 1
                    except json.JSONDecodeError:
                        continue
        except Exception as e:
            print(f"Error loading existing data: {e}")
        
        print(f"Loaded {count} examples from existing Alpaca data")
        self.stats["existing_alpaca"] = count
        return count
    
    def validate_examples(self) -> Tuple[int, int]:
        """Validate all examples and remove invalid ones."""
        valid = []
        invalid = 0
        
        for ex in self.all_examples:
            # Check required fields
            if not ex.get("input") or not ex.get("output"):
                invalid += 1
                continue
            
            # Check SQL validity (basic)
            sql = ex["output"].upper()
            if not any(kw in sql for kw in ["SELECT", "INSERT", "UPDATE", "DELETE", "WITH"]):
                invalid += 1
                continue
            
            valid.append(ex)
        
        print(f"Validation: {len(valid)} valid, {invalid} invalid")
        self.all_examples = valid
        return len(valid), invalid
    
    def stratified_split(self, config: SplitConfig) -> Tuple[List[Dict], List[Dict], List[Dict]]:
        """Create stratified train/val/test splits."""
        random.seed(config.seed)
        
        # Group by stratification keys
        groups = defaultdict(list)
        for ex in self.all_examples:
            key = tuple(ex.get(k, "unknown") for k in config.stratify_by)
            groups[key].append(ex)
        
        train, val, test = [], [], []
        
        for key, examples in groups.items():
            random.shuffle(examples)
            n = len(examples)
            
            # Calculate split indices
            train_end = int(n * config.train_ratio)
            val_end = train_end + int(n * config.val_ratio)
            
            train.extend(examples[:train_end])
            val.extend(examples[train_end:val_end])
            test.extend(examples[val_end:])
        
        # Shuffle final sets
        random.shuffle(train)
        random.shuffle(val)
        random.shuffle(test)
        
        print(f"Split: train={len(train)}, val={len(val)}, test={len(test)}")
        return train, val, test
    
    def save_split(self, data: List[Dict], name: str, format: str = "jsonl") -> Path:
        """Save a split to file."""
        path = self.output_dir / f"{name}.{format}"
        
        if format == "jsonl":
            with open(path, 'w') as f:
                for ex in data:
                    f.write(json.dumps(ex) + "\n")
        elif format == "json":
            with open(path, 'w') as f:
                json.dump(data, f, indent=2)
        
        print(f"Saved {len(data)} examples to {path}")
        return path
    
    def generate_statistics(self, train: List, val: List, test: List) -> Dict:
        """Generate statistics about the dataset."""
        def count_by_key(data: List, key: str) -> Dict[str, int]:
            counts = defaultdict(int)
            for ex in data:
                counts[ex.get(key, "unknown")] += 1
            return dict(counts)
        
        stats = {
            "total_examples": len(self.all_examples),
            "train_size": len(train),
            "val_size": len(val),
            "test_size": len(test),
            "by_source": dict(self.stats),
            "train_by_domain": count_by_key(train, "domain"),
            "train_by_type": count_by_key(train, "type"),
            "val_by_domain": count_by_key(val, "domain"),
            "test_by_domain": count_by_key(test, "domain"),
        }
        
        # Save statistics
        stats_path = self.output_dir / "dataset_statistics.json"
        with open(stats_path, 'w') as f:
            json.dump(stats, f, indent=2)
        
        return stats
    
    def update_training_configs(self, train_path: Path, val_path: Path) -> None:
        """Update nvidia-modelopt config files with new data paths."""
        config_dir = Path(__file__).parent.parent / "nvidia-modelopt" / "configs"
        
        configs_to_update = [
            "t4_qwen_7b.yaml",
            "a100_qwen_9b.yaml",
            "l4_specialist.yaml",
            "h100_specialist.yaml",
            "h200_specialist.yaml",
        ]
        
        for config_name in configs_to_update:
            config_path = config_dir / config_name
            if not config_path.exists():
                continue
            
            try:
                with open(config_path) as f:
                    content = f.read()
                
                # Update train_file path
                old_pattern = 'train_file: '
                new_train_path = str(train_path.relative_to(config_dir.parent))
                
                # Simple replacement of train_file line
                lines = content.split('\n')
                updated_lines = []
                for line in lines:
                    if line.strip().startswith('train_file:'):
                        indent = len(line) - len(line.lstrip())
                        updated_lines.append(' ' * indent + f'train_file: "../schema_pipeline/output/prepared/{train_path.name}"')
                    elif line.strip().startswith('max_train_samples:'):
                        # Remove sample limit for full training
                        indent = len(line) - len(line.lstrip())
                        updated_lines.append(' ' * indent + f'max_train_samples: null  # Use full dataset')
                    else:
                        updated_lines.append(line)
                
                with open(config_path, 'w') as f:
                    f.write('\n'.join(updated_lines))
                
                print(f"Updated {config_name}")
            
            except Exception as e:
                print(f"Error updating {config_name}: {e}")
    
    def _apply_team_filter(self) -> None:
        """Filter loaded examples by team context (country/domain)."""
        if self.team_context.is_global:
            return

        before = len(self.all_examples)
        filtered: List[Dict] = []

        for ex in self.all_examples:
            # Domain filter
            if self.team_context.domain:
                ex_domain = (ex.get("domain") or "").lower()
                if ex_domain and ex_domain != "unknown" and ex_domain != self.team_context.domain:
                    continue

            # Country filter — check if country value appears in input/output text
            if self.team_context.country:
                country_val = self.team_context.country_filter_value
                text = (ex.get("input", "") + " " + ex.get("output", "")).upper()
                # Keep examples that mention this country OR are country-agnostic
                has_any_country = any(
                    cv in text for cv in [
                        "CHINA", "HONG KONG", "INDIA", "SINGAPORE",
                        "TAIWAN", "UNITED ARAB EMIRATES", "UNITED KINGDOM",
                        "UNITED STATES OF AMERICA"
                    ]
                )
                if has_any_country and country_val not in text:
                    continue

            filtered.append(ex)

        self.all_examples = filtered
        print(f"Team filter [{self.team_context.team_id}]: {before} -> {len(filtered)} examples")

    def _load_bilingual_terms(self) -> int:
        """Load Arabic bilingual training pairs when team has Arabic locale."""
        if not self.team_context.has_arabic_locale:
            return 0

        terms_path = Path(__file__).parent.parent / "data" / "arabic_financial_terms.json"
        if not terms_path.exists():
            print(f"Warning: bilingual terms file not found at {terms_path}")
            return 0

        count = 0
        try:
            with open(terms_path) as f:
                data = json.load(f)
            domain_filter = self.team_context.domain
            for domain_key, terms in data.get("terms", {}).items():
                if domain_filter and domain_key != domain_filter:
                    continue
                for term in terms:
                    ar = term.get("arabic", "")
                    en = term.get("english", "")
                    if ar and en:
                        self.all_examples.append({
                            "instruction": "Translate the following Arabic financial term to its English technical equivalent:",
                            "input": ar,
                            "output": en,
                            "domain": domain_key,
                            "type": "bilingual_term",
                            "source": "arabic_financial_terms"
                        })
                        count += 1
        except Exception as e:
            print(f"Error loading bilingual terms: {e}")

        print(f"Loaded {count} bilingual term pairs for Arabic locale")
        self.stats["bilingual_terms"] = count
        return count

    def run(self) -> Dict:
        """Run the full data preparation pipeline."""
        print("="*60)
        print("TRAINING DATA PREPARATION PIPELINE")
        if not self.team_context.is_global:
            print(f"Team context: {self.team_context.team_id}")
        print("="*60)
        
        # Define paths
        project_root = Path(__file__).parent.parent
        
        # Load all data sources
        print("\n=== Loading Data Sources ===")
        
        # 1. Massive generator data
        massive_path = project_root / "data" / "massive_semantic" / "training_data.jsonl"
        self.load_massive_generator_data(massive_path)
        
        # 2. Specialist generator data
        specialist_paths = [
            project_root / "data" / "specialist_training_data.json",
            project_root / "schema_pipeline" / "output" / "specialist_data.json",
        ]
        for sp in specialist_paths:
            if sp.exists():
                self.load_specialist_data(sp)
        
        # 3. Existing Alpaca data
        alpaca_paths = [
            project_root / "schema_pipeline" / "output" / "text2sql_alpaca" / "training_data.jsonl",
        ]
        for ap in alpaca_paths:
            if ap.exists():
                self.load_existing_alpaca_data(ap)
        
        print(f"\nTotal loaded: {len(self.all_examples)} examples")
        
        # Apply team filter
        print("\n=== Applying Team Filter ===")
        self._apply_team_filter()
        
        # Load bilingual terms for Arabic-locale teams
        self._load_bilingual_terms()
        
        # Validate
        print("\n=== Validating Data ===")
        valid, invalid = self.validate_examples()
        
        # Create splits
        print("\n=== Creating Stratified Splits ===")
        config = SplitConfig(
            train_ratio=0.85,
            val_ratio=0.10,
            test_ratio=0.05,
            seed=42,
            stratify_by=("domain", "type")
        )
        train, val, test = self.stratified_split(config)
        
        # Save splits
        print("\n=== Saving Splits ===")
        train_path = self.save_split(train, "train", "jsonl")
        val_path = self.save_split(val, "validation", "jsonl")
        test_path = self.save_split(test, "test", "jsonl")
        
        # Also save as single combined file
        self.save_split(self.all_examples, "all_data", "jsonl")
        
        # Generate statistics
        print("\n=== Generating Statistics ===")
        stats = self.generate_statistics(train, val, test)
        
        # Update configs
        print("\n=== Updating Training Configs ===")
        self.update_training_configs(train_path, val_path)
        
        # Print summary
        print("\n" + "="*60)
        print("SUMMARY")
        print("="*60)
        print(f"Total examples: {stats['total_examples']:,}")
        print(f"  - Train: {stats['train_size']:,} ({stats['train_size']/stats['total_examples']*100:.1f}%)")
        print(f"  - Val: {stats['val_size']:,} ({stats['val_size']/stats['total_examples']*100:.1f}%)")
        print(f"  - Test: {stats['test_size']:,} ({stats['test_size']/stats['total_examples']*100:.1f}%)")
        print(f"\nBy source:")
        for source, count in stats['by_source'].items():
            print(f"  - {source}: {count:,}")
        print(f"\nBy domain (train):")
        for domain, count in sorted(stats['train_by_domain'].items()):
            print(f"  - {domain}: {count:,}")
        
        print(f"\nOutput directory: {self.output_dir}")
        print(f"Files created:")
        print(f"  - train.jsonl ({stats['train_size']:,} examples)")
        print(f"  - validation.jsonl ({stats['val_size']:,} examples)")
        print(f"  - test.jsonl ({stats['test_size']:,} examples)")
        print(f"  - all_data.jsonl ({stats['total_examples']:,} examples)")
        print(f"  - dataset_statistics.json")
        
        return stats


def main():
    parser = argparse.ArgumentParser(description="Prepare training data with stratified splits")
    parser.add_argument(
        "--output-dir",
        type=str,
        default=None,
        help="Output directory for prepared data"
    )
    parser.add_argument(
        "--team",
        type=str,
        default="",
        help="Team context (e.g. 'AE:treasury', 'treasury', 'AE')"
    )
    args = parser.parse_args()
    
    # Parse team context
    team_context = TeamContext.from_cli(args.team) if args.team else GLOBAL_CONTEXT
    
    # Default output directory — append team_id for team-scoped runs
    if args.output_dir:
        output_dir = Path(args.output_dir)
    else:
        base = Path(__file__).parent.parent / "schema_pipeline" / "output" / "prepared"
        if not team_context.is_global:
            output_dir = base / team_context.team_id.replace(":", "_")
        else:
            output_dir = base
    
    preparer = TrainingDataPreparer(output_dir, team_context=team_context)
    stats = preparer.run()
    
    return stats


if __name__ == "__main__":
    main()