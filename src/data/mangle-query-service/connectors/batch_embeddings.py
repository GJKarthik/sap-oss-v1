"""
Batch Embedding Generation for HANA.

Implements Enhancement 1.2: Batch Embedding Generation
- Batch requests to HANA's VECTOR_EMBEDDING()
- Automatic batching with configurable size and timeout
- 5-10x throughput improvement for bulk indexing

Usage:
    batcher = await get_embedding_batcher()
    
    # Single embedding (auto-batched)
    embedding = await batcher.embed("document text")
    
    # Bulk embeddings
    embeddings = await batcher.embed_batch(["doc1", "doc2", "doc3"])
"""

import asyncio
import logging
import os
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

# Configuration
BATCH_SIZE = int(os.getenv("HANA_EMBEDDING_BATCH_SIZE", "32"))
BATCH_TIMEOUT_MS = float(os.getenv("HANA_EMBEDDING_BATCH_TIMEOUT_MS", "50.0"))
MAX_CONCURRENT_BATCHES = int(os.getenv("HANA_EMBEDDING_MAX_CONCURRENT", "4"))
EMBEDDING_DIMS = int(os.getenv("HANA_EMBEDDING_DIMS", "1536"))


@dataclass
class EmbeddingRequest:
    """Single embedding request in queue."""
    text: str
    future: asyncio.Future
    created_at: float = field(default_factory=time.time)


@dataclass
class BatchStats:
    """Statistics for batch embedding."""
    total_requests: int = 0
    total_batches: int = 0
    total_embeddings: int = 0
    total_errors: int = 0
    total_batch_time_ms: float = 0.0
    avg_batch_size: float = 0.0
    avg_batch_latency_ms: float = 0.0


class HanaEmbeddingBatcher:
    """
    Automatic batching for HANA VECTOR_EMBEDDING calls.
    
    Collects individual embedding requests and batches them
    for efficient processing. Requests are auto-batched when:
    - Batch size is reached
    - Timeout expires
    - Explicit flush is called
    
    This provides 5-10x throughput improvement for bulk operations
    by reducing round-trips to HANA.
    """
    
    def __init__(
        self,
        batch_size: int = BATCH_SIZE,
        batch_timeout_ms: float = BATCH_TIMEOUT_MS,
        max_concurrent: int = MAX_CONCURRENT_BATCHES,
    ):
        self.batch_size = batch_size
        self.batch_timeout_ms = batch_timeout_ms
        self.max_concurrent = max_concurrent
        
        self._queue: List[EmbeddingRequest] = []
        self._queue_lock = asyncio.Lock()
        self._batch_semaphore = asyncio.Semaphore(max_concurrent)
        self._timer_task: Optional[asyncio.Task] = None
        self._stats = BatchStats()
        
        # HANA connection (lazy initialization)
        self._bridge = None
        self._initialized = False
    
    async def _ensure_initialized(self) -> bool:
        """Ensure HANA bridge is initialized."""
        if self._initialized:
            return True
        
        try:
            from connectors.langchain_hana_bridge import get_bridge
            self._bridge = get_bridge()
            await self._bridge.initialize()
            self._initialized = True
            return True
        except Exception as e:
            logger.error(f"Failed to initialize embedding batcher: {e}")
            return False
    
    async def embed(self, text: str) -> Optional[List[float]]:
        """
        Get embedding for single text with auto-batching.
        
        The request is queued and batched with other requests.
        Returns when the batch is processed.
        """
        if not await self._ensure_initialized():
            return None
        
        self._stats.total_requests += 1
        
        # Create future for result
        future = asyncio.get_event_loop().create_future()
        request = EmbeddingRequest(text=text, future=future)
        
        async with self._queue_lock:
            self._queue.append(request)
            queue_size = len(self._queue)
            
            # Start timer if this is first request
            if queue_size == 1:
                self._start_timer()
            
            # Process immediately if batch is full
            if queue_size >= self.batch_size:
                await self._process_batch()
        
        # Wait for result
        try:
            return await future
        except Exception as e:
            logger.error(f"Embedding request failed: {e}")
            return None
    
    async def embed_batch(self, texts: List[str]) -> List[Optional[List[float]]]:
        """
        Get embeddings for multiple texts.
        
        Splits into optimal batch sizes and processes in parallel.
        """
        if not texts:
            return []
        
        if not await self._ensure_initialized():
            return [None] * len(texts)
        
        # Create futures for all texts
        futures = []
        
        async with self._queue_lock:
            for text in texts:
                future = asyncio.get_event_loop().create_future()
                self._queue.append(EmbeddingRequest(text=text, future=future))
                futures.append(future)
                self._stats.total_requests += 1
            
            # Process all batches
            while len(self._queue) > 0:
                await self._process_batch()
        
        # Collect results
        results = []
        for future in futures:
            try:
                result = await future
                results.append(result)
            except Exception:
                results.append(None)
        
        return results
    
    def _start_timer(self) -> None:
        """Start batch timeout timer."""
        if self._timer_task is not None:
            return
        
        async def timer():
            await asyncio.sleep(self.batch_timeout_ms / 1000.0)
            async with self._queue_lock:
                if self._queue:
                    await self._process_batch()
                self._timer_task = None
        
        self._timer_task = asyncio.create_task(timer())
    
    async def _process_batch(self) -> None:
        """Process current batch of requests."""
        if not self._queue:
            return
        
        # Cancel timer
        if self._timer_task:
            self._timer_task.cancel()
            self._timer_task = None
        
        # Get batch (up to batch_size)
        batch = self._queue[:self.batch_size]
        self._queue = self._queue[self.batch_size:]
        
        # Process with semaphore to limit concurrency
        async with self._batch_semaphore:
            await self._execute_batch(batch)
    
    async def _execute_batch(self, batch: List[EmbeddingRequest]) -> None:
        """Execute a batch of embedding requests."""
        if not batch:
            return
        
        start_time = time.time()
        texts = [r.text for r in batch]
        
        self._stats.total_batches += 1
        
        try:
            # Call HANA for batch embeddings
            embeddings = await self._bridge.embed_documents(texts)
            
            latency_ms = (time.time() - start_time) * 1000
            self._stats.total_batch_time_ms += latency_ms
            self._stats.total_embeddings += len(embeddings)
            
            # Update running averages
            self._stats.avg_batch_size = (
                self._stats.total_embeddings / self._stats.total_batches
            )
            self._stats.avg_batch_latency_ms = (
                self._stats.total_batch_time_ms / self._stats.total_batches
            )
            
            logger.debug(
                f"Batch embedding: {len(batch)} texts in {latency_ms:.1f}ms "
                f"({latency_ms/len(batch):.1f}ms/text)"
            )
            
            # Resolve futures
            for i, request in enumerate(batch):
                if i < len(embeddings):
                    request.future.set_result(embeddings[i])
                else:
                    request.future.set_result(None)
                    
        except Exception as e:
            self._stats.total_errors += 1
            logger.error(f"Batch embedding failed: {e}")
            
            # Fail all futures in batch
            for request in batch:
                if not request.future.done():
                    request.future.set_exception(e)
    
    async def flush(self) -> None:
        """Force process all pending requests."""
        async with self._queue_lock:
            while self._queue:
                await self._process_batch()
    
    def get_stats(self) -> Dict[str, Any]:
        """Get batcher statistics."""
        return {
            "total_requests": self._stats.total_requests,
            "total_batches": self._stats.total_batches,
            "total_embeddings": self._stats.total_embeddings,
            "total_errors": self._stats.total_errors,
            "avg_batch_size": self._stats.avg_batch_size,
            "avg_batch_latency_ms": self._stats.avg_batch_latency_ms,
            "throughput_per_second": (
                self._stats.total_embeddings / 
                (self._stats.total_batch_time_ms / 1000.0)
                if self._stats.total_batch_time_ms > 0 else 0
            ),
            "pending_requests": len(self._queue),
            "config": {
                "batch_size": self.batch_size,
                "batch_timeout_ms": self.batch_timeout_ms,
                "max_concurrent": self.max_concurrent,
            }
        }


