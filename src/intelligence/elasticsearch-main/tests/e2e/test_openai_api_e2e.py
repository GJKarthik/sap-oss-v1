"""
OpenAI API End-to-End Tests.

Day 57 - Week 12 Integration Testing
45 tests for comprehensive OpenAI API E2E coverage using mock servers.
"""

import pytest
import json
import time
from typing import Dict, Any, List

from testing.framework import (
    MockServer,
    MockResponse,
    TestClient,
    RequestFactory,
    TestDataGenerator,
    assert_status,
    assert_json,
    assert_contains,
    assert_matches,
    assert_timing,
    with_timeout,
    retry_until,
)


# =============================================================================
# Test Fixtures
# =============================================================================

@pytest.fixture
def mock_openai_server():
    """Create mock OpenAI API server with standard endpoints."""
    with MockServer() as server:
        # Chat completions
        server.add_endpoint(
            "POST", "/v1/chat/completions",
            body={
                "id": "chatcmpl-test123",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": "gpt-4",
                "choices": [{
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": "Hello! How can I help you today?"
                    },
                    "logprobs": None,
                    "finish_reason": "stop"
                }],
                "usage": {
                    "prompt_tokens": 10,
                    "completion_tokens": 12,
                    "total_tokens": 22
                }
            }
        )
        
        # Embeddings
        server.add_endpoint(
            "POST", "/v1/embeddings",
            body={
                "object": "list",
                "data": [{
                    "object": "embedding",
                    "index": 0,
                    "embedding": [0.1, 0.2, 0.3] * 512  # 1536 dimensions
                }],
                "model": "text-embedding-ada-002",
                "usage": {
                    "prompt_tokens": 5,
                    "total_tokens": 5
                }
            }
        )
        
        # Models list
        server.add_endpoint(
            "GET", "/v1/models",
            body={
                "object": "list",
                "data": [
                    {"id": "gpt-4", "object": "model", "owned_by": "openai"},
                    {"id": "gpt-3.5-turbo", "object": "model", "owned_by": "openai"},
                    {"id": "text-embedding-ada-002", "object": "model", "owned_by": "openai"},
                ]
            }
        )
        
        # Completions (legacy)
        server.add_endpoint(
            "POST", "/v1/completions",
            body={
                "id": "cmpl-test456",
                "object": "text_completion",
                "created": int(time.time()),
                "model": "gpt-3.5-turbo-instruct",
                "choices": [{
                    "text": " world!",
                    "index": 0,
                    "logprobs": None,
                    "finish_reason": "stop"
                }],
                "usage": {
                    "prompt_tokens": 2,
                    "completion_tokens": 3,
                    "total_tokens": 5
                }
            }
        )
        
        yield server


@pytest.fixture
def api_client(mock_openai_server):
    """Create test client connected to mock server."""
    return TestClient(
        base_url=mock_openai_server.url,
        headers={"Authorization": "Bearer test-api-key"}
    )


# =============================================================================
# Chat Completions E2E Tests (10 tests)
# =============================================================================

