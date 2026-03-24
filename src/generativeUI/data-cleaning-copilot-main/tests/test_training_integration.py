# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""
Tests for training integration module.

Tests cover:
- Data product registry
- Quality gate validation
- ModelOpt client
- Routing recommendations
"""

import pytest
from unittest.mock import Mock, patch, MagicMock
from datetime import datetime
import sys
import os

# Add parent to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from training.data_products import (
    DataProduct,
    DataProductRegistry,
    QualityGateResult,
    QualityGateValidator,
    get_registry,
    get_validator,
    list_products,
    validate_product,
    get_mcp_resources,
    read_resource,
)

from training.modelopt_client import (
    ModelInfo,
    InferenceRequest,
    InferenceResponse,
    ModelOptClient,
    get_client,
    infer,
    get_routing_recommendation,
)


class TestDataProduct:
    """Test DataProduct dataclass."""
    
    def test_create_product(self):
        product = DataProduct(
            id="test-product-v1",
            name="Test Product",
            description="A test product",
            domain="Testing",
            version="1.0.0",
        )
        assert product.id == "test-product-v1"
        assert product.name == "Test Product"
        assert product.domain == "Testing"
    
    def test_product_default_values(self):
        product = DataProduct(
            id="test",
            name="Test",
            description="Desc",
            domain="Domain",
            version="1.0",
        )
        assert product.owner == ""
        assert product.security_class == "confidential"
        assert isinstance(product.tables, list)
        assert isinstance(product.fields, list)
    
    def test_product_with_tables(self):
        product = DataProduct(
            id="test",
            name="Test",
            description="Desc",
            domain="Domain",
            version="1.0",
            tables=["Table1", "Table2"],
            fields=["field1", "field2"],
        )
        assert len(product.tables) == 2
        assert len(product.fields) == 2


class TestQualityGateResult:
    """Test QualityGateResult dataclass."""
    
    def test_passed_result(self):
        result = QualityGateResult(
            gate="field_completeness",
            passed=True,
            score=100,
            threshold=100,
            details="All fields complete",
        )
        assert result.passed is True
        assert result.score == 100
    
    def test_failed_result(self):
        result = QualityGateResult(
            gate="prompt_coverage",
            passed=False,
            score=85,
            threshold=90,
            details="Missing prompts for aggregation queries",
        )
        assert result.passed is False
        assert result.score < result.threshold


class TestDataProductRegistry:
    """Test DataProductRegistry class."""
    
    @pytest.fixture
    def registry(self):
        reg = DataProductRegistry()
        reg._load_mock_products()
        return reg
    
    def test_list_products(self, registry):
        products = registry.list_products()
        assert len(products) >= 3
    
    def test_get_product(self, registry):
        product = registry.get_product("treasury-capital-markets-v1")
        assert product is not None
        assert product.domain == "Treasury"
    
    def test_get_nonexistent_product(self, registry):
        product = registry.get_product("nonexistent")
        assert product is None
    
    def test_get_product_ids(self, registry):
        ids = registry.get_product_ids()
        assert "treasury-capital-markets-v1" in ids
        assert "esg-sustainability-v1" in ids
        assert "performance-bpc-v1" in ids
    
    def test_default_llm_routing(self, registry):
        routing = registry.get_llm_routing()
        assert routing == "vllm-only"
    
    def test_default_security_class(self, registry):
        sec_class = registry.get_security_class()
        assert sec_class == "confidential"
    
    def test_to_mcp_resources(self, registry):
        resources = registry.to_mcp_resources()
        assert len(resources) > 0
        # Should have registry + products + schemas
        uris = [r["uri"] for r in resources]
        assert "training://products/registry" in uris
    
    def test_read_registry_resource(self, registry):
        content = registry.read_mcp_resource("training://products/registry")
        assert "products" in content
        assert "llm_routing" in content
        assert len(content["products"]) >= 3
    
    def test_read_product_resource(self, registry):
        content = registry.read_mcp_resource("training://products/treasury-capital-markets-v1")
        assert content["id"] == "treasury-capital-markets-v1"
        assert content["domain"] == "Treasury"
    
    def test_read_schema_resource(self, registry):
        content = registry.read_mcp_resource("training://products/treasury-capital-markets-v1/schema")
        assert "tables" in content
        assert "fields" in content
    
    def test_read_unknown_resource(self, registry):
        content = registry.read_mcp_resource("unknown://resource")
        assert "error" in content


class TestQualityGateValidator:
    """Test QualityGateValidator class."""
    
    @pytest.fixture
    def registry(self):
        reg = DataProductRegistry()
        reg._load_mock_products()
        return reg
    
    @pytest.fixture
    def validator(self, registry):
        return QualityGateValidator(registry)
    
    def test_validate_product(self, validator):
        results = validator.validate_product("treasury-capital-markets-v1")
        assert len(results) == 4  # 4 quality gates
    
    def test_all_gates_checked(self, validator):
        results = validator.validate_product("treasury-capital-markets-v1")
        gates = {r.gate for r in results}
        assert "field_completeness" in gates
        assert "hierarchy_consistency" in gates
        assert "prompt_coverage" in gates
        assert "schema_mapping_accuracy" in gates
    
    def test_validate_nonexistent_product(self, validator):
        results = validator.validate_product("nonexistent")
        assert len(results) == 1
        assert results[0].passed is False
        assert "not found" in results[0].details
    
    def test_validate_all(self, validator):
        all_results = validator.validate_all()
        assert "treasury-capital-markets-v1" in all_results
        assert "esg-sustainability-v1" in all_results


class TestQualityGateDefinitions:
    """Test quality gate definitions."""
    
    def test_quality_gates_defined(self):
        gates = DataProductRegistry.QUALITY_GATES
        assert "field_completeness" in gates
        assert "hierarchy_consistency" in gates
        assert "prompt_coverage" in gates
        assert "schema_mapping_accuracy" in gates
    
    def test_gate_has_threshold(self):
        gates = DataProductRegistry.QUALITY_GATES
        for gate_name, gate_def in gates.items():
            assert "threshold" in gate_def
            assert "description" in gate_def


class TestModelInfo:
    """Test ModelInfo dataclass."""
    
    def test_create_model(self):
        model = ModelInfo(
            model_id="test-model",
            name="Test Model",
            base_model="gpt-4",
        )
        assert model.model_id == "test-model"
        assert model.fine_tuned is False
    
    def test_finetuned_model(self):
        model = ModelInfo(
            model_id="qwen-finetuned",
            name="Qwen Finetuned",
            base_model="Qwen/Qwen2.5-3B-Instruct",
            fine_tuned=True,
            domain="treasury",
        )
        assert model.fine_tuned is True
        assert model.domain == "treasury"


class TestInferenceRequest:
    """Test InferenceRequest dataclass."""
    
    def test_create_request(self):
        request = InferenceRequest(
            messages=[{"role": "user", "content": "Hello"}],
        )
        assert len(request.messages) == 1
        assert request.model == "qwen-3.5-finetuned"
    
    def test_request_with_options(self):
        request = InferenceRequest(
            messages=[{"role": "user", "content": "Query"}],
            model="qwen-treasury",
            temperature=0.5,
            max_tokens=1024,
            data_class="confidential",
        )
        assert request.model == "qwen-treasury"
        assert request.temperature == 0.5
        assert request.data_class == "confidential"


class TestModelOptClient:
    """Test ModelOptClient class."""
    
    @pytest.fixture
    def client(self):
        return ModelOptClient()
    
    def test_default_models_defined(self, client):
        models = client.DEFAULT_MODELS
        assert "qwen-3.5-finetuned" in models
        assert "qwen-treasury" in models
        assert "qwen-esg" in models
        assert "qwen-performance" in models
    
    def test_domain_routing_defined(self, client):
        routing = client.DOMAIN_ROUTING
        assert routing["treasury"] == "qwen-treasury"
        assert routing["esg"] == "qwen-esg"
        assert routing["performance"] == "qwen-performance"
    
    def test_get_model_for_domain(self, client):
        assert client.get_model_for_domain("treasury") == "qwen-treasury"
        assert client.get_model_for_domain("ESG") == "qwen-esg"
        assert client.get_model_for_domain("unknown") == "qwen-3.5-finetuned"
    
    def test_mock_inference(self, client):
        request = InferenceRequest(
            messages=[{"role": "user", "content": "Query treasury data"}],
        )
        response = client._mock_inference(
            request, "qwen-treasury", datetime.utcnow()
        )
        assert response.backend == "modelopt-mock"
        assert "Treasury" in response.content or "treasury" in response.content.lower()
    
    def test_infer_sync_with_unavailable_service(self, client):
        client._available = False
        request = InferenceRequest(
            messages=[{"role": "user", "content": "Test"}],
        )
        response = client.infer_sync(request)
        assert response.backend == "modelopt-mock"


class TestRoutingRecommendation:
    """Test routing recommendation function."""
    
    def test_confidential_data_uses_modelopt(self):
        rec = get_routing_recommendation(
            message="Query treasury accounts",
            data_class="confidential",
        )
        assert rec["backend"] == "modelopt"
        assert rec["pii_safe"] is True
    
    def test_pii_data_uses_modelopt(self):
        rec = get_routing_recommendation(
            message="Find user emails",
            contains_pii=True,
        )
        assert rec["backend"] == "modelopt"
    
    def test_treasury_keyword_routes_to_specialist(self):
        rec = get_routing_recommendation(
            message="Show me NFRP account balances",
            data_class="confidential",
        )
        assert rec["domain"] == "treasury"
        assert rec["model"] == "qwen-treasury"
    
    def test_esg_keyword_routes_to_specialist(self):
        rec = get_routing_recommendation(
            message="Get carbon footprint metrics",
            data_class="confidential",
        )
        assert rec["domain"] == "esg"
        assert rec["model"] == "qwen-esg"
    
    def test_performance_keyword_routes_to_specialist(self):
        rec = get_routing_recommendation(
            message="Show BPC budget forecasts",
            data_class="confidential",
        )
        assert rec["domain"] == "performance"
        assert rec["model"] == "qwen-performance"
    
    def test_non_sensitive_uses_cloud(self):
        rec = get_routing_recommendation(
            message="What is the weather?",
            data_class="public",
            contains_pii=False,
        )
        assert rec["backend"] == "aicore"


class TestConvenienceFunctions:
    """Test module-level convenience functions."""
    
    def test_list_products_function(self):
        # Reset singleton
        import training.data_products as dp
        dp._registry = None
        
        products = list_products()
        assert len(products) >= 3
        assert all("id" in p for p in products)
    
    def test_validate_product_function(self):
        import training.data_products as dp
        dp._registry = None
        dp._validator = None
        
        results = validate_product("treasury-capital-markets-v1")
        assert len(results) == 4
        assert all("gate" in r for r in results)
    
    def test_get_mcp_resources_function(self):
        import training.data_products as dp
        dp._registry = None
        
        resources = get_mcp_resources()
        assert len(resources) > 0
    
    def test_read_resource_function(self):
        import training.data_products as dp
        dp._registry = None
        
        content = read_resource("training://products/registry")
        assert "products" in content


class TestInferFunction:
    """Test the infer convenience function."""
    
    def test_infer_returns_dict(self):
        result = infer(
            messages=[{"role": "user", "content": "Test query"}],
        )
        assert "content" in result
        assert "model" in result
        assert "backend" in result
    
    def test_infer_with_data_class(self):
        result = infer(
            messages=[{"role": "user", "content": "Treasury query"}],
            data_class="treasury",
        )
        assert result["model"] == "qwen-treasury"