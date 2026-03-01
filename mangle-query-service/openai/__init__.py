"""
Mangle Query Service - OpenAI-compatible HTTP API.

Provides OpenAI-compatible endpoints with Mangle routing rules.
"""

from .router import app

__all__ = ["app"]