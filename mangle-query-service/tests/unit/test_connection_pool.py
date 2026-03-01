"""
Unit tests for connection pool manager.

Day 46 - Week 10 Performance Optimization
45 tests covering connection pooling, lifecycle management, and statistics.
"""

import asyncio
import time
import pytest
from unittest.mock import Mock, AsyncMock, patch
from dataclasses import dataclass

from performance.connection_pool import (
    ConnectionState,
    PoolConfig,
    PooledConnection,
    ConnectionFactory,
    PoolStats,
    ConnectionPool,
    HTTPConnectionFactory,
    PoolManager,
    create_pool_manager,
    create_http_pool,
    get_default_config,
)


# =============================================================================
# Mock Connection Factory
# =============================================================================

class MockConnectionFactory(ConnectionFactory):
    """Mock factory for testing."""
    
    def __init__(self, fail_create: bool = False, fail_validate: bool = False):
        self.fail_create = fail_create
        self.fail_validate = fail_validate
        self.created_count = 0
        self.closed_count = 0
    
    async def create(self):
        if self.fail_create:
            raise ConnectionError("Mock create failed")
        self.created_count += 1
        return f"connection-{self.created_count}"
    
    async def validate(self, connection) -> bool:
        if self.fail_validate:
            return False
        return True
    
    async def close(self, connection) -> None:
        self.closed_count += 1


# =============================================================================
# ConnectionState Tests (3 tests)
# =============================================================================

class TestConnectionState:
    """Tests for ConnectionState enum."""
    
    def test_state_values(self):
        """Test state enum values."""
        assert ConnectionState.IDLE.value == "idle"
        assert ConnectionState.ACTIVE.value == "active"
        assert ConnectionState.STALE.value == "stale"
    
    def test_all_states_defined(self):
        """Test all states are defined."""
        states = list(ConnectionState)
        assert len(states) == 5
    
    def test_error_and_closed_states(self):
        """Test error and closed states."""
        assert ConnectionState.ERROR.value == "error"
        assert ConnectionState.CLOSED.value == "closed"


# =============================================================================
# PoolConfig Tests (8 tests)
# =============================================================================

class TestPoolConfig:
    """Tests for PoolConfig."""
    
    def test_default_config(self):
        """Test default configuration."""
        config = PoolConfig()
        assert config.min_size == 5
        assert config.max_size == 20
        assert config.acquire_timeout == 30.0
    
    def test_hana_config(self):
        """Test HANA-optimized config."""
        config = PoolConfig.for_hana()
        assert config.min_size == 3
        assert config.max_size == 15
        assert config.acquire_timeout == 45.0
    
    def test_elasticsearch_config(self):
        """Test Elasticsearch-optimized config."""
        config = PoolConfig.for_elasticsearch()
        assert config.min_size == 5
        assert config.max_size == 30
        assert config.acquire_timeout == 15.0
    
    def test_http_config(self):
        """Test HTTP-optimized config."""
        config = PoolConfig.for_http()
        assert config.min_size == 10
        assert config.max_size == 50
        assert config.acquire_timeout == 10.0
    
    def test_max_idle_time(self):
        """Test max idle time setting."""
        config = PoolConfig()
        assert config.max_idle_time == 300.0  # 5 minutes
    
    def test_max_lifetime(self):
        """Test max lifetime setting."""
        config = PoolConfig()
        assert config.max_lifetime == 3600.0  # 1 hour
    
    def test_health_check_enabled(self):
        """Test health check settings."""
        config = PoolConfig()
        assert config.enable_health_check is True
        assert config.health_check_interval == 30.0
    
    def test_retry_settings(self):
        """Test retry settings."""
        config = PoolConfig()
        assert config.retry_attempts == 3
        assert config.retry_delay == 0.5


# =============================================================================
# PooledConnection Tests (10 tests)
# =============================================================================

class TestPooledConnection:
    """Tests for PooledConnection wrapper."""
    
    @pytest.fixture
    def pooled(self):
        """Create pooled connection."""
        return PooledConnection(
            connection="test-connection",
            pool_id="test-pool",
        )
    
    def test_init(self, pooled):
        """Test initialization."""
        assert pooled.connection == "test-connection"
        assert pooled.pool_id == "test-pool"
        assert pooled.state == ConnectionState.IDLE
    
    def test_mark_active(self, pooled):
        """Test marking active."""
        pooled.mark_active()
        assert pooled.state == ConnectionState.ACTIVE
        assert pooled.use_count == 1
    
    def test_mark_idle(self, pooled):
        """Test marking idle."""
        pooled.mark_active()
        pooled.mark_idle()
        assert pooled.state == ConnectionState.IDLE
    
    def test_mark_error(self, pooled):
        """Test marking error."""
        pooled.mark_error()
        assert pooled.state == ConnectionState.ERROR
        assert pooled.error_count == 1
    
    def test_mark_stale(self, pooled):
        """Test marking stale."""
        pooled.mark_stale()
        assert pooled.state == ConnectionState.STALE
    
    def test_is_expired(self, pooled):
        """Test expiration check."""
        # Not expired with default lifetime
        assert pooled.is_expired(3600.0) is False
        
        # Expired with very short lifetime
        assert pooled.is_expired(0.0) is True
    
    def test_is_idle_too_long(self, pooled):
        """Test idle timeout check."""
        # Not idle too long initially
        assert pooled.is_idle_too_long(300.0) is False
        
        # Idle too long with 0 timeout
        assert pooled.is_idle_too_long(0.0) is True
    
    def test_needs_validation(self, pooled):
        """Test validation check."""
        # Needs validation with 0 interval
        assert pooled.needs_validation(0.0) is True
        
        # Doesn't need validation with large interval
        assert pooled.needs_validation(3600.0) is False
    
    def test_use_count_increments(self, pooled):
        """Test use count increments."""
        for i in range(3):
            pooled.mark_active()
        assert pooled.use_count == 3
    
    def test_timestamps_update(self, pooled):
        """Test timestamps update on activity."""
        initial_time = pooled.last_used_at
        time.sleep(0.01)
        pooled.mark_active()
        assert pooled.last_used_at > initial_time


