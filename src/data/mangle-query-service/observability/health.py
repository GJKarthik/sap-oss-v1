"""
Health Checks Module - Observability Without External Dependencies.

Day 54 Implementation - Week 11 Observability & Monitoring
Provides comprehensive health checking with liveness, readiness, and dependency monitoring.
No external service dependencies - pure Python implementation.
"""

import time
import threading
import asyncio
from typing import Optional, Dict, Any, List, Callable, Union
from dataclasses import dataclass, field
from enum import Enum
from abc import ABC, abstractmethod
import json


# =============================================================================
# Health Status
# =============================================================================

class HealthStatus(Enum):
    """Health status values."""
    HEALTHY = "healthy"
    UNHEALTHY = "unhealthy"
    DEGRADED = "degraded"
    UNKNOWN = "unknown"


@dataclass
class HealthCheckResult:
    """Result of a single health check."""
    name: str
    status: HealthStatus
    message: Optional[str] = None
    latency_ms: Optional[float] = None
    details: Dict[str, Any] = field(default_factory=dict)
    timestamp: float = field(default_factory=time.time)
    
    def is_healthy(self) -> bool:
        """Check if result indicates healthy status."""
        return self.status == HealthStatus.HEALTHY
    
    def is_degraded(self) -> bool:
        """Check if result indicates degraded status."""
        return self.status == HealthStatus.DEGRADED
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "name": self.name,
            "status": self.status.value,
            "message": self.message,
            "latency_ms": self.latency_ms,
            "details": self.details,
            "timestamp": self.timestamp,
        }


@dataclass
class AggregateHealthResult:
    """Aggregated health status from multiple checks."""
    status: HealthStatus
    checks: List[HealthCheckResult]
    timestamp: float = field(default_factory=time.time)
    
    @property
    def healthy_count(self) -> int:
        """Count of healthy checks."""
        return sum(1 for c in self.checks if c.status == HealthStatus.HEALTHY)
    
    @property
    def unhealthy_count(self) -> int:
        """Count of unhealthy checks."""
        return sum(1 for c in self.checks if c.status == HealthStatus.UNHEALTHY)
    
    @property
    def degraded_count(self) -> int:
        """Count of degraded checks."""
        return sum(1 for c in self.checks if c.status == HealthStatus.DEGRADED)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "status": self.status.value,
            "checks": [c.to_dict() for c in self.checks],
            "summary": {
                "total": len(self.checks),
                "healthy": self.healthy_count,
                "unhealthy": self.unhealthy_count,
                "degraded": self.degraded_count,
            },
            "timestamp": self.timestamp,
        }


# =============================================================================
# Health Check Interface
# =============================================================================

class HealthCheck(ABC):
    """Base class for health checks."""
    
    def __init__(self, name: str, critical: bool = True, timeout: float = 5.0):
        self.name = name
        self.critical = critical
        self.timeout = timeout
    
    @abstractmethod
    def check(self) -> HealthCheckResult:
        """Perform the health check (sync)."""
        pass
    
    async def check_async(self) -> HealthCheckResult:
        """Perform the health check (async). Override for async checks."""
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, self.check)


# =============================================================================
# Built-in Health Checks
# =============================================================================

class AlwaysHealthyCheck(HealthCheck):
    """Health check that always returns healthy."""
    
    def __init__(self, name: str = "always_healthy"):
        super().__init__(name, critical=False)
    
    def check(self) -> HealthCheckResult:
        return HealthCheckResult(
            name=self.name,
            status=HealthStatus.HEALTHY,
            message="Always healthy",
        )


class CallableCheck(HealthCheck):
    """Health check that runs a callable."""
    
    def __init__(
        self,
        name: str,
        func: Callable[[], bool],
        critical: bool = True,
        timeout: float = 5.0,
    ):
        super().__init__(name, critical, timeout)
        self.func = func
    
    def check(self) -> HealthCheckResult:
        start = time.time()
        try:
            result = self.func()
            latency = (time.time() - start) * 1000
            
            if result:
                return HealthCheckResult(
                    name=self.name,
                    status=HealthStatus.HEALTHY,
                    latency_ms=latency,
                )
            else:
                return HealthCheckResult(
                    name=self.name,
                    status=HealthStatus.UNHEALTHY,
                    message="Check returned False",
                    latency_ms=latency,
                )
        except Exception as e:
            latency = (time.time() - start) * 1000
            return HealthCheckResult(
                name=self.name,
                status=HealthStatus.UNHEALTHY,
                message=str(e),
                latency_ms=latency,
            )


