"""
Unit Tests for HTTP Client

Day 1 Deliverable: Comprehensive tests for http_client.py
Target: >80% code coverage
"""

import asyncio
import json
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from typing import AsyncIterator

# Import the modules under test
from mangle_query_service.connectors.http_client import (
    HTTPClientConfig,
    HTTPResponse,
    StreamingResponse,
    AsyncHTTPClient,
    OpenAIHTTPClient,
    HTTPClientError,
    ConnectionError,
    TimeoutError,
    ServerError,
    ClientError,
    get_http_client,
    close_http_client,
)


# ========================================
# Fixtures
# ========================================

@pytest.fixture
def config():
    """Create test configuration."""
    return HTTPClientConfig(
        max_connections=10,
        connect_timeout=1.0,
        read_timeout=5.0,
        log_requests=False,
        log_responses=False,
    )


@pytest.fixture
async def client(config):
    """Create and return a test HTTP client."""
    client = AsyncHTTPClient(config)
    yield client
    await client.close()


# ========================================
# HTTPClientConfig Tests
# ========================================

class TestHTTPClientConfig:
    """Tests for HTTPClientConfig."""
    
    def test_default_values(self):
        """Test default configuration values."""
        config = HTTPClientConfig()
        
        assert config.max_connections == 100
        assert config.connect_timeout == 5.0
        assert config.read_timeout == 30.0
        assert config.log_requests is True
        assert config.log_responses is True
    
    def test_from_env(self):
        """Test creating config from environment variables."""
        with patch.dict('os.environ', {
            'HTTP_MAX_CONNECTIONS': '50',
            'HTTP_CONNECT_TIMEOUT': '10.0',
            'HTTP_READ_TIMEOUT': '60.0',
            'HTTP_LOG_REQUESTS': 'false',
        }):
            config = HTTPClientConfig.from_env()
            
            assert config.max_connections == 50
            assert config.connect_timeout == 10.0
            assert config.read_timeout == 60.0
            assert config.log_requests is False
    
    def test_custom_values(self):
        """Test custom configuration values."""
        config = HTTPClientConfig(
            max_connections=200,
            connect_timeout=3.0,
            stream_timeout=180.0,
        )
        
        assert config.max_connections == 200
        assert config.connect_timeout == 3.0
        assert config.stream_timeout == 180.0


# ========================================
# HTTPResponse Tests
# ========================================

class TestHTTPResponse:
    """Tests for HTTPResponse."""
    
    def test_is_success_200(self):
        """Test success for 200 status."""
        response = HTTPResponse(
            status_code=200,
            headers={},
            body=b'{"result": "ok"}',
            elapsed_ms=100.0,
        )
        
        assert response.is_success is True
        assert response.is_client_error is False
        assert response.is_server_error is False
    
    def test_is_success_201(self):
        """Test success for 201 status."""
        response = HTTPResponse(
            status_code=201,
            headers={},
            body=b'{}',
            elapsed_ms=50.0,
        )
        
        assert response.is_success is True
    
    def test_is_client_error_400(self):
        """Test client error for 400 status."""
        response = HTTPResponse(
            status_code=400,
            headers={},
            body=b'{"error": "bad request"}',
            elapsed_ms=50.0,
        )
        
        assert response.is_success is False
        assert response.is_client_error is True
        assert response.is_server_error is False
    
    def test_is_server_error_500(self):
        """Test server error for 500 status."""
        response = HTTPResponse(
            status_code=500,
            headers={},
            body=b'{"error": "internal error"}',
            elapsed_ms=200.0,
        )
        
        assert response.is_success is False
        assert response.is_client_error is False
        assert response.is_server_error is True
    
    def test_json_parsing(self):
        """Test JSON body parsing."""
        response = HTTPResponse(
            status_code=200,
            headers={"content-type": "application/json"},
            body=b'{"model": "gpt-4", "choices": []}',
            elapsed_ms=100.0,
        )
        
        data = response.json()
        assert data["model"] == "gpt-4"
        assert data["choices"] == []
    
    def test_text_decoding(self):
        """Test text body decoding."""
        response = HTTPResponse(
            status_code=200,
            headers={},
            body=b'Hello, World!',
            elapsed_ms=50.0,
        )
        
        assert response.text() == "Hello, World!"
    
    def test_request_id(self):
        """Test request ID storage."""
        response = HTTPResponse(
            status_code=200,
            headers={},
            body=b'',
            elapsed_ms=50.0,
            request_id="req-123456",
        )
        
        assert response.request_id == "req-123456"


