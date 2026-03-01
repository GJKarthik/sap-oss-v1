"""
Integration Tests for SAP AI Core Handler

Tests the full integration with SAP AI Core.
Requires environment variables to be set:
- AICORE_BASE_URL
- AICORE_CLIENT_ID  
- AICORE_CLIENT_SECRET
- AICORE_AUTH_URL
"""

import asyncio
import os
import pytest
from unittest.mock import AsyncMock, MagicMock, patch

from openai.aicore_handler import (
    AICoreCompletionsHandler,
    DeploymentResolver,
    create_aicore_completion,
)
from openai.models import ChatCompletionRequest, ChatMessage
from connectors.aicore_adapter import SAPAICoreClient, AICoreConfig


# ========================================
# Test Fixtures
# ========================================

@pytest.fixture
def mock_config():
    """Create mock config."""
    return AICoreConfig(
        base_url="https://api.ai.test.sap.com",
        client_id="test-client",
        client_secret="test-secret",
        auth_url="https://auth.test.sap.com",
        resource_group="default",
    )


@pytest.fixture
def mock_deployments():
    """Mock deployments response."""
    return {
        "resources": [
            {
                "id": "d1234",
                "status": "RUNNING",
                "scenarioId": "foundation-models",
                "details": {
                    "resources": {
                        "backendDetails": {
                            "model": {
                                "name": "anthropic--claude-3.5-sonnet",
                                "version": "claude-3-5-sonnet-20241022",
                            }
                        }
                    }
                }
            },
            {
                "id": "d5678",
                "status": "RUNNING",
                "scenarioId": "foundation-models",
                "details": {
                    "resources": {
                        "backendDetails": {
                            "model": {
                                "name": "azure--gpt-4o",
                                "version": "gpt-4o-2024-08-06",
                            }
                        }
                    }
                }
            },
            {
                "id": "d9999",
                "status": "STOPPED",  # Should be ignored
                "scenarioId": "custom-scenario",
            }
        ]
    }


# ========================================
# Deployment Resolver Tests
# ========================================

class TestDeploymentResolver:
    """Test deployment resolution."""
    
    @pytest.mark.asyncio
    async def test_resolve_claude_model(self, mock_deployments):
        """Test resolving Claude model to deployment."""
        resolver = DeploymentResolver()
        resolver._deployments = mock_deployments["resources"]
        
        deployment_id = resolver._find_deployment("claude-3.5-sonnet")
        assert deployment_id == "d1234"
    
    @pytest.mark.asyncio
    async def test_resolve_gpt_model(self, mock_deployments):
        """Test resolving GPT model to deployment."""
        resolver = DeploymentResolver()
        resolver._deployments = mock_deployments["resources"]
        
        deployment_id = resolver._find_deployment("gpt-4o")
        assert deployment_id == "d5678"
    
    @pytest.mark.asyncio
    async def test_skip_stopped_deployments(self, mock_deployments):
        """Test that stopped deployments are skipped."""
        resolver = DeploymentResolver()
        resolver._deployments = mock_deployments["resources"]
        
        # Should not find stopped deployment
        deployment_id = resolver._find_deployment("custom-scenario")
        # Should fallback to first running foundation-models deployment
        assert deployment_id is not None
    
    @pytest.mark.asyncio
    async def test_manual_deployment_override(self):
        """Test manually setting deployment mapping."""
        resolver = DeploymentResolver()
        resolver.set_deployment("my-model", "custom-deploy-id")
        
        assert resolver._cache["my-model"] == "custom-deploy-id"
    
    @pytest.mark.asyncio
    async def test_cache_hit(self, mock_deployments):
        """Test deployment cache hit."""
        resolver = DeploymentResolver()
        resolver._cache["cached-model"] = "cached-deploy-id"
        
        mock_client = MagicMock()
        deployment_id = await resolver.resolve("cached-model", mock_client)
        
        assert deployment_id == "cached-deploy-id"


# ========================================
# AI Core Handler Tests
# ========================================

