#!/usr/bin/env python3
"""
train_gemma4_arabic.py — Fine-tune Gemma 4 E4B-it for Arabic financial text-to-SQL.

Uses Unsloth for 2x speedup + 60% less VRAM. Handles all known Gemma 4 quirks:
  - mm_token_type_ids required field (even for text-only training)
  - Gemma4ClippableLinear layer incompatible with PEFT (monkey-patched)

GPU Requirements:
  - Minimum: 1× T4 16 GB (QLoRA 4-bit)
  - Recommended: 1× A100 40 GB or L4 24 GB

Usage:
    # Dry run (CPU, 50 examples, 5 steps — verify pipeline):
    python train_gemma4_arabic.py --dry-run

    # Quick GPU test (100 steps):
    python train_gemma4_arabic.py --max-steps 100 --data-dir ./data/prepared

    # Full training (3 epochs):
    python train_gemma4_arabic.py --preset full --data-dir ./data/prepared

    # With custom model and GGUF export:
    python train_gemma4_arabic.py --model unsloth/gemma-4-E4B-it-bnb-4bit \\
        --data-dir ./data/prepared --export-gguf q4_k_m
"""

import argparse
import json
import os
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

import torch
import yaml


# ── Gemma 4 Bug Fix #1: Monkey-patch Gemma4ClippableLinear ──────────────
# PEFT rejects Gemma4ClippableLinear because it inherits nn.Module, not
# nn.Linear. We patch it before any model loading occurs.
# Ref: https://dev.to/dentity007/fine-tuning-gemma-4-on-day-zero-3-bugs-we-solved-in-30-minutes-2ke
def _patch_gemma4_clippable_linear():
    """Patch Gemma4ClippableLinear to inherit from nn.Linear so PEFT accepts it."""
    try:
        import torch.nn as nn
        from transformers.models.gemma4 import modeling_gemma4

        class PatchedClippableLinear(nn.Linear):
            def __init__(self, config, in_features, out_features):
                nn.Linear.__init__(self, in_features, out_features, bias=False)
                self.use_clipped_linears = getattr(config, "use_clipped_linears", False)
                if self.use_clipped_linears:
                    self.register_buffer("input_min", torch.tensor(-float("inf")))
                    self.register_buffer("input_max", torch.tensor(float("inf")))
                    self.register_buffer("output_min", torch.tensor(-float("inf")))
                    self.register_buffer("output_max", torch.tensor(float("inf")))

            def forward(self, x):
                if self.use_clipped_linears:
                    x = torch.clamp(x, self.input_min, self.input_max)
                out = nn.Linear.forward(self, x)
                if self.use_clipped_linears:
                    out = torch.clamp(out, self.output_min, self.output_max)
                return out

        modeling_gemma4.Gemma4ClippableLinear = PatchedClippableLinear
        print("✓ Patched Gemma4ClippableLinear for PEFT compatibility")
    except (ImportError, AttributeError):
        # transformers version without Gemma4 — skip (dry-run on older env)
        pass


# ── Gemma 4 Bug Fix #2: Custom data collator for mm_token_type_ids ──────
@dataclass
class Gemma4DataCollator:
    """Data collator that adds token_type_ids and mm_token_type_ids (all zeros).

    Gemma 4 validates these fields in its forward pass even for text-only
    training. Standard collators don't produce mm_token_type_ids.
    """
    tokenizer: object

    def __call__(self, features: list[dict]) -> dict:
        max_len = max(len(f["input_ids"]) for f in features)
        pad_id = self.tokenizer.pad_token_id or 0
        batch = {k: [] for k in ("input_ids", "attention_mask", "token_type_ids",
                                  "mm_token_type_ids", "labels")}
        for f in features:
            seq_len = len(f["input_ids"])
            pad_len = max_len - seq_len
            batch["input_ids"].append(f["input_ids"] + [pad_id] * pad_len)
            batch["attention_mask"].append([1] * seq_len + [0] * pad_len)
            batch["token_type_ids"].append([0] * max_len)
            batch["mm_token_type_ids"].append([0] * max_len)
            labels = f.get("labels", f["input_ids"])
            batch["labels"].append(labels + [-100] * pad_len)
        return {k: torch.tensor(v) for k, v in batch.items()}


