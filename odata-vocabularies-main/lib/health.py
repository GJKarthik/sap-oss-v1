"""
Health Check Module

Comprehensive health checking for OData Vocabularies MCP Server.
Provides detailed status for all components including:
- Vocabulary loading
- Embeddings
- HANA Cloud connectivity
- Elasticsearch connectivity
- Memory usage
- Uptime
"""

import time
import os
import sys
import gc
from dataclasses import dataclass, field, asdict
from typing import Dict, Any, Optional, List
from enum import Enum


class HealthStatus(Enum):
    """Health status values"""
    HEALTHY = "healthy"
    DEGRADED = "degraded"
    UNHEALTHY = "unhealthy"


@dataclass
class ComponentHealth:
    """Health status for a single component"""
    name: str
    status: HealthStatus
    latency_ms: Optional[float] = None
    message: Optional[str] = None
    details: Dict[str, Any] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        result = {
            "status": self.status.value,
        }
        if self.latency_ms is not None:
            result["latency_ms"] = round(self.latency_ms, 2)
        if self.message:
            result["message"] = self.message
        if self.details:
            result.update(self.details)
        return result


@dataclass
class HealthCheckResult:
    """Complete health check result"""
    status: HealthStatus
    version: str
    uptime_seconds: int
    checks: Dict[str, ComponentHealth]
    memory_mb: float
    python_version: str
    timestamp: str
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "status": self.status.value,
            "version": self.version,
            "uptime_seconds": self.uptime_seconds,
            "timestamp": self.timestamp,
            "memory_mb": round(self.memory_mb, 2),
            "python_version": self.python_version,
            "checks": {name: check.to_dict() for name, check in self.checks.items()}
        }


