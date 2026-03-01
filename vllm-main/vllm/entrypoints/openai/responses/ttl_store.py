# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project
"""
TTL-based stores for the Responses API.

These stores implement automatic expiration to prevent memory leaks
when enable_store=True. Entries are automatically evicted after their
TTL expires on access and via periodic background cleanup.
"""

import asyncio
import time
from collections.abc import Callable
from typing import Generic, TypeVar

from vllm.logger import init_logger

logger = init_logger(__name__)

V = TypeVar("V")


class TTLStore(Generic[V]):
    """
    Thread-safe TTL-based dictionary store.
    
    Entries are automatically evicted after ttl_seconds.
    Cleanup runs lazily on get/put and periodically via background task.
    
    Example:
        store = TTLStore[ResponsesResponse](ttl_seconds=3600)
        await store.start_cleanup_task()
        
        await store.put("key1", response)
        value = await store.get("key1")  # Returns None after TTL
        
        await store.stop_cleanup_task()
    """
    
    def __init__(
        self,
        ttl_seconds: int = 3600,
        cleanup_interval_seconds: int = 300,
        max_entries: int = 10000,
        on_evict: Callable[[str, V], None] | None = None,
    ):
        """
        Initialize the TTL store.
        
        Args:
            ttl_seconds: Time-to-live for entries (default: 1 hour)
            cleanup_interval_seconds: How often to run background cleanup (default: 5 min)
            max_entries: Maximum entries before forced eviction (default: 10000)
            on_evict: Optional callback when an entry is evicted
        """
        self._store: dict[str, tuple[V, float]] = {}
        self._lock = asyncio.Lock()
        self._ttl = ttl_seconds
        self._cleanup_interval = cleanup_interval_seconds
        self._max_entries = max_entries
        self._on_evict = on_evict
        self._cleanup_task: asyncio.Task | None = None
        self._running = False
        
        # Statistics
        self._total_puts = 0
        self._total_gets = 0
        self._total_hits = 0
        self._total_evictions = 0
    
    async def start_cleanup_task(self) -> None:
        """Start the background cleanup task."""
        if self._running:
            return
        self._running = True
        self._cleanup_task = asyncio.create_task(
            self._cleanup_loop(),
            name="ttl_store_cleanup"
        )
        logger.info("TTL store cleanup task started (interval: %ds, ttl: %ds)",
                    self._cleanup_interval, self._ttl)
    
    async def stop_cleanup_task(self) -> None:
        """Stop the background cleanup task."""
        self._running = False
        if self._cleanup_task:
            self._cleanup_task.cancel()
            try:
                await self._cleanup_task
            except asyncio.CancelledError:
                pass
            self._cleanup_task = None
    
    async def _cleanup_loop(self) -> None:
        """Background task that periodically cleans up expired entries."""
        while self._running:
            try:
                await asyncio.sleep(self._cleanup_interval)
                evicted_count = await self._cleanup_expired()
                if evicted_count > 0:
                    logger.debug("TTL store cleanup: evicted %d expired entries",
                                 evicted_count)
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.warning("TTL store cleanup error: %s", e)
    
    async def _cleanup_expired(self) -> int:
        """Remove all expired entries. Returns count of evicted entries."""
        now = time.time()
        evicted = 0
        async with self._lock:
            keys_to_remove = [
                key for key, (_, created_at) in self._store.items()
                if now - created_at >= self._ttl
            ]
            for key in keys_to_remove:
                value, _ = self._store.pop(key)
                evicted += 1
                self._total_evictions += 1
                if self._on_evict:
                    try:
                        self._on_evict(key, value)
                    except Exception as e:
                        logger.warning("TTL store on_evict callback error: %s", e)
        return evicted
    
    async def _enforce_max_entries(self) -> None:
        """Evict oldest entries if store exceeds max_entries."""
        if len(self._store) <= self._max_entries:
            return
        
        # Sort by creation time and remove oldest
        sorted_items = sorted(
            self._store.items(),
            key=lambda x: x[1][1]  # Sort by created_at timestamp
        )
        
        # Remove oldest entries until we're under the limit
        entries_to_remove = len(self._store) - self._max_entries
        for key, (value, _) in sorted_items[:entries_to_remove]:
            del self._store[key]
            self._total_evictions += 1
            if self._on_evict:
                try:
                    self._on_evict(key, value)
                except Exception as e:
                    logger.warning("TTL store on_evict callback error: %s", e)
        
        logger.warning("TTL store max entries exceeded, evicted %d oldest entries",
                       entries_to_remove)
    
    async def get(self, key: str) -> V | None:
        """
        Get a value by key. Returns None if not found or expired.
        """
        self._total_gets += 1
        async with self._lock:
            entry = self._store.get(key)
            if entry is None:
                return None
            
            value, created_at = entry
            # Check if expired
            if time.time() - created_at >= self._ttl:
                # Lazy eviction
                del self._store[key]
                self._total_evictions += 1
                if self._on_evict:
                    try:
                        self._on_evict(key, value)
                    except Exception as e:
                        logger.warning("TTL store on_evict callback error: %s", e)
                return None
            
            self._total_hits += 1
            return value
    
    async def put(self, key: str, value: V) -> None:
        """
        Store a value with the given key.
        """
        self._total_puts += 1
        async with self._lock:
            self._store[key] = (value, time.time())
            await self._enforce_max_entries()
    
    async def remove(self, key: str) -> V | None:
        """
        Remove and return a value by key.
        """
        async with self._lock:
            entry = self._store.pop(key, None)
            if entry is None:
                return None
            return entry[0]
    
    async def contains(self, key: str) -> bool:
        """Check if key exists and is not expired."""
        return await self.get(key) is not None
    
    def __len__(self) -> int:
        """Return current number of entries (may include expired)."""
        return len(self._store)
    
    def get_stats(self) -> dict:
        """Return store statistics."""
        return {
            "entries": len(self._store),
            "total_puts": self._total_puts,
            "total_gets": self._total_gets,
            "total_hits": self._total_hits,
            "total_evictions": self._total_evictions,
            "hit_rate": self._total_hits / max(1, self._total_gets),
        }


