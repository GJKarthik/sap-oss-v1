"""
Tests for SAP AI Core Adapter

Tests the request/response transformation for different model types.
"""

import pytest
from unittest.mock import AsyncMock, patch, MagicMock
import json

from connectors.aicore_adapter import (
    ModelFamily,
    detect_model_family,
    AnthropicBedrockAdapter,
    AICoreConfig,
    SAPAICoreClient,
)


# ========================================
# Model Family Detection Tests
# ========================================

class TestModelFamilyDetection:
    """Test model family detection from model ID."""
    
    def test_detect_claude_models(self):
        """Test detection of Claude/Anthropic models."""
        assert detect_model_family("claude-3-opus") == ModelFamily.ANTHROPIC
        assert detect_model_family("claude-3-sonnet") == ModelFamily.ANTHROPIC
        assert detect_model_family("claude-3-haiku") == ModelFamily.ANTHROPIC
        assert detect_model_family("claude-3.5-sonnet") == ModelFamily.ANTHROPIC
        assert detect_model_family("claude-3-5-sonnet-20241022") == ModelFamily.ANTHROPIC
        assert detect_model_family("anthropic--claude-3-opus") == ModelFamily.ANTHROPIC
    
    def test_detect_openai_models(self):
        """Test detection of OpenAI models."""
        assert detect_model_family("gpt-4") == ModelFamily.OPENAI
        assert detect_model_family("gpt-4o") == ModelFamily.OPENAI
        assert detect_model_family("gpt-4-turbo") == ModelFamily.OPENAI
        assert detect_model_family("gpt-3.5-turbo") == ModelFamily.OPENAI
        assert detect_model_family("gpt-4-32k") == ModelFamily.OPENAI
    
    def test_detect_gemini_models(self):
        """Test detection of Gemini models."""
        assert detect_model_family("gemini-pro") == ModelFamily.GEMINI
        assert detect_model_family("gemini-1.5-pro") == ModelFamily.GEMINI
    
    def test_detect_mistral_models(self):
        """Test detection of Mistral models."""
        assert detect_model_family("mistral-7b") == ModelFamily.MISTRAL
        assert detect_model_family("mistral-large") == ModelFamily.MISTRAL
    
    def test_default_to_openai(self):
        """Test unknown models default to OpenAI format."""
        assert detect_model_family("unknown-model") == ModelFamily.OPENAI
        assert detect_model_family("custom-llm") == ModelFamily.OPENAI
    
    def test_case_insensitive(self):
        """Test model detection is case-insensitive."""
        assert detect_model_family("CLAUDE-3-OPUS") == ModelFamily.ANTHROPIC
        assert detect_model_family("GPT-4") == ModelFamily.OPENAI


# ========================================
# Anthropic Bedrock Adapter Tests
# ========================================

