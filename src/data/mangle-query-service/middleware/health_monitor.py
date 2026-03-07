"""
Connection Health Monitoring.

Implements Enhancement 4.2: Connection Health Monitoring
- Periodic health checks for HANA and ES connections
- Connection pool metrics
- Automatic reconnection on failures

This enables proactive issue detection and faster recovery.
"""

import asyncio
import logging
import os
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

# Configuration
HEALTH_CHECK_INTERVAL = float(os.getenv("HEALTH_CHECK_INTERVAL_SECONDS", "30.0"))
HEALTH_CHECK_TIMEOUT = float(os.getenv("HEALTH_CHECK_TIMEOUT_SECONDS", "5.0"))
UNHEALTHY_THRESHOLD = int(os.getenv("HEALTH_UNHEALTHY_THRESHOLD", "3"))
RECOVERY_CHECK_INTERVAL = float(os.getenv("HEALTH_RECOVERY_INTERVAL_SECONDS", "10.0"))


class HealthStatus(Enum):
    """Health status levels."""
    HEALTHY = "healthy"
    DEGRADED = "degraded"
    UNHEALTHY = "unhealthy"
    UNKNOWN = "unknown"


@dataclass
class ServiceHealth:
    """Health status for a single service."""
    name: str
    status: HealthStatus = HealthStatus.UNKNOWN
    last_check: Optional[float] = None
    last_healthy: Optional[float] = None
    consecutive_failures: int = 0
    consecutive_successes: int = 0
    latency_ms: float = 0.0
    error_message: Optional[str] = None
    details: Dict[str, Any] = field(default_factory=dict)


@dataclass
class PoolMetrics:
    """Connection pool metrics."""
    total_connections: int = 0
    active_connections: int = 0
    idle_connections: int = 0
    waiting_requests: int = 0
    max_pool_size: int = 10
    avg_acquisition_time_ms: float = 0.0


class HealthChecker:
    """
    Health checker for a single service.
    
    Performs periodic health checks and tracks status history.
    """
    
    def __init__(
        self,
        name: str,
        check_fn: Callable[[], bool],
        timeout: float = HEALTH_CHECK_TIMEOUT,
        unhealthy_threshold: int = UNHEALTHY_THRESHOLD,
    ):
        self.name = name
        self.check_fn = check_fn
        self.timeout = timeout
        self.unhealthy_threshold = unhealthy_threshold
        
        self._health = ServiceHealth(name=name)
        self._lock = asyncio.Lock()
    
    async def check(self) -> ServiceHealth:
        """Perform health check and return status."""
        start_time = time.time()
        
        try:
            # Run check with timeout
            if asyncio.iscoroutinefunction(self.check_fn):
                result = await asyncio.wait_for(
                    self.check_fn(),
                    timeout=self.timeout
                )
            else:
                result = await asyncio.wait_for(
                    asyncio.to_thread(self.check_fn),
                    timeout=self.timeout
                )
            
            latency_ms = (time.time() - start_time) * 1000
            
            async with self._lock:
                self._health.last_check = time.time()
                self._health.latency_ms = latency_ms
                
                if result:
                    self._health.consecutive_successes += 1
                    self._health.consecutive_failures = 0
                    self._health.last_healthy = time.time()
                    self._health.error_message = None
                    
                    # Determine status based on latency
                    if latency_ms < 100:
                        self._health.status = HealthStatus.HEALTHY
                    elif latency_ms < 500:
                        self._health.status = HealthStatus.DEGRADED
                    else:
                        self._health.status = HealthStatus.DEGRADED
                else:
                    await self._record_failure("Check returned false")
                    
        except asyncio.TimeoutError:
            async with self._lock:
                await self._record_failure(f"Timeout after {self.timeout}s")
                
        except Exception as e:
            async with self._lock:
                await self._record_failure(str(e))
        
        return self._health
    
    async def _record_failure(self, error: str) -> None:
        """Record a health check failure."""
        self._health.consecutive_failures += 1
        self._health.consecutive_successes = 0
        self._health.error_message = error
        self._health.last_check = time.time()
        
        if self._health.consecutive_failures >= self.unhealthy_threshold:
            self._health.status = HealthStatus.UNHEALTHY
        else:
            self._health.status = HealthStatus.DEGRADED
        
        logger.warning(
            f"Health check failed for {self.name}: {error} "
            f"(failures: {self._health.consecutive_failures})"
        )
    
    def get_health(self) -> ServiceHealth:
        """Get current health status."""
        return self._health


