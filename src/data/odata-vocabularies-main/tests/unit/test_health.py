"""
Unit Tests for Health Check Module

Tests comprehensive health checking functionality.
"""

import pytest
import time
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from lib.health import (
    HealthStatus, ComponentHealth, HealthCheckResult,
    HealthChecker, get_health_checker, reset_health_checker
)


class TestHealthStatus:
    """Tests for HealthStatus enum"""
    
    def test_status_values(self):
        """Test status enum values"""
        assert HealthStatus.HEALTHY.value == "healthy"
        assert HealthStatus.DEGRADED.value == "degraded"
        assert HealthStatus.UNHEALTHY.value == "unhealthy"


class TestComponentHealth:
    """Tests for ComponentHealth dataclass"""
    
    def test_basic_health(self):
        """Test basic component health"""
        health = ComponentHealth(
            name="test",
            status=HealthStatus.HEALTHY
        )
        
        assert health.name == "test"
        assert health.status == HealthStatus.HEALTHY
    
    def test_with_latency(self):
        """Test component health with latency"""
        health = ComponentHealth(
            name="test",
            status=HealthStatus.HEALTHY,
            latency_ms=15.5
        )
        
        result = health.to_dict()
        
        assert result["latency_ms"] == 15.5
    
    def test_with_message(self):
        """Test component health with message"""
        health = ComponentHealth(
            name="test",
            status=HealthStatus.DEGRADED,
            message="Service partially available"
        )
        
        result = health.to_dict()
        
        assert result["message"] == "Service partially available"
    
    def test_with_details(self):
        """Test component health with details"""
        health = ComponentHealth(
            name="vocabularies",
            status=HealthStatus.HEALTHY,
            details={"count": 19, "term_count": 398}
        )
        
        result = health.to_dict()
        
        assert result["count"] == 19
        assert result["term_count"] == 398
    
    def test_to_dict_complete(self):
        """Test complete to_dict conversion"""
        health = ComponentHealth(
            name="test",
            status=HealthStatus.HEALTHY,
            latency_ms=10.0,
            message="All good",
            details={"extra": "data"}
        )
        
        result = health.to_dict()
        
        assert result["status"] == "healthy"
        assert result["latency_ms"] == 10.0
        assert result["message"] == "All good"
        assert result["extra"] == "data"


class TestHealthCheckResult:
    """Tests for HealthCheckResult dataclass"""
    
    def test_to_dict(self):
        """Test converting result to dictionary"""
        checks = {
            "test": ComponentHealth(
                name="test",
                status=HealthStatus.HEALTHY
            )
        }
        
        result = HealthCheckResult(
            status=HealthStatus.HEALTHY,
            version="3.0.0",
            uptime_seconds=100,
            checks=checks,
            memory_mb=50.5,
            python_version="3.11.0",
            timestamp="2026-02-26T10:00:00Z"
        )
        
        d = result.to_dict()
        
        assert d["status"] == "healthy"
        assert d["version"] == "3.0.0"
        assert d["uptime_seconds"] == 100
        assert d["memory_mb"] == 50.5
        assert "checks" in d
        assert "test" in d["checks"]


