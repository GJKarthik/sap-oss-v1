"""
Unit Tests for Models Endpoint

Day 10 Tests: Comprehensive tests for /v1/models endpoint
Target: 40+ tests for full coverage

Test Categories:
1. ModelObject creation and serialization
2. ModelObjectExtended with additional fields
3. ModelsListResponse formatting
4. DeleteModelResponse handling
5. ModelsHandler list operations
6. ModelsHandler get operations
7. Filtering by capability, tier, provider
8. Utility functions
9. Error handling
"""

import pytest
from unittest.mock import Mock, patch, MagicMock
from typing import Set

from routing.model_registry import (
    ModelRegistry,
    ModelDefinition,
    ModelCapability,
    ModelTier,
    ModelProvider,
)
from openai.models_endpoint import (
    ModelObject,
    ModelObjectExtended,
    ModelsListResponse,
    ModelsListResponseExtended,
    DeleteModelResponse,
    ModelErrorResponse,
    ModelPermission,
    ModelsHandler,
    get_models_handler,
    list_all_models,
    get_model_info,
    model_supports_streaming,
    model_supports_tools,
    get_recommended_model,
)


# ========================================
# Fixtures
# ========================================

@pytest.fixture
def mock_model_definition():
    """Create a mock model definition."""
    return ModelDefinition(
        id="gpt-4",
        provider=ModelProvider.SAP_AI_CORE,
        backend_id="aicore_primary",
        display_name="GPT-4 via AI Core",
        capabilities={
            ModelCapability.CHAT,
            ModelCapability.FUNCTION_CALLING,
            ModelCapability.STREAMING,
        },
        tier=ModelTier.PREMIUM,
        context_window=8192,
        max_output_tokens=4096,
        enabled=True,
    )


@pytest.fixture
def mock_embedding_model():
    """Create mock embedding model definition."""
    return ModelDefinition(
        id="text-embedding-3-small",
        provider=ModelProvider.SAP_AI_CORE,
        backend_id="aicore_primary",
        display_name="Text Embedding 3 Small",
        capabilities={ModelCapability.EMBEDDING},
        tier=ModelTier.ECONOMY,
        context_window=8191,
        enabled=True,
    )


@pytest.fixture
def mock_registry(mock_model_definition, mock_embedding_model):
    """Create a mock model registry with test models."""
    registry = Mock(spec=ModelRegistry)
    
    models = {
        "gpt-4": mock_model_definition,
        "text-embedding-3-small": mock_embedding_model,
    }
    
    registry.get_model.side_effect = lambda x: models.get(x)
    registry.model_exists.side_effect = lambda x: x in models
    registry.list_models.return_value = list(models.values())
    
    return registry


@pytest.fixture
def handler(mock_registry):
    """Create handler with mock registry."""
    return ModelsHandler(registry=mock_registry)


# ========================================
# Test ModelPermission Enum
# ========================================

class TestModelPermissionEnum:
    """Tests for ModelPermission enum."""
    
    def test_permission_values(self):
        """Test permission enum values."""
        assert ModelPermission.CREATE_ENGINE == "create_engine"
        assert ModelPermission.FINE_TUNE == "fine_tune"
        assert ModelPermission.SAMPLE == "sample"
    
    def test_permission_is_string_enum(self):
        """Test that permissions are string enums."""
        assert isinstance(ModelPermission.CREATE_ENGINE, str)


# ========================================
# Test ModelObject
# ========================================

