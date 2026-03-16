"""
LangChain HANA Bridge for Mangle Query Service.

Addresses Integration Gaps:
- Gap 1: Direct integration with langchain-hana HanaDB for vector search
- Gap 2: Consolidates embedding logic using HanaInternalEmbeddings
- Gap 3: Exposes langchain-hana tools via MCP predicates

This module bridges mangle-query-service with langchain-integration-for-sap-hana-cloud,
enabling the RAG resolution path to use HANA Vector Engine directly.
"""

import asyncio
import json
import logging
import os
from typing import Any, Dict, List, Optional, Tuple
from dataclasses import dataclass, field
from contextlib import asynccontextmanager

logger = logging.getLogger(__name__)

# Configuration
HANA_HOST = os.getenv("HANA_HOST", "")
HANA_PORT = int(os.getenv("HANA_PORT", "443"))
HANA_USER = os.getenv("HANA_USER", "")
HANA_PASSWORD = os.getenv("HANA_PASSWORD", "")
HANA_ENCRYPT = os.getenv("HANA_ENCRYPT", "true").lower() == "true"
HANA_INTERNAL_EMBEDDING_MODEL = os.getenv("HANA_INTERNAL_EMBEDDING_MODEL", "SAP_NEB_V2")

# Try to import langchain-hana components
try:
    from hdbcli import dbapi
    from langchain_hana import HanaDB, HanaInternalEmbeddings
    from langchain_hana.utils import DistanceStrategy
    LANGCHAIN_HANA_AVAILABLE = True
except ImportError:
    LANGCHAIN_HANA_AVAILABLE = False
    logger.warning("langchain-hana not installed. Install with: pip install langchain-hana")


@dataclass
class VectorSearchResult:
    """Result from vector search operation."""
    content: str
    metadata: Dict[str, Any]
    score: float
    embedding: Optional[List[float]] = None


@dataclass
class AsyncConnectionPool:
    """
    Async connection pool for HANA DB.
    
    Addresses langchain-hana Weakness #1: Synchronous connection pool
    """
    host: str
    port: int
    user: str
    password: str
    encrypt: bool = True
    pool_size: int = 5
    _connections: List[Any] = field(default_factory=list)
    _semaphore: asyncio.Semaphore = field(default_factory=lambda: asyncio.Semaphore(5))
    _lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    
    def __post_init__(self):
        self._semaphore = asyncio.Semaphore(self.pool_size)
    
    async def _create_connection(self) -> Any:
        """Create a new HANA connection in executor."""
        if not LANGCHAIN_HANA_AVAILABLE:
            raise RuntimeError("langchain-hana not available")
        
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, lambda: dbapi.connect(
            address=self.host,
            port=self.port,
            user=self.user,
            password=self.password,
            encrypt=self.encrypt,
            sslValidateCertificate=False,
        ))
    
    @asynccontextmanager
    async def acquire(self):
        """Acquire a connection from the pool."""
        await self._semaphore.acquire()
        conn = None
        try:
            async with self._lock:
                if self._connections:
                    conn = self._connections.pop()
            
            if conn is None:
                conn = await self._create_connection()
            
            yield conn
            
        finally:
            if conn:
                async with self._lock:
                    if len(self._connections) < self.pool_size:
                        self._connections.append(conn)
                    else:
                        loop = asyncio.get_event_loop()
                        await loop.run_in_executor(None, conn.close)
            self._semaphore.release()
    
    async def close_all(self):
        """Close all connections in the pool."""
        async with self._lock:
            for conn in self._connections:
                try:
                    loop = asyncio.get_event_loop()
                    await loop.run_in_executor(None, conn.close)
                except Exception:
                    pass
            self._connections.clear()


