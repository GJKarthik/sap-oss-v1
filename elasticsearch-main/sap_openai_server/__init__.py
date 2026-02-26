"""
SAP OpenAI-Compatible Server for Elasticsearch

Provides a full OpenAI-compatible API with Elasticsearch integration for:
- Vector storage and semantic search
- Document retrieval for RAG
- Chat history persistence
"""

from .server import app, main, AICoreConfig, ElasticsearchConfig

__all__ = ["app", "main", "AICoreConfig", "ElasticsearchConfig"]
__version__ = "1.0.0"