class TestModelObject:
    """Tests for ModelObject dataclass."""
    
    def test_create_basic(self):
        """Test basic model object creation."""
        model = ModelObject(id="gpt-4")
        assert model.id == "gpt-4"
        assert model.object == "model"
        assert model.created == 0
        assert model.owned_by == "sap-ai-core"
    
    def test_create_with_all_fields(self):
        """Test creation with all fields."""
        model = ModelObject(
            id="gpt-4",
            object="model",
            created=1234567890,
            owned_by="custom-owner",
            permission=[{"allow_view": True}],
            root="gpt-4-base",
            parent="gpt-4-parent",
        )
        assert model.created == 1234567890
        assert model.owned_by == "custom-owner"
        assert model.root == "gpt-4-base"
        assert model.parent == "gpt-4-parent"
    
    def test_from_definition(self, mock_model_definition):
        """Test creation from ModelDefinition."""
        model = ModelObject.from_definition(mock_model_definition)
        
        assert model.id == "gpt-4"
        assert model.object == "model"
        assert model.owned_by == "sap_ai_core"
        assert model.root == "gpt-4"
        assert model.permission is None
    
    def test_from_definition_with_permissions(self, mock_model_definition):
        """Test creation with permissions."""
        model = ModelObject.from_definition(
            mock_model_definition,
            include_permissions=True,
        )
        
        assert model.permission is not None
        assert len(model.permission) == 1
        assert model.permission[0]["object"] == "model_permission"
        assert model.permission[0]["allow_sampling"] is True
        assert model.permission[0]["allow_fine_tuning"] is False
    
    def test_to_dict_minimal(self):
        """Test minimal dict conversion."""
        model = ModelObject(id="gpt-4")
        result = model.to_dict()
        
        assert result["id"] == "gpt-4"
        assert result["object"] == "model"
        assert result["created"] == 0
        assert result["owned_by"] == "sap-ai-core"
        assert "permission" not in result or result.get("permission") is None
    
    def test_to_dict_with_optional_fields(self):
        """Test dict with optional fields."""
        model = ModelObject(
            id="gpt-4",
            permission=[{"test": True}],
            root="root-model",
            parent="parent-model",
        )
        result = model.to_dict()
        
        assert result["permission"] == [{"test": True}]
        assert result["root"] == "root-model"
        assert result["parent"] == "parent-model"


# ========================================
# Test ModelObjectExtended
# ========================================

class TestModelObjectExtended:
    """Tests for ModelObjectExtended dataclass."""
    
    def test_create_with_extended_fields(self):
        """Test creation with extended fields."""
        model = ModelObjectExtended(
            id="gpt-4",
            display_name="GPT-4",
            capabilities=["chat", "streaming"],
            context_window=8192,
            max_output_tokens=4096,
            tier="premium",
            enabled=True,
        )
        
        assert model.display_name == "GPT-4"
        assert model.capabilities == ["chat", "streaming"]
        assert model.context_window == 8192
        assert model.max_output_tokens == 4096
        assert model.tier == "premium"
        assert model.enabled is True
    
    def test_from_definition_extended(self, mock_model_definition):
        """Test extended creation from definition."""
        model = ModelObjectExtended.from_definition(mock_model_definition)
        
        assert model.id == "gpt-4"
        assert model.display_name == "GPT-4 via AI Core"
        assert "chat" in model.capabilities
        assert model.context_window == 8192
        assert model.max_output_tokens == 4096
        assert model.tier == "premium"
        assert model.enabled is True
    
    def test_to_dict_extended(self, mock_model_definition):
        """Test extended dict conversion."""
        model = ModelObjectExtended.from_definition(mock_model_definition)
        result = model.to_dict()
        
        # Base fields
        assert result["id"] == "gpt-4"
        assert result["object"] == "model"
        
        # Extended fields
        assert result["display_name"] == "GPT-4 via AI Core"
        assert "chat" in result["capabilities"]
        assert result["context_window"] == 8192
        assert result["tier"] == "premium"
        assert result["enabled"] is True


# ========================================
# Test ModelsListResponse
# ========================================

class TestModelsListResponse:
    """Tests for ModelsListResponse dataclass."""
    
    def test_empty_response(self):
        """Test empty models list."""
        response = ModelsListResponse()
        
        assert response.object == "list"
        assert response.data == []
    
    def test_with_models(self):
        """Test response with models."""
        models = [
            ModelObject(id="gpt-4"),
            ModelObject(id="gpt-3.5-turbo"),
        ]
        response = ModelsListResponse(data=models)
        
        assert len(response.data) == 2
        assert response.data[0].id == "gpt-4"
    
    def test_to_dict(self):
        """Test dict conversion."""
        models = [ModelObject(id="gpt-4")]
        response = ModelsListResponse(data=models)
        result = response.to_dict()
        
        assert result["object"] == "list"
        assert len(result["data"]) == 1
        assert result["data"][0]["id"] == "gpt-4"


