"""
Kernel package — SIMD and GPU kernels for LLM inference.

Available submodules:
  kernel.attention      — Flash Attention v1 (baseline)
  kernel.attention_v2   — Flash Attention v2 (outer Q-loop, stack scratch, causal mask)
  kernel.int8_gemm      — INT8 symmetric quantisation + SIMD INT8×INT8→INT32 GEMM
  kernel.t4_tensor_core — NVIDIA T4 Tensor Core helpers
"""
