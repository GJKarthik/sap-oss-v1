"""
Vector Embeddings for Hybrid RAG Search.

Generates embeddings via SAP AI Core and performs hybrid search
combining BM25 (lexical) with kNN (semantic).
"""

import os
import httpx
from typing import List, Dict, Any, Optional
import json
import logging

logger = logging.getLogger(__name__)

# Configuration
AICORE_URL = os.getenv("AICORE_URL", "https://api.ai.core.sap.cloud")
ES_URL = os.getenv("ELASTICSEARCH_URL", "http://elasticsearch:9200")
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "text-embedding-ada-002")
EMBEDDING_DIMS = int(os.getenv("EMBEDDING_DIMS", "1536"))


class EmbeddingClient:
    """
    Client for generating embeddings via SAP AI Core.
    """
    
    def __init__(
        self,
        aicore_url: str = AICORE_URL,
        model: str = EMBEDDING_MODEL,
    ):
        self.aicore_url = aicore_url
        self.model = model
    
    async def embed(self, text: str) -> List[float]:
        """Generate embedding for single text."""
        embeddings = await self.embed_batch([text])
        return embeddings[0] if embeddings else []
    
    async def embed_batch(self, texts: List[str]) -> List[List[float]]:
        """Generate embeddings for batch of texts."""
        
        if not self.aicore_url:
            logger.warning("AI Core URL not configured, using mock embeddings")
            return [self._mock_embedding(t) for t in texts]
        
        try:
            async with httpx.AsyncClient() as client:
                response = await client.post(
                    f"{self.aicore_url}/v1/embeddings",
                    json={
                        "model": self.model,
                        "input": texts,
                    },
                    headers={"Content-Type": "application/json"},
                    timeout=60.0
                )
                
                if response.status_code == 200:
                    result = response.json()
                    return [d["embedding"] for d in result.get("data", [])]
                else:
                    logger.error(f"Embedding API error: {response.status_code}")
                    return [self._mock_embedding(t) for t in texts]
                    
        except Exception as e:
            logger.error(f"Embedding generation failed: {e}")
            return [self._mock_embedding(t) for t in texts]
    
    def _mock_embedding(self, text: str) -> List[float]:
        """Generate deterministic mock embedding for testing."""
        import hashlib
        
        # Create deterministic pseudo-random embedding from text hash
        h = hashlib.sha256(text.encode()).digest()
        embedding = []
        for i in range(EMBEDDING_DIMS):
            # Use bytes to generate values between -1 and 1
            byte_val = h[i % len(h)]
            embedding.append((byte_val / 127.5) - 1.0)
        return embedding