class TestAnthropicBedrockAdapter:
    """Test Anthropic/Bedrock format transformations."""
    
    def test_transform_simple_request(self):
        """Test basic request transformation."""
        messages = [
            {"role": "user", "content": "Hello!"}
        ]
        
        result = AnthropicBedrockAdapter.transform_request(
            messages=messages,
            model="claude-3-sonnet",
            max_tokens=1024,
            temperature=0.7,
        )
        
        assert result["anthropic_version"] == "bedrock-2023-05-31"
        assert result["max_tokens"] == 1024
        assert result["temperature"] == 0.7
        assert len(result["messages"]) == 1
        assert result["messages"][0]["role"] == "user"
        assert result["messages"][0]["content"] == "Hello!"
        assert "system" not in result
    
    def test_transform_with_system_message(self):
        """Test request with system message extraction."""
        messages = [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "Hello!"}
        ]
        
        result = AnthropicBedrockAdapter.transform_request(
            messages=messages,
            model="claude-3-sonnet",
        )
        
        # System message should be extracted
        assert result["system"] == "You are a helpful assistant."
        # Only user message in messages array
        assert len(result["messages"]) == 1
        assert result["messages"][0]["role"] == "user"
    
    def test_transform_with_multiple_system_messages(self):
        """Test combining multiple system messages."""
        messages = [
            {"role": "system", "content": "You are helpful."},
            {"role": "system", "content": "Be concise."},
            {"role": "user", "content": "Hi"}
        ]
        
        result = AnthropicBedrockAdapter.transform_request(
            messages=messages,
            model="claude-3-sonnet",
        )
        
        # System messages should be combined
        assert "You are helpful." in result["system"]
        assert "Be concise." in result["system"]
    
    def test_transform_with_stop_sequences(self):
        """Test stop sequences transformation."""
        result = AnthropicBedrockAdapter.transform_request(
            messages=[{"role": "user", "content": "Hi"}],
            model="claude-3-sonnet",
            stop=["END", "STOP"],
        )
        
        assert result["stop_sequences"] == ["END", "STOP"]
    
    def test_transform_with_single_stop(self):
        """Test single stop string transformation."""
        result = AnthropicBedrockAdapter.transform_request(
            messages=[{"role": "user", "content": "Hi"}],
            model="claude-3-sonnet",
            stop="END",
        )
        
        assert result["stop_sequences"] == ["END"]
    
    def test_transform_response_basic(self):
        """Test basic response transformation."""
        anthropic_response = {
            "id": "msg_123",
            "type": "message",
            "content": [
                {"type": "text", "text": "Hello! How can I help?"}
            ],
            "stop_reason": "end_turn",
            "usage": {
                "input_tokens": 10,
                "output_tokens": 20,
            }
        }
        
        result = AnthropicBedrockAdapter.transform_response(
            response=anthropic_response,
            model="claude-3-sonnet",
        )
        
        assert result["object"] == "chat.completion"
        assert result["model"] == "claude-3-sonnet"
        assert len(result["choices"]) == 1
        assert result["choices"][0]["message"]["role"] == "assistant"
        assert result["choices"][0]["message"]["content"] == "Hello! How can I help?"
        assert result["choices"][0]["finish_reason"] == "stop"
        assert result["usage"]["prompt_tokens"] == 10
        assert result["usage"]["completion_tokens"] == 20
        assert result["usage"]["total_tokens"] == 30
    
    def test_transform_response_multiple_content_blocks(self):
        """Test response with multiple content blocks."""
        anthropic_response = {
            "id": "msg_123",
            "content": [
                {"type": "text", "text": "First part. "},
                {"type": "text", "text": "Second part."}
            ],
            "stop_reason": "end_turn",
        }
        
        result = AnthropicBedrockAdapter.transform_response(
            response=anthropic_response,
            model="claude-3-sonnet",
        )
        
        assert result["choices"][0]["message"]["content"] == "First part. Second part."
    
    def test_transform_response_max_tokens(self):
        """Test max_tokens stop reason mapping."""
        anthropic_response = {
            "content": [{"type": "text", "text": "Truncated..."}],
            "stop_reason": "max_tokens",
        }
        
        result = AnthropicBedrockAdapter.transform_response(
            response=anthropic_response,
            model="claude-3-sonnet",
        )
        
        assert result["choices"][0]["finish_reason"] == "length"


# ========================================
# SAP AI Core Client Tests
# ========================================

