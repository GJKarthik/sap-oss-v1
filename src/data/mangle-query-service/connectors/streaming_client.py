"""
AI Core Streaming Service Client

Connects mangle-query-service (Python) to ai-core-streaming (Zig) as a separate service.

Architecture:
  mangle-query-service:8080 → ai-core-streaming:9000 → SAP AI Core

The Zig service provides:
- High-performance streaming
- XSUAA JWT validation
- GPU memory management
- Pub/sub via Pulsar
"""

import asyncio
import logging
import os
from dataclasses import dataclass, field
from typing import Optional, Dict, Any, AsyncIterator, List
from enum import Enum

import httpx

logger = logging.getLogger(__name__)


class StreamingServiceError(Exception):
    """Error from ai-core-streaming service."""
    def __init__(self, message: str, status_code: int = 500, details: Dict = None):
        super().__init__(message)
        self.status_code = status_code
        self.details = details or {}


@dataclass
class StreamingServiceConfig:
    """Configuration for ai-core-streaming service connection."""
    
    # Service endpoint
    base_url: str = field(default_factory=lambda: os.getenv("STREAMING_SERVICE_URL", "http://localhost:9000"))
    
    # Authentication
    share_xsuaa_token: bool = True  # Pass through XSUAA token
    service_api_key: Optional[str] = field(default_factory=lambda: os.getenv("STREAMING_SERVICE_API_KEY"))
    
    # Connection settings
    timeout_seconds: float = 30.0
    stream_timeout_seconds: float = 300.0
    max_retries: int = 3
    
    # Circuit breaker
    circuit_breaker_threshold: int = 5
    circuit_breaker_reset_seconds: float = 60.0
    
    @classmethod
    def from_env(cls) -> "StreamingServiceConfig":
        """Load from environment."""
        return cls(
            base_url=os.getenv("STREAMING_SERVICE_URL", "http://localhost:9000"),
            service_api_key=os.getenv("STREAMING_SERVICE_API_KEY"),
            timeout_seconds=float(os.getenv("STREAMING_TIMEOUT", "30")),
            stream_timeout_seconds=float(os.getenv("STREAMING_STREAM_TIMEOUT", "300")),
        )


class CircuitState(Enum):
    CLOSED = "closed"    # Normal operation
    OPEN = "open"        # Failing, reject calls
    HALF_OPEN = "half_open"  # Testing if service recovered


@dataclass
class CircuitBreaker:
    """Circuit breaker for service resilience."""
    
    threshold: int = 5
    reset_seconds: float = 60.0
    
    _failures: int = 0
    _state: CircuitState = CircuitState.CLOSED
    _last_failure_time: float = 0
    
    def record_success(self) -> None:
        """Record successful call."""
        self._failures = 0
        self._state = CircuitState.CLOSED
    
    def record_failure(self) -> None:
        """Record failed call."""
        import time
        self._failures += 1
        self._last_failure_time = time.time()
        
        if self._failures >= self.threshold:
            self._state = CircuitState.OPEN
            logger.warning(f"Circuit breaker opened after {self._failures} failures")
    
    def allow_request(self) -> bool:
        """Check if request should be allowed."""
        import time
        
        if self._state == CircuitState.CLOSED:
            return True
        
        if self._state == CircuitState.OPEN:
            # Check if reset time has passed
            if time.time() - self._last_failure_time >= self.reset_seconds:
                self._state = CircuitState.HALF_OPEN
                logger.info("Circuit breaker half-open, testing service")
                return True
            return False
        
        # Half-open: allow one request to test
        return True


