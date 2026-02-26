"""
SAP OpenAI-Compatible Server for vLLM

Provides a full OpenAI-compatible API that routes to SAP AI Core.
"""

from .server import app, main, AICoreConfig

__all__ = ["app", "main", "AICoreConfig"]
__version__ = "1.0.0"