class LangChainHanaBridge:
    """
    Bridge between mangle-query-service and langchain-hana.
    
    Provides async wrapper around HanaDB and HanaInternalEmbeddings,
    exposing them as Mangle predicates.
    """
    
    def __init__(
        self,
        host: str = HANA_HOST,
        port: int = HANA_PORT,
        user: str = HANA_USER,
        password: str = HANA_PASSWORD,
        encrypt: bool = HANA_ENCRYPT,
        embedding_model: str = HANA_INTERNAL_EMBEDDING_MODEL,
        table_name: str = "EMBEDDINGS",
        distance_strategy: str = "cosine",
    ):
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.encrypt = encrypt
        self.embedding_model = embedding_model
        self.table_name = table_name
        self.distance_strategy = distance_strategy
        
        # Async connection pool
        self._pool: Optional[AsyncConnectionPool] = None
        self._hana_db: Optional[Any] = None
        self._embedding: Optional[Any] = None
        self._initialized = False
        self._lock = asyncio.Lock()
    
    def is_configured(self) -> bool:
        """Check if HANA connection is configured."""
        return bool(self.host and self.user and self.password)
    
    async def initialize(self) -> bool:
        """
        Initialize the bridge with langchain-hana components.
        
        Creates async connection pool and HanaDB instance.
        """
        if not LANGCHAIN_HANA_AVAILABLE:
            logger.error("langchain-hana not available")
            return False
        
        if not self.is_configured():
            logger.error("HANA connection not configured")
            return False
        
        async with self._lock:
            if self._initialized:
                return True
            
            try:
                # Create async connection pool
                self._pool = AsyncConnectionPool(
                    host=self.host,
                    port=self.port,
                    user=self.user,
                    password=self.password,
                    encrypt=self.encrypt,
                )
                
                # Create sync connection for HanaDB (it manages its own connection)
                loop = asyncio.get_event_loop()
                conn = await loop.run_in_executor(None, lambda: dbapi.connect(
                    address=self.host,
                    port=self.port,
                    user=self.user,
                    password=self.password,
                    encrypt=self.encrypt,
                    sslValidateCertificate=False,
                ))
                
                # Create internal embeddings (uses HANA's VECTOR_EMBEDDING function)
                self._embedding = HanaInternalEmbeddings(model_id=self.embedding_model)
                
                # Create HanaDB instance
                distance = (
                    DistanceStrategy.COSINE if self.distance_strategy == "cosine"
                    else DistanceStrategy.EUCLIDEAN_DISTANCE
                )
                
                self._hana_db = HanaDB(
                    connection=conn,
                    embedding=self._embedding,
                    distance_strategy=distance,
                    table_name=self.table_name,
                )
                
                self._initialized = True
                logger.info(f"LangChain HANA bridge initialized: table={self.table_name}")
                return True
                
            except Exception as e:
                logger.error(f"Failed to initialize LangChain HANA bridge: {e}")
                return False
    
    async def similarity_search(
        self,
        query: str,
        k: int = 5,
        filter: Optional[Dict[str, Any]] = None,
    ) -> List[VectorSearchResult]:
        """
        Perform similarity search using langchain-hana HanaDB.
        
        This is the main integration point - mangle's RAG path
        calls this instead of ES hybrid search for HANA data.
        
        Args:
            query: Search query text
            k: Number of results to return
            filter: Optional metadata filter
        
        Returns:
            List of VectorSearchResult with content, metadata, score
        """
        if not await self.initialize():
            return []
        
        try:
            # Run sync HanaDB search in executor
            loop = asyncio.get_event_loop()
            results = await loop.run_in_executor(
                None,
                lambda: self._hana_db.similarity_search_with_score(
                    query=query,
                    k=k,
                    filter=filter,
                )
            )
            
            return [
                VectorSearchResult(
                    content=doc.page_content,
                    metadata=doc.metadata,
                    score=score,
                )
                for doc, score in results
            ]
            
        except Exception as e:
            logger.error(f"Similarity search failed: {e}")
            return []
    
    async def similarity_search_with_vectors(
        self,
        query: str,
        k: int = 5,
        filter: Optional[Dict[str, Any]] = None,
    ) -> List[VectorSearchResult]:
        """
        Similarity search returning embedding vectors too.
        
        Useful for reranking or further processing.
        """
        if not await self.initialize():
            return []
        
        try:
            loop = asyncio.get_event_loop()
            
            # Use internal embeddings for query
            results = await loop.run_in_executor(
                None,
                lambda: self._hana_db.similarity_search_with_score_and_vector_by_query(
                    query=query,
                    k=k,
                    filter=filter,
                )
            )
            
            return [
                VectorSearchResult(
                    content=doc.page_content,
                    metadata=doc.metadata,
                    score=score,
                    embedding=vector,
                )
                for doc, score, vector in results
            ]
            
        except Exception as e:
            logger.error(f"Similarity search with vectors failed: {e}")
            return []
    
    async def mmr_search(
        self,
        query: str,
        k: int = 5,
        fetch_k: int = 20,
        lambda_mult: float = 0.5,
        filter: Optional[Dict[str, Any]] = None,
    ) -> List[VectorSearchResult]:
        """
        Maximal Marginal Relevance search for diversity.
        
        Balances relevance with diversity in results.
        """
        if not await self.initialize():
            return []
        
        try:
            loop = asyncio.get_event_loop()
            docs = await loop.run_in_executor(
                None,
                lambda: self._hana_db.max_marginal_relevance_search(
                    query=query,
                    k=k,
                    fetch_k=fetch_k,
                    lambda_mult=lambda_mult,
                    filter=filter,
                )
            )
            
            return [
                VectorSearchResult(
                    content=doc.page_content,
                    metadata=doc.metadata,
                    score=1.0,  # MMR doesn't return scores
                )
                for doc in docs
            ]
            
        except Exception as e:
            logger.error(f"MMR search failed: {e}")
            return []
    
    async def embed_text(self, text: str) -> Optional[List[float]]:
        """
        Generate embedding using HANA's internal VECTOR_EMBEDDING function.
        
        Addresses Gap #2: Consolidates embedding logic.
        Uses HANA's built-in embedding instead of external service.
        """
        if not await self.initialize():
            return None
        
        try:
            loop = asyncio.get_event_loop()
            embedding = await loop.run_in_executor(
                None,
                lambda: self._embedding.embed_query(text)
            )
            return embedding
            
        except Exception as e:
            logger.error(f"Embed text failed: {e}")
            return None
    
    async def embed_documents(self, documents: List[str]) -> List[List[float]]:
        """
        Generate embeddings for multiple documents.
        """
        if not await self.initialize():
            return []
        
        try:
            loop = asyncio.get_event_loop()
            embeddings = await loop.run_in_executor(
                None,
                lambda: self._embedding.embed_documents(documents)
            )
            return embeddings
            
        except Exception as e:
            logger.error(f"Embed documents failed: {e}")
            return []
    
    async def add_texts(
        self,
        texts: List[str],
        metadatas: Optional[List[Dict[str, Any]]] = None,
    ) -> bool:
        """
        Add texts to the vector store.
        
        Uses HANA's internal embedding function for consistency.
        """
        if not await self.initialize():
            return False
        
        try:
            loop = asyncio.get_event_loop()
            await loop.run_in_executor(
                None,
                lambda: self._hana_db.add_texts(texts, metadatas)
            )
            return True
            
        except Exception as e:
            logger.error(f"Add texts failed: {e}")
            return False
    
    async def delete(self, filter: Dict[str, Any]) -> bool:
        """
        Delete entries by metadata filter.
        """
        if not await self.initialize():
            return False
        
        try:
            loop = asyncio.get_event_loop()
            result = await loop.run_in_executor(
                None,
                lambda: self._hana_db.delete(filter=filter)
            )
            return result
            
        except Exception as e:
            logger.error(f"Delete failed: {e}")
            return False
    
    async def health_check(self) -> Dict[str, Any]:
        """Check health of the HANA connection."""
        if not LANGCHAIN_HANA_AVAILABLE:
            return {"status": "unavailable", "error": "langchain-hana not installed"}
        
        if not self.is_configured():
            return {"status": "not_configured"}
        
        if not await self.initialize():
            return {"status": "initialization_failed"}
        
        try:
            # Simple connectivity check
            loop = asyncio.get_event_loop()
            async with self._pool.acquire() as conn:
                cursor = conn.cursor()
                await loop.run_in_executor(None, cursor.execute, "SELECT 1 FROM DUMMY")
                result = await loop.run_in_executor(None, cursor.fetchone)
                cursor.close()
                
                return {
                    "status": "healthy",
                    "host": self.host,
                    "table": self.table_name,
                    "embedding_model": self.embedding_model,
                }
                
        except Exception as e:
            return {"status": "error", "error": str(e)}
    
    async def close(self):
        """Close all connections."""
        if self._pool:
            await self._pool.close_all()