class TestHealthChecker:
    """Tests for HealthChecker class"""
    
    @pytest.fixture
    def checker(self):
        """Create fresh health checker for each test"""
        reset_health_checker()
        return HealthChecker()
    
    def test_uptime(self, checker):
        """Test uptime tracking"""
        uptime = checker.get_uptime()
        assert uptime >= 0
    
    def test_memory_usage(self, checker):
        """Test memory usage reporting"""
        memory = checker.get_memory_usage()
        assert memory > 0
    
    def test_vocabularies_not_registered(self, checker):
        """Test vocabulary check when not registered"""
        result = checker.check_vocabularies()
        
        assert result.status == HealthStatus.UNHEALTHY
        assert "not loaded" in result.message
    
    def test_vocabularies_registered(self, checker):
        """Test vocabulary check when registered"""
        vocabularies = {
            f"vocab_{i}": {"terms": [f"term_{j}" for j in range(10)]}
            for i in range(19)
        }
        checker.register_vocabularies(vocabularies)
        
        result = checker.check_vocabularies()
        
        assert result.status == HealthStatus.HEALTHY
        assert result.details["count"] == 19
    
    def test_vocabularies_few_loaded(self, checker):
        """Test degraded status with few vocabularies"""
        vocabularies = {
            "vocab_1": {"terms": ["term1"]},
            "vocab_2": {"terms": ["term2"]}
        }
        checker.register_vocabularies(vocabularies)
        
        result = checker.check_vocabularies()
        
        assert result.status == HealthStatus.DEGRADED
    
    def test_embeddings_not_registered(self, checker):
        """Test embeddings check when not registered"""
        result = checker.check_embeddings()
        
        assert result.status == HealthStatus.DEGRADED
        assert "not loaded" in result.message
    
    def test_embeddings_registered(self, checker):
        """Test embeddings check when registered"""
        embeddings = {
            "term1": [0.1, 0.2, 0.3],
            "term2": [0.4, 0.5, 0.6]
        }
        checker.register_embeddings(embeddings)
        
        result = checker.check_embeddings()
        
        assert result.status == HealthStatus.HEALTHY
        assert result.details["count"] == 2
        assert result.details["has_vectors"] == True
    
    def test_embeddings_empty(self, checker):
        """Test degraded status with empty embeddings"""
        checker.register_embeddings({})
        
        result = checker.check_embeddings()
        
        assert result.status == HealthStatus.DEGRADED
    
    def test_hana_not_configured(self, checker):
        """Test HANA check when not configured"""
        result = checker.check_hana()
        
        assert result.status == HealthStatus.DEGRADED
        assert "not configured" in result.message
    
    def test_elasticsearch_not_configured(self, checker):
        """Test Elasticsearch check when not configured"""
        result = checker.check_elasticsearch()
        
        assert result.status == HealthStatus.DEGRADED
        assert "not configured" in result.message
    
    def test_auth_not_configured(self, checker):
        """Test auth check when not configured (should be healthy)"""
        result = checker.check_auth()
        
        assert result.status == HealthStatus.HEALTHY
    
    def test_run_all_checks(self, checker):
        """Test running all health checks"""
        # Register some components
        vocabularies = {f"vocab_{i}": {"terms": []} for i in range(19)}
        checker.register_vocabularies(vocabularies)
        
        result = checker.run_all_checks(use_cache=False)
        
        assert result.version == "3.0.0"
        assert "vocabularies" in result.checks
        assert "embeddings" in result.checks
        assert "hana" in result.checks
        assert "elasticsearch" in result.checks
        assert "auth" in result.checks
    
    def test_overall_status_healthy(self, checker):
        """Test overall status when all healthy"""
        vocabularies = {f"vocab_{i}": {"terms": []} for i in range(19)}
        checker.register_vocabularies(vocabularies)
        embeddings = {"term1": [0.1]}
        checker.register_embeddings(embeddings)
        
        result = checker.run_all_checks(use_cache=False)
        
        # Should be degraded due to HANA/ES not configured
        assert result.status in [HealthStatus.HEALTHY, HealthStatus.DEGRADED]
    
    def test_overall_status_unhealthy(self, checker):
        """Test overall status when component unhealthy"""
        # No vocabularies registered
        result = checker.run_all_checks(use_cache=False)
        
        assert result.status == HealthStatus.UNHEALTHY
    
    def test_cache_behavior(self, checker):
        """Test health check result caching"""
        vocabularies = {f"vocab_{i}": {"terms": []} for i in range(19)}
        checker.register_vocabularies(vocabularies)
        
        # First call
        result1 = checker.run_all_checks(use_cache=True)
        time1 = result1.timestamp
        
        # Immediate second call should return cached
        result2 = checker.run_all_checks(use_cache=True)
        time2 = result2.timestamp
        
        assert time1 == time2  # Same cached result
    
    def test_liveness(self, checker):
        """Test liveness probe"""
        result = checker.get_liveness()
        
        assert result["status"] == "alive"
        assert "uptime_seconds" in result
    
    def test_readiness_ready(self, checker):
        """Test readiness probe when ready"""
        vocabularies = {f"vocab_{i}": {"terms": []} for i in range(19)}
        checker.register_vocabularies(vocabularies)
        
        result = checker.get_readiness()
        
        assert result["status"] == "ready"
        assert result["vocabularies"] == 19
    
    def test_readiness_not_ready(self, checker):
        """Test readiness probe when not ready"""
        result = checker.get_readiness()
        
        assert result["status"] == "not_ready"


class TestGlobalHealthChecker:
    """Tests for global health checker functions"""
    
    def test_get_health_checker_singleton(self):
        """Test singleton pattern"""
        reset_health_checker()
        
        checker1 = get_health_checker()
        checker2 = get_health_checker()
        
        assert checker1 is checker2
    
    def test_reset_health_checker(self):
        """Test resetting health checker"""
        checker1 = get_health_checker()
        reset_health_checker()
        checker2 = get_health_checker()
        
        assert checker1 is not checker2