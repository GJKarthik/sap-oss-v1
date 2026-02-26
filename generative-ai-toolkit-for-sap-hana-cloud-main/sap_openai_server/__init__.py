"""
SAP OpenAI-Compatible Server for HANA Cloud Generative AI Toolkit

Provides a full OpenAI-compatible API that routes to SAP AI Core
with native HANA Cloud vector store integration.
"""

from .server import app, main

__version__ = "1.0.0"
__all__ = ["app", "main"]