# ── Config loading ──────────────────────────────────────────────────────
CONFIG_PATH = Path(__file__).parent.parent / "configs" / "gemma4_e4b_arabic.yaml"


def load_config(preset: str = "quick_test") -> dict:
    """Load config YAML and merge model/lora/data sections with the chosen preset."""
    with open(CONFIG_PATH) as f:
        raw = yaml.safe_load(f)
    cfg = {**raw.get("model", {}), **raw.get("lora", {}), **raw.get("data", {})}
    preset_cfg = raw.get(preset, raw.get("quick_test", {}))
    cfg.update(preset_cfg)
    cfg["gguf_methods"] = raw.get("gguf_export", {}).get("quantization_methods", [])
    return cfg


# ── Data loading ────────────────────────────────────────────────────────
def load_prepared_data(data_dir: Path, max_examples: int | None = None):
    """Load prepared JSONL files (output of prepare_arabic_data.py)."""
    from datasets import Dataset

    def _read_jsonl(path: Path, limit: int | None = None) -> list[dict]:
        rows = []
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                rows.append(json.loads(line))
                if limit and len(rows) >= limit:
                    break
        return rows

    train_path = data_dir / "prepared_arabic_train.jsonl"
    eval_path = data_dir / "prepared_arabic_eval.jsonl"

    if not train_path.exists():
        raise FileNotFoundError(
            f"Training data not found at {train_path}. "
            "Run prepare_arabic_data.py first."
        )

    train_rows = _read_jsonl(train_path, max_examples)
    eval_rows = _read_jsonl(eval_path, max(10, (max_examples or 100) // 20))

    return Dataset.from_list(train_rows), Dataset.from_list(eval_rows)


def tokenize_for_gemma4(dataset, tokenizer, max_seq_length: int = 2048):
    """Tokenize chat messages and add Gemma 4-required fields."""

    def _tokenize(example):
        text = tokenizer.apply_chat_template(
            example["messages"], tokenize=False, add_generation_prompt=False
        )
        tok = tokenizer(text, truncation=True, max_length=max_seq_length)
        tok["token_type_ids"] = [0] * len(tok["input_ids"])
        tok["mm_token_type_ids"] = [0] * len(tok["input_ids"])
        tok["labels"] = tok["input_ids"].copy()
        return tok

    return dataset.map(_tokenize, remove_columns=dataset.column_names)


# ── Dry-run data generation ────────────────────────────────────────────
def generate_dry_run_data(output_dir: Path, num_examples: int = 50) -> Path:
    """Generate minimal synthetic data for dry-run testing."""
    output_dir.mkdir(parents=True, exist_ok=True)

    samples = []
    questions_ar = [
        "ما هو إجمالي الإيرادات؟",
        "أظهر الدخل حسب القطاع",
        "ما هو معدل التكلفة إلى الدخل؟",
        "كم يبلغ صافي دخل الفوائد؟",
        "ما هي الأصول الممولة؟",
    ]
    questions_en = [
        "What is total revenue?",
        "Show income by segment",
        "What is the cost-to-income ratio?",
    ]
    sql_templates = [
        "SELECT SUM(AMOUNT) FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN",
        "SELECT SEGMENT, SUM(AMOUNT) FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN GROUP BY SEGMENT",
        "SELECT SUM(COST)/NULLIF(SUM(INCOME),0) FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN",
    ]
    system = "You are a financial analytics SQL assistant for SAP HANA."

    for i in range(num_examples):
        if i % 3 == 0:
            q = questions_en[i % len(questions_en)]
            lang = "en"
        else:
            q = questions_ar[i % len(questions_ar)]
            lang = "ar"
        samples.append({
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": q},
                {"role": "assistant", "content": sql_templates[i % len(sql_templates)]},
            ],
            "language": lang,
            "domain": "performance",
        })

    train_path = output_dir / "prepared_arabic_train.jsonl"
    eval_path = output_dir / "prepared_arabic_eval.jsonl"
    split = max(1, int(len(samples) * 0.95))

    for path, data in [(train_path, samples[:split]), (eval_path, samples[split:])]:
        with open(path, "w", encoding="utf-8") as f:
            for item in data:
                f.write(json.dumps(item, ensure_ascii=False) + "\n")

    return output_dir


# ── Model loading ──────────────────────────────────────────────────────
def load_model(model_name: str, cfg: dict, dry_run: bool = False):
    """Load model with Unsloth FastLanguageModel + LoRA."""
    from unsloth import FastLanguageModel

    max_seq_length = cfg.get("max_seq_length", 2048)
    load_in_4bit = cfg.get("load_in_4bit", True)
    dtype = cfg.get("dtype", None)

    if dry_run:
        # For dry-run on CPU, use smallest possible config
        load_in_4bit = False
        dtype = torch.float32

    print(f"\n{'='*60}")
    print(f"Loading model: {model_name}")
    print(f"  4-bit: {load_in_4bit}  |  dtype: {dtype}  |  seq_len: {max_seq_length}")
    print(f"{'='*60}")

    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=model_name,
        max_seq_length=max_seq_length,
        dtype=dtype,
        load_in_4bit=load_in_4bit,
    )

    # Apply LoRA
    target_modules = cfg.get("target_modules", [
        "q_proj", "k_proj", "v_proj", "o_proj",
        "gate_proj", "up_proj", "down_proj",
    ])
    model = FastLanguageModel.get_peft_model(
        model,
        r=cfg.get("r", 16),
        lora_alpha=cfg.get("alpha", 16),
        lora_dropout=cfg.get("dropout", 0.0),
        target_modules=target_modules,
        use_gradient_checkpointing="unsloth",  # 60% less VRAM
        use_rslora=cfg.get("use_rslora", False),
        loftq_config=cfg.get("loftq_config", None),
    )

    return model, tokenizer


