#!/usr/bin/env python3
"""
Qwen3.5 Quantization Script for T4 GPU using NVIDIA Model Optimizer

This script provides INT8 and INT4 quantization for Qwen models,
optimized for NVIDIA T4 GPUs (16GB VRAM, Turing architecture).

Usage:
    python quantize_qwen.py --model Qwen/Qwen3.5-1.8B --qformat int8
    python quantize_qwen.py --model Qwen/Qwen3.5-4B --qformat int4_awq
    python quantize_qwen.py --config configs/qwen_int8.yaml
"""

import argparse
import logging
import os
import sys
from pathlib import Path
from typing import Optional

import torch
import yaml
from tqdm import tqdm

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger(__name__)


def parse_args() -> argparse.Namespace:
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(
        description="Quantize Qwen3.5 models using NVIDIA Model Optimizer (T4 optimized)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # INT8 quantization (recommended for T4)
  python quantize_qwen.py --model Qwen/Qwen3.5-1.8B --qformat int8

  # INT4 AWQ quantization (best compression)
  python quantize_qwen.py --model Qwen/Qwen3.5-4B --qformat int4_awq

  # Using config file
  python quantize_qwen.py --config configs/qwen_int8.yaml

  # With custom output directory
  python quantize_qwen.py --model Qwen/Qwen3.5-1.8B --qformat int8 --output ./my_quantized_model

T4 GPU Compatibility:
  ✓ int8      - SmoothQuant INT8 (recommended)
  ✓ int4_awq  - AWQ INT4 (best compression)
  ✓ w4a16     - Weight-only 4-bit
  ✗ fp8       - NOT supported (requires Ada+)
  ✗ nvfp4     - NOT supported (requires Blackwell)
        """
    )
    
    parser.add_argument(
        "--model",
        type=str,
        default="Qwen/Qwen3.5-1.8B",
        help="Hugging Face model name or local path (default: Qwen/Qwen3.5-1.8B)"
    )
    
    parser.add_argument(
        "--qformat",
        type=str,
        choices=["int8", "int4_awq", "w4a16"],
        default="int8",
        help="Quantization format (default: int8)"
    )
    
    parser.add_argument(
        "--config",
        type=str,
        help="Path to YAML configuration file"
    )
    
    parser.add_argument(
        "--output",
        type=str,
        default="./outputs",
        help="Output directory for quantized model (default: ./outputs)"
    )
    
    parser.add_argument(
        "--calib-samples",
        type=int,
        default=512,
        help="Number of calibration samples (default: 512)"
    )
    
    parser.add_argument(
        "--calib-seq-len",
        type=int,
        default=2048,
        help="Calibration sequence length (default: 2048)"
    )
    
    parser.add_argument(
        "--device",
        type=str,
        default="cuda:0",
        help="Device to use (default: cuda:0)"
    )
    
    parser.add_argument(
        "--dtype",
        type=str,
        choices=["float16", "bfloat16"],
        default="float16",
        help="Model dtype before quantization (default: float16)"
    )
    
    parser.add_argument(
        "--export-format",
        type=str,
        choices=["hf", "tensorrt_llm", "vllm"],
        default="hf",
        help="Export format (default: hf)"
    )
    
    parser.add_argument(
        "--skip-calibration",
        action="store_true",
        help="Skip calibration (use default scales)"
    )
    
    parser.add_argument(
        "--verbose",
        "-v",
        action="store_true",
        help="Enable verbose output"
    )
    
    return parser.parse_args()


def load_config(config_path: str) -> dict:
    """Load configuration from YAML file."""
    with open(config_path, "r") as f:
        return yaml.safe_load(f)


def check_gpu_compatibility(qformat: str) -> bool:
    """Check if the quantization format is compatible with the current GPU."""
    if not torch.cuda.is_available():
        logger.warning("CUDA is not available. Running in CPU mode.")
        return True
    
    # Get GPU compute capability
    device = torch.cuda.current_device()
    capability = torch.cuda.get_device_capability(device)
    compute_cap = capability[0] * 10 + capability[1]
    device_name = torch.cuda.get_device_name(device)
    
    logger.info(f"GPU: {device_name} (compute capability {capability[0]}.{capability[1]})")
    
    # T4 is compute capability 7.5 (Turing)
    # FP8 requires compute capability 8.9+ (Ada Lovelace)
    # NVFP4 requires Blackwell (compute capability 10.0+)
    
    if qformat in ["fp8", "nvfp4"]:
        logger.error(f"Quantization format '{qformat}' is NOT supported on {device_name}")
        logger.error("FP8 requires Ada Lovelace (RTX 40xx, L4, H100) or newer")
        logger.error("NVFP4 requires Blackwell GPUs")
        logger.error("Please use 'int8' or 'int4_awq' for T4 GPU")
        return False
    
    return True


def get_quantization_config(qformat: str):
    """Get the appropriate quantization configuration for T4."""
    try:
        import modelopt.torch.quantization as mtq
    except ImportError:
        logger.error("nvidia-modelopt is not installed.")
        logger.error("Run: pip install 'nvidia-modelopt[all]' -U --extra-index-url https://pypi.nvidia.com")
        sys.exit(1)
    
    if qformat == "int8":
        # SmoothQuant INT8 - best quality/performance for T4
        if hasattr(mtq, "INT8_SMOOTHQUANT_CFG"):
            return mtq.INT8_SMOOTHQUANT_CFG
        elif hasattr(mtq, "INT8_DEFAULT_CFG"):
            return mtq.INT8_DEFAULT_CFG
        else:
            logger.warning("Using basic INT8 config")
            return {"quant_cfg": {"*weight_quantizer": {"num_bits": 8}}}
    
    elif qformat == "int4_awq":
        # AWQ INT4 - best compression for T4
        if hasattr(mtq, "INT4_AWQ_CFG"):
            return mtq.INT4_AWQ_CFG
        elif hasattr(mtq, "W4A16_AWQ_CFG"):
            return mtq.W4A16_AWQ_CFG
        else:
            logger.warning("Using basic W4A16 config")
            return {"quant_cfg": {"*weight_quantizer": {"num_bits": 4}}}
    
    elif qformat == "w4a16":
        # Weight-only 4-bit
        if hasattr(mtq, "W4A16_CFG"):
            return mtq.W4A16_CFG
        else:
            return {"quant_cfg": {"*weight_quantizer": {"num_bits": 4}}}
    
    else:
        raise ValueError(f"Unknown quantization format: {qformat}")


def load_model_and_tokenizer(model_name: str, dtype: str, device: str):
    """Load the model and tokenizer."""
    from transformers import AutoModelForCausalLM, AutoTokenizer
    
    logger.info(f"Loading model: {model_name}")
    
    torch_dtype = torch.float16 if dtype == "float16" else torch.bfloat16
    
    tokenizer = AutoTokenizer.from_pretrained(
        model_name,
        trust_remote_code=True
    )
    
    # Ensure pad token is set
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    
    model = AutoModelForCausalLM.from_pretrained(
        model_name,
        torch_dtype=torch_dtype,
        device_map=device,
        trust_remote_code=True
    )
    
    logger.info(f"Model loaded on {device} with dtype {dtype}")
    
    # Log model size
    param_count = sum(p.numel() for p in model.parameters())
    logger.info(f"Model parameters: {param_count / 1e9:.2f}B")
    
    return model, tokenizer


def create_calibration_dataloader(
    tokenizer,
    num_samples: int = 512,
    seq_length: int = 2048,
    batch_size: int = 1
):
    """Create a calibration dataloader using CNN/DailyMail dataset."""
    from datasets import load_dataset
    
    logger.info(f"Loading calibration dataset (cnn_dailymail, {num_samples} samples)")
    
    # Load dataset
    dataset = load_dataset("cnn_dailymail", "3.0.0", split="train")
    
    # Sample and tokenize
    samples = []
    for i, item in enumerate(dataset):
        if i >= num_samples:
            break
        text = item["article"]
        tokens = tokenizer(
            text,
            max_length=seq_length,
            truncation=True,
            padding="max_length",
            return_tensors="pt"
        )
        samples.append(tokens["input_ids"])
    
    # Stack into batches
    all_input_ids = torch.cat(samples, dim=0)
    
    # Create simple iterator
    class CalibrationDataLoader:
        def __init__(self, input_ids, batch_size):
            self.input_ids = input_ids
            self.batch_size = batch_size
            self.idx = 0
        
        def __iter__(self):
            self.idx = 0
            return self
        
        def __next__(self):
            if self.idx >= len(self.input_ids):
                raise StopIteration
            batch = self.input_ids[self.idx:self.idx + self.batch_size]
            self.idx += self.batch_size
            return batch
        
        def __len__(self):
            return (len(self.input_ids) + self.batch_size - 1) // self.batch_size
    
    return CalibrationDataLoader(all_input_ids, batch_size)


def quantize_model(
    model,
    tokenizer,
    qformat: str,
    calib_samples: int,
    calib_seq_len: int,
    skip_calibration: bool = False
):
    """Apply quantization to the model."""
    import modelopt.torch.quantization as mtq
    
    logger.info(f"Applying {qformat.upper()} quantization...")
    
    # Get config
    quant_config = get_quantization_config(qformat)
    
    if skip_calibration:
        logger.info("Skipping calibration (using default scales)")
        
        def forward_loop(model):
            pass
    else:
        # Create calibration data
        calib_loader = create_calibration_dataloader(
            tokenizer,
            num_samples=calib_samples,
            seq_length=calib_seq_len
        )
        
        def forward_loop(model):
            """Run forward pass on calibration data."""
            model.eval()
            device = next(model.parameters()).device
            
            with torch.no_grad():
                for batch in tqdm(calib_loader, desc="Calibrating"):
                    batch = batch.to(device)
                    model(batch)
    
    # Apply quantization
    model = mtq.quantize(model, quant_config, forward_loop)
    
    logger.info("Quantization complete!")
    
    return model


def export_model(
    model,
    tokenizer,
    output_dir: str,
    export_format: str,
    model_name: str
):
    """Export the quantized model."""
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)
    
    logger.info(f"Exporting model to {output_path} (format: {export_format})")
    
    if export_format == "hf":
        # Export as Hugging Face checkpoint
        try:
            from modelopt.torch.export import export_hf_checkpoint
            
            with torch.inference_mode():
                export_hf_checkpoint(
                    model,
                    export_dir=str(output_path)
                )
        except ImportError:
            # Fallback: save directly
            logger.warning("export_hf_checkpoint not available, using model.save_pretrained()")
            model.save_pretrained(output_path)
        
        # Save tokenizer
        tokenizer.save_pretrained(output_path)
        
    elif export_format == "tensorrt_llm":
        # Export for TensorRT-LLM
        try:
            from modelopt.torch.export import export_tensorrt_llm_checkpoint
            
            export_tensorrt_llm_checkpoint(
                model,
                export_dir=str(output_path),
                dtype="float16"
            )
        except ImportError:
            logger.error("TensorRT-LLM export requires additional dependencies")
            logger.error("Install tensorrt-llm for this export format")
            sys.exit(1)
            
    elif export_format == "vllm":
        # Export for vLLM (HF format works)
        model.save_pretrained(output_path)
        tokenizer.save_pretrained(output_path)
        
        # Create vLLM config
        vllm_config = {
            "model": str(output_path),
            "quantization": "awq" if "awq" in str(output_path).lower() else "squeezellm"
        }
        
        with open(output_path / "vllm_config.yaml", "w") as f:
            yaml.dump(vllm_config, f)
    
    logger.info(f"Model exported to: {output_path}")
    
    # Log file sizes
    total_size = sum(f.stat().st_size for f in output_path.rglob("*") if f.is_file())
    logger.info(f"Total export size: {total_size / 1e9:.2f} GB")
    
    return output_path


def test_inference(model, tokenizer, device: str):
    """Run a quick inference test."""
    logger.info("Running inference test...")
    
    test_prompt = "What is the capital of France?"
    
    inputs = tokenizer(test_prompt, return_tensors="pt").to(device)
    
    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=50,
            temperature=0.7,
            do_sample=True
        )
    
    response = tokenizer.decode(outputs[0], skip_special_tokens=True)
    logger.info(f"Test prompt: {test_prompt}")
    logger.info(f"Response: {response}")


def main():
    """Main entry point."""
    args = parse_args()
    
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    # Load config file if provided
    config = {}
    if args.config:
        config = load_config(args.config)
        logger.info(f"Loaded config from {args.config}")
    
    # Override with command line args
    model_name = args.model or config.get("model", {}).get("name", "Qwen/Qwen3.5-1.8B")
    qformat = args.qformat or config.get("quantization", {}).get("format", "int8")
    output_dir = args.output or config.get("export", {}).get("output_dir", "./outputs")
    device = args.device or config.get("hardware", {}).get("device", "cuda:0")
    dtype = args.dtype or config.get("model", {}).get("torch_dtype", "float16")
    export_format = args.export_format or config.get("export", {}).get("format", "hf")
    calib_samples = args.calib_samples or config.get("quantization", {}).get("calibration", {}).get("num_samples", 512)
    calib_seq_len = args.calib_seq_len or config.get("quantization", {}).get("calibration", {}).get("seq_length", 2048)
    
    # Print configuration
    logger.info("=" * 60)
    logger.info("Qwen3.5 Quantization for T4 GPU")
    logger.info("=" * 60)
    logger.info(f"Model: {model_name}")
    logger.info(f"Quantization format: {qformat}")
    logger.info(f"Device: {device}")
    logger.info(f"Output: {output_dir}")
    logger.info("=" * 60)
    
    # Check GPU compatibility
    if not check_gpu_compatibility(qformat):
        sys.exit(1)
    
    # Create output directory name
    model_short = model_name.split("/")[-1]
    full_output_dir = os.path.join(output_dir, f"{model_short}_{qformat}")
    
    # Load model
    model, tokenizer = load_model_and_tokenizer(model_name, dtype, device)
    
    # Quantize
    model = quantize_model(
        model,
        tokenizer,
        qformat,
        calib_samples,
        calib_seq_len,
        args.skip_calibration
    )
    
    # Export
    output_path = export_model(
        model,
        tokenizer,
        full_output_dir,
        export_format,
        model_name
    )
    
    # Test inference
    test_inference(model, tokenizer, device)
    
    logger.info("=" * 60)
    logger.info("Quantization complete!")
    logger.info(f"Quantized model saved to: {output_path}")
    logger.info("=" * 60)


if __name__ == "__main__":
    main()