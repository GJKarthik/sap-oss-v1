"""
Production HTTP Client for Mangle Query Service

Day 1 Deliverable: Real HTTP client implementation with:
- Connection pooling (max 100 connections)
- Configurable timeouts (connect: 5s, read: 30s)
- Streaming support for SSE responses
- Request/response logging
- Error handling

Replaces mock responses in unified_router.py
"""

import asyncio
import os
import time
import json
from typing import Optional, Dict, Any, AsyncIterator, Union
from dataclasses import dataclass, field
from contextlib import asynccontextmanager
from datetime import datetime
import logging

import httpx

logger = logging.getLogger(__name__)


# ========================================
# Configuration
# ========================================

@dataclass
class HTTPClientConfig:
    """HTTP client configuration."""
    
    # Connection settings
    max_connections: int = 100
    max_keepalive_connections: int = 20
    keepalive_expiry: float = 30.0
    
    # Timeout settings (seconds)
    connect_timeout: float = 5.0
    read_timeout: float = 30.0
    write_timeout: float = 30.0
    pool_timeout: float = 10.0
    
    # Streaming settings
    stream_timeout: float = 120.0
    stream_chunk_size: int = 1024
    
    # Retry settings (handled by retry middleware, not here)
    # This client is low-level, retry logic is separate
    
    # Debug settings
    log_requests: bool = True
    log_responses: bool = True
    log_body_max_length: int = 1000
    
    @classmethod
    def from_env(cls) -> "HTTPClientConfig":
        """Create config from environment variables."""
        return cls(
            max_connections=int(os.getenv("HTTP_MAX_CONNECTIONS", "100")),
            max_keepalive_connections=int(os.getenv("HTTP_MAX_KEEPALIVE", "20")),
            connect_timeout=float(os.getenv("HTTP_CONNECT_TIMEOUT", "5.0")),
            read_timeout=float(os.getenv("HTTP_READ_TIMEOUT", "30.0")),
            write_timeout=float(os.getenv("HTTP_WRITE_TIMEOUT", "30.0")),
            stream_timeout=float(os.getenv("HTTP_STREAM_TIMEOUT", "120.0")),
            log_requests=os.getenv("HTTP_LOG_REQUESTS", "true").lower() == "true",
            log_responses=os.getenv("HTTP_LOG_RESPONSES", "true").lower() == "true",
        )


# ========================================
# Response Models
# ========================================

@dataclass
class HTTPResponse:
    """HTTP response wrapper."""
    status_code: int
    headers: Dict[str, str]
    body: bytes
    elapsed_ms: float
    request_id: Optional[str] = None
    
    @property
    def is_success(self) -> bool:
        return 200 <= self.status_code < 300
    
    @property
    def is_client_error(self) -> bool:
        return 400 <= self.status_code < 500
    
    @property
    def is_server_error(self) -> bool:
        return 500 <= self.status_code < 600
    
    def json(self) -> Any:
        """Parse body as JSON."""
        return json.loads(self.body)
    
    def text(self) -> str:
        """Decode body as text."""
        return self.body.decode("utf-8")


@dataclass
class StreamingResponse:
    """Streaming response wrapper for SSE."""
    status_code: int
    headers: Dict[str, str]
    stream: AsyncIterator[bytes]
    request_id: Optional[str] = None
    
    @property
    def is_success(self) -> bool:
        return 200 <= self.status_code < 300


# ========================================
# Exceptions
# ========================================

class HTTPClientError(Exception):
    """Base HTTP client error."""
    pass


class ConnectionError(HTTPClientError):
    """Failed to connect to server."""
    pass


class TimeoutError(HTTPClientError):
    """Request timed out."""
    pass


class ServerError(HTTPClientError):
    """Server returned 5xx error."""
    def __init__(self, status_code: int, body: bytes):
        self.status_code = status_code
        self.body = body
        super().__init__(f"Server error: {status_code}")


