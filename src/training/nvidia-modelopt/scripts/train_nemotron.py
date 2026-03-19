#!/usr/bin/env python3
"""
NVIDIA Nemotron Training Script for SAP-OSS Specialists
Supports Nemotron-3-8B, Nemotron-4-15B, and Minitron variants
"""

import os
import sys
import json
import argparse
import torch
from datetime import datetime
from pathlib import Path

# Add parent directory to path
sys.path.insert(0, str(Path(__file__).parent))

from model_registry import (
    ModelSelector, ModelFamily, ModelTier,
    get_training_config, NEMOTRON_MODELS
)


def check_gpu():
    """Check GPU availability and return info."""
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA not available. Nemotron requires GPU.")
    
    gpu_name = torch.cuda.get_device_name(0)
    gpu_memory = torch.cuda.get_device_properties(0).total_memory / 1e9
    
    print(f"=" * 60)
    print("NVIDIA Nemotron Training")
    print(f"=" * 60)
    print(f"GPU: {gpu_name} ({gpu_memory:.1f} GB)")
    
    return gpu_name, gpu_memory


def get_nemotron_model(vram_gb: float, tier: str = "specialist"):
    """Select appropriate Nemotron model based on VRAM."""
    if vram_gb >= 35:
        return "nemotron-4-15b"
    elif vram_gb >= 18:
        return "nemotron-3-8b"
    elif vram_gb >= 10:
        return "minitron-4b"
    else:
        raise ValueError(f"Insufficient VRAM for Nemotron: {vram_gb}GB")


def load_nemotron_model(model_name: str, vram_gb: float):
    """Load Nemotron model with appropriate quantization."""
    from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig
    from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
    
    config = get_training_config(model_name, int(vram_gb))
    
    print(f"\nLoading model: {config['model_id']}")
    print(f"  Quantization: {config['quantization'] or 'Full precision'}")
    print(f"  LoRA rank: {config['lora']['r']}")
    
    # Tokenizer
    tokenizer = AutoTokenizer.from_pretrained(
        config['model_id'],
        trust_remote_code=True,
        padding_side="right"
    )
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    
    # Quantization config
    if config['quantization'] == "4bit":
        bnb_config = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_quant_type="nf4",
            bnb_4bit_compute_dtype=torch.bfloat16,
            bnb_4bit_use_double_quant=True,
        )
    elif config['quantization'] == "8bit":
        bnb_config = BitsAndBytesConfig(
            load_in_8bit=True,
        )
    else:
        bnb_config = None
    
    # Load model
    model = AutoModelForCausalLM.from_pretrained(
        config['model_id'],
        quantization_config=bnb_config,
        device_map="auto",
        trust_remote_code=True,
        torch_dtype=torch.bfloat16 if bnb_config is None else None,
    )
    
    # Prepare for training
    if bnb_config:
        model = prepare_model_for_kbit_training(model)
    
    # LoRA config
    lora_config = LoraConfig(
        r=config['lora']['r'],
        lora_alpha=config['lora']['alpha'],
        target_modules=config['lora']['target_modules'],
        lora_dropout=config['lora']['dropout'],
        bias="none",
        task_type="CAUSAL_LM",
    )
    
    model = get_peft_model(model, lora_config)
    
    # Print trainable parameters
    trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
    total = sum(p.numel() for p in model.parameters())
    print(f"  Trainable params: {trainable:,} / {total:,} ({100*trainable/total:.2f}%)")
    
    return model, tokenizer, config