class HybridSearchClient:
    """
    Hybrid search combining BM25 (lexical) with kNN (semantic).
    
    Uses Elasticsearch 8.x kNN search with dense vectors.
    """
    
    def __init__(
        self,
        es_url: str = ES_URL,
        embedding_client: Optional[EmbeddingClient] = None,
    ):
        self.es_url = es_url
        self.embedding_client = embedding_client or EmbeddingClient()
    
    async def hybrid_search(
        self,
        index: str,
        query: str,
        k: int = 5,
        bm25_fields: List[str] = None,
        bm25_boost: float = 0.3,
        knn_boost: float = 0.7,
        filters: Optional[Dict[str, Any]] = None,
    ) -> List[Dict[str, Any]]:
        """
        Perform hybrid search: BM25 + kNN.
        
        Final score = bm25_boost × BM25_score + knn_boost × kNN_score
        
        Args:
            index: ES index name
            query: Search query text
            k: Number of results
            bm25_fields: Fields for BM25 search
            bm25_boost: Weight for lexical search (0-1)
            knn_boost: Weight for semantic search (0-1)
            filters: Optional ES query filters
        
        Returns:
            List of search results with combined scores
        """
        
        if bm25_fields is None:
            bm25_fields = ["entity_name^3", "description^2", "business_context"]
        
        # Generate query embedding
        query_embedding = await self.embedding_client.embed(query)
        
        # Build hybrid search request
        search_body = {
            "size": k * 2,  # Over-fetch for reranking
            "query": {
                "bool": {
                    "should": [
                        {
                            "multi_match": {
                                "query": query,
                                "fields": bm25_fields,
                                "type": "best_fields",
                                "boost": bm25_boost,
                            }
                        }
                    ]
                }
            },
            "knn": {
                "field": "embedding",
                "query_vector": query_embedding,
                "k": k * 2,
                "num_candidates": 100,
                "boost": knn_boost,
            },
            "_source": {"excludes": ["embedding"]},  # Don't return large vectors
        }
        
        # Add filters
        if filters:
            search_body["query"]["bool"]["filter"] = self._build_filters(filters)
        
        try:
            async with httpx.AsyncClient() as client:
                response = await client.post(
                    f"{self.es_url}/{index}/_search",
                    json=search_body,
                    timeout=30.0
                )
                
                if response.status_code == 200:
                    result = response.json()
                    hits = result.get("hits", {}).get("hits", [])
                    
                    # Deduplicate and return top k
                    seen_ids = set()
                    unique_results = []
                    for hit in hits:
                        doc_id = hit["_id"]
                        if doc_id not in seen_ids:
                            seen_ids.add(doc_id)
                            unique_results.append({
                                "id": doc_id,
                                "score": hit["_score"],
                                **hit["_source"]
                            })
                        if len(unique_results) >= k:
                            break
                    
                    return unique_results
                    
                elif response.status_code == 400:
                    # Likely kNN field doesn't exist, fall back to BM25 only
                    logger.warning(f"kNN search failed, falling back to BM25: {response.text[:200]}")
                    return await self._bm25_search(index, query, k, bm25_fields, filters)
                else:
                    logger.error(f"Hybrid search failed: {response.status_code}")
                    return []
                    
        except Exception as e:
            logger.error(f"Hybrid search error: {e}")
            return []
    
    async def _bm25_search(
        self,
        index: str,
        query: str,
        k: int,
        fields: List[str],
        filters: Optional[Dict[str, Any]] = None,
    ) -> List[Dict[str, Any]]:
        """Fall back to BM25-only search."""
        
        search_body = {
            "size": k,
            "query": {
                "bool": {
                    "must": [
                        {
                            "multi_match": {
                                "query": query,
                                "fields": fields,
                                "type": "best_fields",
                            }
                        }
                    ]
                }
            },
        }
        
        if filters:
            search_body["query"]["bool"]["filter"] = self._build_filters(filters)
        
        try:
            async with httpx.AsyncClient() as client:
                response = await client.post(
                    f"{self.es_url}/{index}/_search",
                    json=search_body,
                    timeout=30.0
                )
                
                if response.status_code == 200:
                    result = response.json()
                    hits = result.get("hits", {}).get("hits", [])
                    return [
                        {"id": h["_id"], "score": h["_score"], **h["_source"]}
                        for h in hits
                    ]
                return []
                
        except Exception as e:
            logger.error(f"BM25 search error: {e}")
            return []
    
    def _build_filters(self, filters: Dict[str, Any]) -> List[Dict]:
        """Build ES filter clauses."""
        clauses = []
        
        for key, value in filters.items():
            if isinstance(value, list):
                clauses.append({"terms": {f"{key}.keyword": value}})
            elif isinstance(value, dict) and "range" in value:
                clauses.append({"range": {key: value["range"]}})
            else:
                clauses.append({"term": {f"{key}.keyword": value}})
        
        return clauses
    
    async def index_with_embedding(
        self,
        index: str,
        doc_id: str,
        document: Dict[str, Any],
        text_field: str = "description",
    ) -> bool:
        """
        Index a document with its embedding.
        
        Generates embedding from the specified text field.
        """
        
        # Generate embedding
        text = document.get(text_field, "")
        if text:
            embedding = await self.embedding_client.embed(text)
            document["embedding"] = embedding
        
        try:
            async with httpx.AsyncClient() as client:
                response = await client.put(
                    f"{self.es_url}/{index}/_doc/{doc_id}",
                    json=document,
                    timeout=30.0
                )
                return response.status_code in [200, 201]
                
        except Exception as e:
            logger.error(f"Index with embedding failed: {e}")
            return False


async def create_vector_index(
    index_name: str,
    embedding_dims: int = EMBEDDING_DIMS,
    es_url: str = ES_URL,
) -> bool:
    """
    Create ES index with dense_vector field for hybrid search.
    """
    
    mapping = {
        "mappings": {
            "properties": {
                "entity_name": {"type": "keyword"},
                "entity_type": {"type": "keyword"},
                "description": {"type": "text", "analyzer": "standard"},
                "business_context": {"type": "text"},
                "odata_namespace": {"type": "keyword"},
                "hana_view": {"type": "keyword"},
                "embedding": {
                    "type": "dense_vector",
                    "dims": embedding_dims,
                    "index": True,
                    "similarity": "cosine",
                },
                "last_updated": {"type": "date"},
            }
        },
        "settings": {
            "number_of_shards": 1,
            "number_of_replicas": 0,
        }
    }
    
    try:
        async with httpx.AsyncClient() as client:
            # Check if index exists
            check = await client.head(f"{es_url}/{index_name}")
            if check.status_code == 200:
                logger.info(f"Index {index_name} already exists")
                return True
            
            # Create index
            response = await client.put(
                f"{es_url}/{index_name}",
                json=mapping,
                timeout=30.0
            )
            
            if response.status_code in [200, 201]:
                logger.info(f"Created vector index: {index_name}")
                return True
            else:
                logger.error(f"Failed to create index: {response.text}")
                return False
                
    except Exception as e:
        logger.error(f"Create vector index failed: {e}")
        return False


# Singleton instances
embedding_client = EmbeddingClient()
hybrid_search = HybridSearchClient()