class TestModelsListResponseExtended:
    """Tests for extended list response."""
    
    def test_with_metadata(self):
        """Test response with filtering metadata."""
        response = ModelsListResponseExtended(
            data=[ModelObject(id="gpt-4")],
            total=1,
            filtered_by={"capability": "chat"},
        )
        
        assert response.total == 1
        assert response.filtered_by["capability"] == "chat"
    
    def test_to_dict_extended(self):
        """Test extended dict conversion."""
        response = ModelsListResponseExtended(
            data=[],
            total=0,
            filtered_by={"tier": "premium"},
        )
        result = response.to_dict()
        
        assert result["total"] == 0
        assert result["filtered_by"]["tier"] == "premium"


# ========================================
# Test DeleteModelResponse
# ========================================

class TestDeleteModelResponse:
    """Tests for DeleteModelResponse dataclass."""
    
    def test_successful_delete(self):
        """Test successful deletion response."""
        response = DeleteModelResponse(
            id="ft-model-123",
            deleted=True,
        )
        
        assert response.id == "ft-model-123"
        assert response.deleted is True
        assert response.error is None
    
    def test_failed_delete(self):
        """Test failed deletion response."""
        response = DeleteModelResponse(
            id="gpt-4",
            deleted=False,
            error="Cannot delete managed models",
        )
        
        assert response.deleted is False
        assert response.error == "Cannot delete managed models"
    
    def test_to_dict(self):
        """Test dict conversion."""
        response = DeleteModelResponse(
            id="test",
            deleted=False,
            error="Not found",
        )
        result = response.to_dict()
        
        assert result["id"] == "test"
        assert result["object"] == "model"
        assert result["deleted"] is False
        assert result["error"] == "Not found"


# ========================================
# Test ModelErrorResponse
# ========================================

class TestModelErrorResponse:
    """Tests for error response."""
    
    def test_basic_error(self):
        """Test basic error response."""
        error = ModelErrorResponse(message="Model not found")
        result = error.to_dict()
        
        assert result["error"]["message"] == "Model not found"
        assert result["error"]["type"] == "invalid_request_error"
    
    def test_full_error(self):
        """Test error with all fields."""
        error = ModelErrorResponse(
            message="Invalid model",
            type="model_not_found",
            param="model",
            code="invalid_model",
        )
        result = error.to_dict()
        
        assert result["error"]["type"] == "model_not_found"
        assert result["error"]["param"] == "model"
        assert result["error"]["code"] == "invalid_model"


# ========================================
# Test ModelsHandler - List Operations
# ========================================

