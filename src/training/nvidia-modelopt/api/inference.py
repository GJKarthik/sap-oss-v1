#!/usr/bin/env python3
"""
Real Inference Engine for Model Optimizer
Integrates with vLLM or Transformers for actual model inference
"""

import os
import logging
import subprocess
from typing import Optional, List, Dict, Any, AsyncIterator
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)


@dataclass
class GPUInfo:
    """Real GPU information from nvidia-smi"""
    name: str
    compute_capability: str
    memory_total_gb: float
    memory_used_gb: float
    memory_free_gb: float
    utilization_percent: int
    temperature_c: int
    driver_version: str
    cuda_version: str


def detect_gpu() -> Optional[GPUInfo]:
    """Detect real GPU using nvidia-smi"""
    try:
        result = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=name,compute_cap,memory.total,memory.used,memory.free,utilization.gpu,temperature.gpu,driver_version",
                "--format=csv,noheader,nounits"
            ],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        if result.returncode != 0:
            logger.warning(f"nvidia-smi failed: {result.stderr}")
            return None
        
        line = result.stdout.strip().split("\n")[0]
        parts = [p.strip() for p in line.split(",")]
        
        # Get CUDA version separately
        cuda_result = subprocess.run(
            ["nvidia-smi", "--query-gpu=cuda_version", "--format=csv,noheader"],
            capture_output=True,
            text=True,
            timeout=5
        )
        cuda_version = cuda_result.stdout.strip() if cuda_result.returncode == 0 else "N/A"
        
        return GPUInfo(
            name=parts[0],
            compute_capability=parts[1],
            memory_total_gb=float(parts[2]) / 1024,
            memory_used_gb=float(parts[3]) / 1024,
            memory_free_gb=float(parts[4]) / 1024,
            utilization_percent=int(parts[5]) if parts[5].isdigit() else 0,
            temperature_c=int(parts[6]) if parts[6].isdigit() else 0,
            driver_version=parts[7],
            cuda_version=cuda_version
        )
    except FileNotFoundError:
        logger.warning("nvidia-smi not found - no GPU detected")
        return None
    except Exception as e:
        logger.error(f"GPU detection error: {e}")
        return None


def get_supported_formats(gpu: Optional[GPUInfo]) -> List[str]:
    """Get supported quantization formats based on GPU compute capability"""
    if not gpu:
        return ["int8", "int4_awq", "w4a16"]  # CPU fallback
    
    try:
        major, minor = map(int, gpu.compute_capability.split("."))
        cc = major * 10 + minor
    except (ValueError, AttributeError, TypeError):
        return ["int8", "int4_awq", "w4a16"]
    
    formats = ["int8", "int4_awq", "w4a16"]
    
    if cc >= 89:  # Ada Lovelace+
        formats.append("fp8")
    
    if cc >= 90:  # Hopper/Blackwell
        formats.append("nvfp4")
    
    return formats


