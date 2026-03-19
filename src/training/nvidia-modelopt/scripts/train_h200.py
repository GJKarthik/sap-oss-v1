#!/usr/bin/env python3
"""
train_h200.py - H200 141GB Optimized Training Script for Specialist Models

Hardware: NVIDIA H200 (141 GiB), 24 CPUs, 240 GiB RAM
Model: Qwen/Qwen2.5-14B-Instruct (or 7B for faster training)
Training: Full BF16 precision, no quantization needed

Usage:
    python train_h200.py --specialist performance
    python train_h200.py --specialist all
"""

import os
import sys
import json
import argparse
import torch
from pathlib import Path
from datetime import datetime

# H200 optimizations
os.environ["PYTORCH_CUDA_ALLOC_CONF"] = "expandable_segments:True"
os.environ["TOKENIZERS_PARALLELISM"] = "false"

def setup_h200():
    """Configure H200 GPU optimizations."""
    print("=" * 60)
    print("H200 141GB Training Environment Setup")
    print("=" * 60)
    
    # Check GPU
    if torch.cuda.is_available():
        gpu_name = torch.cuda.get_device_name(0)
        gpu_mem = torch.cuda.get_device_properties(0).total_memory / 1e9
        print(f"GPU: {gpu_name}")
        print(f"VRAM: {gpu_mem:.1f} GB")
        print(f"CUDA: {torch.version.cuda}")
        
        # Enable TF32 for Hopper architecture
        torch.backends.cuda.matmul.allow_tf32 = True
        torch.backends.cudnn.allow_tf32 = True
        print("TF32 enabled for faster matrix operations")
    else:
        print("ERROR: No GPU detected!")
        sys.exit(1)
    
    print("=" * 60)


def get_specialist_config(specialist: str) -> dict:
    """Get configuration for specific specialist."""
    configs = {
        "performance": {
            "name": "Performance/P&L Specialist",
            "train_file": "train_performance.json",
            "output_dir": "outputs/performance-specialist",
            "description": "Income Statement, Revenue, Costs, Impairment",
        },
        "balance_sheet": {
            "name": "Balance Sheet Specialist", 
            "train_file": "train_balance_sheet.json",
            "output_dir": "outputs/balance_sheet-specialist",
            "description": "Assets, Liabilities, CASA, RWA",
        },
        "treasury": {
            "name": "Treasury/ALM Specialist",
            "train_file": "train_treasury.json",
            "output_dir": "outputs/treasury-specialist",
            "description": "Bonds, IRS, Issuances, ISIN positions",
        },
        "esg": {
            "name": "ESG/Carbon Specialist",
            "train_file": "train_esg.json",
            "output_dir": "outputs/esg-specialist",
            "description": "Financed Emissions, Net Zero, Sustainable Finance",
        },
        "router": {
            "name": "Semantic Router",
            "train_file": "train_router.json",
            "output_dir": "outputs/router",
            "description": "Domain classification model",
            "model_override": "Qwen/Qwen2.5-0.5B-Instruct",  # Smaller model for router
        },
    }
    return configs.get(specialist)


def create_training_data(specialist: str, data_dir: str = "data/specialist_training"):
    """Generate training data if not exists."""
    data_path = Path(data_dir)
    data_path.mkdir(parents=True, exist_ok=True)
    
    config = get_specialist_config(specialist)
    train_file = data_path / config["train_file"]
    
    if train_file.exists():
        print(f"Training data exists: {train_file}")
        with open(train_file) as f:
            data = json.load(f)
        print(f"  Examples: {len(data)}")
        return str(train_file)
    
    print(f"Generating training data for {specialist}...")
    
    # Import generator
    sys.path.insert(0, str(Path(__file__).parent.parent / "schema_pipeline"))
    from specialist_data_generator import SpecialistDataGenerator
    
    generator = SpecialistDataGenerator()
    
    gen_funcs = {
        "performance": generator.generate_performance_examples,
        "balance_sheet": generator.generate_balance_sheet_examples,
        "treasury": generator.generate_treasury_examples,
        "esg": generator.generate_esg_examples,
        "router": generator.generate_router_examples,
    }
    
    examples_count = 50000 if specialist == "router" else 100000
    data = gen_funcs[specialist](examples_count)
    
    with open(train_file, "w") as f:
        json.dump(data, f, indent=2)
    
    print(f"  Generated {len(data)} examples to {train_file}")
    return str(train_file)