class HealthChecker:
    """
    Comprehensive health checker for MCP Server.
    
    Features:
    - Component-level health checks
    - Latency tracking
    - Memory monitoring
    - Uptime tracking
    - Degraded status detection
    """
    
    VERSION = "3.0.0"
    
    def __init__(self):
        self._start_time = time.time()
        self._vocabularies = None
        self._embeddings = None
        self._hana_connector = None
        self._es_client = None
        self._auth_middleware = None
        self._last_check: Optional[HealthCheckResult] = None
        self._check_cache_seconds = 5  # Cache health results for 5 seconds
        self._last_check_time = 0
    
    def register_vocabularies(self, vocabularies: Dict):
        """Register vocabularies for health checking"""
        self._vocabularies = vocabularies
    
    def register_embeddings(self, embeddings: Dict):
        """Register embeddings for health checking"""
        self._embeddings = embeddings
    
    def register_hana(self, connector):
        """Register HANA connector for health checking"""
        self._hana_connector = connector
    
    def register_elasticsearch(self, client):
        """Register Elasticsearch client for health checking"""
        self._es_client = client
    
    def register_auth(self, middleware):
        """Register auth middleware for health checking"""
        self._auth_middleware = middleware
    
    def get_uptime(self) -> int:
        """Get server uptime in seconds"""
        return int(time.time() - self._start_time)
    
    def get_memory_usage(self) -> float:
        """Get current memory usage in MB"""
        try:
            import resource
            usage = resource.getrusage(resource.RUSAGE_SELF)
            return usage.ru_maxrss / 1024  # Convert to MB (macOS reports KB)
        except ImportError:
            # Windows fallback
            try:
                import psutil
                process = psutil.Process()
                return process.memory_info().rss / (1024 * 1024)
            except ImportError:
                # Estimate from gc
                gc.collect()
                return sum(sys.getsizeof(obj) for obj in gc.get_objects()) / (1024 * 1024)
    
    def check_vocabularies(self) -> ComponentHealth:
        """Check vocabulary loading health"""
        start = time.time()
        
        if self._vocabularies is None:
            return ComponentHealth(
                name="vocabularies",
                status=HealthStatus.UNHEALTHY,
                message="Vocabularies not loaded"
            )
        
        count = len(self._vocabularies)
        term_count = sum(
            len(v.get("terms", [])) 
            for v in self._vocabularies.values() 
            if isinstance(v, dict)
        )
        
        latency = (time.time() - start) * 1000
        
        if count < 15:
            return ComponentHealth(
                name="vocabularies",
                status=HealthStatus.DEGRADED,
                latency_ms=latency,
                message=f"Only {count} vocabularies loaded (expected 15+)",
                details={"count": count, "term_count": term_count}
            )
        
        return ComponentHealth(
            name="vocabularies",
            status=HealthStatus.HEALTHY,
            latency_ms=latency,
            details={"count": count, "term_count": term_count}
        )
    
    def check_embeddings(self) -> ComponentHealth:
        """Check embeddings health"""
        start = time.time()
        
        if self._embeddings is None:
            return ComponentHealth(
                name="embeddings",
                status=HealthStatus.DEGRADED,
                message="Embeddings not loaded - semantic search unavailable"
            )
        
        count = len(self._embeddings)
        latency = (time.time() - start) * 1000
        
        # Check if embeddings have actual vectors
        has_vectors = any(
            isinstance(v, (list, tuple)) and len(v) > 0
            for v in self._embeddings.values()
        )
        
        if count == 0:
            return ComponentHealth(
                name="embeddings",
                status=HealthStatus.DEGRADED,
                latency_ms=latency,
                message="No embeddings loaded",
                details={"count": 0, "has_vectors": False}
            )
        
        return ComponentHealth(
            name="embeddings",
            status=HealthStatus.HEALTHY,
            latency_ms=latency,
            details={"count": count, "has_vectors": has_vectors}
        )
    
    def check_hana(self) -> ComponentHealth:
        """Check HANA Cloud connectivity"""
        start = time.time()
        
        if self._hana_connector is None:
            return ComponentHealth(
                name="hana",
                status=HealthStatus.DEGRADED,
                message="HANA connector not configured"
            )
        
        try:
            stats = self._hana_connector.get_stats()
            latency = (time.time() - start) * 1000
            
            if not stats.get("connected", False):
                return ComponentHealth(
                    name="hana",
                    status=HealthStatus.DEGRADED,
                    latency_ms=latency,
                    message="HANA not connected",
                    details=stats
                )
            
            # Check circuit breaker state
            cb_state = stats.get("circuit_breaker_state", "unknown")
            if cb_state == "open":
                return ComponentHealth(
                    name="hana",
                    status=HealthStatus.UNHEALTHY,
                    latency_ms=latency,
                    message="Circuit breaker open - HANA unavailable",
                    details=stats
                )
            
            return ComponentHealth(
                name="hana",
                status=HealthStatus.HEALTHY,
                latency_ms=latency,
                details=stats
            )
        except Exception as e:
            return ComponentHealth(
                name="hana",
                status=HealthStatus.UNHEALTHY,
                latency_ms=(time.time() - start) * 1000,
                message=str(e)
            )
    
    def check_elasticsearch(self) -> ComponentHealth:
        """Check Elasticsearch connectivity"""
        start = time.time()
        
        if self._es_client is None:
            return ComponentHealth(
                name="elasticsearch",
                status=HealthStatus.DEGRADED,
                message="Elasticsearch client not configured"
            )
        
        try:
            stats = self._es_client.get_stats()
            latency = (time.time() - start) * 1000
            
            if not stats.get("connected", False):
                return ComponentHealth(
                    name="elasticsearch",
                    status=HealthStatus.DEGRADED,
                    latency_ms=latency,
                    message="Elasticsearch not connected",
                    details=stats
                )
            
            return ComponentHealth(
                name="elasticsearch",
                status=HealthStatus.HEALTHY,
                latency_ms=latency,
                details=stats
            )
        except Exception as e:
            return ComponentHealth(
                name="elasticsearch",
                status=HealthStatus.UNHEALTHY,
                latency_ms=(time.time() - start) * 1000,
                message=str(e)
            )
    
    def check_auth(self) -> ComponentHealth:
        """Check authentication middleware"""
        start = time.time()
        
        if self._auth_middleware is None:
            return ComponentHealth(
                name="auth",
                status=HealthStatus.HEALTHY,
                message="Auth not configured - all requests allowed"
            )
        
        latency = (time.time() - start) * 1000
        
        try:
            stats = self._auth_middleware.get_stats()
            return ComponentHealth(
                name="auth",
                status=HealthStatus.HEALTHY,
                latency_ms=latency,
                details=stats
            )
        except Exception as e:
            return ComponentHealth(
                name="auth",
                status=HealthStatus.DEGRADED,
                latency_ms=latency,
                message=str(e)
            )
    
    def run_all_checks(self, use_cache: bool = True) -> HealthCheckResult:
        """
        Run all health checks and return aggregated result.
        
        Args:
            use_cache: If True, return cached result if within cache window
        """
        # Return cached result if fresh
        now = time.time()
        if use_cache and self._last_check and (now - self._last_check_time) < self._check_cache_seconds:
            return self._last_check
        
        # Run all component checks
        checks: Dict[str, ComponentHealth] = {}
        
        checks["vocabularies"] = self.check_vocabularies()
        checks["embeddings"] = self.check_embeddings()
        checks["hana"] = self.check_hana()
        checks["elasticsearch"] = self.check_elasticsearch()
        checks["auth"] = self.check_auth()
        
        # Determine overall status
        statuses = [c.status for c in checks.values()]
        
        if HealthStatus.UNHEALTHY in statuses:
            overall_status = HealthStatus.UNHEALTHY
        elif HealthStatus.DEGRADED in statuses:
            overall_status = HealthStatus.DEGRADED
        else:
            overall_status = HealthStatus.HEALTHY
        
        # Create result
        from datetime import datetime
        
        result = HealthCheckResult(
            status=overall_status,
            version=self.VERSION,
            uptime_seconds=self.get_uptime(),
            checks=checks,
            memory_mb=self.get_memory_usage(),
            python_version=f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
            timestamp=datetime.utcnow().isoformat() + "Z"
        )
        
        # Cache result
        self._last_check = result
        self._last_check_time = now
        
        return result
    
    def get_liveness(self) -> Dict[str, Any]:
        """
        Simple liveness check (Kubernetes liveness probe).
        Returns immediately - just checks if server is running.
        """
        return {
            "status": "alive",
            "uptime_seconds": self.get_uptime()
        }
    
    def get_readiness(self) -> Dict[str, Any]:
        """
        Readiness check (Kubernetes readiness probe).
        Checks if server is ready to accept traffic.
        """
        vocab_check = self.check_vocabularies()
        
        if vocab_check.status == HealthStatus.UNHEALTHY:
            return {
                "status": "not_ready",
                "reason": vocab_check.message
            }
        
        return {
            "status": "ready",
            "vocabularies": vocab_check.details.get("count", 0)
        }


# Global health checker instance
_health_checker: Optional[HealthChecker] = None


def get_health_checker() -> HealthChecker:
    """Get or create global health checker instance"""
    global _health_checker
    if _health_checker is None:
        _health_checker = HealthChecker()
    return _health_checker


def reset_health_checker():
    """Reset health checker (for testing)"""
    global _health_checker
    _health_checker = None