class TestModelsHandlerList:
    """Tests for ModelsHandler list operations."""
    
    def test_list_models_basic(self, handler):
        """Test basic model listing."""
        result = handler.list_models()
        
        assert result["object"] == "list"
        assert len(result["data"]) == 2
    
    def test_list_models_extended(self, handler):
        """Test extended model listing."""
        result = handler.list_models(extended=True)
        
        assert result["object"] == "list"
        assert "total" in result
        assert result["total"] == 2
    
    def test_list_chat_models(self, handler, mock_registry):
        """Test filtering chat models."""
        # Only return chat-capable model
        mock_registry.list_models.return_value = [
            ModelDefinition(
                id="gpt-4",
                provider=ModelProvider.SAP_AI_CORE,
                backend_id="aicore",
                display_name="GPT-4",
                capabilities={ModelCapability.CHAT},
            )
        ]
        
        result = handler.list_chat_models()
        assert result["object"] == "list"
    
    def test_list_embedding_models(self, handler, mock_registry):
        """Test filtering embedding models."""
        mock_registry.list_models.return_value = [
            ModelDefinition(
                id="embed",
                provider=ModelProvider.SAP_AI_CORE,
                backend_id="aicore",
                display_name="Embed",
                capabilities={ModelCapability.EMBEDDING},
            )
        ]
        
        result = handler.list_embedding_models()
        assert result["object"] == "list"
    
    def test_list_by_tier(self, handler, mock_registry):
        """Test filtering by tier."""
        result = handler.list_models_by_tier("premium")
        assert result["object"] == "list"
    
    def test_list_with_capability_filter(self, handler, mock_registry):
        """Test capability filtering."""
        mock_registry.list_models.return_value = [
            ModelDefinition(
                id="gpt-4",
                provider=ModelProvider.SAP_AI_CORE,
                backend_id="aicore",
                display_name="GPT-4",
                capabilities={ModelCapability.CHAT, ModelCapability.STREAMING},
            )
        ]
        
        result = handler.list_models(capability="chat")
        assert result["object"] == "list"
    
    def test_list_with_provider_filter(self, handler, mock_registry):
        """Test provider filtering."""
        result = handler.list_models(provider="sap_ai_core")
        assert result["object"] == "list"
    
    def test_list_with_invalid_capability(self, handler, mock_registry):
        """Test invalid capability filter (should log warning)."""
        mock_registry.list_models.return_value = []
        result = handler.list_models(capability="invalid_cap")
        assert result["object"] == "list"
    
    def test_list_with_invalid_tier(self, handler, mock_registry):
        """Test invalid tier filter."""
        mock_registry.list_models.return_value = []
        result = handler.list_models(tier="invalid_tier")
        assert result["object"] == "list"
    
    def test_list_extended_with_filters(self, handler, mock_registry):
        """Test extended response with filter metadata."""
        mock_registry.list_models.return_value = []
        result = handler.list_models(
            capability="chat",
            tier="premium",
            extended=True,
        )
        
        assert result["filtered_by"]["capability"] == "chat"
        assert result["filtered_by"]["tier"] == "premium"


# ========================================
# Test ModelsHandler - Get Operations
# ========================================

class TestModelsHandlerGet:
    """Tests for ModelsHandler get operations."""
    
    def test_get_model_exists(self, handler):
        """Test getting existing model."""
        result = handler.get_model("gpt-4")
        
        assert result is not None
        assert result["id"] == "gpt-4"
        assert result["object"] == "model"
    
    def test_get_model_not_found(self, handler, mock_registry):
        """Test getting non-existent model."""
        mock_registry.get_model.return_value = None
        result = handler.get_model("non-existent")
        
        assert result is None
    
    def test_get_model_extended(self, handler):
        """Test getting model with extended info."""
        result = handler.get_model("gpt-4", extended=True)
        
        assert result is not None
        assert "display_name" in result
        assert "capabilities" in result
    
    def test_get_model_with_permissions(self, handler):
        """Test model includes permissions."""
        result = handler.get_model("gpt-4")
        
        assert result is not None
        assert "permission" in result
    
    def test_model_exists_true(self, handler):
        """Test model_exists returns True for existing."""
        assert handler.model_exists("gpt-4") is True
    
    def test_model_exists_false(self, handler, mock_registry):
        """Test model_exists returns False for missing."""
        mock_registry.model_exists.return_value = False
        assert handler.model_exists("non-existent") is False
    
    def test_get_model_capabilities(self, handler):
        """Test getting model capabilities."""
        caps = handler.get_model_capabilities("gpt-4")
        
        assert caps is not None
        assert "chat" in caps
        assert "streaming" in caps
    
    def test_get_model_capabilities_not_found(self, handler, mock_registry):
        """Test capabilities for non-existent model."""
        mock_registry.get_model.return_value = None
        caps = handler.get_model_capabilities("non-existent")
        
        assert caps is None
    
    def test_get_context_window(self, handler):
        """Test getting context window."""
        window = handler.get_context_window("gpt-4")
        
        assert window == 8192
    
    def test_get_context_window_not_found(self, handler, mock_registry):
        """Test context window for non-existent model."""
        mock_registry.get_model.return_value = None
        window = handler.get_context_window("non-existent")
        
        assert window is None


