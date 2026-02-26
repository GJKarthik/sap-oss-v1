"""
vLLM Infrastructure Agent Module

Provides governance-aware agents with ODPS 4.1 data product integration
for on-premise LLM inference infrastructure.

Note: This IS the vLLM backend - local only, no external routing.
Lowest autonomy (L1), highest oversight requirements.
"""

from .vllm_agent import VLLMAgent, MangleEngine

__all__ = ["VLLMAgent", "MangleEngine"]