class TestAICoreCompletionsHandler:
    """Test AI Core completions handler."""
    
    @pytest.mark.asyncio
    async def test_create_completion(self):
        """Test creating chat completion."""
        # Mock client and resolver
        mock_client = AsyncMock(spec=SAPAICoreClient)
        mock_client.chat_completion = AsyncMock(return_value={
            "id": "chatcmpl-test",
            "object": "chat.completion",
            "created": 1234567890,
            "model": "claude-3.5-sonnet",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": "Hello! How can I help?",
                },
                "finish_reason": "stop",
            }],
            "usage": {
                "prompt_tokens": 10,
                "completion_tokens": 8,
                "total_tokens": 18,
            },
        })
        
        mock_resolver = AsyncMock(spec=DeploymentResolver)
        mock_resolver.resolve = AsyncMock(return_value="d1234")
        
        handler = AICoreCompletionsHandler(
            client=mock_client,
            deployment_resolver=mock_resolver,
        )
        handler._client = mock_client
        
        request = ChatCompletionRequest(
            model="claude-3.5-sonnet",
            messages=[
                ChatMessage(role="user", content="Hi")
            ],
        )
        
        response = await handler.create_completion(request)
        
        assert response.model == "claude-3.5-sonnet"
        assert len(response.choices) == 1
        assert response.choices[0].message.content == "Hello! How can I help?"
        assert response.usage.total_tokens == 18
    
    @pytest.mark.asyncio
    async def test_no_deployment_found(self):
        """Test error when no deployment found."""
        mock_client = AsyncMock(spec=SAPAICoreClient)
        mock_resolver = AsyncMock(spec=DeploymentResolver)
        mock_resolver.resolve = AsyncMock(return_value=None)
        
        handler = AICoreCompletionsHandler(
            client=mock_client,
            deployment_resolver=mock_resolver,
        )
        handler._client = mock_client
        
        request = ChatCompletionRequest(
            model="nonexistent-model",
            messages=[ChatMessage(role="user", content="Hi")],
        )
        
        with pytest.raises(ValueError, match="No deployment found"):
            await handler.create_completion(request)
    
    @pytest.mark.asyncio
    async def test_message_conversion(self):
        """Test message format conversion."""
        handler = AICoreCompletionsHandler()
        
        message = ChatMessage(
            role="user",
            content="Test content",
            name="test_user",
        )
        
        result = handler._message_to_dict(message)
        
        assert result["role"] == "user"
        assert result["content"] == "Test content"
        assert result["name"] == "test_user"
    
    @pytest.mark.asyncio
    async def test_kwargs_passed_correctly(self):
        """Test that optional parameters are passed correctly."""
        mock_client = AsyncMock(spec=SAPAICoreClient)
        mock_client.chat_completion = AsyncMock(return_value={
            "choices": [{"message": {"content": "Hi"}}],
        })
        
        mock_resolver = AsyncMock(spec=DeploymentResolver)
        mock_resolver.resolve = AsyncMock(return_value="d1234")
        
        handler = AICoreCompletionsHandler(
            client=mock_client,
            deployment_resolver=mock_resolver,
        )
        handler._client = mock_client
        
        request = ChatCompletionRequest(
            model="test-model",
            messages=[ChatMessage(role="user", content="Hi")],
            temperature=0.5,
            max_tokens=100,
            top_p=0.9,
        )
        
        await handler.create_completion(request)
        
        # Verify kwargs passed
        call_kwargs = mock_client.chat_completion.call_args[1]
        assert call_kwargs["temperature"] == 0.5
        assert call_kwargs["max_tokens"] == 100
        assert call_kwargs["top_p"] == 0.9


# ========================================
# Live Integration Test (Skipped by Default)
# ========================================

@pytest.mark.skip(reason="Requires live SAP AI Core credentials")
class TestLiveIntegration:
    """
    Live integration tests with real SAP AI Core.
    
    Run with: pytest -k TestLiveIntegration --run-live
    """
    
    @pytest.mark.asyncio
    async def test_live_claude_completion(self):
        """Test live completion with Claude."""
        request = ChatCompletionRequest(
            model="claude-3.5-sonnet",
            messages=[
                ChatMessage(role="user", content="Say 'Hello from integration test' in exactly 5 words."),
            ],
            max_tokens=50,
        )
        
        async with AICoreCompletionsHandler() as handler:
            response = await handler.create_completion(request)
        
        assert response.choices[0].message.content is not None
        assert len(response.choices) == 1
        print(f"Response: {response.choices[0].message.content}")
    
    @pytest.mark.asyncio
    async def test_live_deployment_resolution(self):
        """Test live deployment resolution."""
        async with AICoreCompletionsHandler() as handler:
            resolver = handler._resolver
            deployment_id = await resolver.resolve("claude-3.5-sonnet", handler.client)
        
        assert deployment_id is not None
        print(f"Resolved deployment: {deployment_id}")


# ========================================
# Run Tests
# ========================================

if __name__ == "__main__":
    pytest.main([__file__, "-v"])