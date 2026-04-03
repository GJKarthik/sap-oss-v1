#!/usr/bin/env python3
"""
export_gemma4_gguf.py — Export fine-tuned Gemma 4 LoRA adapter to GGUF format.

Merges the LoRA adapter with the base model using Unsloth's
save_pretrained_merged(), then exports to GGUF with configurable quantization.

Usage:
    # Default Q4_K_M quantization:
    python export_gemma4_gguf.py --adapter-dir ./outputs/gemma4-arabic

    # Specific quantization:
    python export_gemma4_gguf.py --adapter-dir ./outputs/gemma4-arabic --quantization Q8_0

    # Full precision (no quantization):
    python export_gemma4_gguf.py --adapter-dir ./outputs/gemma4-arabic --quantization F16
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

VALID_QUANTIZATIONS = ["Q4_K_M", "Q5_K_M", "Q8_0", "F16"]

DEFAULT_OUTPUT_DIR = os.path.join(
    os.path.dirname(__file__),
    "../../intelligence/vllm-main/models/gemma4-arabic-finance",
)

MODEL_CARD = {
    "model_name": "gemma4-arabic-finance",
    "base_model": "google/gemma-4-E4B-it",
    "fine_tune_method": "QLoRA (Unsloth)",
    "language": ["ar", "en"],
    "domains": [
        "Arabic financial text-to-SQL",
        "SAP HANA BPC analytics",
        "Banking regulatory reporting (SAMA/NFRP)",
    ],
    "architecture": "gemma4",
    "params_b": 8.0,
    "context_length": 8192,
    "lora_config": {
        "r": 16,
        "alpha": 16,
        "target_modules": [
            "q_proj", "k_proj", "v_proj", "o_proj",
            "gate_proj", "up_proj", "down_proj",
        ],
    },
}


def export_gguf(adapter_dir: str, output_dir: str, quantization: str) -> str:
    """Merge LoRA adapter with base and export to GGUF format.

    Returns the path to the exported GGUF file.
    """
    from unsloth import FastLanguageModel

    print(f"\n{'='*60}")
    print(f"Gemma 4 Arabic → GGUF Export")
    print(f"{'='*60}")
    print(f"  Adapter:      {adapter_dir}")
    print(f"  Output:        {output_dir}")
    print(f"  Quantization:  {quantization}")
    print(f"{'='*60}\n")

    # Load the fine-tuned model with LoRA adapter
    print("Loading fine-tuned model with LoRA adapter...")
    model, tokenizer = FastLanguageModel.from_pretrained(
        model_name=adapter_dir,
        max_seq_length=MODEL_CARD["context_length"],
        load_in_4bit=True,
    )

    os.makedirs(output_dir, exist_ok=True)

    # Merge LoRA and export to GGUF
    print(f"Merging LoRA weights and exporting GGUF ({quantization})...")
    model.save_pretrained_gguf(
        output_dir,
        tokenizer,
        quantization_method=quantization.lower(),
    )

    # Find the exported GGUF file
    gguf_files = list(Path(output_dir).glob("*.gguf"))
    if not gguf_files:
        print("ERROR: No GGUF file produced. Check Unsloth output.")
        sys.exit(1)

    gguf_path = str(gguf_files[0])
    gguf_size_mb = os.path.getsize(gguf_path) / (1024 * 1024)

    # Write model card / metadata
    metadata = {
        **MODEL_CARD,
        "quantization": quantization,
        "gguf_file": os.path.basename(gguf_path),
        "gguf_size_mb": round(gguf_size_mb, 1),
        "exported_at": datetime.now(timezone.utc).isoformat(),
        "adapter_source": os.path.abspath(adapter_dir),
    }
    metadata_path = os.path.join(output_dir, "model_card.json")
    with open(metadata_path, "w", encoding="utf-8") as f:
        json.dump(metadata, f, indent=2, ensure_ascii=False)

    print(f"\n{'='*60}")
    print(f"✓ GGUF export complete")
    print(f"{'='*60}")
    print(f"  File:  {gguf_path}")
    print(f"  Size:  {gguf_size_mb:.1f} MB")
    print(f"  Card:  {metadata_path}")
    print(f"\nTo serve:")
    print(f"  bash scripts/start_arabic_server.sh")

    return gguf_path


def main():
    parser = argparse.ArgumentParser(
        description="Export fine-tuned Gemma 4 LoRA adapter to GGUF format",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Quantization options:\n"
            "  Q4_K_M  — 4-bit, best quality/size tradeoff (default)\n"
            "  Q5_K_M  — 5-bit, slightly better quality\n"
            "  Q8_0    — 8-bit, near-lossless\n"
            "  F16     — 16-bit float, full precision\n"
        ),
    )
    parser.add_argument(
        "--adapter-dir", type=str, required=True,
        help="Path to the LoRA adapter directory (output of train_gemma4_arabic.py)",
    )
    parser.add_argument(
        "--output-dir", type=str, default=DEFAULT_OUTPUT_DIR,
        help=f"Output directory for GGUF file (default: {DEFAULT_OUTPUT_DIR})",
    )
    parser.add_argument(
        "--quantization", type=str, default="Q4_K_M",
        choices=VALID_QUANTIZATIONS,
        help="GGUF quantization method (default: Q4_K_M)",
    )
    args = parser.parse_args()

    if not os.path.isdir(args.adapter_dir):
        print(f"ERROR: Adapter directory not found: {args.adapter_dir}")
        sys.exit(1)

    export_gguf(args.adapter_dir, args.output_dir, args.quantization)


if __name__ == "__main__":
    main()
