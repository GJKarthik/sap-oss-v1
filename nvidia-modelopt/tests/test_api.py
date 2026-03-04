#!/usr/bin/env python3
"""
Unit tests for Model Optimizer API
"""

import pytest
import sys
import os
from datetime import datetime
from unittest.mock import patch, MagicMock

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi.testclient import TestClient


class TestHealthEndpoints:
    """Test health and root endpoints"""
    
    @pytest.fixture
    def client(self):
        from api.main import app
        return TestClient(app)
    
    def test_root_endpoint(self, client):
        """Test root endpoint returns service info"""
        response = client.get("/")
        assert response.status_code == 200
        data = response.json()
        assert data["service"] == "model-optimizer"
        assert data["version"] == "1.0.0"
        assert data["status"] == "healthy"
    
    def test_health_endpoint(self, client):
        """Test health endpoint"""
        response = client.get("/health")
        assert response.status_code == 200
        data = response.json()
        assert data["status"] == "healthy"


class TestOpenAICompatEndpoints:
    """Test OpenAI-compatible endpoints"""
    
    @pytest.fixture
    def client(self):
        from api.main import app
        return TestClient(app)
    
    def test_list_models(self, client):
        """Test /v1/models endpoint"""
        response = client.get("/v1/models")
        assert response.status_code == 200
        data = response.json()
        assert data["object"] == "list"
        assert isinstance(data["data"], list)
        assert len(data["data"]) > 0
        # Check model structure
        model = data["data"][0]
        assert "id" in model
        assert "object" in model
        assert model["object"] == "model"
        assert "created" in model
        assert "owned_by" in model
    
    def test_get_model(self, client):
        """Test /v1/models/{model_id} endpoint"""
        response = client.get("/v1/models/qwen3.5-1.8b-int8")
        assert response.status_code == 200
        data = response.json()
        assert data["id"] == "qwen3.5-1.8b-int8"
        assert data["object"] == "model"
    
    def test_get_model_not_found(self, client):
        """Test /v1/models/{model_id} with invalid model"""
        response = client.get("/v1/models/nonexistent-model")
        assert response.status_code == 404


class TestJobEndpoints:
    """Test job management endpoints"""
    
    @pytest.fixture
    def client(self):
        from api.main import app
        return TestClient(app)
    
    def test_create_job(self, client):
        """Test creating a new job"""
        job_config = {
            "config": {
                "model_name": "Qwen/Qwen3.5-1.8B",
                "quant_format": "int8",
                "calib_samples": 512,
                "export_format": "hf"
            }
        }
        response = client.post("/jobs", json=job_config)
        assert response.status_code == 200
        data = response.json()
        assert "id" in data
        assert data["status"] in ["pending", "running"]
        assert data["config"]["model_name"] == "Qwen/Qwen3.5-1.8B"
    
    def test_list_jobs(self, client):
        """Test listing jobs"""
        response = client.get("/jobs")
        assert response.status_code == 200
        data = response.json()
        assert isinstance(data, list)
    
    def test_get_job_not_found(self, client):
        """Test getting non-existent job"""
        response = client.get("/jobs/nonexistent-job-id")
        assert response.status_code == 404


class TestGPUEndpoint:
    """Test GPU status endpoint"""
    
    @pytest.fixture
    def client(self):
        from api.main import app
        return TestClient(app)
    
    def test_gpu_status(self, client):
        """Test GPU status endpoint returns valid data"""
        response = client.get("/gpu/status")
        assert response.status_code == 200
        data = response.json()
        assert "gpu_name" in data
        assert "compute_capability" in data
        assert "total_memory_gb" in data
        assert "supported_formats" in data
        assert isinstance(data["supported_formats"], list)


