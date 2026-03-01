"""
Performance optimization module for Mangle Query Service.

Week 10 Implementation - Performance & Optimization
"""

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

__all__ = [
    # Connection States
    "ConnectionState",
    
    # Configuration
    "PoolConfig",
    
    # Connection Wrapper
    "PooledConnection",
    
    # Factory Interface
    "ConnectionFactory",
    
    # Statistics
    "PoolStats",
    
    # Pool Classes
    "ConnectionPool",
    "HTTPConnectionFactory",
    "PoolManager",
    
    # Factory Functions
    "create_pool_manager",
    "create_http_pool",
    "get_default_config",
]