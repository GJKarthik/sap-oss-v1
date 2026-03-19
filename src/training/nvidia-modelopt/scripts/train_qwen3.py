#!/usr/bin/env python3
"""
Qwen 3.5 Training Script for SAP-OSS Specialists
Forward-compatible with Qwen 3.5 (auto-fallback to Qwen 2.5 until release)
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
    get_training_config, QWEN35_MODELS, QWEN25_MODELS, FALLBACK_MAP
)


def check_gpu():
    """Check GPU availability and return info."""
    if not torch.cuda.is_available():
        print("WARNING: CUDA not available. Training will be slow on CPU.")
        return "CPU", 0
    
    gpu_name = torch.cuda.get_device_name(0)
    gpu_memory = torch.cuda.get_device_properties(0).total_memory / 1e9
    
    print(f"=" * 60)
    print("Qwen 3.5 Training (with Qwen 2.5 Fallback)")
    print(f"=" * 60)
    print(f"GPU: {gpu_name} ({gpu_memory:.1f} GB)")
    
    return gpu_name, gpu_memory


def check_qwen35_availability(model_name: str) -> bool:
    """Check if Qwen 3.5 model is available on HuggingFace."""
    from huggingface_hub import model_info, HfApi
    
    config = QWEN35_MODELS.get(model_name)
    if not config:
        return False
    
    try:
        api = HfApi()
        info = api.model_info(config.model_id)
        return True
    except Exception:
        return False


def select_model(requested: str, vram_gb: float, tier: str = "specialist") -> str:
    """Select model based on request and availability."""
    
    # Qwen 3.5 tier mapping
    QWEN35_BY_TIER = {
        "router": "qwen3.5-0.8b",
        "specialist": "qwen3.5-9b",
        "complex": "qwen3.5-35b",
    }
    
    # Qwen 2.5 fallback by VRAM
    QWEN25_BY_VRAM = {
        (0, 8): "qwen2.5-1.5b",
        (8, 16): "qwen2.5-3b",
        (16, 24): "qwen2.5-7b",
        (24, 40): "qwen2.5-14b",
        (40, 80): "qwen2.5-32b",
        (80, 200): "qwen2.5-72b",
    }
    
    if requested != "auto":
        # User specified a model
        if requested.startswith("qwen3.5"):
            # Check availability
            if check_qwen35_availability(requested):
                print(f"✓ Qwen 3.5 available: {requested}")
                return requested
            else:
                fallback = FALLBACK_MAP.get(requested)
                if fallback:
                    print(f"⚠ Qwen 3.5 not available. Falling back to {fallback}")
                    return fallback
        return requested
    
    # Auto-select based on tier
    qwen35_model = QWEN35_BY_TIER.get(tier, "qwen3.5-9b")
    
    # Check Qwen 3.5 availability
    if check_qwen35_availability(qwen35_model):
        print(f"✓ Auto-selected Qwen 3.5: {qwen35_model}")
        return qwen35_model
    
    # Fallback to Qwen 2.5 based on VRAM
    for (min_vram, max_vram), model in QWEN25_BY_VRAM.items():
        if min_vram <= vram_gb < max_vram:
            print(f"⚠ Qwen 3.5 not available. Auto-selected Qwen 2.5: {model}")
            return model
    
    # Default
    return "qwen2.5-7b"


def load_model(model_name: str, vram_gb: float):
    """Load model with appropriate quantization and LoRA."""
    from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig
    from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
    
    config = get_training_config(model_name, int(vram_gb))
    
    print(f"\nLoading model: {config['model_id']}")
    print(f"  Family: {config['model_family']}")
    print(f"  Tier: {config['model_tier']}")
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
        attn_implementation="flash_attention_2" if torch.cuda.is_available() else None,
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


def create_dataset(specialist_type: str, tokenizer, max_length: int = 2048, num_examples: int = 500):
    """Create dataset for training."""
    from datasets import Dataset
    
    # Specialist-specific configurations
    SPECIALIST_CONFIGS = {
        "router": {
            "system": """You are a financial query router. Analyze the user's question and classify it into one of these categories:
- performance: P&L, income, revenue, costs, margins, profitability
- balance_sheet: Assets, liabilities, deposits, loans, capital, ratios
- treasury: Bonds, derivatives, positions, MtM, duration, yield
- esg: Emissions, sustainability, carbon, net-zero, ESG metrics

Respond with ONLY the category name.""",
            "examples": [
                ("What was our total revenue last quarter?", "performance"),
                ("Show the CIB income for Q1 2025", "performance"),
                ("What's our NIM% trend?", "performance"),
                ("Show asset allocation by segment", "balance_sheet"),
                ("What is the CASA to TD ratio?", "balance_sheet"),
                ("Get bond portfolio duration", "treasury"),
                ("Show MtM for ISIN US91282CGB19", "treasury"),
                ("Financed emissions by sector", "esg"),
                ("What is our Scope 3 carbon footprint?", "esg"),
            ]
        },
        "performance": {
            "system": """You are an expert SAP HANA SQL query generator specialized in financial performance analysis.
Generate precise SQL queries for P&L, income statement, and profitability analysis.

Key tables:
- BPC.ZFI_FIN_OVER_AFO_CP_FIN: Main P&L fact table
- BPC.SEGMENT: Segment dimension (CIB, WRB, Group)
- BPC.PERIOD: Time dimension (YTD, QTD, MTD, Q1-Q4)

Key columns: AMOUNT, SEGMENT, PERIOD, YEAR, ACCOUNT_TYPE, CURRENCY, VERSION""",
            "examples": [
                (
                    "What was the total income for CIB segment in Q1 2025?",
                    """SELECT 
    SUM(AMOUNT) as TOTAL_INCOME
FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN
WHERE SEGMENT = 'CIB' 
    AND PERIOD = 'Q1' 
    AND YEAR = 2025 
    AND ACCOUNT_TYPE = 'INCOME'
    AND VERSION = 'ACTUALS'"""
                ),
                (
                    "Show income by segment for FY2024 with YoY comparison",
                    """SELECT 
    SEGMENT,
    SUM(CASE WHEN YEAR = 2024 THEN AMOUNT END) as FY2024,
    SUM(CASE WHEN YEAR = 2023 THEN AMOUNT END) as FY2023,
    ROUND((SUM(CASE WHEN YEAR = 2024 THEN AMOUNT END) - 
           SUM(CASE WHEN YEAR = 2023 THEN AMOUNT END)) / 
           NULLIF(SUM(CASE WHEN YEAR = 2023 THEN AMOUNT END), 0) * 100, 2) as YOY_PCT
FROM BPC.ZFI_FIN_OVER_AFO_CP_FIN
WHERE ACCOUNT_TYPE = 'INCOME' 
    AND YEAR IN (2023, 2024)
    AND VERSION = 'ACTUALS'
GROUP BY SEGMENT
ORDER BY FY2024 DESC"""
                ),
            ]
        },
        "treasury": {
            "system": """You are an expert SAP HANA SQL query generator specialized in treasury and ALM analysis.
Generate precise SQL queries for bond positions, derivatives, and portfolio metrics.

Key tables:
- TREASURY.POSITION: Bond and derivative positions
- TREASURY.INSTRUMENT: Instrument master data
- TREASURY.PORTFOLIO: Portfolio groupings

Key columns: ISIN, NOTIONAL, MTM_VALUE, PV01, DURATION, YIELD, COUNTRY, PORTFOLIO_ID, COB_DATE""",
            "examples": [
                (
                    "Get the total MtM for ISIN US91282CGB19 in Hong Kong",
                    """SELECT 
    SUM(MTM_VALUE) as TOTAL_MTM
FROM TREASURY.POSITION
WHERE ISIN = 'US91282CGB19' 
    AND COUNTRY = 'HONG KONG'"""
                ),
                (
                    "Show portfolio duration and PV01 by country",
                    """SELECT 
    COUNTRY,
    SUM(NOTIONAL * DURATION) / NULLIF(SUM(NOTIONAL), 0) as WAV_DURATION,
    SUM(PV01) as TOTAL_PV01
FROM TREASURY.POSITION
WHERE COB_DATE = CURRENT_DATE
GROUP BY COUNTRY
ORDER BY TOTAL_PV01 DESC"""
                ),
            ]
        },
        "esg": {
            "system": """You are an expert SAP HANA SQL query generator specialized in ESG and sustainability analysis.
