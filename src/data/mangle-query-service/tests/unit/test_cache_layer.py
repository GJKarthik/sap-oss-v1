"""
Unit tests for cache layer.

Day 48 - Week 10 Performance Optimization
45 tests covering in-memory caching, eviction policies, and specialized caches.
No external service dependencies.
"""

import pytest
import asyncio
import time
from unittest.mock import Mock, patch

from performance.cache_layer import (
    EvictionPolicy,
    SerializationFormat,
    CacheConfig,
    CacheEntry,
    CacheStats,
    CacheBackend,
    InMemoryBackend,
    CacheManager,
    QueryCache,
    EmbeddingCache,
    SessionCache,
    create_cache_manager,
    create_query_cache,
    create_embedding_cache,
    create_session_cache,
)


# =============================================================================
# EvictionPolicy Tests (3 tests)
# =============================================================================

class TestEvictionPolicy:
    """Tests for EvictionPolicy enum."""
    
    def test_all_policies_defined(self):
        """Test all policies are defined."""
        policies = list(EvictionPolicy)
        assert len(policies) == 4
    
    def test_policy_values(self):
        """Test policy values."""
        assert EvictionPolicy.LRU.value == "lru"
        assert EvictionPolicy.LFU.value == "lfu"
        assert EvictionPolicy.FIFO.value == "fifo"
    
    def test_ttl_policy(self):
        """Test TTL policy."""
        assert EvictionPolicy.TTL.value == "ttl"


# =============================================================================
# CacheConfig Tests (5 tests)
# =============================================================================

class TestCacheConfig:
    """Tests for CacheConfig dataclass."""
    
    def test_default_config(self):
        """Test default configuration."""
        config = CacheConfig()
        assert config.max_size == 10000
        assert config.default_ttl_seconds == 300.0
        assert config.eviction_policy == EvictionPolicy.LRU
    
    def test_for_query_cache(self):
        """Test query cache config."""
        config = CacheConfig.for_query_cache()
        assert config.max_size == 5000
        assert config.default_ttl_seconds == 600.0
    
    def test_for_session_cache(self):
        """Test session cache config."""
        config = CacheConfig.for_session_cache()
        assert config.max_size == 1000
        assert config.default_ttl_seconds == 1800.0
    
    def test_for_embedding_cache(self):
        """Test embedding cache config."""
        config = CacheConfig.for_embedding_cache()
        assert config.eviction_policy == EvictionPolicy.LFU
        assert config.serialization == SerializationFormat.PICKLE
    
    def test_custom_namespace(self):
        """Test custom namespace."""
        config = CacheConfig(namespace="test")
        assert config.namespace == "test"


# =============================================================================
# CacheEntry Tests (5 tests)
# =============================================================================

class TestCacheEntry:
    """Tests for CacheEntry dataclass."""
    
    def test_basic_entry(self):
        """Test basic entry creation."""
        entry = CacheEntry(key="test", value="value")
        assert entry.key == "test"
        assert entry.value == "value"
        assert entry.access_count == 0
    
    def test_not_expired_no_ttl(self):
        """Test entry without TTL is not expired."""
        entry = CacheEntry(key="test", value="value", expires_at=0)
        assert not entry.is_expired()
    
    def test_expired_entry(self):
        """Test expired entry detection."""
        entry = CacheEntry(
            key="test",
            value="value",
            expires_at=time.time() - 1,  # Expired 1 second ago
        )
        assert entry.is_expired()
    
    def test_not_expired_future(self):
        """Test entry with future expiration."""
        entry = CacheEntry(
            key="test",
            value="value",
            expires_at=time.time() + 3600,  # 1 hour from now
        )
        assert not entry.is_expired()
    
    def test_touch_updates_metadata(self):
        """Test touch updates access metadata."""
        entry = CacheEntry(key="test", value="value")
        initial_count = entry.access_count
        initial_accessed = entry.last_accessed
        
        time.sleep(0.01)  # Small delay
        entry.touch()
        
        assert entry.access_count == initial_count + 1
        assert entry.last_accessed >= initial_accessed