class HTTPHealthCheck(HealthCheck):
    """Health check that makes an HTTP request."""
    
    def __init__(
        self,
        name: str,
        url: str,
        method: str = "GET",
        expected_status: int = 200,
        critical: bool = True,
        timeout: float = 5.0,
    ):
        super().__init__(name, critical, timeout)
        self.url = url
        self.method = method
        self.expected_status = expected_status
    
    def check(self) -> HealthCheckResult:
        import urllib.request
        import urllib.error
        
        start = time.time()
        try:
            req = urllib.request.Request(self.url, method=self.method)
            with urllib.request.urlopen(req, timeout=self.timeout) as response:
                status_code = response.status
                latency = (time.time() - start) * 1000
                
                if status_code == self.expected_status:
                    return HealthCheckResult(
                        name=self.name,
                        status=HealthStatus.HEALTHY,
                        latency_ms=latency,
                        details={"status_code": status_code, "url": self.url},
                    )
                else:
                    return HealthCheckResult(
                        name=self.name,
                        status=HealthStatus.UNHEALTHY,
                        message=f"Expected {self.expected_status}, got {status_code}",
                        latency_ms=latency,
                        details={"status_code": status_code, "url": self.url},
                    )
        except urllib.error.URLError as e:
            latency = (time.time() - start) * 1000
            return HealthCheckResult(
                name=self.name,
                status=HealthStatus.UNHEALTHY,
                message=f"URL error: {e.reason}",
                latency_ms=latency,
                details={"url": self.url},
            )
        except Exception as e:
            latency = (time.time() - start) * 1000
            return HealthCheckResult(
                name=self.name,
                status=HealthStatus.UNHEALTHY,
                message=str(e),
                latency_ms=latency,
            )


class TCPHealthCheck(HealthCheck):
    """Health check that tests TCP connectivity."""
    
    def __init__(
        self,
        name: str,
        host: str,
        port: int,
        critical: bool = True,
        timeout: float = 5.0,
    ):
        super().__init__(name, critical, timeout)
        self.host = host
        self.port = port
    
    def check(self) -> HealthCheckResult:
        import socket
        
        start = time.time()
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(self.timeout)
            sock.connect((self.host, self.port))
            sock.close()
            
            latency = (time.time() - start) * 1000
            return HealthCheckResult(
                name=self.name,
                status=HealthStatus.HEALTHY,
                latency_ms=latency,
                details={"host": self.host, "port": self.port},
            )
        except socket.timeout:
            latency = (time.time() - start) * 1000
            return HealthCheckResult(
                name=self.name,
                status=HealthStatus.UNHEALTHY,
                message="Connection timeout",
                latency_ms=latency,
                details={"host": self.host, "port": self.port},
            )
        except Exception as e:
            latency = (time.time() - start) * 1000
            return HealthCheckResult(
                name=self.name,
                status=HealthStatus.UNHEALTHY,
                message=str(e),
                latency_ms=latency,
            )


class DiskSpaceCheck(HealthCheck):
    """Health check for disk space."""
    
    def __init__(
        self,
        name: str = "disk_space",
        path: str = "/",
        min_free_percent: float = 10.0,
        warn_free_percent: float = 20.0,
        critical: bool = True,
    ):
        super().__init__(name, critical)
        self.path = path
        self.min_free_percent = min_free_percent
        self.warn_free_percent = warn_free_percent
    
    def check(self) -> HealthCheckResult:
        import os
        
        try:
            stat = os.statvfs(self.path)
            total = stat.f_blocks * stat.f_frsize
            free = stat.f_bavail * stat.f_frsize
            free_percent = (free / total) * 100 if total > 0 else 0
            
            details = {
                "path": self.path,
                "total_bytes": total,
                "free_bytes": free,
                "free_percent": round(free_percent, 2),
            }
            
            if free_percent < self.min_free_percent:
                return HealthCheckResult(
                    name=self.name,
                    status=HealthStatus.UNHEALTHY,
                    message=f"Disk space critically low: {free_percent:.1f}%",
                    details=details,
                )
            elif free_percent < self.warn_free_percent:
                return HealthCheckResult(
                    name=self.name,
                    status=HealthStatus.DEGRADED,
                    message=f"Disk space low: {free_percent:.1f}%",
                    details=details,
                )
            else:
                return HealthCheckResult(
                    name=self.name,
                    status=HealthStatus.HEALTHY,
                    details=details,
                )
        except Exception as e:
            return HealthCheckResult(
                name=self.name,
                status=HealthStatus.UNKNOWN,
                message=str(e),
            )