# ── Training ───────────────────────────────────────────────────────────
def train(model, tokenizer, train_dataset, eval_dataset, cfg: dict,
          output_dir: str, max_steps: int | None = None):
    """Train with SFTTrainer (or plain Trainer) + Gemma4DataCollator."""
    from trl import SFTTrainer, SFTConfig

    training_args = SFTConfig(
        output_dir=output_dir,
        per_device_train_batch_size=cfg.get("per_device_train_batch_size", 2),
        gradient_accumulation_steps=cfg.get("gradient_accumulation_steps", 4),
        num_train_epochs=cfg.get("num_train_epochs", 1),
        max_steps=max_steps if max_steps else cfg.get("max_steps", -1),
        learning_rate=cfg.get("learning_rate", 2e-4),
        lr_scheduler_type=cfg.get("lr_scheduler_type", "linear"),
        warmup_steps=cfg.get("warmup_steps", 10),
        warmup_ratio=cfg.get("warmup_ratio", 0.0),
        weight_decay=cfg.get("weight_decay", 0.01),
        max_grad_norm=cfg.get("max_grad_norm", 1.0),
        optim=cfg.get("optim", "adamw_8bit"),
        bf16=cfg.get("bf16", True) and torch.cuda.is_available(),
        fp16=False,
        logging_steps=cfg.get("logging_steps", 10),
        save_strategy=cfg.get("save_strategy", "steps"),
        save_steps=cfg.get("save_steps", 50),
        save_total_limit=cfg.get("save_total_limit", 1),
        eval_strategy=cfg.get("eval_strategy", "steps"),
        eval_steps=cfg.get("eval_steps", 50),
        seed=cfg.get("seed", 42),
        report_to="none",
        dataset_text_field=None,
        remove_unused_columns=False,  # Critical for Gemma 4 mm_token_type_ids
        max_seq_length=cfg.get("max_seq_length", 2048),
        packing=cfg.get("packing", False),
    )

    trainer = SFTTrainer(
        model=model,
        args=training_args,
        train_dataset=train_dataset,
        eval_dataset=eval_dataset,
        data_collator=Gemma4DataCollator(tokenizer),
    )

    print(f"\n{'='*60}")
    print("Starting Gemma 4 E4B Arabic Fine-Tuning")
    print(f"{'='*60}")
    print(f"  Train examples: {len(train_dataset):,}")
    print(f"  Eval examples:  {len(eval_dataset):,}")
    print(f"  Batch size:     {training_args.per_device_train_batch_size} × "
          f"{training_args.gradient_accumulation_steps}")
    print(f"  Max steps:      {training_args.max_steps}")
    print(f"  Learning rate:  {training_args.learning_rate}")

    trainer.train()

    # Save LoRA adapter
    model.save_pretrained(output_dir)
    tokenizer.save_pretrained(output_dir)
    print(f"\n✓ LoRA adapter saved to {output_dir}")

    return trainer