# ========================================
# Test ModelsHandler - Capability Checks
# ========================================

class TestModelsHandlerCapabilities:
    """Tests for capability checking."""
    
    def test_supports_capability_true(self, handler):
        """Test model supports capability."""
        assert handler.supports_capability("gpt-4", "chat") is True
        assert handler.supports_capability("gpt-4", "streaming") is True
    
    def test_supports_capability_false(self, handler):
        """Test model doesn't support capability."""
        assert handler.supports_capability("gpt-4", "embedding") is False
    
    def test_supports_capability_invalid(self, handler):
        """Test invalid capability returns False."""
        assert handler.supports_capability("gpt-4", "invalid") is False
    
    def test_supports_capability_model_not_found(self, handler, mock_registry):
        """Test capability check for missing model."""
        mock_registry.get_model.return_value = None
        assert handler.supports_capability("missing", "chat") is False


# ========================================
# Test ModelsHandler - Delete Operations
# ========================================

class TestModelsHandlerDelete:
    """Tests for delete operations."""
    
    def test_delete_managed_model(self, handler):
        """Test deleting managed model fails."""
        result = handler.delete_model("gpt-4")
        
        assert result["deleted"] is False
        assert "Cannot delete" in result["error"]
    
    def test_delete_non_existent_model(self, handler, mock_registry):
        """Test deleting non-existent model."""
        mock_registry.get_model.return_value = None
        result = handler.delete_model("non-existent")
        
        assert result["deleted"] is False
        assert result["error"] == "Model not found"


# ========================================
# Test Utility Functions
# ========================================

class TestUtilityFunctions:
    """Tests for module-level utility functions."""
    
    @patch('openai.models_endpoint.get_model_registry')
    def test_get_models_handler(self, mock_get_registry):
        """Test handler factory function."""
        mock_registry = Mock()
        mock_get_registry.return_value = mock_registry
        
        handler = get_models_handler()
        assert handler is not None
    
    @patch('openai.models_endpoint.ModelsHandler')
    def test_list_all_models(self, mock_handler_class):
        """Test list_all_models utility."""
        mock_instance = Mock()
        mock_instance.list_models.return_value = {"object": "list", "data": []}
        mock_handler_class.return_value = mock_instance
        
        result = list_all_models()
        assert result["object"] == "list"
    
    @patch('openai.models_endpoint.ModelsHandler')
    def test_get_model_info(self, mock_handler_class):
        """Test get_model_info utility."""
        mock_instance = Mock()
        mock_instance.get_model.return_value = {"id": "gpt-4"}
        mock_handler_class.return_value = mock_instance
        
        result = get_model_info("gpt-4")
        assert result["id"] == "gpt-4"
    
    @patch('openai.models_endpoint.ModelsHandler')
    def test_model_supports_streaming(self, mock_handler_class):
        """Test streaming capability check."""
        mock_instance = Mock()
        mock_instance.supports_capability.return_value = True
        mock_handler_class.return_value = mock_instance
        
        result = model_supports_streaming("gpt-4")
        assert result is True
    
    @patch('openai.models_endpoint.ModelsHandler')
    def test_model_supports_tools(self, mock_handler_class):
        """Test tool capability check."""
        mock_instance = Mock()
        mock_instance.supports_capability.side_effect = lambda m, c: c == "function_calling"
        mock_handler_class.return_value = mock_instance
        
        result = model_supports_tools("gpt-4")
        assert result is True
    
    @patch('openai.models_endpoint.ModelsHandler')
    def test_get_recommended_model_found(self, mock_handler_class):
        """Test getting recommended model."""
        mock_instance = Mock()
        mock_instance.list_models.return_value = {
            "data": [{"id": "gpt-4"}]
        }
        mock_handler_class.return_value = mock_instance
        
        result = get_recommended_model("chat", "standard")
        assert result == "gpt-4"
    
    @patch('openai.models_endpoint.ModelsHandler')
    def test_get_recommended_model_fallback(self, mock_handler_class):
        """Test recommended model fallback."""
        mock_instance = Mock()
        # First call (with tier) returns empty, second (without tier) returns model
        mock_instance.list_models.side_effect = [
            {"data": []},
            {"data": [{"id": "fallback"}]},
        ]
        mock_handler_class.return_value = mock_instance
        
        result = get_recommended_model("chat", "premium")
        assert result == "fallback"
    
    @patch('openai.models_endpoint.ModelsHandler')
    def test_get_recommended_model_none(self, mock_handler_class):
        """Test no recommended model available."""
        mock_instance = Mock()
        mock_instance.list_models.return_value = {"data": []}
        mock_handler_class.return_value = mock_instance
        
        result = get_recommended_model("invalid", "invalid")
        assert result is None