def create_nemotron_dataset(specialist_type: str, tokenizer, max_length: int = 2048):
    """Create dataset for Nemotron training."""
    from datasets import Dataset
    
    # Specialist-specific prompt templates
    SPECIALIST_TEMPLATES = {
        "router": {
            "system": "You are a query classifier. Classify the user's financial query into one of: performance, balance_sheet, treasury, esg.",
            "examples": [
                ("What was our total revenue last quarter?", "performance"),
                ("Show me the current asset allocation", "balance_sheet"),
                ("Calculate the bond portfolio duration", "treasury"),
                ("What is our carbon footprint for 2024?", "esg"),
            ]
        },
        "performance": {
            "system": "You are a financial SQL expert specializing in P&L and income statement analysis. Generate SAP HANA SQL queries.",
            "examples": [
                (
                    "What was the total income for CIB segment in Q1 2025?",
                    "SELECT SUM(AMOUNT) as TOTAL_INCOME FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN WHERE SEGMENT = 'CIB' AND PERIOD = 'Q1' AND YEAR = 2025 AND ACCOUNT_TYPE = 'INCOME'"
                ),
            ]
        },
        "treasury": {
            "system": "You are a treasury SQL expert specializing in bond positions, derivatives, and ALM. Generate SAP HANA SQL queries.",
            "examples": [
                (
                    "Get the total MtM for ISIN US91282CGB19 in Hong Kong",
                    "SELECT SUM(MTM_VALUE) as TOTAL_MTM FROM TREASURY.POSITION WHERE ISIN = 'US91282CGB19' AND COUNTRY = 'HONG KONG'"
                ),
            ]
        },
        "esg": {
            "system": "You are an ESG SQL expert specializing in carbon emissions and sustainability metrics. Generate SAP HANA SQL queries.",
            "examples": [
                (
                    "What is the financed emission for ASEAN in December 2024?",
                    "SELECT SUM(FINANCED_EMISSION) FROM ESG.SF_FLAT WHERE BOOKING_LOCATION = 'ASEAN' AND PERIOD = '202412'"
                ),
            ]
        },
        "balance_sheet": {
            "system": "You are a balance sheet SQL expert specializing in assets, liabilities, and capital. Generate SAP HANA SQL queries.",
            "examples": [
                (
                    "What is the CASA to TD ratio for Group?",
                    "SELECT SUM(CASE WHEN ACCOUNT_TYPE = 'CASA' THEN AMOUNT END) / NULLIF(SUM(CASE WHEN ACCOUNT_TYPE = 'TD' THEN AMOUNT END), 0) as CASA_TD_RATIO FROM GL.FAGLFLEXT WHERE SEGMENT = 'GROUP'"
                ),
            ]
        },
    }
    
    template = SPECIALIST_TEMPLATES.get(specialist_type, SPECIALIST_TEMPLATES["performance"])
    
    # Generate training examples
    data = []
    base_examples = template["examples"]
    
    # Expand with variations (simplified for POC)
    for _ in range(500):  # 500 examples per specialist
        for question, answer in base_examples:
            prompt = f"""<|im_start|>system
{template['system']}
<|im_end|>
<|im_start|>user
{question}
<|im_end|>
<|im_start|>assistant
{answer}
<|im_end|>"""
            data.append({"text": prompt})
    
    dataset = Dataset.from_list(data)
    
    def tokenize(example):
        return tokenizer(
            example["text"],
            truncation=True,
            max_length=max_length,
            padding="max_length",
        )
    
    tokenized = dataset.map(tokenize, remove_columns=["text"])
    return tokenized


def train_nemotron(
    model,
    tokenizer,
    train_dataset,
    config: dict,
    output_dir: str,
    specialist_type: str,
):
    """Train Nemotron model with LoRA."""
    from transformers import TrainingArguments, Trainer, DataCollatorForLanguageModeling
    
    training_args = TrainingArguments(
        output_dir=output_dir,
        num_train_epochs=config['training']['num_train_epochs'],
        per_device_train_batch_size=config['batch_size'],
        gradient_accumulation_steps=config['gradient_accumulation_steps'],
        learning_rate=config['training']['learning_rate'],
        warmup_ratio=config['training']['warmup_ratio'],
        logging_steps=10,
        save_steps=100,
        save_total_limit=2,
        fp16=False,
        bf16=True,
        optim="paged_adamw_8bit",
        report_to="none",
        remove_unused_columns=False,
    )
    
    data_collator = DataCollatorForLanguageModeling(
        tokenizer=tokenizer,
        mlm=False,
    )
    
    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=train_dataset,
        data_collator=data_collator,
    )
    
    print(f"\n{'=' * 60}")
    print(f"Starting Nemotron training: {specialist_type}")
    print(f"{'=' * 60}")
    print(f"  Batch size: {config['batch_size']} x {config['gradient_accumulation_steps']} = {config['batch_size'] * config['gradient_accumulation_steps']}")
    print(f"  Learning rate: {config['training']['learning_rate']}")
    print(f"  Epochs: {config['training']['num_train_epochs']}")
    
    trainer.train()
    
    # Save LoRA adapter
    model.save_pretrained(output_dir)
    tokenizer.save_pretrained(output_dir)
    
    print(f"\n✓ Model saved to {output_dir}")
    
    return trainer