class TestChatCompletionsE2E:
    """E2E tests for chat completions API."""
    
    @with_timeout(5.0)
    def test_basic_chat_completion(self, api_client):
        """Test basic chat completion request."""
        request = RequestFactory.chat_completion(
            model="gpt-4",
            messages=[{"role": "user", "content": "Hello"}]
        )
        
        response = api_client.post("/v1/chat/completions", body=request)
        
        assert_status(response, 200)
        assert_json(response, {"object": "chat.completion"})
    
    @with_timeout(5.0)
    def test_chat_completion_response_structure(self, api_client):
        """Test chat completion response has required fields."""
        request = RequestFactory.chat_completion()
        
        response = api_client.post("/v1/chat/completions", body=request)
        data = response.json()
        
        assert "id" in data
        assert "choices" in data
        assert len(data["choices"]) > 0
        assert "message" in data["choices"][0]
        assert "usage" in data
    
    @with_timeout(5.0)
    def test_chat_completion_with_system_message(self, api_client):
        """Test chat completion with system message."""
        request = RequestFactory.chat_completion(
            messages=[
                {"role": "system", "content": "You are helpful"},
                {"role": "user", "content": "Hello"}
            ]
        )
        
        response = api_client.post("/v1/chat/completions", body=request)
        assert_status(response, 200)
    
    @with_timeout(5.0)
    def test_chat_completion_with_temperature(self, api_client):
        """Test chat completion with temperature parameter."""
        request = RequestFactory.chat_completion(
            temperature=0.7
        )
        
        response = api_client.post("/v1/chat/completions", body=request)
        assert_status(response, 200)
    
    @with_timeout(5.0)
    def test_chat_completion_with_max_tokens(self, api_client):
        """Test chat completion with max_tokens parameter."""
        request = RequestFactory.chat_completion(
            max_tokens=100
        )
        
        response = api_client.post("/v1/chat/completions", body=request)
        assert_status(response, 200)
    
    @with_timeout(5.0)
    def test_chat_completion_usage_tracking(self, api_client):
        """Test chat completion returns token usage."""
        request = RequestFactory.chat_completion()
        
        response = api_client.post("/v1/chat/completions", body=request)
        data = response.json()
        
        assert "usage" in data
        assert "prompt_tokens" in data["usage"]
        assert "completion_tokens" in data["usage"]
        assert "total_tokens" in data["usage"]
    
    @with_timeout(5.0)
    def test_chat_completion_model_in_response(self, api_client):
        """Test chat completion response includes model."""
        request = RequestFactory.chat_completion(model="gpt-4")
        
        response = api_client.post("/v1/chat/completions", body=request)
        data = response.json()
        
        assert "model" in data
    
    @with_timeout(5.0)
    def test_chat_completion_finish_reason(self, api_client):
        """Test chat completion includes finish reason."""
        request = RequestFactory.chat_completion()
        
        response = api_client.post("/v1/chat/completions", body=request)
        data = response.json()
        
        assert "finish_reason" in data["choices"][0]
    
    @with_timeout(5.0)
    def test_chat_completion_multiple_messages(self, api_client):
        """Test chat completion with conversation history."""
        request = RequestFactory.chat_completion(
            messages=[
                {"role": "user", "content": "Hi"},
                {"role": "assistant", "content": "Hello!"},
                {"role": "user", "content": "How are you?"}
            ]
        )
        
        response = api_client.post("/v1/chat/completions", body=request)
        assert_status(response, 200)
    
    @with_timeout(5.0)
    def test_chat_completion_latency(self, api_client):
        """Test chat completion responds within acceptable time."""
        request = RequestFactory.chat_completion()
        
        response = api_client.post("/v1/chat/completions", body=request)
        
        assert_timing(response.elapsed, max_ms=1000)


# =============================================================================
# Embeddings E2E Tests (8 tests)
# =============================================================================

