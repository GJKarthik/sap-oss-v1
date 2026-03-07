"""
Caching Layer - In-Memory and Redis-Compatible Abstraction.

Day 48 Implementation - Week 10 Performance Optimization
Provides unified caching with TTL, invalidation strategies, and statistics.
No external service dependencies - uses in-memory backend by default.
"""

import asyncio
import logging
import time
import hashlib
import json
import pickle
from typing import Optional, Dict, Any, List, Set, Callable, TypeVar, Generic
from dataclasses import dataclass, field
from enum import Enum
from collections import OrderedDict
from abc import ABC, abstractmethod
import threading

logger = logging.getLogger(__name__)

T = TypeVar('T')


# =============================================================================
# Cache Configuration
# =============================================================================

class EvictionPolicy(str, Enum):
    """Cache eviction policies."""
    LRU = "lru"  # Least Recently Used
    LFU = "lfu"  # Least Frequently Used
    FIFO = "fifo"  # First In First Out
    TTL = "ttl"  # Time To Live only


class SerializationFormat(str, Enum):
    """Serialization formats."""
    JSON = "json"
    PICKLE = "pickle"
    STRING = "string"


@dataclass
class CacheConfig:
    """Cache configuration."""
    max_size: int = 10000
    default_ttl_seconds: float = 300.0  # 5 minutes
    eviction_policy: EvictionPolicy = EvictionPolicy.LRU
    serialization: SerializationFormat = SerializationFormat.JSON
    enable_statistics: bool = True
    enable_compression: bool = False
    namespace: str = ""
    
    @classmethod
    def for_query_cache(cls) -> "CacheConfig":
        """Config for query results."""
        return cls(
            max_size=5000,
            default_ttl_seconds=600.0,  # 10 minutes
            eviction_policy=EvictionPolicy.LRU,
        )
    
    @classmethod
    def for_session_cache(cls) -> "CacheConfig":
        """Config for session data."""
        return cls(
            max_size=1000,
            default_ttl_seconds=1800.0,  # 30 minutes
            eviction_policy=EvictionPolicy.LRU,
        )
    
    @classmethod
    def for_embedding_cache(cls) -> "CacheConfig":
        """Config for embeddings."""
        return cls(
            max_size=10000,
            default_ttl_seconds=3600.0,  # 1 hour
            eviction_policy=EvictionPolicy.LFU,
            serialization=SerializationFormat.PICKLE,
        )


# =============================================================================
# Cache Entry
# =============================================================================

@dataclass
class CacheEntry(Generic[T]):
    """Single cache entry with metadata."""
    key: str
    value: T
    created_at: float = field(default_factory=time.time)
    expires_at: float = 0.0
    access_count: int = 0
    last_accessed: float = field(default_factory=time.time)
    size_bytes: int = 0
    tags: Set[str] = field(default_factory=set)
    
    def is_expired(self, now: Optional[float] = None) -> bool:
        """Check if entry is expired."""
        if self.expires_at == 0:
            return False
        now = now or time.time()
        return now >= self.expires_at
    
    def touch(self):
        """Update access metadata."""
        self.access_count += 1
        self.last_accessed = time.time()


# =============================================================================
# Cache Statistics
# =============================================================================

@dataclass
class CacheStats:
    """Cache statistics."""
    hits: int = 0
    misses: int = 0
    sets: int = 0
    deletes: int = 0
    evictions: int = 0
    expirations: int = 0
    current_size: int = 0
    max_size: int = 0
    total_bytes: int = 0
    
    @property
    def hit_rate(self) -> float:
        """Calculate hit rate percentage."""
        total = self.hits + self.misses
        if total == 0:
            return 0.0
        return (self.hits / total) * 100
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "hits": self.hits,
            "misses": self.misses,
            "sets": self.sets,
            "deletes": self.deletes,
            "evictions": self.evictions,
            "expirations": self.expirations,
            "current_size": self.current_size,
            "max_size": self.max_size,
            "total_bytes": self.total_bytes,
            "hit_rate": round(self.hit_rate, 2),
        }
    
    def reset(self):
        """Reset statistics."""
        self.hits = 0
        self.misses = 0
        self.sets = 0
        self.deletes = 0
        self.evictions = 0
        self.expirations = 0


# =============================================================================
# Cache Backend Interface
# =============================================================================

class CacheBackend(ABC):
    """Abstract cache backend interface."""
    
    @abstractmethod
    async def get(self, key: str) -> Optional[CacheEntry]:
        """Get entry by key."""
        pass
    
    @abstractmethod
    async def set(self, entry: CacheEntry) -> bool:
        """Set entry."""
        pass
    
    @abstractmethod
    async def delete(self, key: str) -> bool:
        """Delete entry by key."""
        pass
    
    @abstractmethod
    async def exists(self, key: str) -> bool:
        """Check if key exists."""
        pass
    
    @abstractmethod
    async def clear(self) -> int:
        """Clear all entries, return count."""
        pass
    
    @abstractmethod
    async def keys(self, pattern: str = "*") -> List[str]:
        """Get keys matching pattern."""
        pass
    
    @abstractmethod
    def size(self) -> int:
        """Get current entry count."""
        pass


