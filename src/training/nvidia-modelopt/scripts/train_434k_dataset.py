#!/usr/bin/env python3
"""
Training Script for 434K Semantic SQL Dataset.

Optimized for:
- T4 (16GB): Qwen2.5-0.5B or 3B with aggressive quantization
- L4 (24GB): Qwen2.5-7B with 4-bit quantization
- A100 (40GB): Qwen2.5-14B

Usage:
    python train_434k_dataset.py --gpu t4|l4|a100 [--epochs 3] [--samples N]
"""

import os
import sys
import argparse
import json
import torch
from pathlib import Path
from datetime import datetime

# Suppress warnings
os.environ["TOKENIZERS_PARALLELISM"] = "false"
os.environ["TRANSFORMERS_NO_ADVISORY_WARNINGS"] = "1"


def setup_logging(gpu_type: str):
    """Setup logging to file and console."""
    log_dir = Path("~/training/logs").expanduser()
    log_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    log_file = log_dir / f"train_{gpu_type}_{timestamp}.log"
    return log_file


def get_gpu_config(gpu_type: str) -> dict:
    """Get GPU-specific configuration."""
    configs = {
        "t4": {
            "model_id": "Qwen/Qwen2.5-0.5B-Instruct",  # Smaller model for T4
            "max_seq_length": 512,
            "batch_size": 4,
            "gradient_accumulation": 8,
            "lora_r": 16,
            "lora_alpha": 32,
            "learning_rate": 2e-4,
            "epochs": 3,
            "fp16": True,
            "bf16": False,
            "quantize_4bit": True,
        },
        "l4": {
            "model_id": "Qwen/Qwen2.5-7B-Instruct",
            "max_seq_length": 1024,
            "batch_size": 2,
            "gradient_accumulation": 16,
            "lora_r": 32,
            "lora_alpha": 64,
            "learning_rate": 1e-4,
            "epochs": 3,
            "fp16": False,
            "bf16": True,
            "quantize_4bit": True,
        },
        "a100": {
            "model_id": "Qwen/Qwen2.5-14B-Instruct",
            "max_seq_length": 2048,
            "batch_size": 4,
            "gradient_accumulation": 8,
            "lora_r": 64,
            "lora_alpha": 128,
            "learning_rate": 5e-5,
            "epochs": 3,
            "fp16": False,
            "bf16": True,
            "quantize_4bit": True,
        },
    }
    return configs.get(gpu_type, configs["t4"])


def load_training_data(data_path: str, max_samples: int = None) -> list:
    """Load training data from JSONL file."""
    data = []
    with open(data_path, 'r') as f:
        for i, line in enumerate(f):
            if max_samples and i >= max_samples:
                break
            try:
                item = json.loads(line.strip())
                data.append(item)
            except json.JSONDecodeError:
                continue
    return data


def format_example(item: dict, tokenizer) -> str:
    """Format a single training example in ChatML format."""
    instruction = item.get("instruction", "Generate SAP HANA SQL for the following question:")
    input_text = item.get("input", "")
    output = item.get("output", "")
    
    # ChatML format for Qwen
    formatted = f"""<|im_start|>system
You are an expert SAP HANA SQL generator. Generate precise, executable SQL queries for banking and financial data.
<|im_end|>
<|im_start|>user
{instruction}

{input_text}
<|im_end|>
<|im_start|>assistant
{output}
<|im_end|>"""
    return formatted