# ========================================
# Test Registry Integration
# ========================================

class TestRegistryIntegration:
    """Tests for registry property access."""
    
    def test_registry_property(self, handler, mock_registry):
        """Test registry property returns registry."""
        assert handler.registry is mock_registry
    
    def test_handler_with_none_registry(self):
        """Test handler with None registry uses global."""
        with patch('openai.models_endpoint.get_model_registry') as mock_get:
            mock_get.return_value = Mock()
            handler = ModelsHandler(registry=None)
            assert handler.registry is not None


# ========================================
# Test Edge Cases
# ========================================

class TestEdgeCases:
    """Tests for edge cases and error handling."""
    
    def test_empty_capabilities_set(self):
        """Test model with no capabilities."""
        definition = ModelDefinition(
            id="minimal",
            provider=ModelProvider.SAP_AI_CORE,
            backend_id="test",
            display_name="Minimal",
            capabilities=set(),
        )
        
        model = ModelObjectExtended.from_definition(definition)
        assert model.capabilities == []
    
    def test_model_id_truncation_in_permission(self):
        """Test permission ID uses truncated model ID."""
        definition = ModelDefinition(
            id="very-long-model-id-that-exceeds-eight-chars",
            provider=ModelProvider.SAP_AI_CORE,
            backend_id="test",
            display_name="Long",
        )
        
        model = ModelObject.from_definition(definition, include_permissions=True)
        perm_id = model.permission[0]["id"]
        
        assert perm_id.startswith("modelperm-")
        assert len(perm_id) == len("modelperm-") + 8
    
    def test_none_max_output_tokens(self):
        """Test model with None max_output_tokens."""
        definition = ModelDefinition(
            id="test",
            provider=ModelProvider.SAP_AI_CORE,
            backend_id="test",
            display_name="Test",
            max_output_tokens=None,
        )
        
        model = ModelObjectExtended.from_definition(definition)
        result = model.to_dict()
        
        assert "max_output_tokens" not in result or result["max_output_tokens"] is None


# ========================================
# Test OpenAI API Compliance
# ========================================

class TestOpenAICompliance:
    """Tests for OpenAI API format compliance."""
    
    def test_list_response_format(self, handler, mock_registry):
        """Test list response matches OpenAI format."""
        mock_registry.list_models.return_value = [
            ModelDefinition(
                id="gpt-4",
                provider=ModelProvider.SAP_AI_CORE,
                backend_id="test",
                display_name="GPT-4",
            )
        ]
        
        result = handler.list_models()
        
        # OpenAI required fields
        assert "object" in result
        assert result["object"] == "list"
        assert "data" in result
        assert isinstance(result["data"], list)
    
    def test_model_object_format(self, handler, mock_registry):
        """Test model object matches OpenAI format."""
        result = handler.get_model("gpt-4")
        
        # OpenAI required fields
        assert "id" in result
        assert "object" in result
        assert result["object"] == "model"
        assert "created" in result
        assert "owned_by" in result
    
    def test_delete_response_format(self, handler):
        """Test delete response matches OpenAI format."""
        result = handler.delete_model("gpt-4")
        
        assert "id" in result
        assert "object" in result
        assert "deleted" in result


if __name__ == "__main__":
    pytest.main([__file__, "-v"])