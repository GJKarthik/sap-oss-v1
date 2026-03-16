"""
Connection Pool Manager for High-Performance Backend Connections.

Day 46 Implementation - Week 10 Performance Optimization
Provides unified connection pooling for HANA, Elasticsearch, and HTTP backends.
"""

import asyncio
import logging
import time
import ssl
from typing import Optional, Dict, Any, List, TypeVar, Generic, Callable
from dataclasses import dataclass, field
from enum import Enum
from contextlib import asynccontextmanager
import threading
import queue
from abc import ABC, abstractmethod
import hashlib

logger = logging.getLogger(__name__)

T = TypeVar('T')


# =============================================================================
# Connection States
# =============================================================================

class ConnectionState(str, Enum):
    """Connection lifecycle states."""
    IDLE = "idle"
    ACTIVE = "active"
    STALE = "stale"
    CLOSED = "closed"
    ERROR = "error"


# =============================================================================
# Pool Configuration
# =============================================================================

@dataclass
class PoolConfig:
    """Connection pool configuration."""
    min_size: int = 5
    max_size: int = 20
    max_idle_time: float = 300.0  # 5 minutes
    max_lifetime: float = 3600.0  # 1 hour
    acquire_timeout: float = 30.0  # seconds
    validation_interval: float = 60.0  # seconds
    retry_attempts: int = 3
    retry_delay: float = 0.5
    enable_health_check: bool = True
    health_check_interval: float = 30.0

    @classmethod
    def for_hana(cls) -> "PoolConfig":
        """Configuration optimized for SAP HANA."""
        return cls(
            min_size=3,
            max_size=15,
            max_idle_time=180.0,
            max_lifetime=1800.0,
            acquire_timeout=45.0,
        )

    @classmethod
    def for_elasticsearch(cls) -> "PoolConfig":
        """Configuration optimized for Elasticsearch."""
        return cls(
            min_size=5,
            max_size=30,
            max_idle_time=120.0,
            max_lifetime=600.0,
            acquire_timeout=15.0,
        )

    @classmethod
    def for_http(cls) -> "PoolConfig":
        """Configuration optimized for HTTP clients."""
        return cls(
            min_size=10,
            max_size=50,
            max_idle_time=60.0,
            max_lifetime=300.0,
            acquire_timeout=10.0,
        )


# =============================================================================
# Connection Wrapper
# =============================================================================

@dataclass
class PooledConnection(Generic[T]):
    """Wrapper for pooled connections with metadata."""
    connection: T
    pool_id: str
    created_at: float = field(default_factory=time.time)
    last_used_at: float = field(default_factory=time.time)
    last_validated_at: float = field(default_factory=time.time)
    use_count: int = 0
    state: ConnectionState = ConnectionState.IDLE
    error_count: int = 0
    _lock: threading.Lock = field(default_factory=threading.Lock)

    def mark_active(self):
        """Mark connection as active."""
        with self._lock:
            self.state = ConnectionState.ACTIVE
            self.last_used_at = time.time()
            self.use_count += 1

    def mark_idle(self):
        """Mark connection as idle."""
        with self._lock:
            self.state = ConnectionState.IDLE
            self.last_used_at = time.time()

    def mark_error(self):
        """Mark connection as having an error."""
        with self._lock:
            self.state = ConnectionState.ERROR
            self.error_count += 1

    def mark_stale(self):
        """Mark connection as stale."""
        with self._lock:
            self.state = ConnectionState.STALE

    def is_expired(self, max_lifetime: float) -> bool:
        """Check if connection has exceeded max lifetime."""
        return (time.time() - self.created_at) > max_lifetime

    def is_idle_too_long(self, max_idle_time: float) -> bool:
        """Check if connection has been idle too long."""
        return (
            self.state == ConnectionState.IDLE and
            (time.time() - self.last_used_at) > max_idle_time
        )

    def needs_validation(self, interval: float) -> bool:
        """Check if connection needs validation."""
        return (time.time() - self.last_validated_at) > interval


# =============================================================================
# Connection Factory Interface
# =============================================================================

class ConnectionFactory(ABC, Generic[T]):
    """Abstract factory for creating connections."""

    @abstractmethod
    async def create(self) -> T:
        """Create a new connection."""
        pass

    @abstractmethod
    async def validate(self, connection: T) -> bool:
        """Validate a connection is still usable."""
        pass

    @abstractmethod
    async def close(self, connection: T) -> None:
        """Close a connection."""
        pass


# =============================================================================
# Connection Pool Statistics
# =============================================================================

