#!/usr/bin/env python3
"""
train_t4.py

Fine-tuning script optimized for NVIDIA T4 GPU (16GB)
Uses 4-bit quantization + LoRA for memory efficiency
"""
import os
import sys
import json
import torch
from dataclasses import dataclass, field
from typing import Optional

from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    BitsAndBytesConfig,
    TrainingArguments,
    Trainer,
    DataCollatorForSeq2Seq,
)
from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
from datasets import Dataset


@dataclass
class TrainingConfig:
    """Training configuration for T4 GPU (16GB VRAM)

    Optimized for Brev T4 instances:
    - 4-bit NF4 quantization to fit 7B model
    - LoRA on attention + MLP for better quality
    - Gradient checkpointing for memory
    - FP16 (T4 lacks native BF16)
    """
    model_name: str = "Qwen/Qwen2.5-7B-Instruct"
    output_dir: str = "./outputs/qwen-7b-text2sql-t4"

    # Training params optimized for T4 16GB
    num_train_epochs: int = 3
    per_device_train_batch_size: int = 1
    gradient_accumulation_steps: int = 32  # effective batch = 32
    learning_rate: float = 2e-4
    max_steps: int = -1  # Use full epochs
    warmup_ratio: float = 0.05

    # LoRA config - include MLP layers for better quality
    lora_r: int = 16
    lora_alpha: int = 32
    lora_dropout: float = 0.05

    # Data config
    max_seq_length: int = 1024
    max_samples: int = None  # Use all available data

    # Data path (override with --data flag)
    data_dir: str = "data/specialist_training"


def load_training_data(data_dir: str, max_samples: int = None):
    """Load real training data from specialist_training directory.

    Tries JSONL first, then JSON, then falls back to synthetic examples
    if no training data is found.
    """
    data_path = Path(data_dir)
    examples = []

    # Try JSONL files first (434K dataset format)
    for jsonl_file in sorted(data_path.glob("*.jsonl")):
        with open(jsonl_file) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        examples.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
        if max_samples and len(examples) >= max_samples:
            break

    # Try JSON files (specialist format)
    if not examples:
        for json_file in sorted(data_path.glob("train_*.json")):
            with open(json_file) as f:
                data = json.load(f)
                if isinstance(data, list):
                    examples.extend(data)
            if max_samples and len(examples) >= max_samples:
                break

    if not examples:
        print("WARNING: No training data found, using minimal synthetic examples")
        examples = [
            {"instruction": "Generate SQL for SAP HANA", "input": "Show total amount by country",
             "output": "SELECT COUNTRY_CODE, SUM(AMOUNT_USD) AS total FROM BTP.FACT GROUP BY COUNTRY_CODE"},
            {"instruction": "Generate SQL for SAP HANA", "input": "List top 10 entities by revenue",
             "output": "SELECT ENTITY_CODE, SUM(AMOUNT_USD) AS revenue FROM BTP.FACT GROUP BY ENTITY_CODE ORDER BY revenue DESC LIMIT 10"},
        ] * 50

    if max_samples:
        examples = examples[:max_samples]
    return examples


def format_example(example: dict, tokenizer) -> dict:
    """Format example for training"""
    prompt = f"""### Instruction:
{example['instruction']}

### Input:
{example['input']}

### Response:
{example['output']}"""
    
    return {"text": prompt}


