# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Observability module for Data Cleaning Copilot.

Provides:
- Prometheus metrics collection
- Structured logging configuration
- Request tracing
- Health check utilities
"""

import os
import sys
import time
import functools
from typing import Any, Callable, Dict, Optional
from contextlib import contextmanager
from datetime import datetime, timezone
from loguru import logger

# =============================================================================
# Prometheus Metrics (optional dependency)
# =============================================================================

_PROMETHEUS_AVAILABLE = False
_metrics_registry = None

try:
    from prometheus_client import (
        Counter,
        Histogram,
        Gauge,
        Info,
        CollectorRegistry,
        generate_latest,
        CONTENT_TYPE_LATEST,
    )

    _PROMETHEUS_AVAILABLE = True
    _metrics_registry = CollectorRegistry()

    # Define metrics
    REQUESTS_TOTAL = Counter(
        "dcc_requests_total",
        "Total number of requests processed",
        ["service", "method", "status"],
        registry=_metrics_registry,
    )

    REQUEST_LATENCY = Histogram(
        "dcc_request_latency_seconds",
        "Request latency in seconds",
        ["service", "method"],
        buckets=(0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0),
        registry=_metrics_registry,
    )

    CHECKS_GENERATED = Counter(
        "dcc_checks_generated_total",
        "Total number of validation checks generated",
        ["database", "agent_version"],
        registry=_metrics_registry,
    )

    CHECKS_EXECUTED = Counter(
        "dcc_checks_executed_total",
        "Total number of validation checks executed",
        ["database", "status"],
        registry=_metrics_registry,
    )

    VIOLATIONS_FOUND = Counter(
        "dcc_violations_found_total",
        "Total number of data violations found",
        ["database", "table", "check_type"],
        registry=_metrics_registry,
    )

    LLM_CALLS = Counter(
        "dcc_llm_calls_total",
        "Total number of LLM API calls",
        ["provider", "model", "status"],
        registry=_metrics_registry,
    )

    LLM_LATENCY = Histogram(
        "dcc_llm_latency_seconds",
        "LLM API call latency in seconds",
        ["provider", "model"],
        buckets=(0.5, 1.0, 2.0, 5.0, 10.0, 30.0, 60.0, 120.0),
        registry=_metrics_registry,
    )

    LLM_TOKENS = Counter(
        "dcc_llm_tokens_total",
        "Total tokens consumed by LLM calls",
        ["provider", "model", "direction"],  # direction: input/output
        registry=_metrics_registry,
    )

    SANDBOX_EXECUTIONS = Counter(
        "dcc_sandbox_executions_total",
        "Total sandbox code executions",
        ["outcome"],  # success, blocked, timeout, error
        registry=_metrics_registry,
    )

    SANDBOX_LATENCY = Histogram(
        "dcc_sandbox_latency_seconds",
        "Sandbox execution latency in seconds",
        buckets=(0.1, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0),
        registry=_metrics_registry,
    )

    ACTIVE_SESSIONS = Gauge(
        "dcc_active_sessions",
        "Number of active copilot sessions",
        registry=_metrics_registry,
    )

    BUILD_INFO = Info(
        "dcc_build",
        "Build information",
        registry=_metrics_registry,
    )

    # Set build info
    BUILD_INFO.info(
        {
            "version": os.environ.get("DCC_VERSION", "0.1.0"),
            "python_version": f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
        }
    )

    logger.info("Prometheus metrics enabled")

except ImportError:
    logger.debug("prometheus_client not installed; metrics collection disabled")


def metrics_available() -> bool:
    """Check if Prometheus metrics are available."""
    return _PROMETHEUS_AVAILABLE


def get_metrics() -> bytes:
    """Generate Prometheus metrics output."""
    if not _PROMETHEUS_AVAILABLE:
        return b"# Prometheus metrics not available\n"
    return generate_latest(_metrics_registry)


def get_metrics_content_type() -> str:
    """Get the content type for Prometheus metrics."""
    if not _PROMETHEUS_AVAILABLE:
        return "text/plain"
    return CONTENT_TYPE_LATEST


# =============================================================================
# Metric Recording Helpers
# =============================================================================


def record_request(service: str, method: str, status: str, latency: float) -> None:
    """Record a request metric."""
    if not _PROMETHEUS_AVAILABLE:
        return
    REQUESTS_TOTAL.labels(service=service, method=method, status=status).inc()
    REQUEST_LATENCY.labels(service=service, method=method).observe(latency)


def record_check_generated(database: str, agent_version: str, count: int = 1) -> None:
    """Record check generation metric."""
    if not _PROMETHEUS_AVAILABLE:
        return
    CHECKS_GENERATED.labels(database=database, agent_version=agent_version).inc(count)


def record_check_executed(database: str, status: str) -> None:
    """Record check execution metric."""
    if not _PROMETHEUS_AVAILABLE:
        return
    CHECKS_EXECUTED.labels(database=database, status=status).inc()


def record_violation(database: str, table: str, check_type: str, count: int = 1) -> None:
    """Record violation metric."""
    if not _PROMETHEUS_AVAILABLE:
        return
    VIOLATIONS_FOUND.labels(database=database, table=table, check_type=check_type).inc(count)


def record_llm_call(
    provider: str,
    model: str,
    status: str,
    latency: float,
    input_tokens: int = 0,
    output_tokens: int = 0,
) -> None:
    """Record LLM API call metric."""
    if not _PROMETHEUS_AVAILABLE:
        return
    LLM_CALLS.labels(provider=provider, model=model, status=status).inc()
    LLM_LATENCY.labels(provider=provider, model=model).observe(latency)
    if input_tokens > 0:
        LLM_TOKENS.labels(provider=provider, model=model, direction="input").inc(input_tokens)
    if output_tokens > 0:
        LLM_TOKENS.labels(provider=provider, model=model, direction="output").inc(output_tokens)


def record_sandbox_execution(outcome: str, latency: float) -> None:
    """Record sandbox execution metric."""
    if not _PROMETHEUS_AVAILABLE:
        return
    SANDBOX_EXECUTIONS.labels(outcome=outcome).inc()
    SANDBOX_LATENCY.observe(latency)


def set_active_sessions(count: int) -> None:
    """Set active sessions gauge."""
    if not _PROMETHEUS_AVAILABLE:
        return
    ACTIVE_SESSIONS.set(count)


@contextmanager
def track_request(service: str, method: str):
    """Context manager to track request latency and status."""
    start_time = time.monotonic()
    status = "success"
    try:
        yield
    except Exception:
        status = "error"
        raise
    finally:
        latency = time.monotonic() - start_time
        record_request(service, method, status, latency)


def track_latency(service: str, method: str):
    """Decorator to track function latency."""

    def decorator(func: Callable) -> Callable:
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            with track_request(service, method):
                return func(*args, **kwargs)

        return wrapper

    return decorator


# =============================================================================
# Structured Logging Configuration
# =============================================================================


def configure_logging(
    level: str = "INFO",
    json_format: bool = False,
    include_context: bool = True,
) -> None:
    """
    Configure structured logging for the application.

    Parameters
    ----------
    level : str
        Log level (DEBUG, INFO, WARNING, ERROR, CRITICAL)
    json_format : bool
        If True, output logs in JSON format (recommended for production)
    include_context : bool
        If True, include additional context in log messages
    """
    # Remove default handler
    logger.remove()

    # Determine format based on environment
    if json_format or os.environ.get("LOG_FORMAT") == "json":
        # JSON format for production/cloud logging
        logger.add(
            sys.stdout,
            format="{message}",
            level=level.upper(),
            serialize=True,
        )
    else:
        # Human-readable format for development
        format_str = (
            "<green>{time:YYYY-MM-DD HH:mm:ss.SSS}</green> | "
            "<level>{level: <8}</level> | "
            "<cyan>{name}</cyan>:<cyan>{function}</cyan>:<cyan>{line}</cyan> | "
            "<level>{message}</level>"
        )
        if include_context:
            format_str += " | {extra}"

        logger.add(
            sys.stdout,
            format=format_str,
            level=level.upper(),
            colorize=True,
        )

    # Also log to file if configured
    log_file = os.environ.get("LOG_FILE")
    if log_file:
        logger.add(
            log_file,
            rotation="100 MB",
            retention="7 days",
            compression="gz",
            level=level.upper(),
            serialize=json_format,
        )

    logger.info(
        f"Logging configured: level={level}, json={json_format}, "
        f"metrics={'enabled' if _PROMETHEUS_AVAILABLE else 'disabled'}"
    )


def get_request_logger(request_id: Optional[str] = None, **context):
    """
    Get a logger with request context bound.

    Parameters
    ----------
    request_id : Optional[str]
        Unique request identifier
    **context
        Additional context to bind to the logger

    Returns
    -------
    Logger with bound context
    """
    ctx = {"request_id": request_id} if request_id else {}
    ctx.update(context)
    return logger.bind(**ctx)


# =============================================================================
# Health Check Utilities
# =============================================================================


class HealthStatus:
    """Health check status container."""

    def __init__(self):
        self.checks: Dict[str, Dict[str, Any]] = {}

    def add_check(self, name: str, healthy: bool, message: str = "", details: Optional[Dict] = None) -> None:
        """Add a health check result."""
        self.checks[name] = {
            "healthy": healthy,
            "message": message,
            "details": details or {},
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }

    def is_healthy(self) -> bool:
        """Return True if all checks are healthy."""
        return all(check["healthy"] for check in self.checks.values())

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "status": "healthy" if self.is_healthy() else "unhealthy",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "checks": self.checks,
        }


def check_database_health(database: Any) -> tuple[bool, str]:
    """Check if database is accessible and has data."""
    try:
        tables = list(database.table_data.keys()) if hasattr(database, "table_data") else []
        if not tables:
            return False, "No tables loaded"
        return True, f"{len(tables)} tables loaded"
    except Exception as e:
        return False, str(e)


def check_llm_health(session_manager: Any) -> tuple[bool, str]:
    """Check if LLM service is accessible."""
    try:
        if session_manager is None:
            return False, "Session manager not initialized"
        # Basic check - more detailed health check would require actual API call
        return True, "Session manager available"
    except Exception as e:
        return False, str(e)


def check_mcp_health(mcp_endpoint: str) -> tuple[bool, str]:
    """Check if MCP server is accessible."""
    try:
        import urllib.request

        req = urllib.request.Request(
            f"{mcp_endpoint.rstrip('/')}/health",
            method="GET",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            if resp.status == 200:
                return True, "MCP server healthy"
            return False, f"MCP server returned status {resp.status}"
    except Exception as e:
        return False, str(e)


def get_health_status(
    database: Optional[Any] = None,
    session_manager: Optional[Any] = None,
    mcp_endpoint: Optional[str] = None,
) -> HealthStatus:
    """
    Perform comprehensive health check.

    Parameters
    ----------
    database : Optional[Any]
        Database instance to check
    session_manager : Optional[Any]
        LLM session manager to check
    mcp_endpoint : Optional[str]
        MCP server endpoint to check

    Returns
    -------
    HealthStatus with all check results
    """
    status = HealthStatus()

    # Database health
    if database is not None:
        healthy, message = check_database_health(database)
        status.add_check("database", healthy, message)

    # LLM health
    if session_manager is not None:
        healthy, message = check_llm_health(session_manager)
        status.add_check("llm", healthy, message)

    # MCP health
    if mcp_endpoint:
        healthy, message = check_mcp_health(mcp_endpoint)
        status.add_check("mcp", healthy, message)

    # Metrics health
    status.add_check(
        "metrics",
        True,
        "enabled" if _PROMETHEUS_AVAILABLE else "disabled (prometheus_client not installed)",
    )

    return status