def train_specialist(specialist: str, model_name: str = "Qwen/Qwen2.5-14B-Instruct"):
    """Train a specialist model on H200."""
    from transformers import (
        AutoModelForCausalLM,
        AutoTokenizer,
        TrainingArguments,
        Trainer,
        DataCollatorForLanguageModeling,
    )
    from peft import LoraConfig, get_peft_model, TaskType
    from datasets import Dataset
    
    config = get_specialist_config(specialist)
    if not config:
        print(f"Unknown specialist: {specialist}")
        return
    
    # Use smaller model for router
    if "model_override" in config:
        model_name = config["model_override"]
    
    print(f"\n{'='*60}")
    print(f"Training: {config['name']}")
    print(f"Model: {model_name}")
    print(f"Description: {config['description']}")
    print(f"{'='*60}\n")
    
    # Generate/load training data
    train_file = create_training_data(specialist)
    
    # Load data
    with open(train_file) as f:
        data = json.load(f)
    
    print(f"Loaded {len(data)} training examples")
    
    # Load tokenizer
    print(f"\nLoading tokenizer...")
    tokenizer = AutoTokenizer.from_pretrained(model_name, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    
    # Load model - Full BF16 on H200 (no quantization needed!)
    print(f"\nLoading model in BF16 (full precision on H200)...")
    model = AutoModelForCausalLM.from_pretrained(
        model_name,
        torch_dtype=torch.bfloat16,
        device_map="auto",
        trust_remote_code=True,
        attn_implementation="flash_attention_2",  # Use Flash Attention 2
    )
    
    print(f"Model loaded: {model.get_memory_footprint() / 1e9:.2f} GB")
    
    # LoRA config - Higher rank for H200
    lora_r = 16 if "0.5B" in model_name else 32
    lora_config = LoraConfig(
        task_type=TaskType.CAUSAL_LM,
        r=lora_r,
        lora_alpha=lora_r * 2,
        lora_dropout=0.05,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
        bias="none",
    )
    
    model = get_peft_model(model, lora_config)
    trainable_params = sum(p.numel() for p in model.parameters() if p.requires_grad)
    total_params = sum(p.numel() for p in model.parameters())
    print(f"Trainable params: {trainable_params:,} ({100*trainable_params/total_params:.2f}%)")
    
    # Prepare dataset
    def format_example(ex):
        if specialist == "router":
            # Classification task
            return f"Classify this query into one of: performance, balance_sheet, treasury, esg\n\nQuery: {ex['question']}\n\nCategory: {ex['label']}"
        else:
            # Text-to-SQL task
            return f"Generate SQL for SAP HANA from the following question:\n\nQuestion: {ex['question']}\n\nSQL: {ex['query']}"
    
    formatted_data = [{"text": format_example(ex)} for ex in data]
    dataset = Dataset.from_list(formatted_data)
    
    # Tokenize
    def tokenize(batch):
        return tokenizer(
            batch["text"],
            padding="max_length",
            truncation=True,
            max_length=2048,
            return_tensors="pt",
        )
    
    tokenized_dataset = dataset.map(tokenize, batched=True, remove_columns=["text"])
    
    # H200 optimized training arguments
    batch_size = 4 if "14B" in model_name else 16
    grad_accum = 8 if "14B" in model_name else 2
    
    training_args = TrainingArguments(
        output_dir=config["output_dir"],
        
        # H200 can handle larger batches
        per_device_train_batch_size=batch_size,
        gradient_accumulation_steps=grad_accum,
        
        # Learning rate
        learning_rate=2e-4,
        lr_scheduler_type="cosine",
        warmup_ratio=0.03,
        
        # Duration
        num_train_epochs=3,
        
        # Precision - Full BF16 on H200
        bf16=True,
        tf32=True,
        
        # No gradient checkpointing needed on H200 (141GB!)
        gradient_checkpointing=False,
        
        # Optimization
        optim="adamw_torch_fused",
        weight_decay=0.01,
        max_grad_norm=1.0,
        
        # Logging
        logging_steps=25,
        logging_dir=f"{config['output_dir']}/logs",
        report_to=["tensorboard"],
        
        # Saving
        save_strategy="steps",
        save_steps=500,
        save_total_limit=2,
        
        # Performance
        dataloader_num_workers=8,
        dataloader_pin_memory=True,
    )
    
    # Data collator
    data_collator = DataCollatorForLanguageModeling(tokenizer=tokenizer, mlm=False)
    
    # Trainer
    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=tokenized_dataset,
        data_collator=data_collator,
    )
    
    # Train
    print(f"\nStarting training...")
    print(f"  Batch size: {batch_size} x {grad_accum} = {batch_size * grad_accum}")
    print(f"  Steps per epoch: {len(tokenized_dataset) // (batch_size * grad_accum)}")
    print(f"  Total epochs: 3")
    
    start_time = datetime.now()
    trainer.train()
    
    elapsed = datetime.now() - start_time
    print(f"\nTraining completed in {elapsed}")
    
    # Save final model
    trainer.save_model(f"{config['output_dir']}/final")
    print(f"Model saved to {config['output_dir']}/final")
    
    # Save adapter only (smaller)
    model.save_pretrained(f"{config['output_dir']}/lora-adapter")
    print(f"LoRA adapter saved to {config['output_dir']}/lora-adapter")
    
    return config["output_dir"]


def main():
    parser = argparse.ArgumentParser(description="H200 Specialist Training")
    parser.add_argument("--specialist", type=str, required=True,
                       choices=["performance", "balance_sheet", "treasury", "esg", "router", "all"],
                       help="Which specialist to train")
    parser.add_argument("--model", type=str, default="Qwen/Qwen2.5-14B-Instruct",
                       help="Base model to use")
    args = parser.parse_args()
    
    setup_h200()
    
    if args.specialist == "all":
        specialists = ["performance", "balance_sheet", "treasury", "esg", "router"]
        for sp in specialists:
            train_specialist(sp, args.model)
    else:
        train_specialist(args.specialist, args.model)


if __name__ == "__main__":
    main()