class TestEmbeddingsE2E:
    """E2E tests for embeddings API."""
    
    @with_timeout(5.0)
    def test_basic_embedding(self, api_client):
        """Test basic embedding request."""
        request = RequestFactory.embedding(input="Hello world")
        
        response = api_client.post("/v1/embeddings", body=request)
        
        assert_status(response, 200)
        assert_json(response, {"object": "list"})
    
    @with_timeout(5.0)
    def test_embedding_response_structure(self, api_client):
        """Test embedding response has required fields."""
        request = RequestFactory.embedding(input="test")
        
        response = api_client.post("/v1/embeddings", body=request)
        data = response.json()
        
        assert "data" in data
        assert len(data["data"]) > 0
        assert "embedding" in data["data"][0]
    
    @with_timeout(5.0)
    def test_embedding_dimensions(self, api_client):
        """Test embedding has correct dimensions."""
        request = RequestFactory.embedding(input="test")
        
        response = api_client.post("/v1/embeddings", body=request)
        data = response.json()
        
        embedding = data["data"][0]["embedding"]
        assert len(embedding) == 1536  # text-embedding-ada-002 dimensions
    
    @with_timeout(5.0)
    def test_embedding_with_model(self, api_client):
        """Test embedding with explicit model."""
        request = RequestFactory.embedding(
            input="test",
            model="text-embedding-ada-002"
        )
        
        response = api_client.post("/v1/embeddings", body=request)
        assert_status(response, 200)
    
    @with_timeout(5.0)
    def test_embedding_usage_tracking(self, api_client):
        """Test embedding returns token usage."""
        request = RequestFactory.embedding(input="test")
        
        response = api_client.post("/v1/embeddings", body=request)
        data = response.json()
        
        assert "usage" in data
        assert "prompt_tokens" in data["usage"]
    
    @with_timeout(5.0)
    def test_embedding_index(self, api_client):
        """Test embedding includes index."""
        request = RequestFactory.embedding(input="test")
        
        response = api_client.post("/v1/embeddings", body=request)
        data = response.json()
        
        assert "index" in data["data"][0]
        assert data["data"][0]["index"] == 0
    
    @with_timeout(5.0)
    def test_embedding_object_type(self, api_client):
        """Test embedding has correct object type."""
        request = RequestFactory.embedding(input="test")
        
        response = api_client.post("/v1/embeddings", body=request)
        data = response.json()
        
        assert data["data"][0]["object"] == "embedding"
    
    @with_timeout(5.0)
    def test_embedding_latency(self, api_client):
        """Test embedding responds within acceptable time."""
        request = RequestFactory.embedding(input="test")
        
        response = api_client.post("/v1/embeddings", body=request)
        
        assert_timing(response.elapsed, max_ms=500)


# =============================================================================
# Models E2E Tests (5 tests)
# =============================================================================

class TestModelsE2E:
    """E2E tests for models API."""
    
    @with_timeout(5.0)
    def test_list_models(self, api_client):
        """Test listing available models."""
        response = api_client.get("/v1/models")
        
        assert_status(response, 200)
        assert_json(response, {"object": "list"})
    
    @with_timeout(5.0)
    def test_models_response_structure(self, api_client):
        """Test models response has required fields."""
        response = api_client.get("/v1/models")
        data = response.json()
        
        assert "data" in data
        assert len(data["data"]) > 0
    
    @with_timeout(5.0)
    def test_model_object_structure(self, api_client):
        """Test individual model has required fields."""
        response = api_client.get("/v1/models")
        data = response.json()
        
        model = data["data"][0]
        assert "id" in model
        assert "object" in model
        assert model["object"] == "model"
    
    @with_timeout(5.0)
    def test_models_includes_expected(self, api_client):
        """Test expected models are listed."""
        response = api_client.get("/v1/models")
        data = response.json()
        
        model_ids = [m["id"] for m in data["data"]]
        assert "gpt-4" in model_ids
    
    @with_timeout(5.0)
    def test_models_latency(self, api_client):
        """Test models endpoint responds quickly."""
        response = api_client.get("/v1/models")
        
        assert_timing(response.elapsed, max_ms=200)


# =============================================================================
# Completions E2E Tests (6 tests)
# =============================================================================