class InferenceEngine:
    """
    Real inference engine supporting multiple backends
    """
    
    def __init__(self, model_path: str, backend: str = "auto"):
        self.model_path = model_path
        self.backend = backend
        self.model = None
        self.tokenizer = None
        self.gpu = detect_gpu()
        self._loaded = False
        
    def load(self):
        """Load the model based on available backend"""
        if self._loaded:
            return
        
        # Try vLLM first (best performance)
        if self.backend in ("auto", "vllm"):
            try:
                from vllm import LLM, SamplingParams
                self.model = LLM(
                    model=self.model_path,
                    trust_remote_code=True,
                    tensor_parallel_size=1,
                    dtype="auto",
                    gpu_memory_utilization=0.9,
                )
                self.backend = "vllm"
                self._loaded = True
                logger.info(f"Loaded model with vLLM: {self.model_path}")
                return
            except ImportError:
                logger.info("vLLM not available, trying transformers")
            except Exception as e:
                logger.warning(f"vLLM load failed: {e}")
        
        # Fallback to transformers
        if self.backend in ("auto", "transformers"):
            try:
                import torch
                from transformers import AutoModelForCausalLM, AutoTokenizer
                
                self.tokenizer = AutoTokenizer.from_pretrained(
                    self.model_path,
                    trust_remote_code=True
                )
                
                device = "cuda" if torch.cuda.is_available() else "cpu"
                dtype = torch.float16 if device == "cuda" else torch.float32
                
                self.model = AutoModelForCausalLM.from_pretrained(
                    self.model_path,
                    torch_dtype=dtype,
                    device_map="auto",
                    trust_remote_code=True
                )
                
                if self.tokenizer.pad_token is None:
                    self.tokenizer.pad_token = self.tokenizer.eos_token
                
                self.backend = "transformers"
                self._loaded = True
                logger.info(f"Loaded model with transformers: {self.model_path}")
                return
            except ImportError:
                logger.error("Neither vLLM nor transformers available")
            except Exception as e:
                logger.error(f"Transformers load failed: {e}")
        
        raise RuntimeError(f"Could not load model {self.model_path}")
    
    def generate(
        self,
        prompt: str,
        max_tokens: int = 2048,
        temperature: float = 0.7,
        top_p: float = 1.0,
        stop: Optional[List[str]] = None,
    ) -> str:
        """Generate completion for a prompt"""
        if not self._loaded:
            self.load()
        
        if self.backend == "vllm":
            from vllm import SamplingParams
            sampling_params = SamplingParams(
                max_tokens=max_tokens,
                temperature=temperature,
                top_p=top_p,
                stop=stop,
            )
            outputs = self.model.generate([prompt], sampling_params)
            return outputs[0].outputs[0].text
        
        elif self.backend == "transformers":
            import torch
            
            inputs = self.tokenizer(prompt, return_tensors="pt")
            inputs = {k: v.to(self.model.device) for k, v in inputs.items()}
            
            with torch.no_grad():
                outputs = self.model.generate(
                    **inputs,
                    max_new_tokens=max_tokens,
                    temperature=temperature if temperature > 0 else None,
                    top_p=top_p if temperature > 0 else None,
                    do_sample=temperature > 0,
                    pad_token_id=self.tokenizer.pad_token_id,
                )
            
            response = self.tokenizer.decode(outputs[0], skip_special_tokens=True)
            # Remove the prompt from the response
            if response.startswith(prompt):
                response = response[len(prompt):]
            return response.strip()
        
        raise RuntimeError(f"Unknown backend: {self.backend}")
    
    async def generate_stream(
        self,
        prompt: str,
        max_tokens: int = 2048,
        temperature: float = 0.7,
        top_p: float = 1.0,
        stop: Optional[List[str]] = None,
    ) -> AsyncIterator[str]:
        """Stream generate completion tokens"""
        if not self._loaded:
            self.load()
        
        if self.backend == "transformers":
            import torch
            from transformers import TextIteratorStreamer
            from threading import Thread
            
            inputs = self.tokenizer(prompt, return_tensors="pt")
            inputs = {k: v.to(self.model.device) for k, v in inputs.items()}
            
            streamer = TextIteratorStreamer(
                self.tokenizer,
                skip_prompt=True,
                skip_special_tokens=True
            )
            
            generation_kwargs = dict(
                **inputs,
                max_new_tokens=max_tokens,
                temperature=temperature if temperature > 0 else None,
                top_p=top_p if temperature > 0 else None,
                do_sample=temperature > 0,
                streamer=streamer,
            )
            
            thread = Thread(target=self.model.generate, kwargs=generation_kwargs)
            thread.start()
            
            for text in streamer:
                yield text
            
            thread.join()
        else:
            # For vLLM, fall back to non-streaming
            result = self.generate(prompt, max_tokens, temperature, top_p, stop)
            for word in result.split():
                yield word + " "


# Singleton instance management
_engines: Dict[str, InferenceEngine] = {}


def get_engine(model_id: str) -> InferenceEngine:
    """Get or create an inference engine for a model."""
    from .model_registry import resolve_path

    if model_id not in _engines:
        path = resolve_path(model_id)
        _engines[model_id] = InferenceEngine(path)
    return _engines[model_id]


def model_exists(model_id: str) -> bool:
    """Check if a model exists locally."""
    from .model_registry import model_exists_locally

    return model_exists_locally(model_id)