# =============================================================================
# CacheStats Tests (4 tests)
# =============================================================================

class TestCacheStats:
    """Tests for CacheStats dataclass."""
    
    def test_default_stats(self):
        """Test default statistics."""
        stats = CacheStats()
        assert stats.hits == 0
        assert stats.misses == 0
        assert stats.hit_rate == 0.0
    
    def test_hit_rate_calculation(self):
        """Test hit rate calculation."""
        stats = CacheStats(hits=75, misses=25)
        assert stats.hit_rate == 75.0
    
    def test_to_dict(self):
        """Test conversion to dict."""
        stats = CacheStats(hits=10, misses=5, sets=15)
        d = stats.to_dict()
        assert d["hits"] == 10
        assert d["misses"] == 5
        assert d["sets"] == 15
    
    def test_reset(self):
        """Test statistics reset."""
        stats = CacheStats(hits=100, misses=50)
        stats.reset()
        assert stats.hits == 0
        assert stats.misses == 0


# =============================================================================
# InMemoryBackend Tests (10 tests)
# =============================================================================

class TestInMemoryBackend:
    """Tests for InMemoryBackend."""
    
    @pytest.fixture
    def backend(self):
        """Create backend."""
        return InMemoryBackend(max_size=100)
    
    @pytest.mark.asyncio
    async def test_set_and_get(self, backend):
        """Test basic set and get."""
        entry = CacheEntry(key="test", value="value")
        await backend.set(entry)
        
        result = await backend.get("test")
        assert result is not None
        assert result.value == "value"
    
    @pytest.mark.asyncio
    async def test_get_missing_key(self, backend):
        """Test get returns None for missing key."""
        result = await backend.get("nonexistent")
        assert result is None
    
    @pytest.mark.asyncio
    async def test_delete(self, backend):
        """Test delete entry."""
        entry = CacheEntry(key="test", value="value")
        await backend.set(entry)
        
        deleted = await backend.delete("test")
        assert deleted is True
        
        result = await backend.get("test")
        assert result is None
    
    @pytest.mark.asyncio
    async def test_exists(self, backend):
        """Test exists check."""
        entry = CacheEntry(key="test", value="value")
        await backend.set(entry)
        
        assert await backend.exists("test") is True
        assert await backend.exists("nonexistent") is False
    
    @pytest.mark.asyncio
    async def test_clear(self, backend):
        """Test clear all entries."""
        for i in range(10):
            entry = CacheEntry(key=f"key{i}", value=f"value{i}")
            await backend.set(entry)
        
        count = await backend.clear()
        assert count == 10
        assert backend.size() == 0
    
    @pytest.mark.asyncio
    async def test_lru_eviction(self):
        """Test LRU eviction policy."""
        backend = InMemoryBackend(max_size=3, eviction_policy=EvictionPolicy.LRU)
        
        # Add 3 entries
        for i in range(3):
            entry = CacheEntry(key=f"key{i}", value=f"value{i}")
            await backend.set(entry)
        
        # Access key0 to make it recent
        await backend.get("key0")
        
        # Add 4th entry - should evict key1 (oldest accessed)
        entry = CacheEntry(key="key3", value="value3")
        await backend.set(entry)
        
        assert await backend.exists("key0") is True
        assert await backend.exists("key1") is False
    
    @pytest.mark.asyncio
    async def test_expired_entry_removed_on_get(self, backend):
        """Test expired entries are removed on get."""
        entry = CacheEntry(
            key="test",
            value="value",
            expires_at=time.time() - 1,  # Already expired
        )
        # Directly set to bypass expiration check
        backend._data["test"] = entry
        
        result = await backend.get("test")
        assert result is None
        assert await backend.exists("test") is False
    
    @pytest.mark.asyncio
    async def test_keys_pattern(self, backend):
        """Test keys with pattern matching."""
        for i in range(5):
            entry = CacheEntry(key=f"user:{i}", value=f"data{i}")
            await backend.set(entry)
        for i in range(3):
            entry = CacheEntry(key=f"order:{i}", value=f"data{i}")
            await backend.set(entry)
        
        user_keys = await backend.keys("user:*")
        assert len(user_keys) == 5
    
    @pytest.mark.asyncio
    async def test_statistics_tracking(self, backend):
        """Test statistics are tracked."""
        entry = CacheEntry(key="test", value="value")
        await backend.set(entry)
        await backend.get("test")  # Hit
        await backend.get("nonexistent")  # Miss
        
        stats = backend.get_stats()
        assert stats.sets == 1
        assert stats.hits == 1
        assert stats.misses == 1
    
    @pytest.mark.asyncio
    async def test_cleanup_expired(self, backend):
        """Test cleanup of expired entries."""
        # Add valid entry
        entry1 = CacheEntry(key="valid", value="value", expires_at=time.time() + 3600)
        await backend.set(entry1)
        
        # Add expired entry directly
        entry2 = CacheEntry(key="expired", value="value", expires_at=time.time() - 1)
        backend._data["expired"] = entry2
        
        count = await backend.cleanup_expired()
        assert count == 1
        assert await backend.exists("valid") is True