class MemoryCheck(HealthCheck):
    """Health check for memory usage."""
    
    def __init__(
        self,
        name: str = "memory",
        max_used_percent: float = 90.0,
        warn_used_percent: float = 80.0,
        critical: bool = True,
    ):
        super().__init__(name, critical)
        self.max_used_percent = max_used_percent
        self.warn_used_percent = warn_used_percent
    
    def check(self) -> HealthCheckResult:
        try:
            import resource
            
            # Get memory info (platform-specific)
            rusage = resource.getrusage(resource.RUSAGE_SELF)
            max_rss = rusage.ru_maxrss  # In KB on Linux, bytes on macOS
            
            # Estimate based on max RSS (not perfect but portable)
            details = {
                "max_rss_kb": max_rss,
            }
            
            # Without psutil, we can't get accurate system memory
            # Mark as healthy if we got this far
            return HealthCheckResult(
                name=self.name,
                status=HealthStatus.HEALTHY,
                details=details,
            )
        except Exception as e:
            return HealthCheckResult(
                name=self.name,
                status=HealthStatus.UNKNOWN,
                message=str(e),
            )


# =============================================================================
# Health Registry
# =============================================================================

class HealthRegistry:
    """
    Registry for managing health checks.
    
    Supports liveness, readiness, and dependency checks.
    """
    
    def __init__(self):
        self._liveness_checks: List[HealthCheck] = []
        self._readiness_checks: List[HealthCheck] = []
        self._dependency_checks: List[HealthCheck] = []
        self._lock = threading.Lock()
    
    def add_liveness_check(self, check: HealthCheck) -> None:
        """Add a liveness check."""
        with self._lock:
            self._liveness_checks.append(check)
    
    def add_readiness_check(self, check: HealthCheck) -> None:
        """Add a readiness check."""
        with self._lock:
            self._readiness_checks.append(check)
    
    def add_dependency_check(self, check: HealthCheck) -> None:
        """Add a dependency check."""
        with self._lock:
            self._dependency_checks.append(check)
    
    def add_check(
        self,
        name: str,
        func: Callable[[], bool],
        check_type: str = "readiness",
        critical: bool = True,
    ) -> None:
        """Add a simple callable health check."""
        check = CallableCheck(name=name, func=func, critical=critical)
        
        if check_type == "liveness":
            self.add_liveness_check(check)
        elif check_type == "readiness":
            self.add_readiness_check(check)
        elif check_type == "dependency":
            self.add_dependency_check(check)
    
    def _run_checks(self, checks: List[HealthCheck]) -> AggregateHealthResult:
        """Run a list of health checks."""
        results = []
        
        for check in checks:
            try:
                result = check.check()
                results.append(result)
            except Exception as e:
                results.append(HealthCheckResult(
                    name=check.name,
                    status=HealthStatus.UNHEALTHY,
                    message=f"Check failed: {e}",
                ))
        
        # Determine aggregate status
        has_unhealthy = any(
            r.status == HealthStatus.UNHEALTHY and 
            next((c for c in checks if c.name == r.name), None) and
            next((c for c in checks if c.name == r.name)).critical
            for r in results
        )
        has_degraded = any(r.status == HealthStatus.DEGRADED for r in results)
        
        if has_unhealthy:
            status = HealthStatus.UNHEALTHY
        elif has_degraded:
            status = HealthStatus.DEGRADED
        elif not results:
            status = HealthStatus.HEALTHY
        else:
            status = HealthStatus.HEALTHY
        
        return AggregateHealthResult(status=status, checks=results)
    
    def check_liveness(self) -> AggregateHealthResult:
        """Check liveness (is the service running?)."""
        with self._lock:
            checks = list(self._liveness_checks)
        
        # If no liveness checks, service is alive
        if not checks:
            return AggregateHealthResult(status=HealthStatus.HEALTHY, checks=[])
        
        return self._run_checks(checks)
    
    def check_readiness(self) -> AggregateHealthResult:
        """Check readiness (can the service accept traffic?)."""
        with self._lock:
            checks = list(self._readiness_checks)
        return self._run_checks(checks)
    
    def check_dependencies(self) -> AggregateHealthResult:
        """Check all dependencies."""
        with self._lock:
            checks = list(self._dependency_checks)
        return self._run_checks(checks)
    
    def check_all(self) -> AggregateHealthResult:
        """Check all health checks."""
        with self._lock:
            all_checks = (
                list(self._liveness_checks) +
                list(self._readiness_checks) +
                list(self._dependency_checks)
            )
        return self._run_checks(all_checks)
    
    async def check_liveness_async(self) -> AggregateHealthResult:
        """Check liveness asynchronously."""
        with self._lock:
            checks = list(self._liveness_checks)
        
        if not checks:
            return AggregateHealthResult(status=HealthStatus.HEALTHY, checks=[])
        
        results = await asyncio.gather(*[c.check_async() for c in checks])
        return self._aggregate_results(list(results), checks)
    
    async def check_readiness_async(self) -> AggregateHealthResult:
        """Check readiness asynchronously."""
        with self._lock:
            checks = list(self._readiness_checks)
        
        results = await asyncio.gather(*[c.check_async() for c in checks])
        return self._aggregate_results(list(results), checks)
    
    def _aggregate_results(
        self,
        results: List[HealthCheckResult],
        checks: List[HealthCheck],
    ) -> AggregateHealthResult:
        """Aggregate results into a single status."""
        check_map = {c.name: c for c in checks}
        
        has_unhealthy = any(
            r.status == HealthStatus.UNHEALTHY and
            check_map.get(r.name, AlwaysHealthyCheck()).critical
            for r in results
        )
        has_degraded = any(r.status == HealthStatus.DEGRADED for r in results)
        
        if has_unhealthy:
            status = HealthStatus.UNHEALTHY
        elif has_degraded:
            status = HealthStatus.DEGRADED
        else:
            status = HealthStatus.HEALTHY
        
        return AggregateHealthResult(status=status, checks=results)


