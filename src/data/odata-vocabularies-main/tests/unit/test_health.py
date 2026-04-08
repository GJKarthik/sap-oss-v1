"""
Unit tests for the health-check module.
"""

import time
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from lib.health import (
    ComponentHealth,
    HealthCheckResult,
    HealthChecker,
    HealthStatus,
    get_health_checker,
    reset_health_checker,
)


class DummyStatsSource:
    """Simple test double for connector and middleware stats."""

    def __init__(self, stats):
        self._stats = stats

    def get_stats(self):
        return self._stats


class TestHealthStatus:
    """Tests for HealthStatus enum."""

    def test_status_values(self):
        assert HealthStatus.HEALTHY.value == "healthy"
        assert HealthStatus.DEGRADED.value == "degraded"
        assert HealthStatus.UNHEALTHY.value == "unhealthy"


class TestComponentHealth:
    """Tests for ComponentHealth dataclass."""

    def test_basic_health(self):
        health = ComponentHealth(name="test", status=HealthStatus.HEALTHY)

        assert health.name == "test"
        assert health.status == HealthStatus.HEALTHY

    def test_with_latency(self):
        health = ComponentHealth(name="test", status=HealthStatus.HEALTHY, latency_ms=15.5)
        result = health.to_dict()
        assert result["latency_ms"] == 15.5

    def test_with_message(self):
        health = ComponentHealth(
            name="test",
            status=HealthStatus.DEGRADED,
            message="Service partially available",
        )
        result = health.to_dict()
        assert result["message"] == "Service partially available"

    def test_with_details(self):
        health = ComponentHealth(
            name="vocabularies",
            status=HealthStatus.HEALTHY,
            details={"count": 19, "term_count": 398},
        )
        result = health.to_dict()
        assert result["count"] == 19
        assert result["term_count"] == 398


class TestHealthCheckResult:
    """Tests for HealthCheckResult dataclass."""

    def test_to_dict(self):
        checks = {
            "test": ComponentHealth(name="test", status=HealthStatus.HEALTHY),
        }

        result = HealthCheckResult(
            status=HealthStatus.HEALTHY,
            version="3.0.0",
            uptime_seconds=100,
            checks=checks,
            memory_mb=50.5,
            python_version="3.11.0",
            timestamp="2026-02-26T10:00:00Z",
        )

        data = result.to_dict()

        assert data["status"] == "healthy"
        assert data["version"] == "3.0.0"
        assert data["uptime_seconds"] == 100
        assert data["memory_mb"] == 50.5
        assert "checks" in data
        assert "test" in data["checks"]


class TestHealthChecker:
    """Tests for HealthChecker."""

    @pytest.fixture
    def checker(self):
        reset_health_checker()
        return HealthChecker()

    def test_uptime(self, checker):
        assert checker.get_uptime() >= 0

    def test_memory_usage(self, checker):
        assert checker.get_memory_usage() > 0

    def test_vocabularies_not_registered(self, checker):
        result = checker.check_vocabularies()
        assert result.status == HealthStatus.UNHEALTHY
        assert "not loaded" in result.message

    def test_vocabularies_registered(self, checker):
        vocabularies = {
            f"vocab_{i}": {"terms": [f"term_{j}" for j in range(10)]}
            for i in range(19)
        }
        checker.register_vocabularies(vocabularies)

        result = checker.check_vocabularies()

        assert result.status == HealthStatus.HEALTHY
        assert result.details["count"] == 19

    def test_embeddings_not_registered(self, checker):
        result = checker.check_embeddings()
        assert result.status == HealthStatus.DEGRADED
        assert "not loaded" in result.message

    def test_embeddings_registered(self, checker):
        checker.register_embeddings({"term1": [0.1, 0.2, 0.3], "term2": [0.4, 0.5, 0.6]})

        result = checker.check_embeddings()

        assert result.status == HealthStatus.HEALTHY
        assert result.details["count"] == 2
        assert result.details["has_vectors"] is True

    def test_hana_not_configured(self, checker):
        result = checker.check_hana()

        assert result.status == HealthStatus.DEGRADED
        assert "not configured" in result.message

    def test_hana_healthy(self, checker):
        checker.register_hana(
            DummyStatsSource(
                {
                    "connected": True,
                    "circuit_breaker_state": "closed",
                    "total_connections": 1,
                }
            )
        )

        result = checker.check_hana()

        assert result.status == HealthStatus.HEALTHY
        assert result.details["connected"] is True

    def test_hana_vector_not_configured(self, checker):
        result = checker.check_hana_vector()

        assert result.status == HealthStatus.DEGRADED
        assert "not configured" in result.message

    def test_hana_vector_degraded_when_disconnected(self, checker):
        checker.register_hana_vector(
            DummyStatsSource(
                {
                    "connected": False,
                    "total_requests": 0,
                    "table_prefix": "ODATA",
                }
            )
        )

        result = checker.check_hana_vector()

        assert result.status == HealthStatus.DEGRADED
        assert "not connected" in result.message

    def test_hana_vector_healthy(self, checker):
        checker.register_hana_vector(
            DummyStatsSource(
                {
                    "connected": True,
                    "schema": "VECTOR",
                    "table_prefix": "ODATA",
                    "total_requests": 5,
                }
            )
        )

        result = checker.check_hana_vector()

        assert result.status == HealthStatus.HEALTHY
        assert result.details["schema"] == "VECTOR"

    def test_auth_not_configured(self, checker):
        result = checker.check_auth()
        assert result.status == HealthStatus.HEALTHY

    def test_run_all_checks(self, checker):
        checker.register_vocabularies({f"vocab_{i}": {"terms": []} for i in range(19)})

        result = checker.run_all_checks(use_cache=False)

        assert result.version == "3.0.0"
        assert "vocabularies" in result.checks
        assert "embeddings" in result.checks
        assert "hana" in result.checks
        assert "hana_vector" in result.checks
        assert "auth" in result.checks

    def test_overall_status_unhealthy(self, checker):
        result = checker.run_all_checks(use_cache=False)
        assert result.status == HealthStatus.UNHEALTHY

    def test_cache_behavior(self, checker):
        checker.register_vocabularies({f"vocab_{i}": {"terms": []} for i in range(19)})

        result1 = checker.run_all_checks(use_cache=True)
        result2 = checker.run_all_checks(use_cache=True)

        assert result1.timestamp == result2.timestamp

    def test_liveness(self, checker):
        result = checker.get_liveness()

        assert result["status"] == "alive"
        assert "uptime_seconds" in result

    def test_readiness_ready(self, checker):
        checker.register_vocabularies({f"vocab_{i}": {"terms": []} for i in range(19)})

        result = checker.get_readiness()

        assert result["status"] == "ready"
        assert result["vocabularies"] == 19

    def test_readiness_not_ready(self, checker):
        result = checker.get_readiness()
        assert result["status"] == "not_ready"


class TestGlobalHealthChecker:
    """Tests for global health-checker helpers."""

    def test_get_health_checker_singleton(self):
        reset_health_checker()

        checker1 = get_health_checker()
        checker2 = get_health_checker()

        assert checker1 is checker2

    def test_reset_health_checker(self):
        checker1 = get_health_checker()
        reset_health_checker()
        checker2 = get_health_checker()

        assert checker1 is not checker2
