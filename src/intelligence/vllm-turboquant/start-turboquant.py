#!/usr/bin/env python3
"""
TurboQuant vLLM Starter - Universal for AWQ and FP8 models
Supports both compressed-tensors (AWQ) and native FP8 quantization
"""
import os
import asyncio
import argparse

# CRITICAL: Force spawn method BEFORE any vLLM/TurboQuant import
os.environ["VLLM_WORKER_MULTIPROC_METHOD"] = "spawn"

from turboquant.integration.vllm import set_mode
from vllm.entrypoints.openai.api_server import run_server, make_arg_parser

if __name__ == "__main__":
    # === Parameters from ServingTemplate (env vars) ===
    model_name          = os.environ.get("MODEL", "Qwen/Qwen3.5-35B-A3B-FP8")
    data_type           = os.environ.get("DATA_TYPE", "auto")
    gpu_mem_util        = float(os.environ.get("GPU_MEM_UTIL", "0.95"))
    max_model_len       = int(os.environ.get("MAX_MODEL_LEN", "16384"))
    max_batched_tokens  = int(os.environ.get("MAX_BATCHED_TOKENS", "32768"))
    max_num_seqs        = int(os.environ.get("MAX_NUM_SEQS", "64"))
    
    # NEW: Quantization control (optional - for AWQ models)
    quantization        = os.environ.get("QUANTIZATION", "")  # e.g., "compressed-tensors" for AWQ
    
    # NEW: KV Cache dtype control (fp8 for FP8 models, auto for AWQ)
    kv_cache_dtype      = os.environ.get("KV_CACHE_DTYPE", "auto")

    # Build full CLI arguments so vLLM parser can fill EVERY field
    cli = [
        "--model", model_name,
        "--dtype", data_type,
        "--gpu-memory-utilization", str(gpu_mem_util),
        "--max-model-len", str(max_model_len),
        "--max-num-batched-tokens", str(max_batched_tokens),
        "--max-num-seqs", str(max_num_seqs),
        "--enable-prefix-caching",
        "--enable-chunked-prefill",
        "--tensor-parallel-size", "1",
        "--language-model-only",
        "--kv-cache-dtype", kv_cache_dtype,
    ]
    
    # Add quantization flag only if specified (AWQ models need it, FP8 doesn't)
    if quantization:
        cli.extend(["--quantization", quantization])

    # Create base parser, then let vLLM's make_arg_parser add all arguments
    base_parser = argparse.ArgumentParser(description="vLLM OpenAI-compatible API server with TurboQuant")
    parser = make_arg_parser(base_parser)
    cli_args = parser.parse_args(cli)

    # ← Activate TurboQuant KV compression BEFORE run_server creates the engine
    # This sets global state that the engine will use when it's created
    set_mode("hybrid")

    # Device type logic
    device = os.getenv("VLLM_DEVICE", "cuda")
    print(f"🚀 Device target: {device}")
    
    if device == "cpu":
        cli_args.extend(["--device", "cpu"])
    else:
        # GPU optimizations
        print(f"🚀 TurboQuant KV-Cache ENABLED → hybrid mode (3b keys / 4b values)")
        cli_args.extend(["--kv-cache-dtype", "fp8"])
        print(f"   ~31% KV savings | L40S concurrency throttle ready")

    # Start OpenAI-compatible server - it will create the engine internally (only ONCE)
    asyncio.run(run_server(cli_args))