class TTLDequeStore(Generic[V]):
    """
    TTL-based store for deque-like structures (e.g., event streams).
    
    Stores a deque and an event signal together, with automatic expiration.
    """
    
    def __init__(
        self,
        ttl_seconds: int = 3600,
        cleanup_interval_seconds: int = 300,
    ):
        self._store: dict[str, tuple[V, asyncio.Event, float]] = {}
        self._lock = asyncio.Lock()
        self._ttl = ttl_seconds
        self._cleanup_interval = cleanup_interval_seconds
        self._cleanup_task: asyncio.Task | None = None
        self._running = False
    
    async def start_cleanup_task(self) -> None:
        """Start the background cleanup task."""
        if self._running:
            return
        self._running = True
        self._cleanup_task = asyncio.create_task(
            self._cleanup_loop(),
            name="ttl_deque_store_cleanup"
        )
    
    async def stop_cleanup_task(self) -> None:
        """Stop the background cleanup task."""
        self._running = False
        if self._cleanup_task:
            self._cleanup_task.cancel()
            try:
                await self._cleanup_task
            except asyncio.CancelledError:
                pass
    
    async def _cleanup_loop(self) -> None:
        """Background cleanup task."""
        while self._running:
            try:
                await asyncio.sleep(self._cleanup_interval)
                await self._cleanup_expired()
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.warning("TTL deque store cleanup error: %s", e)
    
    async def _cleanup_expired(self) -> int:
        """Remove expired entries."""
        now = time.time()
        evicted = 0
        async with self._lock:
            keys_to_remove = [
                key for key, (_, _, created_at) in self._store.items()
                if now - created_at >= self._ttl
            ]
            for key in keys_to_remove:
                del self._store[key]
                evicted += 1
        return evicted
    
    async def get(self, key: str) -> tuple[V, asyncio.Event] | None:
        """Get deque and event by key."""
        async with self._lock:
            entry = self._store.get(key)
            if entry is None:
                return None
            
            deque_val, event, created_at = entry
            if time.time() - created_at >= self._ttl:
                del self._store[key]
                return None
            
            return (deque_val, event)
    
    async def put(self, key: str, deque_val: V, event: asyncio.Event) -> None:
        """Store a deque and event."""
        async with self._lock:
            self._store[key] = (deque_val, event, time.time())
    
    async def remove(self, key: str) -> None:
        """Remove entry by key."""
        async with self._lock:
            self._store.pop(key, None)
    
    def __contains__(self, key: str) -> bool:
        """Check if key exists (may include expired)."""
        return key in self._store