class HealthMonitor:
    """
    Health monitor for all services.
    
    Coordinates health checks across HANA, Elasticsearch, and other services.
    Provides aggregate health status and triggers alerts.
    """
    
    def __init__(
        self,
        check_interval: float = HEALTH_CHECK_INTERVAL,
        recovery_interval: float = RECOVERY_CHECK_INTERVAL,
    ):
        self.check_interval = check_interval
        self.recovery_interval = recovery_interval
        
        self._checkers: Dict[str, HealthChecker] = {}
        self._pool_metrics: Dict[str, PoolMetrics] = {}
        self._running = False
        self._task: Optional[asyncio.Task] = None
        
        # Callbacks
        self._on_health_change: List[Callable[[str, HealthStatus, HealthStatus], None]] = []
        self._on_unhealthy: List[Callable[[str, str], None]] = []
        self._on_recovered: List[Callable[[str], None]] = []
    
    def register_service(
        self,
        name: str,
        check_fn: Callable[[], bool],
        **kwargs,
    ) -> None:
        """Register a service for health monitoring."""
        self._checkers[name] = HealthChecker(name=name, check_fn=check_fn, **kwargs)
        logger.info(f"Registered health checker for {name}")
    
    def on_health_change(
        self,
        callback: Callable[[str, HealthStatus, HealthStatus], None],
    ) -> None:
        """Register callback for health status changes."""
        self._on_health_change.append(callback)
    
    def on_unhealthy(
        self,
        callback: Callable[[str, str], None],
    ) -> None:
        """Register callback when service becomes unhealthy."""
        self._on_unhealthy.append(callback)
    
    def on_recovered(
        self,
        callback: Callable[[str], None],
    ) -> None:
        """Register callback when service recovers."""
        self._on_recovered.append(callback)
    
    async def start(self) -> None:
        """Start the health monitoring loop."""
        if self._running:
            return
        
        self._running = True
        self._task = asyncio.create_task(self._monitor_loop())
        logger.info(f"Health monitor started (interval: {self.check_interval}s)")
    
    async def stop(self) -> None:
        """Stop the health monitoring loop."""
        self._running = False
        
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass
        
        logger.info("Health monitor stopped")
    
    async def _monitor_loop(self) -> None:
        """Main monitoring loop."""
        while self._running:
            try:
                await self._check_all()
                
                # Use shorter interval if any service is unhealthy
                if any(
                    c.get_health().status == HealthStatus.UNHEALTHY
                    for c in self._checkers.values()
                ):
                    await asyncio.sleep(self.recovery_interval)
                else:
                    await asyncio.sleep(self.check_interval)
                    
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.error(f"Health monitor error: {e}")
                await asyncio.sleep(self.check_interval)
    
    async def _check_all(self) -> None:
        """Check health of all registered services."""
        for name, checker in self._checkers.items():
            old_status = checker.get_health().status
            
            await checker.check()
            
            new_status = checker.get_health().status
            
            # Trigger callbacks on status change
            if old_status != new_status:
                for callback in self._on_health_change:
                    try:
                        callback(name, old_status, new_status)
                    except Exception as e:
                        logger.error(f"Health change callback error: {e}")
                
                # Specific callbacks
                if new_status == HealthStatus.UNHEALTHY:
                    error = checker.get_health().error_message or "Unknown"
                    for callback in self._on_unhealthy:
                        try:
                            callback(name, error)
                        except Exception:
                            pass
                
                elif old_status == HealthStatus.UNHEALTHY and new_status in [
                    HealthStatus.HEALTHY,
                    HealthStatus.DEGRADED,
                ]:
                    for callback in self._on_recovered:
                        try:
                            callback(name)
                        except Exception:
                            pass
    
    async def check_now(self, service_name: Optional[str] = None) -> Dict[str, ServiceHealth]:
        """Perform immediate health check."""
        if service_name:
            if service_name in self._checkers:
                await self._checkers[service_name].check()
                return {service_name: self._checkers[service_name].get_health()}
            return {}
        
        await self._check_all()
        return self.get_all_health()
    
    def get_health(self, service_name: str) -> Optional[ServiceHealth]:
        """Get health status for a specific service."""
        if service_name in self._checkers:
            return self._checkers[service_name].get_health()
        return None
    
    def get_all_health(self) -> Dict[str, ServiceHealth]:
        """Get health status for all services."""
        return {
            name: checker.get_health()
            for name, checker in self._checkers.items()
        }
    
    def get_aggregate_status(self) -> HealthStatus:
        """Get aggregate health status across all services."""
        if not self._checkers:
            return HealthStatus.UNKNOWN
        
        statuses = [c.get_health().status for c in self._checkers.values()]
        
        if any(s == HealthStatus.UNHEALTHY for s in statuses):
            return HealthStatus.UNHEALTHY
        
        if any(s == HealthStatus.DEGRADED for s in statuses):
            return HealthStatus.DEGRADED
        
        if any(s == HealthStatus.UNKNOWN for s in statuses):
            return HealthStatus.DEGRADED
        
        return HealthStatus.HEALTHY
    
    def update_pool_metrics(self, service_name: str, metrics: PoolMetrics) -> None:
        """Update connection pool metrics for a service."""
        self._pool_metrics[service_name] = metrics
    
    def get_pool_metrics(self, service_name: str) -> Optional[PoolMetrics]:
        """Get pool metrics for a service."""
        return self._pool_metrics.get(service_name)
    
    def get_summary(self) -> Dict[str, Any]:
        """Get health monitoring summary."""
        health_data = self.get_all_health()
        
        return {
            "aggregate_status": self.get_aggregate_status().value,
            "services": {
                name: {
                    "status": h.status.value,
                    "latency_ms": h.latency_ms,
                    "last_check_ago_seconds": (
                        time.time() - h.last_check if h.last_check else None
                    ),
                    "last_healthy_ago_seconds": (
                        time.time() - h.last_healthy if h.last_healthy else None
                    ),
                    "consecutive_failures": h.consecutive_failures,
                    "error": h.error_message,
                }
                for name, h in health_data.items()
            },
            "pool_metrics": {
                name: {
                    "total": m.total_connections,
                    "active": m.active_connections,
                    "idle": m.idle_connections,
                    "waiting": m.waiting_requests,
                    "utilization": m.active_connections / m.max_pool_size if m.max_pool_size > 0 else 0,
                }
                for name, m in self._pool_metrics.items()
            },
            "config": {
                "check_interval_seconds": self.check_interval,
                "recovery_interval_seconds": self.recovery_interval,
            }
        }


