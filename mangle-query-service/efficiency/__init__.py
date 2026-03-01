"""
Efficiency module for mangle-query-service.
Phase 1: Semantic Cache + Request Batching
"""

from .semantic_cache import SemanticCache
from .batch_client import BatchedAICoreClient

__all__ = ["SemanticCache", "BatchedAICoreClient"]