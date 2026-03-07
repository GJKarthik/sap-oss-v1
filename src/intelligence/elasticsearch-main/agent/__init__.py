"""
Elasticsearch Agent Module

Provides governance-aware agents with ODPS 4.1 data product integration
for Elasticsearch search and analytics operations.

Note: Index-based routing - confidential indices route to vLLM.
"""

from .elasticsearch_agent import ElasticsearchAgent, MangleEngine

__all__ = ["ElasticsearchAgent", "MangleEngine"]