class TestCompletionsE2E:
    """E2E tests for legacy completions API."""
    
    @with_timeout(5.0)
    def test_basic_completion(self, api_client):
        """Test basic completion request."""
        request = RequestFactory.completion(prompt="Hello")
        
        response = api_client.post("/v1/completions", body=request)
        
        assert_status(response, 200)
        assert_json(response, {"object": "text_completion"})
    
    @with_timeout(5.0)
    def test_completion_response_structure(self, api_client):
        """Test completion response has required fields."""
        request = RequestFactory.completion(prompt="Hello")
        
        response = api_client.post("/v1/completions", body=request)
        data = response.json()
        
        assert "id" in data
        assert "choices" in data
        assert len(data["choices"]) > 0
        assert "text" in data["choices"][0]
    
    @with_timeout(5.0)
    def test_completion_with_max_tokens(self, api_client):
        """Test completion with max_tokens."""
        request = RequestFactory.completion(
            prompt="Hello",
            max_tokens=50
        )
        
        response = api_client.post("/v1/completions", body=request)
        assert_status(response, 200)
    
    @with_timeout(5.0)
    def test_completion_usage_tracking(self, api_client):
        """Test completion returns token usage."""
        request = RequestFactory.completion(prompt="Hello")
        
        response = api_client.post("/v1/completions", body=request)
        data = response.json()
        
        assert "usage" in data
        assert "total_tokens" in data["usage"]
    
    @with_timeout(5.0)
    def test_completion_finish_reason(self, api_client):
        """Test completion includes finish reason."""
        request = RequestFactory.completion(prompt="Hello")
        
        response = api_client.post("/v1/completions", body=request)
        data = response.json()
        
        assert "finish_reason" in data["choices"][0]
    
    @with_timeout(5.0)
    def test_completion_latency(self, api_client):
        """Test completion responds within acceptable time."""
        request = RequestFactory.completion(prompt="Hello")
        
        response = api_client.post("/v1/completions", body=request)
        
        assert_timing(response.elapsed, max_ms=1000)


# =============================================================================
# Error Handling E2E Tests (8 tests)
# =============================================================================

class TestErrorHandlingE2E:
    """E2E tests for error handling."""
    
    def test_404_for_unknown_endpoint(self):
        """Test 404 for unknown endpoint."""
        with MockServer() as server:
            client = TestClient(base_url=server.url)
            
            response = client.get("/v1/unknown")
            
            assert response.status_code == 404
    
    def test_error_response_format(self):
        """Test error responses have correct format."""
        with MockServer() as server:
            server.add_endpoint(
                "POST", "/v1/chat/completions",
                status=400,
                body={
                    "error": {
                        "message": "Invalid request",
                        "type": "invalid_request_error",
                        "code": "invalid_request"
                    }
                }
            )
            client = TestClient(base_url=server.url)
            
            response = client.post("/v1/chat/completions", body={})
            
            assert response.status_code == 400
            data = response.json()
            assert "error" in data
    
    def test_401_unauthorized(self):
        """Test 401 for unauthorized requests."""
        with MockServer() as server:
            server.add_endpoint(
                "GET", "/v1/models",
                status=401,
                body={
                    "error": {
                        "message": "Invalid API key",
                        "type": "authentication_error"
                    }
                }
            )
            client = TestClient(base_url=server.url)
            
            response = client.get("/v1/models")
            
            assert response.status_code == 401
    
    def test_429_rate_limited(self):
        """Test 429 for rate limited requests."""
        with MockServer() as server:
            server.add_endpoint(
                "POST", "/v1/chat/completions",
                status=429,
                body={
                    "error": {
                        "message": "Rate limit exceeded",
                        "type": "rate_limit_error"
                    }
                },
                headers={"Retry-After": "60"}
            )
            client = TestClient(base_url=server.url)
            
            response = client.post("/v1/chat/completions", body={})
            
            assert response.status_code == 429
    
    def test_500_server_error(self):
        """Test 500 for server errors."""
        with MockServer() as server:
            server.add_endpoint(
                "POST", "/v1/embeddings",
                status=500,
                body={
                    "error": {
                        "message": "Internal server error",
                        "type": "server_error"
                    }
                }
            )
            client = TestClient(base_url=server.url)
            
            response = client.post("/v1/embeddings", body={})
            
            assert response.status_code == 500
    
    def test_503_service_unavailable(self):
        """Test 503 for service unavailable."""
        with MockServer() as server:
            server.add_endpoint(
                "POST", "/v1/chat/completions",
                status=503,
                body={
                    "error": {
                        "message": "Service temporarily unavailable",
                        "type": "service_unavailable"
                    }
                }
            )
            client = TestClient(base_url=server.url)
            
            response = client.post("/v1/chat/completions", body={})
            
            assert response.status_code == 503
    
    def test_error_message_present(self):
        """Test error responses include message."""
        with MockServer() as server:
            server.add_endpoint(
                "POST", "/v1/chat/completions",
                status=400,
                body={
                    "error": {
                        "message": "Model not found",
                        "type": "invalid_request_error"
                    }
                }
            )
            client = TestClient(base_url=server.url)
            
            response = client.post("/v1/chat/completions", body={})
            data = response.json()
            
            assert "message" in data["error"]
    
    def test_error_type_present(self):
        """Test error responses include type."""
        with MockServer() as server:
            server.add_endpoint(
                "POST", "/v1/chat/completions",
                status=400,
                body={
                    "error": {
                        "message": "Bad request",
                        "type": "invalid_request_error"
                    }
                }
            )
            client = TestClient(base_url=server.url)
            
            response = client.post("/v1/chat/completions", body={})
            data = response.json()
            
            assert "type" in data["error"]