# =============================================================================
# In-Memory Backend
# =============================================================================

class InMemoryBackend(CacheBackend):
    """
    Thread-safe in-memory cache backend.
    
    Features:
    - Multiple eviction policies (LRU, LFU, FIFO, TTL)
    - Automatic expiration cleanup
    - Key pattern matching
    """
    
    def __init__(
        self,
        max_size: int = 10000,
        eviction_policy: EvictionPolicy = EvictionPolicy.LRU,
    ):
        self.max_size = max_size
        self.eviction_policy = eviction_policy
        self._data: OrderedDict[str, CacheEntry] = OrderedDict()
        self._lock = threading.RLock()
        self._stats = CacheStats(max_size=max_size)
    
    async def get(self, key: str) -> Optional[CacheEntry]:
        """Get entry by key."""
        with self._lock:
            entry = self._data.get(key)
            if entry is None:
                self._stats.misses += 1
                return None
            
            # Check expiration
            if entry.is_expired():
                del self._data[key]
                self._stats.expirations += 1
                self._stats.misses += 1
                return None
            
            # Update access
            entry.touch()
            
            # LRU: move to end
            if self.eviction_policy == EvictionPolicy.LRU:
                self._data.move_to_end(key)
            
            self._stats.hits += 1
            return entry
    
    async def set(self, entry: CacheEntry) -> bool:
        """Set entry with eviction if needed."""
        with self._lock:
            # Check if key already exists
            existing = entry.key in self._data
            
            # Evict if at capacity and new key
            if not existing and len(self._data) >= self.max_size:
                self._evict()
            
            self._data[entry.key] = entry
            
            # LRU: move to end
            if self.eviction_policy == EvictionPolicy.LRU:
                self._data.move_to_end(entry.key)
            
            self._stats.sets += 1
            self._stats.current_size = len(self._data)
            self._stats.total_bytes += entry.size_bytes
            
            return True
    
    async def delete(self, key: str) -> bool:
        """Delete entry by key."""
        with self._lock:
            if key in self._data:
                entry = self._data.pop(key)
                self._stats.deletes += 1
                self._stats.current_size = len(self._data)
                self._stats.total_bytes -= entry.size_bytes
                return True
            return False
    
    async def exists(self, key: str) -> bool:
        """Check if key exists and not expired."""
        with self._lock:
            entry = self._data.get(key)
            if entry is None:
                return False
            if entry.is_expired():
                del self._data[key]
                self._stats.expirations += 1
                return False
            return True
    
    async def clear(self) -> int:
        """Clear all entries."""
        with self._lock:
            count = len(self._data)
            self._data.clear()
            self._stats.current_size = 0
            self._stats.total_bytes = 0
            return count
    
    async def keys(self, pattern: str = "*") -> List[str]:
        """Get keys matching pattern."""
        with self._lock:
            if pattern == "*":
                return list(self._data.keys())
            
            # Simple glob matching
            import fnmatch
            return [k for k in self._data.keys() if fnmatch.fnmatch(k, pattern)]
    
    def size(self) -> int:
        """Get current entry count."""
        with self._lock:
            return len(self._data)
    
    def _evict(self):
        """Evict entry based on policy."""
        if not self._data:
            return
        
        if self.eviction_policy == EvictionPolicy.LRU:
            # Remove oldest (first item)
            key, _ = self._data.popitem(last=False)
        elif self.eviction_policy == EvictionPolicy.LFU:
            # Remove least frequently used
            key = min(self._data.keys(), key=lambda k: self._data[k].access_count)
            del self._data[key]
        elif self.eviction_policy == EvictionPolicy.FIFO:
            # Remove first inserted
            key, _ = self._data.popitem(last=False)
        elif self.eviction_policy == EvictionPolicy.TTL:
            # Remove closest to expiration
            key = min(self._data.keys(), key=lambda k: self._data[k].expires_at or float('inf'))
            del self._data[key]
        
        self._stats.evictions += 1
        self._stats.current_size = len(self._data)
    
    def get_stats(self) -> CacheStats:
        """Get statistics."""
        with self._lock:
            return self._stats
    
    async def cleanup_expired(self) -> int:
        """Remove all expired entries."""
        with self._lock:
            now = time.time()
            expired_keys = [
                k for k, v in self._data.items()
                if v.is_expired(now)
            ]
            
            for key in expired_keys:
                del self._data[key]
                self._stats.expirations += 1
            
            self._stats.current_size = len(self._data)
            return len(expired_keys)