# ── GGUF export ────────────────────────────────────────────────────────
def export_gguf(model, tokenizer, output_dir: str, methods: list[str]):
    """Export model to GGUF format via Unsloth."""
    for method in methods:
        gguf_dir = os.path.join(output_dir, f"gguf-{method}")
        print(f"Exporting GGUF ({method}) to {gguf_dir} ...")
        model.save_pretrained_gguf(gguf_dir, tokenizer, quantization_method=method)
        print(f"  ✓ {method} export complete")


# ── Main ───────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="Fine-tune Gemma 4 E4B-it for Arabic text-to-SQL (Unsloth)"
    )
    parser.add_argument("--model", default="unsloth/gemma-4-E4B-it-bnb-4bit",
                        help="Model name or path (default: unsloth/gemma-4-E4B-it-bnb-4bit)")
    parser.add_argument("--preset", default="quick_test", choices=["quick_test", "full_train"],
                        help="Config preset (default: quick_test)")
    parser.add_argument("--dry-run", action="store_true",
                        help="CPU dry run: 50 synthetic examples, 5 steps")
    parser.add_argument("--max-steps", type=int, default=None,
                        help="Override max training steps")
    parser.add_argument("--output-dir", type=Path, default=Path("./outputs/gemma4-arabic"),
                        help="Output directory for LoRA adapter")
    parser.add_argument("--data-dir", type=Path, default=Path("./data/prepared"),
                        help="Directory with prepared JSONL files")
    parser.add_argument("--arabic-ratio", type=float, default=0.7,
                        help="Arabic data ratio (used only with --dry-run)")
    parser.add_argument("--export-gguf", type=str, default=None,
                        help="GGUF quantization method (e.g. q4_k_m, q8_0)")
    args = parser.parse_args()

    # Patch Gemma 4 quirks before loading
    _patch_gemma4_clippable_linear()

    # Load config
    cfg = load_config(args.preset)

    if args.dry_run:
        print("\n🧪 DRY RUN MODE — synthetic data, 5 steps, CPU")
        args.max_steps = 5
        args.model = "unsloth/gemma-4-E4B-it-bnb-4bit"
        tmp_dir = Path(tempfile.mkdtemp(prefix="gemma4_dryrun_"))
        args.data_dir = generate_dry_run_data(tmp_dir, num_examples=50)
        args.output_dir = tmp_dir / "output"

    # Load data
    train_ds, eval_ds = load_prepared_data(args.data_dir, max_examples=50 if args.dry_run else None)
    print(f"Loaded {len(train_ds):,} train + {len(eval_ds):,} eval examples")

    # Load model
    model, tokenizer = load_model(args.model, cfg, dry_run=args.dry_run)

    # Tokenize
    print("Tokenizing datasets ...")
    max_seq = cfg.get("max_seq_length", 2048)
    train_tok = tokenize_for_gemma4(train_ds, tokenizer, max_seq)
    eval_tok = tokenize_for_gemma4(eval_ds, tokenizer, max_seq)

    # Train
    output_dir = str(args.output_dir)
    os.makedirs(output_dir, exist_ok=True)
    trainer = train(model, tokenizer, train_tok, eval_tok, cfg, output_dir, args.max_steps)

    # GGUF export
    if args.export_gguf:
        export_gguf(model, tokenizer, output_dir, [args.export_gguf])
    elif not args.dry_run and cfg.get("gguf_methods"):
        print("\nTip: export GGUF with --export-gguf q4_k_m")

    print(f"\n{'='*60}")
    print("✓ COMPLETE")
    print(f"{'='*60}")
    print(f"  Output: {output_dir}")
    if args.dry_run:
        print("  (dry-run — output is ephemeral)")


if __name__ == "__main__":
    main()