@dataclass
class PoolStats:
    """Connection pool statistics."""
    total_connections: int = 0
    active_connections: int = 0
    idle_connections: int = 0
    waiting_requests: int = 0
    total_acquires: int = 0
    total_releases: int = 0
    total_creates: int = 0
    total_closes: int = 0
    total_errors: int = 0
    total_timeouts: int = 0
    avg_acquire_time_ms: float = 0.0
    avg_connection_lifetime_s: float = 0.0

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "total_connections": self.total_connections,
            "active_connections": self.active_connections,
            "idle_connections": self.idle_connections,
            "waiting_requests": self.waiting_requests,
            "total_acquires": self.total_acquires,
            "total_releases": self.total_releases,
            "total_creates": self.total_creates,
            "total_closes": self.total_closes,
            "total_errors": self.total_errors,
            "total_timeouts": self.total_timeouts,
            "avg_acquire_time_ms": round(self.avg_acquire_time_ms, 2),
            "avg_connection_lifetime_s": round(self.avg_connection_lifetime_s, 2),
        }


# =============================================================================
# Connection Pool
# =============================================================================

class ConnectionPool(Generic[T]):
    """
    High-performance connection pool with automatic management.
    
    Features:
    - Async-safe connection acquisition and release
    - Automatic connection validation and cleanup
    - Connection lifetime management
    - Health monitoring and statistics
    - Graceful degradation under load
    """

    def __init__(
        self,
        factory: ConnectionFactory[T],
        config: PoolConfig = None,
        name: str = "default",
    ):
        self.factory = factory
        self.config = config or PoolConfig()
        self.name = name
        self.pool_id = hashlib.md5(f"{name}:{time.time()}".encode()).hexdigest()[:8]

        self._connections: List[PooledConnection[T]] = []
        self._lock = asyncio.Lock()
        self._condition = asyncio.Condition(self._lock)
        self._closed = False
        self._stats = PoolStats()
        self._acquire_times: List[float] = []
        
        # Background tasks
        self._maintenance_task: Optional[asyncio.Task] = None
        self._health_check_task: Optional[asyncio.Task] = None

    async def start(self):
        """Start the pool and initialize minimum connections."""
        logger.info(f"Starting connection pool '{self.name}' with min={self.config.min_size}")
        
        # Create initial connections
        for _ in range(self.config.min_size):
            try:
                await self._create_connection()
            except Exception as e:
                logger.warning(f"Failed to create initial connection: {e}")

        # Start background tasks
        self._maintenance_task = asyncio.create_task(self._maintenance_loop())
        if self.config.enable_health_check:
            self._health_check_task = asyncio.create_task(self._health_check_loop())

        logger.info(f"Pool '{self.name}' started with {len(self._connections)} connections")

    async def stop(self):
        """Stop the pool and close all connections."""
        logger.info(f"Stopping connection pool '{self.name}'")
        self._closed = True

        # Cancel background tasks
        if self._maintenance_task:
            self._maintenance_task.cancel()
        if self._health_check_task:
            self._health_check_task.cancel()

        # Close all connections
        async with self._lock:
            for pooled in self._connections:
                try:
                    await self.factory.close(pooled.connection)
                    self._stats.total_closes += 1
                except Exception as e:
                    logger.warning(f"Error closing connection: {e}")
            self._connections.clear()

        logger.info(f"Pool '{self.name}' stopped")

    async def _create_connection(self) -> PooledConnection[T]:
        """Create a new pooled connection."""
        connection = await self.factory.create()
        pooled = PooledConnection(
            connection=connection,
            pool_id=self.pool_id,
        )
        self._connections.append(pooled)
        self._stats.total_creates += 1
        self._stats.total_connections = len(self._connections)
        return pooled

    async def _close_connection(self, pooled: PooledConnection[T]):
        """Close and remove a connection from the pool."""
        try:
            await self.factory.close(pooled.connection)
            pooled.state = ConnectionState.CLOSED
            self._stats.total_closes += 1
        except Exception as e:
            logger.warning(f"Error closing connection: {e}")
        finally:
            if pooled in self._connections:
                self._connections.remove(pooled)
            self._stats.total_connections = len(self._connections)

    async def acquire(self, timeout: float = None) -> PooledConnection[T]:
        """
        Acquire a connection from the pool.
        
        Args:
            timeout: Maximum time to wait for a connection
            
        Returns:
            PooledConnection wrapper
            
        Raises:
            TimeoutError: If timeout is exceeded
            RuntimeError: If pool is closed
        """
        if self._closed:
            raise RuntimeError(f"Pool '{self.name}' is closed")

        timeout = timeout or self.config.acquire_timeout
        start_time = time.time()

        async with self._condition:
            while True:
                # Check timeout
                elapsed = time.time() - start_time
                if elapsed >= timeout:
                    self._stats.total_timeouts += 1
                    raise TimeoutError(f"Timeout acquiring connection from pool '{self.name}'")

                # Try to find an idle connection
                for pooled in self._connections:
                    if pooled.state == ConnectionState.IDLE:
                        # Validate if needed
                        if pooled.needs_validation(self.config.validation_interval):
                            is_valid = await self.factory.validate(pooled.connection)
                            pooled.last_validated_at = time.time()
                            if not is_valid:
                                await self._close_connection(pooled)
                                continue

                        # Check expiration
                        if pooled.is_expired(self.config.max_lifetime):
                            await self._close_connection(pooled)
                            continue

                        pooled.mark_active()
                        self._stats.total_acquires += 1
                        self._stats.active_connections += 1
                        self._stats.idle_connections = sum(
                            1 for p in self._connections if p.state == ConnectionState.IDLE
                        )
                        
                        # Track acquire time
                        acquire_time = (time.time() - start_time) * 1000
                        self._acquire_times.append(acquire_time)
                        if len(self._acquire_times) > 1000:
                            self._acquire_times = self._acquire_times[-1000:]
                        self._stats.avg_acquire_time_ms = sum(self._acquire_times) / len(self._acquire_times)
                        
                        return pooled

                # No idle connections available
                if len(self._connections) < self.config.max_size:
                    # Create new connection
                    try:
                        pooled = await self._create_connection()
                        pooled.mark_active()
                        self._stats.total_acquires += 1
                        self._stats.active_connections += 1
                        return pooled
                    except Exception as e:
                        logger.error(f"Failed to create connection: {e}")
                        self._stats.total_errors += 1

                # Wait for a connection to become available
                self._stats.waiting_requests += 1
                try:
                    remaining_timeout = timeout - elapsed
                    await asyncio.wait_for(
                        self._condition.wait(),
                        timeout=remaining_timeout
                    )
                except asyncio.TimeoutError:
                    self._stats.total_timeouts += 1
                    raise TimeoutError(f"Timeout acquiring connection from pool '{self.name}'")
                finally:
                    self._stats.waiting_requests = max(0, self._stats.waiting_requests - 1)

    async def release(self, pooled: PooledConnection[T], error: bool = False):
        """
        Release a connection back to the pool.
        
        Args:
            pooled: The pooled connection to release
            error: Whether the connection had an error
        """
        if self._closed:
            try:
                await self.factory.close(pooled.connection)
            except Exception:
                pass
            return

        async with self._condition:
            if error:
                pooled.mark_error()
                # Close connections with too many errors
                if pooled.error_count >= 3:
                    await self._close_connection(pooled)
                else:
                    pooled.mark_idle()
            else:
                pooled.mark_idle()

            self._stats.total_releases += 1
            self._stats.active_connections = sum(
                1 for p in self._connections if p.state == ConnectionState.ACTIVE
            )
            self._stats.idle_connections = sum(
                1 for p in self._connections if p.state == ConnectionState.IDLE
            )

            # Notify waiting acquirers
            self._condition.notify()

    @asynccontextmanager
    async def connection(self, timeout: float = None):
        """
        Context manager for acquiring and releasing connections.
        
        Usage:
            async with pool.connection() as conn:
                await conn.execute(...)
        """
        pooled = await self.acquire(timeout)
        error = False
        try:
            yield pooled.connection
        except Exception:
            error = True
            raise
        finally:
            await self.release(pooled, error=error)

    async def _maintenance_loop(self):
        """Background task for pool maintenance."""
        while not self._closed:
            try:
                await asyncio.sleep(self.config.validation_interval)
                await self._cleanup_stale_connections()
                await self._ensure_min_connections()
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"Maintenance error: {e}")

    async def _cleanup_stale_connections(self):
        """Remove stale and expired connections."""
        async with self._lock:
            to_close = []
            for pooled in self._connections:
                if pooled.state != ConnectionState.ACTIVE:
                    if pooled.is_expired(self.config.max_lifetime):
                        to_close.append(pooled)
                    elif pooled.is_idle_too_long(self.config.max_idle_time):
                        # Keep minimum connections
                        if len(self._connections) - len(to_close) > self.config.min_size:
                            to_close.append(pooled)

            for pooled in to_close:
                await self._close_connection(pooled)

    async def _ensure_min_connections(self):
        """Ensure minimum number of connections."""
        async with self._lock:
            current = len(self._connections)
            needed = self.config.min_size - current
            for _ in range(needed):
                try:
                    await self._create_connection()
                except Exception as e:
                    logger.warning(f"Failed to create connection: {e}")

    async def _health_check_loop(self):
        """Background task for health checking."""
        while not self._closed:
            try:
                await asyncio.sleep(self.config.health_check_interval)
                await self._health_check()
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"Health check error: {e}")

    async def _health_check(self):
        """Validate all idle connections."""
        async with self._lock:
            for pooled in self._connections:
                if pooled.state == ConnectionState.IDLE:
                    try:
                        is_valid = await self.factory.validate(pooled.connection)
                        pooled.last_validated_at = time.time()
                        if not is_valid:
                            await self._close_connection(pooled)
                    except Exception as e:
                        logger.warning(f"Health check failed: {e}")
                        pooled.mark_error()

    def get_stats(self) -> PoolStats:
        """Get current pool statistics."""
        return self._stats

    def is_healthy(self) -> bool:
        """Check if pool is healthy."""
        return (
            not self._closed and
            len(self._connections) >= self.config.min_size and
            self._stats.total_errors < self._stats.total_acquires * 0.1
        )


