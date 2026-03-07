"""
Health check module for cross-service status monitoring.

Provides health endpoints that check:
- Local Elasticsearch connection
- External service availability (Mangle, OData Vocab)
- Circuit breaker states
"""

import time
import asyncio
from datetime import datetime
from typing import Dict, Optional, Any
from dataclasses import dataclass
from enum import Enum
import logging
import httpx

logger = logging.getLogger(__name__)


class HealthStatus(Enum):
    """Health check status values."""
    HEALTHY = "healthy"
    DEGRADED = "degraded"
    UNHEALTHY = "unhealthy"


@dataclass
class ServiceHealth:
    """Health status for a single service."""
    name: str
    status: HealthStatus
    latency_ms: Optional[float] = None
    message: Optional[str] = None
    last_check: Optional[datetime] = None
    details: Optional[Dict] = None


class HealthChecker:
    """
    Health checker for cross-service monitoring.
    
    Checks health of:
    - Local Elasticsearch cluster
    - Mangle Query Service
    - OData Vocabularies Service
    - SAP AI Core
    """
    
    def __init__(self):
        self.services: Dict[str, str] = {}
        self._timeout = 5.0
        self._cache: Dict[str, ServiceHealth] = {}
        self._cache_ttl = 30  # seconds
    
    def register_service(self, name: str, health_url: str):
        """Register a service for health checking."""
        self.services[name] = health_url
    
    async def check_service(self, name: str, url: str) -> ServiceHealth:
        """Check health of a single service."""
        start = time.time()
        
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                response = await client.get(url)
                latency = (time.time() - start) * 1000
                
                if response.status_code == 200:
                    return ServiceHealth(
                        name=name,
                        status=HealthStatus.HEALTHY,
                        latency_ms=latency,
                        last_check=datetime.utcnow(),
                        details=response.json() if response.headers.get("content-type", "").startswith("application/json") else None
                    )
                else:
                    return ServiceHealth(
                        name=name,
                        status=HealthStatus.UNHEALTHY,
                        latency_ms=latency,
                        message=f"HTTP {response.status_code}",
                        last_check=datetime.utcnow()
                    )
        except httpx.TimeoutException:
            return ServiceHealth(
                name=name,
                status=HealthStatus.UNHEALTHY,
                latency_ms=(time.time() - start) * 1000,
                message="Timeout",
                last_check=datetime.utcnow()
            )
        except Exception as e:
            return ServiceHealth(
                name=name,
                status=HealthStatus.UNHEALTHY,
                latency_ms=(time.time() - start) * 1000,
                message=str(e),
                last_check=datetime.utcnow()
            )
    
    async def check_all(self, use_cache: bool = True) -> Dict[str, ServiceHealth]:
        """Check health of all registered services."""
        results = {}
        
        for name, url in self.services.items():
            # Check cache
            if use_cache and name in self._cache:
                cached = self._cache[name]
                if cached.last_check:
                    age = (datetime.utcnow() - cached.last_check).total_seconds()
                    if age < self._cache_ttl:
                        results[name] = cached
                        continue
            
            # Check service
            health = await self.check_service(name, url)
            self._cache[name] = health
            results[name] = health
        
        return results
    
    async def get_aggregate_status(self) -> Dict[str, Any]:
        """Get aggregate health status for all services."""
        services = await self.check_all()
        
        # Add circuit breaker states
        try:
            from .circuit_breaker import get_all_breaker_stats
            breaker_stats = get_all_breaker_stats()
        except ImportError:
            breaker_stats = {}
        
        # Determine overall status
        statuses = [s.status for s in services.values()]
        
        if all(s == HealthStatus.HEALTHY for s in statuses):
            overall = HealthStatus.HEALTHY
        elif any(s == HealthStatus.UNHEALTHY for s in statuses):
            overall = HealthStatus.DEGRADED
        else:
            overall = HealthStatus.DEGRADED
        
        return {
            "status": overall.value,
            "timestamp": datetime.utcnow().isoformat(),
            "services": {
                name: {
                    "status": health.status.value,
                    "latency_ms": health.latency_ms,
                    "message": health.message
                }
                for name, health in services.items()
            },
            "circuit_breakers": breaker_stats
        }


# Global health checker instance
_health_checker: Optional[HealthChecker] = None


def get_health_checker() -> HealthChecker:
    """Get the global health checker."""
    global _health_checker
    if _health_checker is None:
        _health_checker = HealthChecker()
        # Register default services (can be configured via env vars)
        import os
        
        _health_checker.register_service(
            "elasticsearch",
            os.getenv("ES_HEALTH_URL", "http://localhost:9200/_cluster/health")
        )
        _health_checker.register_service(
            "mangle-query-service",
            os.getenv("MANGLE_HEALTH_URL", "http://localhost:50051/health")
        )
        _health_checker.register_service(
            "odata-vocabularies",
            os.getenv("ODATA_VOCAB_HEALTH_URL", "http://localhost:9100/health")
        )
    return _health_checker


async def get_health() -> Dict[str, Any]:
    """Get health status for all services."""
    checker = get_health_checker()
    return await checker.get_aggregate_status()


def health_endpoint():
    """
    Create FastAPI health endpoint.
    
    Usage:
        from fastapi import FastAPI
        from middleware.health import health_endpoint
        
        app = FastAPI()
        app.get("/health")(health_endpoint())
    """
    async def endpoint():
        return await get_health()
    return endpoint


# Synchronous health check for simple cases
def check_local_health() -> Dict[str, Any]:
    """Synchronous local health check."""
    from .circuit_breaker import get_all_breaker_stats
    from .rate_limiter import get_mcp_limiter, get_openai_limiter
    
    return {
        "status": "healthy",
        "timestamp": datetime.utcnow().isoformat(),
        "service": "elasticsearch-mcp-server",
        "version": "1.0.0",
        "components": {
            "rate_limiter": {
                "mcp": get_mcp_limiter().get_metrics(),
                "openai": get_openai_limiter().get_metrics()
            },
            "circuit_breakers": get_all_breaker_stats()
        }
    }