class TestModelCatalog:
    """Test model catalog endpoints"""
    
    @pytest.fixture
    def client(self):
        from api.main import app
        return TestClient(app)
    
    def test_list_models_catalog(self, client):
        """Test listing model catalog"""
        response = client.get("/models/catalog")
        assert response.status_code == 200
        data = response.json()
        assert isinstance(data, list)
        assert len(data) > 0
        model = data[0]
        assert "name" in model
        assert "size_gb" in model
        assert "parameters" in model
        assert "recommended_quant" in model
        assert "t4_compatible" in model
    
    def test_quant_formats(self, client):
        """Test listing quantization formats"""
        response = client.get("/models/quant-formats")
        assert response.status_code == 200
        data = response.json()
        assert "formats" in data
        assert isinstance(data["formats"], list)


class TestAuthentication:
    """Test authentication module"""
    
    def test_generate_api_key(self):
        """Test API key generation"""
        from api.auth import generate_api_key
        key = generate_api_key("test")
        assert key.startswith("mo-")
        assert len(key) == 51  # "mo-" + 48 hex chars
    
    def test_validate_api_key_invalid(self):
        """Test validation of invalid API key"""
        from api.auth import validate_api_key
        assert validate_api_key("invalid-key") == False
        assert validate_api_key("") == False
        assert validate_api_key(None) == False
    
    def test_validate_api_key_valid(self):
        """Test validation of valid API key"""
        from api.auth import generate_api_key, validate_api_key
        key = generate_api_key("test")
        assert validate_api_key(key) == True
    
    def test_extract_token(self):
        """Test token extraction from header"""
        from api.auth import extract_token
        assert extract_token("Bearer test-token") == "test-token"
        assert extract_token("test-token") == "test-token"
        assert extract_token("") == None
        assert extract_token(None) == None


class TestRateLimiter:
    """Test rate limiting"""
    
    def test_rate_limiter_allows_requests(self):
        """Test rate limiter allows requests under limit"""
        from api.auth import RateLimiter
        limiter = RateLimiter(requests_per_minute=10)
        for i in range(10):
            assert limiter.is_allowed("test-client") == True
    
    def test_rate_limiter_blocks_excess(self):
        """Test rate limiter blocks requests over limit"""
        from api.auth import RateLimiter
        limiter = RateLimiter(requests_per_minute=5)
        for i in range(5):
            limiter.is_allowed("test-client")
        # 6th request should be blocked
        assert limiter.is_allowed("test-client") == False


class TestInference:
    """Test inference module"""
    
    def test_get_supported_formats(self):
        """Test supported formats for different GPUs"""
        from api.inference import get_supported_formats, GPUInfo
        
        # T4 GPU (sm_75)
        t4 = GPUInfo(
            name="Tesla T4",
            compute_capability="7.5",
            memory_total_gb=16,
            memory_used_gb=0,
            memory_free_gb=16,
            utilization_percent=0,
            temperature_c=30,
            driver_version="535.0",
            cuda_version="12.0"
        )
        formats = get_supported_formats(t4)
        assert "int8" in formats
        assert "int4_awq" in formats
        
        # A100 GPU (sm_80) - supports same as T4 base formats
        a100 = GPUInfo(
            name="A100",
            compute_capability="8.0",
            memory_total_gb=80,
            memory_used_gb=0,
            memory_free_gb=80,
            utilization_percent=0,
            temperature_c=30,
            driver_version="535.0",
            cuda_version="12.0"
        )
        formats = get_supported_formats(a100)
        assert "int8" in formats
        
        # H100 GPU (sm_90) - supports FP8
        h100 = GPUInfo(
            name="H100",
            compute_capability="9.0",
            memory_total_gb=80,
            memory_used_gb=0,
            memory_free_gb=80,
            utilization_percent=0,
            temperature_c=30,
            driver_version="535.0",
            cuda_version="12.0"
        )
        formats = get_supported_formats(h100)
        assert "fp8" in formats  # H100 supports FP8


if __name__ == "__main__":
    pytest.main([__file__, "-v"])