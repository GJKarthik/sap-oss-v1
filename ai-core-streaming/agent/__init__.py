"""
AI Core Streaming Agent Module

Provides governance-aware agents with ODPS 4.1 data product integration
for SAP AI Core streaming inference infrastructure.

Note: External backend for public/internal data.
Routes to vLLM for confidential, blocks restricted.
"""

from .aicore_streaming_agent import AICoreStreamingAgent, MangleEngine

__all__ = ["AICoreStreamingAgent", "MangleEngine"]