# =============================================================================
# Cache Manager
# =============================================================================

class CacheManager:
    """
    Unified cache manager with multiple backends and namespaces.
    
    Features:
    - Multiple cache namespaces
    - Automatic serialization/deserialization
    - Tag-based invalidation
    - TTL management
    - Statistics per namespace
    """
    
    def __init__(
        self,
        config: Optional[CacheConfig] = None,
        backend: Optional[CacheBackend] = None,
    ):
        self.config = config or CacheConfig()
        self._backend = backend or InMemoryBackend(
            max_size=self.config.max_size,
            eviction_policy=self.config.eviction_policy,
        )
        self._serializer = self._get_serializer()
        self._tag_index: Dict[str, Set[str]] = {}  # tag -> keys
        self._lock = threading.RLock()
    
    def _get_serializer(self) -> tuple:
        """Get serializer/deserializer functions."""
        if self.config.serialization == SerializationFormat.JSON:
            return (json.dumps, json.loads)
        elif self.config.serialization == SerializationFormat.PICKLE:
            return (pickle.dumps, pickle.loads)
        else:  # STRING
            return (str, str)
    
    def _make_key(self, key: str) -> str:
        """Create namespaced key."""
        if self.config.namespace:
            return f"{self.config.namespace}:{key}"
        return key
    
    async def get(self, key: str, default: Any = None) -> Any:
        """Get value by key."""
        full_key = self._make_key(key)
        entry = await self._backend.get(full_key)
        
        if entry is None:
            return default
        
        try:
            _, deserialize = self._serializer
            return deserialize(entry.value)
        except Exception:
            return entry.value
    
    async def set(
        self,
        key: str,
        value: Any,
        ttl: Optional[float] = None,
        tags: Optional[List[str]] = None,
    ) -> bool:
        """Set value with optional TTL and tags."""
        full_key = self._make_key(key)
        
        # Serialize value
        try:
            serialize, _ = self._serializer
            serialized = serialize(value)
        except Exception:
            serialized = value
        
        # Calculate expiration
        ttl = ttl if ttl is not None else self.config.default_ttl_seconds
        expires_at = time.time() + ttl if ttl > 0 else 0
        
        # Estimate size
        size_bytes = len(str(serialized).encode('utf-8'))
        
        # Create entry
        entry = CacheEntry(
            key=full_key,
            value=serialized,
            expires_at=expires_at,
            size_bytes=size_bytes,
            tags=set(tags or []),
        )
        
        # Update tag index
        if tags:
            with self._lock:
                for tag in tags:
                    if tag not in self._tag_index:
                        self._tag_index[tag] = set()
                    self._tag_index[tag].add(full_key)
        
        return await self._backend.set(entry)
    
    async def delete(self, key: str) -> bool:
        """Delete value by key."""
        full_key = self._make_key(key)
        
        # Remove from tag index
        with self._lock:
            for tag_keys in self._tag_index.values():
                tag_keys.discard(full_key)
        
        return await self._backend.delete(full_key)
    
    async def exists(self, key: str) -> bool:
        """Check if key exists."""
        full_key = self._make_key(key)
        return await self._backend.exists(full_key)
    
    async def get_or_set(
        self,
        key: str,
        factory: Callable[[], Any],
        ttl: Optional[float] = None,
        tags: Optional[List[str]] = None,
    ) -> Any:
        """Get value or set from factory if missing."""
        value = await self.get(key)
        if value is not None:
            return value
        
        # Generate value
        if asyncio.iscoroutinefunction(factory):
            value = await factory()
        else:
            value = factory()
        
        await self.set(key, value, ttl=ttl, tags=tags)
        return value
    
    async def invalidate_by_tag(self, tag: str) -> int:
        """Invalidate all entries with given tag."""
        with self._lock:
            keys = list(self._tag_index.get(tag, set()))
        
        count = 0
        for key in keys:
            if await self._backend.delete(key):
                count += 1
        
        # Clear tag index
        with self._lock:
            if tag in self._tag_index:
                del self._tag_index[tag]
        
        return count
    
    async def invalidate_by_prefix(self, prefix: str) -> int:
        """Invalidate all entries with key prefix."""
        full_prefix = self._make_key(prefix)
        keys = await self._backend.keys(f"{full_prefix}*")
        
        count = 0
        for key in keys:
            if await self._backend.delete(key):
                count += 1
        
        return count
    
    async def clear(self) -> int:
        """Clear all cache entries."""
        with self._lock:
            self._tag_index.clear()
        return await self._backend.clear()
    
    def get_stats(self) -> Dict[str, Any]:
        """Get cache statistics."""
        if isinstance(self._backend, InMemoryBackend):
            return self._backend.get_stats().to_dict()
        return {"backend": "external", "size": self._backend.size()}
    
    async def cleanup_expired(self) -> int:
        """Cleanup expired entries."""
        if isinstance(self._backend, InMemoryBackend):
            return await self._backend.cleanup_expired()
        return 0