# ========================================
# StreamingResponse Tests
# ========================================

class TestStreamingResponse:
    """Tests for StreamingResponse."""
    
    def test_is_success(self):
        """Test success check for streaming response."""
        async def empty_stream():
            yield b''
        
        response = StreamingResponse(
            status_code=200,
            headers={"content-type": "text/event-stream"},
            stream=empty_stream(),
        )
        
        assert response.is_success is True
    
    def test_not_success(self):
        """Test non-success streaming response."""
        async def empty_stream():
            yield b''
        
        response = StreamingResponse(
            status_code=500,
            headers={},
            stream=empty_stream(),
        )
        
        assert response.is_success is False


# ========================================
# Exception Tests
# ========================================

class TestExceptions:
    """Tests for HTTP client exceptions."""
    
    def test_connection_error(self):
        """Test ConnectionError exception."""
        error = ConnectionError("Failed to connect to localhost:8080")
        
        assert "Failed to connect" in str(error)
        assert isinstance(error, HTTPClientError)
    
    def test_timeout_error(self):
        """Test TimeoutError exception."""
        error = TimeoutError("Request timed out after 30s")
        
        assert "timed out" in str(error)
        assert isinstance(error, HTTPClientError)
    
    def test_server_error(self):
        """Test ServerError exception."""
        error = ServerError(503, b'{"error": "service unavailable"}')
        
        assert error.status_code == 503
        assert error.body == b'{"error": "service unavailable"}'
        assert "Server error: 503" in str(error)
    
    def test_client_error(self):
        """Test ClientError exception."""
        error = ClientError(401, b'{"error": "unauthorized"}')
        
        assert error.status_code == 401
        assert error.body == b'{"error": "unauthorized"}'
        assert "Client error: 401" in str(error)


# ========================================
# AsyncHTTPClient Tests
# ========================================