# Mangle predicate implementations
# These are exposed via MCP for use in Mangle rules

async def hana_vector_search(
    query: str,
    k: int = 5,
    filter_json: Optional[str] = None,
) -> str:
    """
    Mangle predicate: hana_vector_search(Query, K, FilterJSON) -> ResultsJSON
    
    Addresses Gap #1: Direct integration with langchain-hana.
    """
    bridge = get_bridge()
    filter_dict = json.loads(filter_json) if filter_json else None
    
    results = await bridge.similarity_search(query, k, filter_dict)
    
    return json.dumps([
        {
            "content": r.content,
            "metadata": r.metadata,
            "score": r.score,
        }
        for r in results
    ])


async def hana_mmr_search(
    query: str,
    k: int = 5,
    fetch_k: int = 20,
    lambda_mult: float = 0.5,
    filter_json: Optional[str] = None,
) -> str:
    """
    Mangle predicate: hana_mmr_search(Query, K, FetchK, Lambda, FilterJSON) -> ResultsJSON
    """
    bridge = get_bridge()
    filter_dict = json.loads(filter_json) if filter_json else None
    
    results = await bridge.mmr_search(query, k, fetch_k, lambda_mult, filter_dict)
    
    return json.dumps([
        {
            "content": r.content,
            "metadata": r.metadata,
            "score": r.score,
        }
        for r in results
    ])


async def hana_embed(text: str) -> str:
    """
    Mangle predicate: hana_embed(Text) -> EmbeddingJSON
    
    Uses HANA's internal VECTOR_EMBEDDING function.
    """
    bridge = get_bridge()
    embedding = await bridge.embed_text(text)
    
    if embedding:
        return json.dumps(embedding)
    return "[]"


# Singleton bridge instance
_bridge: Optional[LangChainHanaBridge] = None
_bridge_lock = asyncio.Lock()


def get_bridge() -> LangChainHanaBridge:
    """Get or create the bridge singleton."""
    global _bridge
    if _bridge is None:
        _bridge = LangChainHanaBridge()
    return _bridge


async def initialize_bridge() -> bool:
    """Initialize the bridge singleton."""
    global _bridge
    async with _bridge_lock:
        if _bridge is None:
            _bridge = LangChainHanaBridge()
        return await _bridge.initialize()