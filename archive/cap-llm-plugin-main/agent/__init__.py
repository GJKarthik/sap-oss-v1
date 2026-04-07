"""
CAP LLM Plugin Agent Module

Provides governance-aware agents with ODPS 4.1 data product integration
and regulations/mangle compliance for CAP applications.
"""

from .cap_llm_agent import CapLlmAgent, MangleEngine

__all__ = ["CapLlmAgent", "MangleEngine"]