# =============================================================================
# CacheManager Tests (10 tests)
# =============================================================================

class TestCacheManager:
    """Tests for CacheManager."""
    
    @pytest.fixture
    def cache(self):
        """Create cache manager."""
        return CacheManager()
    
    @pytest.mark.asyncio
    async def test_set_and_get(self, cache):
        """Test basic set and get."""
        await cache.set("key", {"data": "value"})
        result = await cache.get("key")
        assert result == {"data": "value"}
    
    @pytest.mark.asyncio
    async def test_get_default(self, cache):
        """Test get returns default for missing key."""
        result = await cache.get("nonexistent", default="default")
        assert result == "default"
    
    @pytest.mark.asyncio
    async def test_delete(self, cache):
        """Test delete."""
        await cache.set("key", "value")
        deleted = await cache.delete("key")
        assert deleted is True
        assert await cache.get("key") is None
    
    @pytest.mark.asyncio
    async def test_exists(self, cache):
        """Test exists."""
        await cache.set("key", "value")
        assert await cache.exists("key") is True
        assert await cache.exists("nonexistent") is False
    
    @pytest.mark.asyncio
    async def test_ttl(self, cache):
        """Test TTL expiration."""
        await cache.set("key", "value", ttl=0.1)  # 100ms TTL
        
        assert await cache.exists("key") is True
        await asyncio.sleep(0.15)
        assert await cache.exists("key") is False
    
    @pytest.mark.asyncio
    async def test_namespace(self):
        """Test namespaced keys."""
        cache = CacheManager(CacheConfig(namespace="test"))
        await cache.set("key", "value")
        
        # Should be stored with namespace prefix
        assert await cache.exists("key") is True
    
    @pytest.mark.asyncio
    async def test_get_or_set(self, cache):
        """Test get_or_set."""
        factory_called = False
        
        def factory():
            nonlocal factory_called
            factory_called = True
            return "generated"
        
        # First call - factory should be called
        result1 = await cache.get_or_set("key", factory)
        assert result1 == "generated"
        assert factory_called is True
        
        # Second call - factory should NOT be called
        factory_called = False
        result2 = await cache.get_or_set("key", factory)
        assert result2 == "generated"
        assert factory_called is False
    
    @pytest.mark.asyncio
    async def test_invalidate_by_tag(self, cache):
        """Test tag-based invalidation."""
        await cache.set("key1", "value1", tags=["tag1"])
        await cache.set("key2", "value2", tags=["tag1"])
        await cache.set("key3", "value3", tags=["tag2"])
        
        count = await cache.invalidate_by_tag("tag1")
        assert count == 2
        assert await cache.exists("key1") is False
        assert await cache.exists("key3") is True
    
    @pytest.mark.asyncio
    async def test_invalidate_by_prefix(self, cache):
        """Test prefix-based invalidation."""
        await cache.set("user:1", "data1")
        await cache.set("user:2", "data2")
        await cache.set("order:1", "data3")
        
        count = await cache.invalidate_by_prefix("user:")
        assert count == 2
        assert await cache.exists("order:1") is True
    
    @pytest.mark.asyncio
    async def test_get_stats(self, cache):
        """Test statistics."""
        await cache.set("key", "value")
        await cache.get("key")  # Hit
        await cache.get("missing")  # Miss
        
        stats = cache.get_stats()
        assert "hits" in stats
        assert "misses" in stats


