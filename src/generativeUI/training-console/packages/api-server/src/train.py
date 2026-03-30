import argparse
import json
import sys
import logging

try:
    from transformers import AutoModelForCausalLM, AutoTokenizer, TrainingArguments, TrainerCallback
    from datasets import Dataset
    from trl import SFTTrainer
except ImportError:
    print(json.dumps({"error": "Failed to import ML libraries. Is torch/transformers installed?"}))
    sys.exit(1)

# Disable default HF logging to avoid polluting our strict JSON stdout orchestrator pipe
logging.getLogger("transformers").setLevel(logging.ERROR)

class JsonProgressCallback(TrainerCallback):
    def on_log(self, args, state, control, logs=None, **kwargs):
        if logs is None:
            return
        
        # We only care about steps that log mathematical loss
        if "loss" in logs or "eval_loss" in logs:
            payload = {
                "epoch": round(state.epoch, 2) if state.epoch else 0,
                "train_loss": round(logs.get("loss", 0.0), 4),
                "val_loss": round(logs.get("eval_loss", 0.0), 4)
            }
            # Flush strictly as a single JSON line for the orchestrator to parse
            print(json.dumps(payload))
            sys.stdout.flush()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model_name", type=str, required=True)
    parser.add_argument("--peft_r", type=int, default=0)
    parser.add_argument("--peft_alpha", type=int, default=16)
    parser.add_argument("--peft_dropout", type=float, default=0.05)
    args = parser.parse_args()

    # 1. Dummy Dataset for proof of work
    dummy_data = {
        "text": [
            "The quick brown fox jumps over the lazy dog.",
            "Machine learning is fascinating.",
            "PyTorch makes deep learning accessible.",
            "This is a dummy dataset for streaming testing."
        ] * 10 
    }
    dataset = Dataset.from_dict(dummy_data)

    # 2. Load Model and Tokenizer
    model_id = args.model_name
    
    try:
        tokenizer = AutoTokenizer.from_pretrained(model_id)
        if getattr(tokenizer, "pad_token", None) is None:
            tokenizer.pad_token = tokenizer.eos_token
            
        model = AutoModelForCausalLM.from_pretrained(model_id)
        
        # Apply LoRA if requested via subprocess arguments
        if args.peft_r > 0:
            from peft import LoraConfig, get_peft_model
            # Auto-detect target modules based on generic fallback
            targets = ["c_proj", "c_attn"] if "gpt2" in model_id.lower() else ["q_proj", "v_proj"]
            
            peft_config = LoraConfig(
                task_type="CAUSAL_LM",
                r=args.peft_r,
                lora_alpha=args.peft_alpha,
                lora_dropout=args.peft_dropout,
                target_modules=targets
            )
            model = get_peft_model(model, peft_config)
            
    except Exception as e:
        print(json.dumps({"error": f"Failed to load model {model_id}: {str(e)}"}))
        sys.exit(1)

    # 3. Training Arguments 
    # Set miniaturized parameters to ensure it trains safely on a Mac without crashing VRAM
    training_args = TrainingArguments(
        output_dir="./tmp_trainer",
        per_device_train_batch_size=1,
        gradient_accumulation_steps=1,
        num_train_epochs=3,
        logging_steps=1, # Log every step so we get real-time JSON updates over the pipe
        eval_strategy="steps",
        eval_steps=2,
        save_strategy="no",
        report_to="none",
        fp16=False, # Disable fp16 to ensure safe CPU/Mac fallback capability
        use_cpu=True # Force CPU to avoid architecture mismatches on standard test runners
    )

    # 4. Initialize genuine SFTTrainer
    trainer = SFTTrainer(
        model=model,
        train_dataset=dataset,
        eval_dataset=dataset,
        dataset_text_field="text",
        max_seq_length=16,
        args=training_args,
        callbacks=[JsonProgressCallback()]
    )

    # 5. Execute True Deep Learning
    trainer.train()

    # 6. Final Evaluation Telemetry
    import math
    eval_results = trainer.evaluate()
    perplexity = math.exp(eval_results.get("eval_loss", 0.0))
    
    final_payload = {
        "final_evaluation": {
            "perplexity": round(perplexity, 4),
            "eval_loss": round(eval_results.get("eval_loss", 0.0), 4),
            "runtime_sec": round(eval_results.get("eval_runtime", 0.0), 2)
        }
    }
    print(json.dumps(final_payload))
    sys.stdout.flush()

if __name__ == "__main__":
    main()