# =============================================================================
# PoolStats Tests (4 tests)
# =============================================================================

class TestPoolStats:
    """Tests for PoolStats."""
    
    def test_default_stats(self):
        """Test default statistics."""
        stats = PoolStats()
        assert stats.total_connections == 0
        assert stats.active_connections == 0
        assert stats.idle_connections == 0
    
    def test_to_dict(self):
        """Test conversion to dictionary."""
        stats = PoolStats(
            total_connections=10,
            active_connections=5,
            idle_connections=5,
        )
        d = stats.to_dict()
        assert d["total_connections"] == 10
        assert d["active_connections"] == 5
    
    def test_avg_acquire_time_rounded(self):
        """Test average acquire time is rounded."""
        stats = PoolStats(avg_acquire_time_ms=1.2345678)
        d = stats.to_dict()
        assert d["avg_acquire_time_ms"] == 1.23
    
    def test_error_and_timeout_tracking(self):
        """Test error and timeout tracking."""
        stats = PoolStats(
            total_errors=5,
            total_timeouts=2,
        )
        assert stats.total_errors == 5
        assert stats.total_timeouts == 2


# =============================================================================
# ConnectionPool Tests (12 tests)
# =============================================================================

class TestConnectionPool:
    """Tests for ConnectionPool."""
    
    @pytest.fixture
    def factory(self):
        """Create mock factory."""
        return MockConnectionFactory()
    
    @pytest.fixture
    def config(self):
        """Create test config."""
        return PoolConfig(
            min_size=2,
            max_size=5,
            max_idle_time=60.0,
            max_lifetime=300.0,
            acquire_timeout=5.0,
            validation_interval=30.0,
            enable_health_check=False,
        )
    
    @pytest.fixture
    async def pool(self, factory, config):
        """Create and start pool."""
        pool = ConnectionPool(factory, config, "test")
        await pool.start()
        yield pool
        await pool.stop()
    
    @pytest.mark.asyncio
    async def test_start_creates_min_connections(self, factory, config):
        """Test start creates minimum connections."""
        pool = ConnectionPool(factory, config, "test")
        await pool.start()
        
        assert len(pool._connections) == config.min_size
        assert factory.created_count == config.min_size
        
        await pool.stop()
    
    @pytest.mark.asyncio
    async def test_acquire_returns_connection(self, pool):
        """Test acquiring a connection."""
        pooled = await pool.acquire()
        assert pooled is not None
        assert pooled.state == ConnectionState.ACTIVE
        await pool.release(pooled)
    
    @pytest.mark.asyncio
    async def test_release_returns_to_idle(self, pool):
        """Test releasing returns to idle."""
        pooled = await pool.acquire()
        await pool.release(pooled)
        assert pooled.state == ConnectionState.IDLE
    
    @pytest.mark.asyncio
    async def test_release_with_error(self, pool):
        """Test releasing with error."""
        pooled = await pool.acquire()
        await pool.release(pooled, error=True)
        assert pooled.error_count == 1
    
    @pytest.mark.asyncio
    async def test_connection_context_manager(self, pool):
        """Test connection context manager."""
        async with pool.connection() as conn:
            assert conn is not None
    
    @pytest.mark.asyncio
    async def test_pool_closed_raises_error(self, factory, config):
        """Test acquiring from closed pool raises error."""
        pool = ConnectionPool(factory, config, "test")
        await pool.start()
        await pool.stop()
        
        with pytest.raises(RuntimeError):
            await pool.acquire()
    
    @pytest.mark.asyncio
    async def test_acquire_timeout(self, factory):
        """Test acquire timeout."""
        # Create pool with no connections
        config = PoolConfig(
            min_size=0,
            max_size=0,  # No connections allowed
            acquire_timeout=0.1,
            enable_health_check=False,
        )
        pool = ConnectionPool(factory, config, "test")
        await pool.start()
        
        with pytest.raises(TimeoutError):
            await pool.acquire(timeout=0.1)
        
        await pool.stop()
    
    @pytest.mark.asyncio
    async def test_get_stats(self, pool):
        """Test getting pool statistics."""
        stats = pool.get_stats()
        assert isinstance(stats, PoolStats)
        assert stats.total_creates >= 2
    
    @pytest.mark.asyncio
    async def test_is_healthy(self, pool):
        """Test health check."""
        assert pool.is_healthy() is True
    
    @pytest.mark.asyncio
    async def test_creates_new_when_needed(self, factory, config):
        """Test creates new connection when needed."""
        pool = ConnectionPool(factory, config, "test")
        await pool.start()
        
        # Acquire all initial connections
        acquired = []
        for _ in range(config.min_size):
            acquired.append(await pool.acquire())
        
        # Next acquire should create new
        new_conn = await pool.acquire()
        assert len(pool._connections) > config.min_size
        
        # Cleanup
        for p in acquired:
            await pool.release(p)
        await pool.release(new_conn)
        await pool.stop()
    
    @pytest.mark.asyncio
    async def test_respects_max_size(self, factory):
        """Test respects maximum size."""
        config = PoolConfig(
            min_size=1,
            max_size=2,
            acquire_timeout=0.5,
            enable_health_check=False,
        )
        pool = ConnectionPool(factory, config, "test")
        await pool.start()
        
        # Acquire all connections
        p1 = await pool.acquire()
        p2 = await pool.acquire()
        
        # Next should timeout
        with pytest.raises(TimeoutError):
            await pool.acquire(timeout=0.2)
        
        await pool.release(p1)
        await pool.release(p2)
        await pool.stop()
    
    @pytest.mark.asyncio
    async def test_stats_track_acquires(self, pool):
        """Test statistics track acquires."""
        initial = pool.get_stats().total_acquires
        
        pooled = await pool.acquire()
        await pool.release(pooled)
        
        assert pool.get_stats().total_acquires == initial + 1


