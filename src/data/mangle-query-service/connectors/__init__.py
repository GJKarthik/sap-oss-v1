"""
Mangle Query Service Connectors.

- hana: SAP HANA Cloud connector for analytical queries
- embeddings: Vector embeddings and hybrid search
"""

from .hana import HANAClient, HANAResolver, hana_resolver
from .embeddings import (
    EmbeddingClient, 
    HybridSearchClient,
    embedding_client,
    hybrid_search,
    create_vector_index,
)

__all__ = [
    "HANAClient",
    "HANAResolver",
    "hana_resolver",
    "EmbeddingClient",
    "HybridSearchClient",
    "embedding_client",
    "hybrid_search",
    "create_vector_index",
]