class ClientError(HTTPClientError):
    """Server returned 4xx error."""
    def __init__(self, status_code: int, body: bytes):
        self.status_code = status_code
        self.body = body
        super().__init__(f"Client error: {status_code}")


# ========================================
# Async HTTP Client
# ========================================

class AsyncHTTPClient:
    """
    Production async HTTP client with connection pooling.
    
    Features:
    - Connection pooling with configurable limits
    - Automatic keepalive management
    - Streaming support for SSE
    - Request/response logging
    - Configurable timeouts
    
    Usage:
        async with AsyncHTTPClient() as client:
            response = await client.post(
                "http://backend/v1/chat/completions",
                json={"model": "gpt-4", "messages": [...]},
            )
    """
    
    def __init__(self, config: Optional[HTTPClientConfig] = None):
        self.config = config or HTTPClientConfig.from_env()
        self._client: Optional[httpx.AsyncClient] = None
        self._request_counter = 0
    
    async def __aenter__(self) -> "AsyncHTTPClient":
        await self.start()
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb):
        await self.close()
    
    async def start(self):
        """Initialize the HTTP client."""
        if self._client is not None:
            return
        
        # Configure connection limits
        limits = httpx.Limits(
            max_connections=self.config.max_connections,
            max_keepalive_connections=self.config.max_keepalive_connections,
            keepalive_expiry=self.config.keepalive_expiry,
        )
        
        # Configure timeouts
        timeout = httpx.Timeout(
            connect=self.config.connect_timeout,
            read=self.config.read_timeout,
            write=self.config.write_timeout,
            pool=self.config.pool_timeout,
        )
        
        self._client = httpx.AsyncClient(
            limits=limits,
            timeout=timeout,
            http2=True,  # Enable HTTP/2 for better performance
        )
        
        logger.info(
            "HTTP client started",
            extra={
                "max_connections": self.config.max_connections,
                "connect_timeout": self.config.connect_timeout,
                "read_timeout": self.config.read_timeout,
            }
        )
    
    async def close(self):
        """Close the HTTP client and release connections."""
        if self._client is not None:
            await self._client.aclose()
            self._client = None
            logger.info("HTTP client closed")
    
    def _generate_request_id(self) -> str:
        """Generate unique request ID for tracing."""
        self._request_counter += 1
        return f"req-{int(time.time())}-{self._request_counter:06d}"
    
    def _log_request(
        self,
        request_id: str,
        method: str,
        url: str,
        headers: Dict[str, str],
        body: Optional[bytes] = None,
    ):
        """Log outgoing request."""
        if not self.config.log_requests:
            return
        
        body_preview = ""
        if body:
            body_str = body.decode("utf-8", errors="replace")
            if len(body_str) > self.config.log_body_max_length:
                body_preview = body_str[:self.config.log_body_max_length] + "..."
            else:
                body_preview = body_str
        
        logger.info(
            f"HTTP Request {request_id}",
            extra={
                "request_id": request_id,
                "method": method,
                "url": url,
                "headers": {k: v for k, v in headers.items() if k.lower() != "authorization"},
                "body_preview": body_preview,
            }
        )
    
    def _log_response(
        self,
        request_id: str,
        status_code: int,
        elapsed_ms: float,
        body: Optional[bytes] = None,
    ):
        """Log response."""
        if not self.config.log_responses:
            return
        
        body_preview = ""
        if body:
            body_str = body.decode("utf-8", errors="replace")
            if len(body_str) > self.config.log_body_max_length:
                body_preview = body_str[:self.config.log_body_max_length] + "..."
            else:
                body_preview = body_str
        
        log_level = logging.INFO if 200 <= status_code < 400 else logging.WARNING
        logger.log(
            log_level,
            f"HTTP Response {request_id}",
            extra={
                "request_id": request_id,
                "status_code": status_code,
                "elapsed_ms": elapsed_ms,
                "body_preview": body_preview,
            }
        )
    
    async def request(
        self,
        method: str,
        url: str,
        headers: Optional[Dict[str, str]] = None,
        json: Optional[Dict[str, Any]] = None,
        data: Optional[bytes] = None,
        timeout: Optional[float] = None,
    ) -> HTTPResponse:
        """
        Make an HTTP request.
        
        Args:
            method: HTTP method (GET, POST, etc.)
            url: Request URL
            headers: Optional headers
            json: JSON body (will be serialized)
            data: Raw body bytes
            timeout: Override default timeout
            
        Returns:
            HTTPResponse with status, headers, body
            
        Raises:
            ConnectionError: Failed to connect
            TimeoutError: Request timed out
            ServerError: 5xx response
            ClientError: 4xx response
        """
        if self._client is None:
            await self.start()
        
        request_id = self._generate_request_id()
        headers = headers or {}
        
        # Add request ID to headers for tracing
        headers["X-Request-ID"] = request_id
        
        # Prepare body
        body_bytes = None
        if json is not None:
            body_bytes = json.dumps(json).encode("utf-8")
            headers.setdefault("Content-Type", "application/json")
        elif data is not None:
            body_bytes = data
        
        self._log_request(request_id, method, url, headers, body_bytes)
        
        start_time = time.time()
        try:
            response = await self._client.request(
                method=method,
                url=url,
                headers=headers,
                content=body_bytes,
                timeout=timeout,
            )
            
            elapsed_ms = (time.time() - start_time) * 1000
            body = await response.aread()
            
            self._log_response(request_id, response.status_code, elapsed_ms, body)
            
            http_response = HTTPResponse(
                status_code=response.status_code,
                headers=dict(response.headers),
                body=body,
                elapsed_ms=elapsed_ms,
                request_id=request_id,
            )
            
            return http_response
            
        except httpx.ConnectError as e:
            elapsed_ms = (time.time() - start_time) * 1000
            logger.error(f"Connection error {request_id}: {e}")
            raise ConnectionError(f"Failed to connect to {url}: {e}")
            
        except httpx.TimeoutException as e:
            elapsed_ms = (time.time() - start_time) * 1000
            logger.error(f"Timeout {request_id}: {e}")
            raise TimeoutError(f"Request to {url} timed out: {e}")
    
    async def get(
        self,
        url: str,
        headers: Optional[Dict[str, str]] = None,
        timeout: Optional[float] = None,
    ) -> HTTPResponse:
        """Make GET request."""
        return await self.request("GET", url, headers=headers, timeout=timeout)
    
    async def post(
        self,
        url: str,
        headers: Optional[Dict[str, str]] = None,
        json: Optional[Dict[str, Any]] = None,
        data: Optional[bytes] = None,
        timeout: Optional[float] = None,
    ) -> HTTPResponse:
        """Make POST request."""
        return await self.request(
            "POST", url, headers=headers, json=json, data=data, timeout=timeout
        )
    
    async def stream_post(
        self,
        url: str,
        headers: Optional[Dict[str, str]] = None,
        json: Optional[Dict[str, Any]] = None,
        timeout: Optional[float] = None,
    ) -> StreamingResponse:
        """
        Make streaming POST request for SSE responses.
        
        Args:
            url: Request URL
            headers: Optional headers
            json: JSON body
            timeout: Override default stream timeout
            
        Returns:
            StreamingResponse with async iterator for body chunks
        """
        if self._client is None:
            await self.start()
        
        request_id = self._generate_request_id()
        headers = headers or {}
        headers["X-Request-ID"] = request_id
        headers["Accept"] = "text/event-stream"
        
        body_bytes = None
        if json is not None:
            body_bytes = json.dumps(json).encode("utf-8")
            headers.setdefault("Content-Type", "application/json")
        
        self._log_request(request_id, "POST (stream)", url, headers, body_bytes)
        
        # Use stream timeout
        stream_timeout = timeout or self.config.stream_timeout
        
        try:
            # Create streaming request
            req = self._client.build_request(
                method="POST",
                url=url,
                headers=headers,
                content=body_bytes,
            )
            
            response = await self._client.send(
                req,
                stream=True,
                timeout=httpx.Timeout(
                    connect=self.config.connect_timeout,
                    read=stream_timeout,
                    write=self.config.write_timeout,
                    pool=self.config.pool_timeout,
                ),
            )
            
            async def stream_body() -> AsyncIterator[bytes]:
                """Yield response body chunks."""
                try:
                    async for chunk in response.aiter_bytes(
                        chunk_size=self.config.stream_chunk_size
                    ):
                        yield chunk
                finally:
                    await response.aclose()
            
            return StreamingResponse(
                status_code=response.status_code,
                headers=dict(response.headers),
                stream=stream_body(),
                request_id=request_id,
            )
            
        except httpx.ConnectError as e:
            logger.error(f"Connection error {request_id}: {e}")
            raise ConnectionError(f"Failed to connect to {url}: {e}")
            
        except httpx.TimeoutException as e:
            logger.error(f"Timeout {request_id}: {e}")
            raise TimeoutError(f"Stream request to {url} timed out: {e}")