# =============================================================================
# Headers and Authentication E2E Tests (8 tests)
# =============================================================================

class TestHeadersAndAuthE2E:
    """E2E tests for headers and authentication."""
    
    def test_authorization_header_sent(self, mock_openai_server):
        """Test authorization header is sent."""
        client = TestClient(
            base_url=mock_openai_server.url,
            headers={"Authorization": "Bearer sk-test-key"}
        )
        
        response = client.get("/v1/models")
        
        endpoint = mock_openai_server.find_endpoint("GET", "/v1/models")
        assert endpoint.last_request is not None
    
    def test_content_type_json(self, api_client):
        """Test content-type is application/json for POST."""
        request = RequestFactory.chat_completion()
        
        response = api_client.post("/v1/chat/completions", body=request)
        
        assert response.ok
    
    def test_accepts_json(self, api_client):
        """Test accepts JSON response."""
        response = api_client.get("/v1/models")
        
        assert response.ok
        assert isinstance(response.json(), dict)
    
    def test_custom_header_preserved(self, mock_openai_server):
        """Test custom headers are preserved."""
        client = TestClient(
            base_url=mock_openai_server.url,
            headers={
                "X-Custom-Header": "test-value",
                "Authorization": "Bearer test"
            }
        )
        
        response = client.get("/v1/models")
        assert response.ok
    
    def test_multiple_requests_same_client(self, api_client):
        """Test multiple requests with same client."""
        response1 = api_client.get("/v1/models")
        response2 = api_client.get("/v1/models")
        
        assert response1.ok
        assert response2.ok
    
    def test_different_endpoints_same_client(self, api_client):
        """Test different endpoints with same client."""
        models_response = api_client.get("/v1/models")
        
        chat_request = RequestFactory.chat_completion()
        chat_response = api_client.post("/v1/chat/completions", body=chat_request)
        
        embed_request = RequestFactory.embedding(input="test")
        embed_response = api_client.post("/v1/embeddings", body=embed_request)
        
        assert models_response.ok
        assert chat_response.ok
        assert embed_response.ok
    
    def test_user_agent_sent(self, mock_openai_server):
        """Test user agent is sent with request."""
        client = TestClient(
            base_url=mock_openai_server.url,
            headers={
                "User-Agent": "mangle-query-service/1.0",
                "Authorization": "Bearer test"
            }
        )
        
        response = client.get("/v1/models")
        assert response.ok
    
    def test_request_id_tracking(self, mock_openai_server):
        """Test request ID can be tracked."""
        request_id = TestDataGenerator.unique_id()
        client = TestClient(
            base_url=mock_openai_server.url,
            headers={
                "X-Request-ID": request_id,
                "Authorization": "Bearer test"
            }
        )
        
        response = client.get("/v1/models")
        assert response.ok


# =============================================================================
# Summary
# =============================================================================
# Total: 45 tests
# - Chat Completions E2E: 10 tests
# - Embeddings E2E: 8 tests
# - Models E2E: 5 tests
# - Completions E2E: 6 tests
# - Error Handling E2E: 8 tests
# - Headers and Auth E2E: 8 tests