Generate precise SQL queries for carbon emissions, financed emissions, and net-zero metrics.

Key tables:
- ESG.SF_FLAT: Main ESG fact table
- ESG.NET_ZERO: Net-zero tracking
- ESG.CLIENT_ESG: Client ESG scores

Key columns: FINANCED_EMISSION, BOOKING_LOCATION, NET_ZERO_SECTOR, PERIOD, SCOPE, CLIENT_SEGMENT""",
            "examples": [
                (
                    "What is the financed emission for ASEAN in December 2024?",
                    """SELECT 
    SUM(FINANCED_EMISSION) as TOTAL_FINANCED_EMISSION
FROM ESG.SF_FLAT
WHERE BOOKING_LOCATION = 'ASEAN' 
    AND PERIOD = '202412'"""
                ),
                (
                    "Show top 10 sectors by financed emissions for net-zero",
                    """SELECT 
    NET_ZERO_SECTOR,
    SUM(FINANCED_EMISSION) as TOTAL_EMISSION
FROM ESG.SF_FLAT
WHERE NET_ZERO_SECTOR IS NOT NULL
GROUP BY NET_ZERO_SECTOR
ORDER BY TOTAL_EMISSION DESC
LIMIT 10"""
                ),
            ]
        },
        "balance_sheet": {
            "system": """You are an expert SAP HANA SQL query generator specialized in balance sheet analysis.
Generate precise SQL queries for assets, liabilities, capital, and financial ratios.

Key tables:
- GL.FAGLFLEXT: General ledger balances
- GL.SKA1: Account master
- BS.DEPOSITS: Customer deposits
- BS.LOANS: Loans and advances

Key columns: ACCOUNT, AMOUNT, COMPANY_CODE, PERIOD, LEDGER, ACCOUNT_TYPE""",
            "examples": [
                (
                    "What is the CASA to TD ratio for Group?",
                    """SELECT 
    SUM(CASE WHEN ACCOUNT_TYPE = 'CASA' THEN AMOUNT END) / 
    NULLIF(SUM(CASE WHEN ACCOUNT_TYPE = 'TD' THEN AMOUNT END), 0) as CASA_TD_RATIO
FROM BS.DEPOSITS
WHERE SEGMENT = 'GROUP'"""
                ),
                (
                    "Show total assets by legal entity",
                    """SELECT 
    COMPANY_CODE,
    SUM(AMOUNT) as TOTAL_ASSETS
FROM GL.FAGLFLEXT
WHERE ACCOUNT_TYPE = 'ASSET' 
    AND LEDGER = '0L'
GROUP BY COMPANY_CODE
ORDER BY TOTAL_ASSETS DESC"""
                ),
            ]
        },
    }
    
    config = SPECIALIST_CONFIGS.get(specialist_type, SPECIALIST_CONFIGS["performance"])
    
    # Generate training examples
    data = []
    base_examples = config["examples"]
    
    # Expand with variations
    for i in range(num_examples):
        question, answer = base_examples[i % len(base_examples)]
        
        # Create chat format
        prompt = f"""<|im_start|>system
{config['system']}
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