# ========================================
# Global Client Instance
# ========================================

_global_client: Optional[AsyncHTTPClient] = None


async def get_http_client() -> AsyncHTTPClient:
    """Get or create the global HTTP client."""
    global _global_client
    if _global_client is None:
        _global_client = AsyncHTTPClient()
        await _global_client.start()
    return _global_client


async def close_http_client():
    """Close the global HTTP client."""
    global _global_client
    if _global_client is not None:
        await _global_client.close()
        _global_client = None


# ========================================
# OpenAI-Specific Client Methods
# ========================================

class OpenAIHTTPClient(AsyncHTTPClient):
    """
    HTTP client with OpenAI-specific methods.
    
    Adds convenience methods for OpenAI API calls
    with proper header handling and SSE parsing.
    """
    
    async def chat_completions(
        self,
        endpoint: str,
        model: str,
        messages: list,
        stream: bool = False,
        api_key: Optional[str] = None,
        **kwargs,
    ) -> Union[HTTPResponse, StreamingResponse]:
        """
        Call OpenAI-compatible chat completions endpoint.
        
        Args:
            endpoint: Base URL (e.g., http://backend:8080/v1)
            model: Model name
            messages: List of message dicts
            stream: Whether to stream response
            api_key: Bearer token for auth
            **kwargs: Additional OpenAI parameters
            
        Returns:
            HTTPResponse for non-streaming, StreamingResponse for streaming
        """
        url = f"{endpoint.rstrip('/')}/chat/completions"
        
        headers = {
            "Content-Type": "application/json",
        }
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"
        
        payload = {
            "model": model,
            "messages": messages,
            "stream": stream,
            **kwargs,
        }
        
        if stream:
            return await self.stream_post(url, headers=headers, json=payload)
        else:
            return await self.post(url, headers=headers, json=payload)
    
    @staticmethod
    async def parse_sse_stream(
        stream: AsyncIterator[bytes]
    ) -> AsyncIterator[Dict[str, Any]]:
        """
        Parse SSE stream from OpenAI-compatible endpoint.
        
        Yields parsed JSON objects from data: lines.
        """
        buffer = ""
        
        async for chunk in stream:
            buffer += chunk.decode("utf-8", errors="replace")
            
            # Process complete lines
            while "\n" in buffer:
                line, buffer = buffer.split("\n", 1)
                line = line.strip()
                
                # Skip empty lines and comments
                if not line or line.startswith(":"):
                    continue
                
                # Check for end of stream
                if line == "data: [DONE]":
                    return
                
                # Parse data line
                if line.startswith("data: "):
                    data = line[6:]  # Remove "data: " prefix
                    try:
                        yield json.loads(data)
                    except json.JSONDecodeError:
                        logger.warning(f"Failed to parse SSE data: {data[:100]}")
                        continue