def main():
    parser = argparse.ArgumentParser(description="Train Qwen on 434K semantic SQL dataset")
    parser.add_argument("--gpu", type=str, default="t4", choices=["t4", "l4", "a100"],
                        help="GPU type for optimization")
    parser.add_argument("--epochs", type=int, default=None, help="Override epochs")
    parser.add_argument("--samples", type=int, default=None, help="Limit training samples")
    parser.add_argument("--data", type=str, default="~/training/data/train.jsonl",
                        help="Path to training data")
    parser.add_argument("--output", type=str, default="~/training/outputs",
                        help="Output directory")
    args = parser.parse_args()
    
    # Get GPU config
    config = get_gpu_config(args.gpu)
    if args.epochs:
        config["epochs"] = args.epochs
    
    print("=" * 60)
    print(f"SEMANTIC SQL TRAINING - {args.gpu.upper()} GPU")
    print(f"Model: {config['model_id']}")
    print(f"Dataset: 434K examples")
    print("=" * 60)
    
    # Check GPU
    if not torch.cuda.is_available():
        print("ERROR: No GPU available!")
        sys.exit(1)
    
    gpu_name = torch.cuda.get_device_name(0)
    gpu_mem = torch.cuda.get_device_properties(0).total_memory / 1e9
    print(f"GPU: {gpu_name} ({gpu_mem:.1f} GB)")
    
    # Import training libraries
    print("\nLoading libraries...")
    from transformers import (
        AutoModelForCausalLM, 
        AutoTokenizer, 
        TrainingArguments, 
        Trainer,
        DataCollatorForLanguageModeling,
        BitsAndBytesConfig
    )
    from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
    from datasets import Dataset
    
    # Load data
    data_path = Path(args.data).expanduser()
    print(f"\nLoading data from {data_path}...")
    training_data = load_training_data(str(data_path), args.samples)
    print(f"Loaded {len(training_data):,} examples")
    
    # Load tokenizer
    print(f"\nLoading tokenizer: {config['model_id']}...")
    tokenizer = AutoTokenizer.from_pretrained(config["model_id"], trust_remote_code=True)
    tokenizer.pad_token = tokenizer.eos_token
    tokenizer.padding_side = "right"
    
    # Quantization config
    bnb_config = None
    if config["quantize_4bit"]:
        bnb_config = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_quant_type="nf4",
            bnb_4bit_compute_dtype=torch.bfloat16 if config["bf16"] else torch.float16,
            bnb_4bit_use_double_quant=True
        )
    
    # Load model
    print(f"\nLoading model: {config['model_id']}...")
    model = AutoModelForCausalLM.from_pretrained(
        config["model_id"],
        quantization_config=bnb_config,
        device_map="auto",
        trust_remote_code=True,
        torch_dtype=torch.bfloat16 if config["bf16"] else torch.float16
    )
    
    if config["quantize_4bit"]:
        model = prepare_model_for_kbit_training(model)
    
    # LoRA configuration
    lora_config = LoraConfig(
        r=config["lora_r"],
        lora_alpha=config["lora_alpha"],
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
        lora_dropout=0.05,
        bias="none",
        task_type="CAUSAL_LM"
    )
    
    model = get_peft_model(model, lora_config)
    model.print_trainable_parameters()
    
    # Prepare dataset
    print("\nPreparing dataset...")
    texts = [format_example(item, tokenizer) for item in training_data]
    dataset = Dataset.from_dict({"text": texts})
    
    def tokenize_function(examples):
        return tokenizer(
            examples["text"],
            truncation=True,
            max_length=config["max_seq_length"],
            padding="max_length"
        )
    
    tokenized_dataset = dataset.map(
        tokenize_function,
        batched=True,
        remove_columns=["text"],
        num_proc=4
    )
    
    # Training arguments
    output_dir = Path(args.output).expanduser() / f"semantic_sql_{args.gpu}_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    output_dir.mkdir(parents=True, exist_ok=True)
    
    training_args = TrainingArguments(
        output_dir=str(output_dir),
        num_train_epochs=config["epochs"],
        per_device_train_batch_size=config["batch_size"],
        gradient_accumulation_steps=config["gradient_accumulation"],
        learning_rate=config["learning_rate"],
        warmup_ratio=0.1,
        logging_steps=10,
        save_steps=500,
        save_total_limit=3,
        fp16=config["fp16"],
        bf16=config["bf16"],
        optim="paged_adamw_8bit",
        report_to="none",
        gradient_checkpointing=True,
        dataloader_num_workers=2,
        seed=42,
    )
    
    # Data collator
    data_collator = DataCollatorForLanguageModeling(
        tokenizer=tokenizer,
        mlm=False
    )
    
    # Create trainer
    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=tokenized_dataset,
        data_collator=data_collator,
    )
    
    # Train
    print("\n" + "=" * 60)
    print("STARTING TRAINING")
    print(f"Output: {output_dir}")
    print("=" * 60)
    
    trainer.train()
    
    # Save model
    print("\nSaving model...")
    model.save_pretrained(output_dir / "final_model")
    tokenizer.save_pretrained(output_dir / "final_model")
    
    print("\n" + "=" * 60)
    print("TRAINING COMPLETE!")
    print(f"Model saved to: {output_dir / 'final_model'}")
    print("=" * 60)


if __name__ == "__main__":
    main()