class TestAsyncHTTPClient:
    """Tests for AsyncHTTPClient."""
    
    @pytest.mark.asyncio
    async def test_client_initialization(self, config):
        """Test client initialization."""
        client = AsyncHTTPClient(config)
        
        assert client.config == config
        assert client._client is None
        
        await client.start()
        assert client._client is not None
        
        await client.close()
        assert client._client is None
    
    @pytest.mark.asyncio
    async def test_context_manager(self, config):
        """Test async context manager."""
        async with AsyncHTTPClient(config) as client:
            assert client._client is not None
        
        assert client._client is None
    
    @pytest.mark.asyncio
    async def test_generate_request_id(self, config):
        """Test request ID generation."""
        client = AsyncHTTPClient(config)
        
        id1 = client._generate_request_id()
        id2 = client._generate_request_id()
        
        assert id1 != id2
        assert id1.startswith("req-")
        assert id2.startswith("req-")
    
    @pytest.mark.asyncio
    async def test_post_request(self, config):
        """Test POST request with mocked httpx."""
        import httpx
        
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.headers = {"content-type": "application/json"}
        mock_response.aread = AsyncMock(return_value=b'{"result": "success"}')
        
        with patch('httpx.AsyncClient') as MockClient:
            mock_client_instance = MagicMock()
            mock_client_instance.request = AsyncMock(return_value=mock_response)
            mock_client_instance.aclose = AsyncMock()
            MockClient.return_value = mock_client_instance
            
            async with AsyncHTTPClient(config) as client:
                response = await client.post(
                    "http://localhost:8080/v1/chat/completions",
                    json={"model": "gpt-4", "messages": []},
                )
                
                assert response.status_code == 200
                assert response.json()["result"] == "success"
    
    @pytest.mark.asyncio
    async def test_get_request(self, config):
        """Test GET request with mocked httpx."""
        import httpx
        
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.headers = {}
        mock_response.aread = AsyncMock(return_value=b'OK')
        
        with patch('httpx.AsyncClient') as MockClient:
            mock_client_instance = MagicMock()
            mock_client_instance.request = AsyncMock(return_value=mock_response)
            mock_client_instance.aclose = AsyncMock()
            MockClient.return_value = mock_client_instance
            
            async with AsyncHTTPClient(config) as client:
                response = await client.get("http://localhost:8080/health")
                
                assert response.status_code == 200
                assert response.text() == "OK"
    
    @pytest.mark.asyncio
    async def test_connection_error_handling(self, config):
        """Test connection error is properly wrapped."""
        import httpx
        
        with patch('httpx.AsyncClient') as MockClient:
            mock_client_instance = MagicMock()
            mock_client_instance.request = AsyncMock(
                side_effect=httpx.ConnectError("Connection refused")
            )
            mock_client_instance.aclose = AsyncMock()
            MockClient.return_value = mock_client_instance
            
            async with AsyncHTTPClient(config) as client:
                with pytest.raises(ConnectionError) as exc_info:
                    await client.get("http://localhost:8080/health")
                
                assert "Failed to connect" in str(exc_info.value)
    
    @pytest.mark.asyncio
    async def test_timeout_error_handling(self, config):
        """Test timeout error is properly wrapped."""
        import httpx
        
        with patch('httpx.AsyncClient') as MockClient:
            mock_client_instance = MagicMock()
            mock_client_instance.request = AsyncMock(
                side_effect=httpx.TimeoutException("Read timeout")
            )
            mock_client_instance.aclose = AsyncMock()
            MockClient.return_value = mock_client_instance
            
            async with AsyncHTTPClient(config) as client:
                with pytest.raises(TimeoutError) as exc_info:
                    await client.get("http://localhost:8080/slow")
                
                assert "timed out" in str(exc_info.value)


# ========================================
# OpenAIHTTPClient Tests
# ========================================

class TestOpenAIHTTPClient:
    """Tests for OpenAI-specific HTTP client."""
    
    @pytest.mark.asyncio
    async def test_chat_completions_non_streaming(self, config):
        """Test non-streaming chat completions."""
        import httpx
        
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.headers = {"content-type": "application/json"}
        mock_response.aread = AsyncMock(return_value=b'''{
            "id": "chatcmpl-123",
            "object": "chat.completion",
            "choices": [{"message": {"content": "Hello!"}}]
        }''')
        
        with patch('httpx.AsyncClient') as MockClient:
            mock_client_instance = MagicMock()
            mock_client_instance.request = AsyncMock(return_value=mock_response)
            mock_client_instance.aclose = AsyncMock()
            MockClient.return_value = mock_client_instance
            
            async with OpenAIHTTPClient(config) as client:
                response = await client.chat_completions(
                    endpoint="http://localhost:8080/v1",
                    model="gpt-4",
                    messages=[{"role": "user", "content": "Hi"}],
                    stream=False,
                )
                
                assert response.status_code == 200
                data = response.json()
                assert data["id"] == "chatcmpl-123"
    
    @pytest.mark.asyncio
    async def test_parse_sse_stream(self):
        """Test SSE stream parsing."""
        async def mock_stream() -> AsyncIterator[bytes]:
            yield b'data: {"id": "1", "choices": [{"delta": {"content": "Hello"}}]}\n\n'
            yield b'data: {"id": "1", "choices": [{"delta": {"content": " World"}}]}\n\n'
            yield b'data: [DONE]\n\n'
        
        chunks = []
        async for chunk in OpenAIHTTPClient.parse_sse_stream(mock_stream()):
            chunks.append(chunk)
        
        assert len(chunks) == 2
        assert chunks[0]["choices"][0]["delta"]["content"] == "Hello"
        assert chunks[1]["choices"][0]["delta"]["content"] == " World"
    
    @pytest.mark.asyncio
    async def test_parse_sse_stream_with_empty_lines(self):
        """Test SSE parsing handles empty lines."""
        async def mock_stream() -> AsyncIterator[bytes]:
            yield b'\n'
            yield b': comment\n'
            yield b'data: {"id": "1"}\n\n'
            yield b'\n'
            yield b'data: [DONE]\n\n'
        
        chunks = []
        async for chunk in OpenAIHTTPClient.parse_sse_stream(mock_stream()):
            chunks.append(chunk)
        
        assert len(chunks) == 1
        assert chunks[0]["id"] == "1"
    
    @pytest.mark.asyncio
    async def test_parse_sse_stream_malformed_json(self):
        """Test SSE parsing handles malformed JSON gracefully."""
        async def mock_stream() -> AsyncIterator[bytes]:
            yield b'data: not-valid-json\n\n'
            yield b'data: {"id": "2"}\n\n'
            yield b'data: [DONE]\n\n'
        
        chunks = []
        async for chunk in OpenAIHTTPClient.parse_sse_stream(mock_stream()):
            chunks.append(chunk)
        
        # Should skip malformed JSON and continue
        assert len(chunks) == 1
        assert chunks[0]["id"] == "2"