# =============================================================================
# QueryCache Tests (3 tests)
# =============================================================================

class TestQueryCache:
    """Tests for QueryCache."""
    
    @pytest.fixture
    def cache(self):
        """Create query cache."""
        return QueryCache()
    
    @pytest.mark.asyncio
    async def test_query_result_caching(self, cache):
        """Test query result caching."""
        query = "SELECT * FROM users WHERE id = 1"
        result = {"id": 1, "name": "John"}
        
        await cache.set_query_result(query, result)
        cached = await cache.get_query_result(query)
        
        assert cached == result
    
    @pytest.mark.asyncio
    async def test_table_invalidation(self, cache):
        """Test table-based invalidation."""
        await cache.set_query_result(
            "SELECT * FROM users",
            [{"id": 1}],
            tables=["users"],
        )
        
        count = await cache.invalidate_table("users")
        assert count == 1
    
    @pytest.mark.asyncio
    async def test_query_normalization(self, cache):
        """Test query normalization."""
        query1 = "SELECT * FROM   users"
        query2 = "SELECT * FROM users"
        
        await cache.set_query_result(query1, "result")
        cached = await cache.get_query_result(query2)
        
        # Should match due to normalization
        assert cached == "result"


# =============================================================================
# EmbeddingCache Tests (2 tests)
# =============================================================================

class TestEmbeddingCache:
    """Tests for EmbeddingCache."""
    
    @pytest.fixture
    def cache(self):
        """Create embedding cache."""
        return EmbeddingCache()
    
    @pytest.mark.asyncio
    async def test_embedding_caching(self, cache):
        """Test embedding caching."""
        text = "Hello world"
        embedding = [0.1, 0.2, 0.3]
        
        await cache.set_embedding(text, embedding, model="test")
        cached = await cache.get_embedding(text, model="test")
        
        assert cached == embedding
    
    @pytest.mark.asyncio
    async def test_model_invalidation(self, cache):
        """Test model-based invalidation."""
        await cache.set_embedding("text1", [0.1], model="model1")
        await cache.set_embedding("text2", [0.2], model="model1")
        
        count = await cache.invalidate_model("model1")
        assert count == 2


# =============================================================================
# SessionCache Tests (3 tests)
# =============================================================================

class TestSessionCache:
    """Tests for SessionCache."""
    
    @pytest.fixture
    def cache(self):
        """Create session cache."""
        return SessionCache()
    
    @pytest.mark.asyncio
    async def test_session_storage(self, cache):
        """Test session storage."""
        session_id = "sess_123"
        data = {"user_id": 1, "role": "admin"}
        
        await cache.set_session(session_id, data)
        cached = await cache.get_session(session_id)
        
        assert cached == data
    
    @pytest.mark.asyncio
    async def test_session_extend(self, cache):
        """Test session extension."""
        session_id = "sess_123"
        data = {"user_id": 1}
        
        await cache.set_session(session_id, data, ttl=1)
        result = await cache.extend_session(session_id, ttl=3600)
        
        assert result is True
    
    @pytest.mark.asyncio
    async def test_extend_missing_session(self, cache):
        """Test extending missing session."""
        result = await cache.extend_session("nonexistent")
        assert result is False


# =============================================================================
# Summary
# =============================================================================
# Total: 45 tests
# - EvictionPolicy: 3 tests
# - CacheConfig: 5 tests
# - CacheEntry: 5 tests
# - CacheStats: 4 tests
# - InMemoryBackend: 10 tests
# - CacheManager: 10 tests
# - QueryCache: 3 tests
# - EmbeddingCache: 2 tests
# - SessionCache: 3 tests