class TestSAPAICoreClient:
    """Test SAP AI Core client functionality."""
    
    @pytest.fixture
    def config(self):
        return AICoreConfig(
            base_url="https://api.ai.sap.com",
            client_id="test-client",
            client_secret="test-secret",
            auth_url="https://auth.sap.com",
            resource_group="default",
        )
    
    @pytest.fixture
    def client(self, config):
        return SAPAICoreClient(config)
    
    @pytest.mark.asyncio
    async def test_config_from_env(self):
        """Test config loading from environment."""
        with patch.dict('os.environ', {
            'AICORE_BASE_URL': 'https://test.api.ai.sap.com',
            'AICORE_CLIENT_ID': 'env-client-id',
            'AICORE_CLIENT_SECRET': 'env-secret',
            'AICORE_AUTH_URL': 'https://test.auth.sap.com',
            'AICORE_RESOURCE_GROUP': 'test-group',
        }):
            config = AICoreConfig.from_env()
            
            assert config.base_url == 'https://test.api.ai.sap.com'
            assert config.client_id == 'env-client-id'
            assert config.client_secret == 'env-secret'
            assert config.auth_url == 'https://test.auth.sap.com'
            assert config.resource_group == 'test-group'
    
    @pytest.mark.asyncio
    async def test_anthropic_completion_url(self, client, config):
        """Test Anthropic model uses /invoke endpoint."""
        mock_http = AsyncMock()
        mock_response = MagicMock()
        mock_response.json.return_value = {
            "content": [{"type": "text", "text": "Hi!"}],
            "stop_reason": "end_turn",
        }
        mock_response.raise_for_status = MagicMock()
        mock_http.post = AsyncMock(return_value=mock_response)
        
        client._http_client = mock_http
        client._access_token = "test-token"
        client._token_expires = 9999999999
        
        await client.chat_completion(
            model="claude-3-sonnet",
            messages=[{"role": "user", "content": "Hi"}],
            deployment_id="deploy-123",
        )
        
        # Verify /invoke endpoint was called
        call_args = mock_http.post.call_args
        url = call_args[0][0]
        assert "/invoke" in url
        assert "deploy-123" in url
    
    @pytest.mark.asyncio
    async def test_openai_completion_url(self, client, config):
        """Test OpenAI model uses /chat/completions endpoint."""
        mock_http = AsyncMock()
        mock_response = MagicMock()
        mock_response.json.return_value = {
            "choices": [{"message": {"content": "Hi!"}}],
        }
        mock_response.raise_for_status = MagicMock()
        mock_http.post = AsyncMock(return_value=mock_response)
        
        client._http_client = mock_http
        client._access_token = "test-token"
        client._token_expires = 9999999999
        
        await client.chat_completion(
            model="gpt-4",
            messages=[{"role": "user", "content": "Hi"}],
            deployment_id="deploy-456",
        )
        
        # Verify /chat/completions endpoint was called
        call_args = mock_http.post.call_args
        url = call_args[0][0]
        assert "/chat/completions" in url
        assert "deploy-456" in url
    
    @pytest.mark.asyncio
    async def test_anthropic_request_format(self, client, config):
        """Test Anthropic request uses bedrock format."""
        mock_http = AsyncMock()
        mock_response = MagicMock()
        mock_response.json.return_value = {
            "content": [{"type": "text", "text": "Hi!"}],
            "stop_reason": "end_turn",
        }
        mock_response.raise_for_status = MagicMock()
        mock_http.post = AsyncMock(return_value=mock_response)
        
        client._http_client = mock_http
        client._access_token = "test-token"
        client._token_expires = 9999999999
        
        await client.chat_completion(
            model="claude-3-sonnet",
            messages=[{"role": "user", "content": "Hi"}],
            deployment_id="deploy-123",
        )
        
        # Verify request body format
        call_args = mock_http.post.call_args
        request_body = call_args[1]["json"]
        
        assert request_body["anthropic_version"] == "bedrock-2023-05-31"
        assert "max_tokens" in request_body
        assert request_body["messages"][0]["content"] == "Hi"
    
    @pytest.mark.asyncio
    async def test_anthropic_response_normalized(self, client, config):
        """Test Anthropic response is normalized to OpenAI format."""
        mock_http = AsyncMock()
        mock_response = MagicMock()
        mock_response.json.return_value = {
            "id": "msg_123",
            "content": [{"type": "text", "text": "Hello from Claude!"}],
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 5, "output_tokens": 10},
        }
        mock_response.raise_for_status = MagicMock()
        mock_http.post = AsyncMock(return_value=mock_response)
        
        client._http_client = mock_http
        client._access_token = "test-token"
        client._token_expires = 9999999999
        
        result = await client.chat_completion(
            model="claude-3-sonnet",
            messages=[{"role": "user", "content": "Hi"}],
            deployment_id="deploy-123",
        )
        
        # Verify OpenAI format response
        assert result["object"] == "chat.completion"
        assert result["choices"][0]["message"]["role"] == "assistant"
        assert result["choices"][0]["message"]["content"] == "Hello from Claude!"
        assert result["usage"]["total_tokens"] == 15


# ========================================
# Run Tests
# ========================================

if __name__ == "__main__":
    pytest.main([__file__, "-v"])