def train(
    model,
    tokenizer,
    train_dataset,
    config: dict,
    output_dir: str,
    specialist_type: str,
    max_steps: int = None,
):
    """Train model with LoRA."""
    from transformers import TrainingArguments, Trainer, DataCollatorForLanguageModeling
    
    # Calculate steps if max_steps provided
    num_epochs = config['training']['num_train_epochs']
    if max_steps:
        # Override epochs based on max_steps
        steps_per_epoch = len(train_dataset) // (config['batch_size'] * config['gradient_accumulation_steps'])
        num_epochs = max(1, max_steps // steps_per_epoch)
    
    training_args = TrainingArguments(
        output_dir=output_dir,
        num_train_epochs=num_epochs,
        max_steps=max_steps if max_steps else -1,
        per_device_train_batch_size=config['batch_size'],
        gradient_accumulation_steps=config['gradient_accumulation_steps'],
        learning_rate=config['training']['learning_rate'],
        warmup_ratio=config['training']['warmup_ratio'],
        logging_steps=10,
        save_steps=100,
        save_total_limit=2,
        fp16=False,
        bf16=torch.cuda.is_available(),
        optim="paged_adamw_8bit" if config['quantization'] else "adamw_torch",
        report_to="none",
        remove_unused_columns=False,
        gradient_checkpointing=True,
        gradient_checkpointing_kwargs={"use_reentrant": False},
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
    print(f"Starting Training: {specialist_type}")
    print(f"{'=' * 60}")
    print(f"  Model: {config['model_id']}")
    print(f"  Batch size: {config['batch_size']} x {config['gradient_accumulation_steps']} = {config['batch_size'] * config['gradient_accumulation_steps']}")
    print(f"  Learning rate: {config['training']['learning_rate']}")
    print(f"  Max steps: {max_steps or 'auto (based on epochs)'}")
    
    trainer.train()
    
    # Save
    model.save_pretrained(output_dir)
    tokenizer.save_pretrained(output_dir)
    
    # Save config
    with open(os.path.join(output_dir, "training_config.json"), "w") as f:
        json.dump({
            "specialist_type": specialist_type,
            "model_config": config,
            "timestamp": datetime.now().isoformat(),
        }, f, indent=2)
    
    print(f"\n✓ Model saved to {output_dir}")
    
    return trainer


def quick_eval(model, tokenizer, specialist_type: str):
    """Quick evaluation after training."""
    test_queries = {
        "router": ["What was revenue?", "Show bond MtM", "CASA ratio?", "Carbon emissions?"],
        "performance": ["Total income Q1 2025", "NII by segment FY2024"],
        "treasury": ["MtM for US91282CGB19", "Portfolio duration by country"],
        "esg": ["Financed emissions ASEAN", "Net zero by sector"],
        "balance_sheet": ["CASA to TD ratio", "Assets by entity"],
    }
    
    queries = test_queries.get(specialist_type, test_queries["performance"])[:2]
    
    print(f"\n{'=' * 60}")
    print("Quick Evaluation")
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
        
        print(f"\n📝 Query: {query}")
        print(f"💬 Response: {response[:300]}...")


def main():
    parser = argparse.ArgumentParser(description="Qwen 3.5 Training (with fallback)")
    parser.add_argument("--specialist", required=True,
                        choices=["router", "performance", "balance_sheet", "treasury", "esg"],
                        help="Specialist type to train")
    parser.add_argument("--model", default="auto",
                        help="Model: auto, qwen3.5-0.8b, qwen3.5-9b, qwen2.5-7b, etc.")
    parser.add_argument("--tier", default="specialist",
                        choices=["router", "specialist", "complex"],
                        help="Model tier for auto-selection")
    parser.add_argument("--output-dir", default="./outputs/qwen",
                        help="Output directory")
    parser.add_argument("--num-examples", type=int, default=500,
                        help="Number of training examples")
    parser.add_argument("--max-steps", type=int, default=None,
                        help="Maximum training steps")
    parser.add_argument("--eval-only", action="store_true",
                        help="Only run evaluation")
    
    args = parser.parse_args()
    
    # Check GPU
    gpu_name, vram_gb = check_gpu()
    
    # Select model
    model_name = select_model(args.model, vram_gb, args.tier)
    
    # Load model
    model, tokenizer, config = load_model(model_name, vram_gb)
    
    # Output directory
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    output_dir = os.path.join(args.output_dir, f"{args.specialist}_{model_name}_{timestamp}")
    os.makedirs(output_dir, exist_ok=True)
    
    if not args.eval_only:
        # Create dataset
        print(f"\nPreparing {args.specialist} training data...")
        train_dataset = create_dataset(
            args.specialist,
            tokenizer,
            config['training']['max_seq_length'],
            args.num_examples
        )
        print(f"Dataset size: {len(train_dataset)}")
        
        # Train
        train(
            model, tokenizer, train_dataset,
            config, output_dir, args.specialist,
            args.max_steps
        )
    
    # Quick eval
    quick_eval(model, tokenizer, args.specialist)
    
    print(f"\n{'=' * 60}")
    print("COMPLETE")
    print(f"{'=' * 60}")
    print(f"Model: {config['model_id']}")
    print(f"Specialist: {args.specialist}")
    print(f"Output: {output_dir}")


if __name__ == "__main__":
    main()