# =============================================================================
# HTTP Connection Factory
# =============================================================================

class HTTPConnectionFactory(ConnectionFactory[Any]):
    """Factory for HTTP client sessions."""

    def __init__(
        self,
        base_url: str,
        timeout: float = 30.0,
        ssl_context: Optional[ssl.SSLContext] = None,
    ):
        self.base_url = base_url
        self.timeout = timeout
        self.ssl_context = ssl_context

    async def create(self):
        """Create a new HTTP session."""
        import aiohttp
        
        connector = aiohttp.TCPConnector(
            limit=0,  # Pool manages limits
            enable_cleanup_closed=True,
            ssl=self.ssl_context,
        )
        timeout = aiohttp.ClientTimeout(total=self.timeout)
        session = aiohttp.ClientSession(
            base_url=self.base_url,
            connector=connector,
            timeout=timeout,
        )
        return session

    async def validate(self, connection) -> bool:
        """Validate HTTP session is usable."""
        return not connection.closed

    async def close(self, connection) -> None:
        """Close HTTP session."""
        await connection.close()


# =============================================================================
# Pool Manager
# =============================================================================

class PoolManager:
    """
    Manages multiple connection pools for different backends.
    
    Provides a unified interface for connection management across
    HANA, Elasticsearch, HTTP, and other backends.
    """

    def __init__(self):
        self._pools: Dict[str, ConnectionPool] = {}
        self._lock = asyncio.Lock()

    async def register_pool(
        self,
        name: str,
        factory: ConnectionFactory,
        config: PoolConfig = None,
    ) -> ConnectionPool:
        """Register and start a new connection pool."""
        async with self._lock:
            if name in self._pools:
                raise ValueError(f"Pool '{name}' already exists")
            
            pool = ConnectionPool(factory, config, name)
            await pool.start()
            self._pools[name] = pool
            return pool

    async def get_pool(self, name: str) -> ConnectionPool:
        """Get a registered pool by name."""
        async with self._lock:
            if name not in self._pools:
                raise KeyError(f"Pool '{name}' not found")
            return self._pools[name]

    async def close_all(self):
        """Close all registered pools."""
        async with self._lock:
            for pool in self._pools.values():
                await pool.stop()
            self._pools.clear()

    def get_all_stats(self) -> Dict[str, Dict]:
        """Get statistics for all pools."""
        return {
            name: pool.get_stats().to_dict()
            for name, pool in self._pools.items()
        }

    def is_all_healthy(self) -> bool:
        """Check if all pools are healthy."""
        return all(pool.is_healthy() for pool in self._pools.values())


# =============================================================================
# Factory Functions
# =============================================================================

def create_pool_manager() -> PoolManager:
    """Create a pool manager."""
    return PoolManager()


def create_http_pool(
    name: str,
    base_url: str,
    config: PoolConfig = None,
) -> tuple:
    """Create an HTTP connection pool (returns factory and config)."""
    factory = HTTPConnectionFactory(base_url)
    config = config or PoolConfig.for_http()
    return factory, config


def get_default_config(backend: str) -> PoolConfig:
    """Get default config for a backend type."""
    configs = {
        "hana": PoolConfig.for_hana,
        "elasticsearch": PoolConfig.for_elasticsearch,
        "http": PoolConfig.for_http,
    }
    factory = configs.get(backend.lower(), PoolConfig)
    return factory()