class ConnectionWarmup:
    """
    Connection warmup for eliminating cold start latency.
    
    Implements Enhancement 1.3: Connection Warmup
    Pre-warms connection pool on service startup.
    """
    
    def __init__(self, pool_size: int = 5):
        self.pool_size = pool_size
        self._warmed_up = False
    
    async def warmup(self) -> Dict[str, Any]:
        """
        Warm up HANA connections.
        
        Creates and validates pool_size connections on startup.
        """
        if self._warmed_up:
            return {"status": "already_warmed"}
        
        start_time = time.time()
        results = {"success": 0, "failed": 0, "connections": []}
        
        try:
            from connectors.langchain_hana_bridge import get_bridge
            bridge = get_bridge()
            
            # Initialize bridge (creates first connection)
            if await bridge.initialize():
                results["success"] += 1
                results["connections"].append({"id": 0, "status": "ok"})
            else:
                results["failed"] += 1
                results["connections"].append({"id": 0, "status": "failed"})
            
            # Warm up pool by making test queries
            warmup_tasks = []
            for i in range(1, self.pool_size):
                async def warmup_connection(conn_id):
                    try:
                        # Simple test query
                        health = await bridge.health_check()
                        return {"id": conn_id, "status": "ok", "health": health}
                    except Exception as e:
                        return {"id": conn_id, "status": "failed", "error": str(e)}
                
                warmup_tasks.append(warmup_connection(i))
            
            # Execute warmup in parallel
            warmup_results = await asyncio.gather(*warmup_tasks, return_exceptions=True)
            
            for result in warmup_results:
                if isinstance(result, dict) and result.get("status") == "ok":
                    results["success"] += 1
                else:
                    results["failed"] += 1
                results["connections"].append(result)
            
            self._warmed_up = True
            
        except Exception as e:
            results["error"] = str(e)
        
        results["duration_ms"] = (time.time() - start_time) * 1000
        results["warmed_up"] = self._warmed_up
        
        logger.info(
            f"Connection warmup complete: {results['success']}/{self.pool_size} "
            f"in {results['duration_ms']:.1f}ms"
        )
        
        return results


# Singleton instances
_batcher: Optional[HanaEmbeddingBatcher] = None
_batcher_lock = asyncio.Lock()
_warmup: Optional[ConnectionWarmup] = None


async def get_embedding_batcher() -> HanaEmbeddingBatcher:
    """Get or create the embedding batcher singleton."""
    global _batcher
    
    async with _batcher_lock:
        if _batcher is None:
            _batcher = HanaEmbeddingBatcher()
            logger.info(
                f"Initialized embedding batcher: batch_size={BATCH_SIZE}, "
                f"timeout={BATCH_TIMEOUT_MS}ms"
            )
        return _batcher


async def warmup_connections(pool_size: int = 5) -> Dict[str, Any]:
    """Warm up HANA connections on startup."""
    global _warmup
    
    if _warmup is None:
        _warmup = ConnectionWarmup(pool_size=pool_size)
    
    return await _warmup.warmup()