def evaluate_nemotron(model, tokenizer, specialist_type: str):
    """Quick evaluation of trained model."""
    test_queries = {
        "router": ["What was our revenue last year?", "Show bond portfolio"],
        "performance": ["Total income for Q1 2025", "Show P&L by segment"],
        "treasury": ["Get MtM for ISIN US12345", "Bond portfolio duration"],
        "esg": ["Financed emissions for 2024", "Carbon footprint by sector"],
        "balance_sheet": ["CASA to TD ratio", "Total assets by entity"],
    }
    
    queries = test_queries.get(specialist_type, test_queries["performance"])
    
    print(f"\n{'=' * 60}")
    print("Evaluation Results")
    print(f"{'=' * 60}")
    
    model.eval()
    for query in queries:
        prompt = f"<|im_start|>user\n{query}\n<|im_end|>\n<|im_start|>assistant\n"
        inputs = tokenizer(prompt, return_tensors="pt").to(model.device)
        
        with torch.no_grad():
            outputs = model.generate(
                **inputs,
                max_new_tokens=256,
                temperature=0.1,
                do_sample=False,
                pad_token_id=tokenizer.pad_token_id,
            )
        
        response = tokenizer.decode(outputs[0], skip_special_tokens=True)
        response = response.split("<|im_start|>assistant")[-1].strip()
        
        print(f"\nQuery: {query}")
        print(f"Response: {response[:200]}...")


def main():
    parser = argparse.ArgumentParser(description="Nemotron Training")
    parser.add_argument("--specialist", required=True,
                        choices=["router", "performance", "balance_sheet", "treasury", "esg"],
                        help="Specialist type to train")
    parser.add_argument("--model", default="auto",
                        help="Model name or 'auto' to select based on GPU")
    parser.add_argument("--output-dir", default="./outputs/nemotron",
                        help="Output directory")
    parser.add_argument("--max-steps", type=int, default=None,
                        help="Maximum training steps (overrides epochs)")
    parser.add_argument("--eval-only", action="store_true",
                        help="Only run evaluation")
    
    args = parser.parse_args()
    
    # Check GPU
    gpu_name, vram_gb = check_gpu()
    
    # Select model
    if args.model == "auto":
        model_name = get_nemotron_model(vram_gb)
        print(f"\nAuto-selected model: {model_name}")
    else:
        model_name = args.model
    
    # Load model
    model, tokenizer, config = load_nemotron_model(model_name, vram_gb)
    
    # Output directory
    output_dir = os.path.join(args.output_dir, f"{args.specialist}_{model_name}")
    os.makedirs(output_dir, exist_ok=True)
    
    if not args.eval_only:
        # Create dataset
        print(f"\nPreparing {args.specialist} training data...")
        train_dataset = create_nemotron_dataset(
            args.specialist,
            tokenizer,
            config['training']['max_seq_length']
        )
        print(f"Dataset size: {len(train_dataset)}")
        
        # Override max_steps if specified
        if args.max_steps:
            config['training']['num_train_epochs'] = 1
        
        # Train
        train_nemotron(
            model, tokenizer, train_dataset,
            config, output_dir, args.specialist
        )
    
    # Evaluate
    evaluate_nemotron(model, tokenizer, args.specialist)
    
    print(f"\n{'=' * 60}")
    print("TRAINING COMPLETE")
    print(f"{'=' * 60}")
    print(f"Model: {config['model_id']}")
    print(f"Specialist: {args.specialist}")
    print(f"Output: {output_dir}")


if __name__ == "__main__":
    main()