# =============================================================================
# Specialized Caches
# =============================================================================

class QueryCache(CacheManager):
    """Cache optimized for query results."""
    
    def __init__(self, max_size: int = 5000, ttl: float = 600.0):
        config = CacheConfig(
            max_size=max_size,
            default_ttl_seconds=ttl,
            eviction_policy=EvictionPolicy.LRU,
            namespace="query",
        )
        super().__init__(config)
    
    def _hash_query(self, query: str) -> str:
        """Create hash key for query."""
        normalized = ' '.join(query.split())
        return hashlib.md5(normalized.encode()).hexdigest()[:16]
    
    async def get_query_result(self, query: str) -> Optional[Any]:
        """Get cached query result."""
        key = self._hash_query(query)
        return await self.get(key)
    
    async def set_query_result(
        self,
        query: str,
        result: Any,
        ttl: Optional[float] = None,
        tables: Optional[List[str]] = None,
    ) -> bool:
        """Cache query result with optional table tags."""
        key = self._hash_query(query)
        tags = [f"table:{t}" for t in (tables or [])]
        return await self.set(key, result, ttl=ttl, tags=tags)
    
    async def invalidate_table(self, table: str) -> int:
        """Invalidate all queries touching a table."""
        return await self.invalidate_by_tag(f"table:{table}")


class EmbeddingCache(CacheManager):
    """Cache optimized for embeddings."""
    
    def __init__(self, max_size: int = 10000, ttl: float = 3600.0):
        config = CacheConfig(
            max_size=max_size,
            default_ttl_seconds=ttl,
            eviction_policy=EvictionPolicy.LFU,
            serialization=SerializationFormat.PICKLE,
            namespace="embedding",
        )
        super().__init__(config)
    
    def _hash_text(self, text: str, model: str) -> str:
        """Create hash key for text and model."""
        content = f"{model}:{text}"
        return hashlib.sha256(content.encode()).hexdigest()[:24]
    
    async def get_embedding(
        self,
        text: str,
        model: str = "default",
    ) -> Optional[List[float]]:
        """Get cached embedding."""
        key = self._hash_text(text, model)
        return await self.get(key)
    
    async def set_embedding(
        self,
        text: str,
        embedding: List[float],
        model: str = "default",
        ttl: Optional[float] = None,
    ) -> bool:
        """Cache embedding."""
        key = self._hash_text(text, model)
        return await self.set(key, embedding, ttl=ttl, tags=[f"model:{model}"])
    
    async def invalidate_model(self, model: str) -> int:
        """Invalidate all embeddings for a model."""
        return await self.invalidate_by_tag(f"model:{model}")


class SessionCache(CacheManager):
    """Cache optimized for session data."""
    
    def __init__(self, max_size: int = 1000, ttl: float = 1800.0):
        config = CacheConfig(
            max_size=max_size,
            default_ttl_seconds=ttl,
            eviction_policy=EvictionPolicy.LRU,
            namespace="session",
        )
        super().__init__(config)
    
    async def get_session(self, session_id: str) -> Optional[Dict[str, Any]]:
        """Get session data."""
        return await self.get(session_id)
    
    async def set_session(
        self,
        session_id: str,
        data: Dict[str, Any],
        ttl: Optional[float] = None,
    ) -> bool:
        """Set session data."""
        return await self.set(session_id, data, ttl=ttl)
    
    async def extend_session(
        self,
        session_id: str,
        ttl: Optional[float] = None,
    ) -> bool:
        """Extend session TTL."""
        data = await self.get_session(session_id)
        if data is None:
            return False
        return await self.set_session(session_id, data, ttl=ttl)


# =============================================================================
# Factory Functions
# =============================================================================

def create_cache_manager(
    config: Optional[CacheConfig] = None,
) -> CacheManager:
    """Create cache manager with configuration."""
    return CacheManager(config=config)


def create_query_cache(
    max_size: int = 5000,
    ttl: float = 600.0,
) -> QueryCache:
    """Create query result cache."""
    return QueryCache(max_size=max_size, ttl=ttl)


def create_embedding_cache(
    max_size: int = 10000,
    ttl: float = 3600.0,
) -> EmbeddingCache:
    """Create embedding cache."""
    return EmbeddingCache(max_size=max_size, ttl=ttl)


def create_session_cache(
    max_size: int = 1000,
    ttl: float = 1800.0,
) -> SessionCache:
    """Create session cache."""
    return SessionCache(max_size=max_size, ttl=ttl)