# ========================================
# Global Client Tests
# ========================================

class TestGlobalClient:
    """Tests for global client functions."""
    
    @pytest.mark.asyncio
    async def test_get_http_client_creates_singleton(self):
        """Test that get_http_client returns singleton."""
        # Reset global state
        import mangle_query_service.connectors.http_client as module
        module._global_client = None
        
        with patch('httpx.AsyncClient') as MockClient:
            mock_client_instance = MagicMock()
            mock_client_instance.aclose = AsyncMock()
            MockClient.return_value = mock_client_instance
            
            client1 = await get_http_client()
            client2 = await get_http_client()
            
            assert client1 is client2
            
            await close_http_client()
            assert module._global_client is None
    
    @pytest.mark.asyncio
    async def test_close_http_client_handles_none(self):
        """Test close handles None client gracefully."""
        import mangle_query_service.connectors.http_client as module
        module._global_client = None
        
        # Should not raise
        await close_http_client()


# ========================================
# Integration-like Tests (with mocks)
# ========================================

class TestHTTPClientIntegration:
    """Integration-style tests with mocked backends."""
    
    @pytest.mark.asyncio
    async def test_full_request_response_cycle(self, config):
        """Test complete request-response cycle."""
        import httpx
        
        # Simulate a realistic OpenAI response
        openai_response = {
            "id": "chatcmpl-abc123",
            "object": "chat.completion",
            "created": 1699000000,
            "model": "gpt-4",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": "Hello! How can I help you today?"
                },
                "finish_reason": "stop"
            }],
            "usage": {
                "prompt_tokens": 10,
                "completion_tokens": 8,
                "total_tokens": 18
            }
        }
        
        mock_response = MagicMock()
        mock_response.status_code = 200
        mock_response.headers = {"content-type": "application/json"}
        mock_response.aread = AsyncMock(
            return_value=json.dumps(openai_response).encode()
        )
        
        with patch('httpx.AsyncClient') as MockClient:
            mock_client_instance = MagicMock()
            mock_client_instance.request = AsyncMock(return_value=mock_response)
            mock_client_instance.aclose = AsyncMock()
            MockClient.return_value = mock_client_instance
            
            async with AsyncHTTPClient(config) as client:
                response = await client.post(
                    "http://backend:8080/v1/chat/completions",
                    json={
                        "model": "gpt-4",
                        "messages": [{"role": "user", "content": "Hello"}]
                    }
                )
                
                assert response.is_success
                data = response.json()
                assert data["model"] == "gpt-4"
                assert len(data["choices"]) == 1
                assert "Hello!" in data["choices"][0]["message"]["content"]


# ========================================
# Run Tests
# ========================================

if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])