class StreamingServiceClient:
    """
    Client for ai-core-streaming Zig service.
    
    Routes high-performance streaming requests to the Zig backend
    while maintaining OpenAI API compatibility.
    """
    
    def __init__(self, config: Optional[StreamingServiceConfig] = None):
        self.config = config or StreamingServiceConfig.from_env()
        self._http_client: Optional[httpx.AsyncClient] = None
        self._circuit = CircuitBreaker(
            threshold=self.config.circuit_breaker_threshold,
            reset_seconds=self.config.circuit_breaker_reset_seconds,
        )
    
    async def __aenter__(self) -> "StreamingServiceClient":
        self._http_client = httpx.AsyncClient(
            base_url=self.config.base_url,
            timeout=httpx.Timeout(self.config.timeout_seconds),
        )
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        if self._http_client:
            await self._http_client.aclose()
    
    @property
    def client(self) -> httpx.AsyncClient:
        if not self._http_client:
            raise RuntimeError("Client not initialized. Use async context manager.")
        return self._http_client
    
    def _build_headers(self, xsuaa_token: Optional[str] = None) -> Dict[str, str]:
        """Build request headers."""
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        
        # Pass through XSUAA token if configured
        if self.config.share_xsuaa_token and xsuaa_token:
            headers["Authorization"] = f"Bearer {xsuaa_token}"
        
        # Add service API key if configured
        if self.config.service_api_key:
            headers["X-API-Key"] = self.config.service_api_key
        
        return headers
    
    # ========================================
    # Health & Status
    # ========================================
    
    async def health_check(self) -> Dict[str, Any]:
        """Check ai-core-streaming service health."""
        try:
            response = await self.client.get("/health")
            response.raise_for_status()
            self._circuit.record_success()
            return response.json()
        except Exception as e:
            self._circuit.record_failure()
            raise StreamingServiceError(f"Health check failed: {e}")
    
    async def get_status(self) -> Dict[str, Any]:
        """Get service status and metrics."""
        response = await self.client.get("/status")
        response.raise_for_status()
        return response.json()
    
    # ========================================
    # Chat Completions (Streaming)
    # ========================================
    
    async def chat_completion(
        self,
        messages: List[Dict[str, Any]],
        model: str = "claude-3.5-sonnet",
        xsuaa_token: Optional[str] = None,
        **kwargs,
    ) -> Dict[str, Any]:
        """
        Non-streaming chat completion via ai-core-streaming.
        
        The Zig service handles:
        - XSUAA token validation
        - Model routing
        - Response transformation
        """
        if not self._circuit.allow_request():
            raise StreamingServiceError(
                "Circuit breaker open - service unavailable",
                status_code=503,
            )
        
        payload = {
            "model": model,
            "messages": messages,
            "stream": False,
            **kwargs,
        }
        
        try:
            response = await self.client.post(
                "/v1/chat/completions",
                json=payload,
                headers=self._build_headers(xsuaa_token),
            )
            response.raise_for_status()
            self._circuit.record_success()
            return response.json()
        except httpx.HTTPStatusError as e:
            self._circuit.record_failure()
            raise StreamingServiceError(
                f"Chat completion failed: {e}",
                status_code=e.response.status_code,
            )
        except Exception as e:
            self._circuit.record_failure()
            raise StreamingServiceError(f"Chat completion error: {e}")
    
    async def stream_chat_completion(
        self,
        messages: List[Dict[str, Any]],
        model: str = "claude-3.5-sonnet",
        xsuaa_token: Optional[str] = None,
        **kwargs,
    ) -> AsyncIterator[Dict[str, Any]]:
        """
        Streaming chat completion via ai-core-streaming.
        
        Yields SSE chunks from the Zig service.
        """
        if not self._circuit.allow_request():
            raise StreamingServiceError(
                "Circuit breaker open - service unavailable",
                status_code=503,
            )
        
        payload = {
            "model": model,
            "messages": messages,
            "stream": True,
            **kwargs,
        }
        
        try:
            async with self.client.stream(
                "POST",
                "/v1/chat/completions",
                json=payload,
                headers=self._build_headers(xsuaa_token),
                timeout=httpx.Timeout(self.config.stream_timeout_seconds),
            ) as response:
                response.raise_for_status()
                self._circuit.record_success()
                
                async for line in response.aiter_lines():
                    if line.startswith("data: "):
                        data = line[6:]
                        if data == "[DONE]":
                            break
                        
                        import json
                        try:
                            yield json.loads(data)
                        except json.JSONDecodeError:
                            logger.warning(f"Invalid JSON in stream: {data}")
                            continue
        except httpx.HTTPStatusError as e:
            self._circuit.record_failure()
            raise StreamingServiceError(
                f"Stream failed: {e}",
                status_code=e.response.status_code,
            )
        except Exception as e:
            self._circuit.record_failure()
            raise StreamingServiceError(f"Stream error: {e}")
    
    # ========================================
    # Embeddings
    # ========================================
    
    async def create_embedding(
        self,
        input_text: str | List[str],
        model: str = "text-embedding-ada-002",
        xsuaa_token: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Create embeddings via ai-core-streaming."""
        if not self._circuit.allow_request():
            raise StreamingServiceError("Circuit breaker open", status_code=503)
        
        payload = {
            "model": model,
            "input": input_text,
        }
        
        try:
            response = await self.client.post(
                "/v1/embeddings",
                json=payload,
                headers=self._build_headers(xsuaa_token),
            )
            response.raise_for_status()
            self._circuit.record_success()
            return response.json()
        except Exception as e:
            self._circuit.record_failure()
            raise StreamingServiceError(f"Embedding error: {e}")
    
    # ========================================
    # Pub/Sub (Pulsar Integration)
    # ========================================
    
    async def publish_prompt(
        self,
        topic: str,
        prompt: Dict[str, Any],
        xsuaa_token: Optional[str] = None,
    ) -> Dict[str, Any]:
        """
        Publish a prompt to ai-core-streaming pub/sub.
        
        Used for async prompt processing via Pulsar.
        """
        payload = {
            "topic": topic,
            "payload": prompt,
        }
        
        response = await self.client.post(
            "/v1/publish",
            json=payload,
            headers=self._build_headers(xsuaa_token),
        )
        response.raise_for_status()
        return response.json()
    
    async def subscribe_responses(
        self,
        subscription: str,
        xsuaa_token: Optional[str] = None,
    ) -> AsyncIterator[Dict[str, Any]]:
        """
        Subscribe to responses from ai-core-streaming.
        
        Used for receiving async completions via Pulsar.
        """
        params = {"subscription": subscription}
        
        async with self.client.stream(
            "GET",
            "/v1/subscribe",
            params=params,
            headers=self._build_headers(xsuaa_token),
            timeout=httpx.Timeout(None),  # No timeout for subscription
        ) as response:
            response.raise_for_status()
            
            async for line in response.aiter_lines():
                if line.startswith("data: "):
                    import json
                    yield json.loads(line[6:])


# ========================================
# Singleton Instance
# ========================================

_streaming_client: Optional[StreamingServiceClient] = None


async def get_streaming_client() -> StreamingServiceClient:
    """Get singleton streaming client."""
    global _streaming_client
    
    if _streaming_client is None:
        _streaming_client = StreamingServiceClient()
        await _streaming_client.__aenter__()
    
    return _streaming_client


# ========================================
# Exports
# ========================================

__all__ = [
    "StreamingServiceClient",
    "StreamingServiceConfig",
    "StreamingServiceError",
    "get_streaming_client",
]