# Singleton instance
_monitor: Optional[HealthMonitor] = None
_monitor_lock = asyncio.Lock()


async def get_health_monitor() -> HealthMonitor:
    """Get or create the health monitor singleton."""
    global _monitor
    
    async with _monitor_lock:
        if _monitor is None:
            _monitor = HealthMonitor()
            logger.info("Initialized health monitor")
        return _monitor


async def setup_default_health_checks() -> HealthMonitor:
    """Set up default health checks for HANA and ES."""
    monitor = await get_health_monitor()
    
    # HANA health check
    async def hana_check():
        try:
            from connectors.langchain_hana_bridge import get_bridge
            bridge = get_bridge()
            return await bridge.health_check()
        except Exception as e:
            logger.debug(f"HANA health check failed: {e}")
            return False
    
    monitor.register_service("hana", hana_check)
    
    # Elasticsearch health check
    async def es_check():
        try:
            import httpx
            es_url = os.getenv("ES_URL", "http://localhost:9200")
            async with httpx.AsyncClient() as client:
                response = await client.get(f"{es_url}/_cluster/health", timeout=5.0)
                data = response.json()
                return data.get("status") in ["green", "yellow"]
        except Exception as e:
            logger.debug(f"ES health check failed: {e}")
            return False
    
    monitor.register_service("elasticsearch", es_check)
    
    # Start monitoring
    await monitor.start()
    
    return monitor