def main():
    print("=" * 60)
    print("T4 GPU Text-to-SQL Training")
    print("=" * 60)
    
    config = TrainingConfig()
    
    # Check GPU
    if not torch.cuda.is_available():
        print("ERROR: CUDA not available!")
        sys.exit(1)
    
    device = torch.cuda.get_device_name(0)
    memory = torch.cuda.get_device_properties(0).total_memory / 1e9
    print(f"GPU: {device} ({memory:.1f} GB)")
    
    # Load tokenizer
    print(f"\nLoading tokenizer: {config.model_name}")
    tokenizer = AutoTokenizer.from_pretrained(
        config.model_name,
        trust_remote_code=True,
    )
    tokenizer.pad_token = tokenizer.eos_token
    tokenizer.padding_side = "right"
    
    # 4-bit quantization config
    bnb_config = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_compute_dtype=torch.float16,
        bnb_4bit_quant_type="nf4",
        bnb_4bit_use_double_quant=True,
    )
    
    # Load model
    print(f"Loading model with 4-bit quantization...")
    model = AutoModelForCausalLM.from_pretrained(
        config.model_name,
        quantization_config=bnb_config,
        device_map="auto",
        trust_remote_code=True,
    )
    
    memory_used = torch.cuda.memory_allocated() / 1e9
    print(f"Model loaded: {memory_used:.2f} GB")
    
    # Prepare for LoRA training
    model = prepare_model_for_kbit_training(model)
    
    lora_config = LoraConfig(
        r=config.lora_r,
        lora_alpha=config.lora_alpha,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
        lora_dropout=config.lora_dropout,
        bias="none",
        task_type="CAUSAL_LM",
    )
    
    model = get_peft_model(model, lora_config)
    
    trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
    total = sum(p.numel() for p in model.parameters())
    print(f"LoRA: {trainable:,} trainable / {total:,} total ({100*trainable/total:.2f}%)")
    
    # Prepare dataset
    print(f"\nLoading training data from {config.data_dir}...")
    raw_data = load_training_data(config.data_dir, config.max_samples)
    print(f"Loaded {len(raw_data):,} examples")
    
    # Tokenize
    def tokenize(example):
        prompt = f"""### Instruction:
{example['instruction']}

### Input:
{example['input']}

### Response:
{example['output']}{tokenizer.eos_token}"""
        
        result = tokenizer(
            prompt,
            truncation=True,
            max_length=config.max_seq_length,
            padding="max_length",
        )
        result["labels"] = result["input_ids"].copy()
        return result
    
    dataset = Dataset.from_list(raw_data)
    tokenized_dataset = dataset.map(tokenize, remove_columns=dataset.column_names)
    
    print(f"Dataset size: {len(tokenized_dataset)}")
    
    # Training arguments - optimized for T4 16GB on Brev
    training_args = TrainingArguments(
        output_dir=config.output_dir,
        num_train_epochs=config.num_train_epochs,
        per_device_train_batch_size=config.per_device_train_batch_size,
        gradient_accumulation_steps=config.gradient_accumulation_steps,
        learning_rate=config.learning_rate,
        warmup_ratio=config.warmup_ratio,
        lr_scheduler_type="cosine",
        max_steps=config.max_steps,
        fp16=True,
        bf16=False,  # T4 lacks native BF16
        logging_steps=10,
        save_steps=500,
        save_total_limit=3,
        eval_strategy="no",
        gradient_checkpointing=True,
        gradient_checkpointing_kwargs={"use_reentrant": False},
        optim="paged_adamw_8bit",
        weight_decay=0.01,
        max_grad_norm=1.0,
        report_to="none",
        dataloader_num_workers=2,
        dataloader_pin_memory=True,
        seed=42,
    )
    
    # Data collator
    data_collator = DataCollatorForSeq2Seq(
        tokenizer=tokenizer,
        model=model,
        padding=True,
    )
    
    # Trainer
    trainer = Trainer(
        model=model,
        args=training_args,
        train_dataset=tokenized_dataset,
        data_collator=data_collator,
    )
    
    # Train
    print("\n" + "=" * 60)
    print("Starting training...")
    print("=" * 60)
    
    trainer.train()
    
    # Save
    print("\nSaving model...")
    model.save_pretrained(config.output_dir)
    tokenizer.save_pretrained(config.output_dir)
    
    print(f"\nTraining complete! Model saved to: {config.output_dir}")
    
    # Test inference
    print("\n" + "=" * 60)
    print("Testing inference...")
    print("=" * 60)
    
    test_prompt = """### Instruction:
Generate SQL for SAP HANA

### Input:
Show total revenue by country for Q4 2024

### Response:
"""
    
    inputs = tokenizer(test_prompt, return_tensors="pt").to("cuda")
    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=100,
            temperature=0.1,
            do_sample=True,
        )
    
    response = tokenizer.decode(outputs[0], skip_special_tokens=True)
    print(f"Input: Show total revenue by country for Q4 2024")
    print(f"Output: {response.split('### Response:')[-1].strip()}")
    
    print("\n" + "=" * 60)
    print("TRAINING COMPLETE!")
    print("=" * 60)


if __name__ == "__main__":
    main()