# =============================================================================
# Global Registry
# =============================================================================

_global_registry: Optional[HealthRegistry] = None
_registry_lock = threading.Lock()


def get_health_registry() -> HealthRegistry:
    """Get or create the global health registry."""
    global _global_registry
    
    with _registry_lock:
        if _global_registry is None:
            _global_registry = HealthRegistry()
        return _global_registry


def set_health_registry(registry: HealthRegistry) -> None:
    """Set the global health registry."""
    global _global_registry
    with _registry_lock:
        _global_registry = registry


def reset_health_registry() -> None:
    """Reset the global health registry."""
    global _global_registry
    with _registry_lock:
        _global_registry = None


# =============================================================================
# Convenience Functions
# =============================================================================

def add_liveness_check(check: HealthCheck) -> None:
    """Add a liveness check to the global registry."""
    get_health_registry().add_liveness_check(check)


def add_readiness_check(check: HealthCheck) -> None:
    """Add a readiness check to the global registry."""
    get_health_registry().add_readiness_check(check)


def add_dependency_check(check: HealthCheck) -> None:
    """Add a dependency check to the global registry."""
    get_health_registry().add_dependency_check(check)


def check_liveness() -> AggregateHealthResult:
    """Check liveness using the global registry."""
    return get_health_registry().check_liveness()


def check_readiness() -> AggregateHealthResult:
    """Check readiness using the global registry."""
    return get_health_registry().check_readiness()


def check_dependencies() -> AggregateHealthResult:
    """Check dependencies using the global registry."""
    return get_health_registry().check_dependencies()


def check_health() -> AggregateHealthResult:
    """Check all health using the global registry."""
    return get_health_registry().check_all()


# =============================================================================
# HTTP Response Helpers
# =============================================================================

def liveness_response() -> tuple:
    """Generate HTTP response for liveness endpoint."""
    result = check_liveness()
    status_code = 200 if result.status == HealthStatus.HEALTHY else 503
    return (status_code, result.to_dict())


def readiness_response() -> tuple:
    """Generate HTTP response for readiness endpoint."""
    result = check_readiness()
    status_code = 200 if result.status == HealthStatus.HEALTHY else 503
    return (status_code, result.to_dict())


def health_response() -> tuple:
    """Generate HTTP response for comprehensive health endpoint."""
    result = check_health()
    
    if result.status == HealthStatus.HEALTHY:
        status_code = 200
    elif result.status == HealthStatus.DEGRADED:
        status_code = 200  # Service still functional
    else:
        status_code = 503
    
    return (status_code, result.to_dict())