# =============================================================================
# PoolManager Tests (6 tests)
# =============================================================================

class TestPoolManager:
    """Tests for PoolManager."""
    
    @pytest.fixture
    def manager(self):
        """Create pool manager."""
        return PoolManager()
    
    @pytest.fixture
    def factory(self):
        """Create mock factory."""
        return MockConnectionFactory()
    
    @pytest.fixture
    def config(self):
        """Create test config."""
        return PoolConfig(
            min_size=1,
            max_size=3,
            enable_health_check=False,
        )
    
    @pytest.mark.asyncio
    async def test_register_pool(self, manager, factory, config):
        """Test registering a pool."""
        pool = await manager.register_pool("test", factory, config)
        assert pool is not None
        await manager.close_all()
    
    @pytest.mark.asyncio
    async def test_get_pool(self, manager, factory, config):
        """Test getting a registered pool."""
        await manager.register_pool("test", factory, config)
        pool = await manager.get_pool("test")
        assert pool is not None
        await manager.close_all()
    
    @pytest.mark.asyncio
    async def test_get_pool_not_found(self, manager):
        """Test getting non-existent pool."""
        with pytest.raises(KeyError):
            await manager.get_pool("nonexistent")
    
    @pytest.mark.asyncio
    async def test_duplicate_registration(self, manager, factory, config):
        """Test duplicate registration raises error."""
        await manager.register_pool("test", factory, config)
        
        with pytest.raises(ValueError):
            await manager.register_pool("test", factory, config)
        
        await manager.close_all()
    
    @pytest.mark.asyncio
    async def test_get_all_stats(self, manager, factory, config):
        """Test getting all pool stats."""
        await manager.register_pool("pool1", factory, config)
        await manager.register_pool("pool2", MockConnectionFactory(), config)
        
        stats = manager.get_all_stats()
        assert "pool1" in stats
        assert "pool2" in stats
        
        await manager.close_all()
    
    @pytest.mark.asyncio
    async def test_is_all_healthy(self, manager, factory, config):
        """Test health check for all pools."""
        await manager.register_pool("test", factory, config)
        assert manager.is_all_healthy() is True
        await manager.close_all()


# =============================================================================
# Module Functions Tests (2 tests)
# =============================================================================

class TestModuleFunctions:
    """Tests for module-level functions."""
    
    def test_create_pool_manager(self):
        """Test create_pool_manager."""
        manager = create_pool_manager()
        assert isinstance(manager, PoolManager)
    
    def test_get_default_config(self):
        """Test get_default_config."""
        hana = get_default_config("hana")
        es = get_default_config("elasticsearch")
        http = get_default_config("http")
        
        assert hana.max_size == 15
        assert es.max_size == 30
        assert http.max_size == 50


# =============================================================================
# Summary
# =============================================================================
# Total: 45 tests
# - ConnectionState: 3 tests
# - PoolConfig: 8 tests
# - PooledConnection: 10 tests
# - PoolStats: 4 tests
# - ConnectionPool: 12 tests
# - PoolManager: 6 tests
# - Module Functions: 2 tests