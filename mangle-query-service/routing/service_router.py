"""
Service Router - Routes requests between backends

Routes OpenAI-compatible requests to appropriate backend:
1. SAP AI Core (direct) - via aicore_adapter.py
2. ai-core-streaming (Zig service) - via streaming_client.py

Routing is based on:
- Request type (streaming vs non-streaming)
- Model requirements
- Service availability
- Configuration
"""

import logging
import os
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional, Dict, Any, AsyncIterator, List

from openai.models import (
    ChatCompletionRequest,
    ChatCompletionResponse,
    ChatCompletionChunk,
)

logger = logging.getLogger(__name__)


class BackendType(Enum):
    """Available backends for request routing."""
    AICORE_DIRECT = "aicore_direct"      # Direct to SAP AI Core
    STREAMING_SERVICE = "streaming"       # Via ai-core-streaming Zig service
    AUTO = "auto"                         # Automatic selection


@dataclass
class RoutingConfig:
    """Configuration for service routing."""
    
    # Default backend selection
    default_backend: BackendType = BackendType.AUTO
    
    # When to use streaming service
    streaming_threshold_tokens: int = 1000  # Use streaming for long responses
    prefer_streaming_for_stream: bool = True  # Route stream=True to streaming service
    
    # Fallback behavior
    fallback_on_error: bool = True
    
    # Service availability
    streaming_service_enabled: bool = field(
        default_factory=lambda: os.getenv("STREAMING_SERVICE_ENABLED", "true").lower() == "true"
    )
    aicore_direct_enabled: bool = True
    
    @classmethod
    def from_env(cls) -> "RoutingConfig":
        """Load from environment."""
        default = os.getenv("DEFAULT_BACKEND", "auto")
        return cls(
            default_backend=BackendType(default) if default in [e.value for e in BackendType] else BackendType.AUTO,
            streaming_service_enabled=os.getenv("STREAMING_SERVICE_ENABLED", "true").lower() == "true",
            prefer_streaming_for_stream=os.getenv("PREFER_STREAMING_SERVICE", "true").lower() == "true",
        )


class ServiceRouter:
    """
    Routes requests to appropriate backend service.
    
    Architecture:
    ```
    Client Request
         │
    ServiceRouter
         │
    ├─── BackendType.AICORE_DIRECT ──→ SAPAICoreClient (Python)
    │                                        │
    │                                        ↓
    │                                   SAP AI Core
    │
    └─── BackendType.STREAMING_SERVICE ──→ StreamingServiceClient
                                               │
                                               ↓
                                        ai-core-streaming (Zig :9000)
                                               │
                                               ↓
                                          SAP AI Core
    ```
    """
    
    def __init__(self, config: Optional[RoutingConfig] = None):
        self.config = config or RoutingConfig.from_env()
        self._aicore_handler = None
        self._streaming_client = None
    
    async def _get_aicore_handler(self):
        """Lazy load AI Core handler."""
        if self._aicore_handler is None:
            from openai.aicore_handler import AICoreCompletionsHandler
            self._aicore_handler = AICoreCompletionsHandler()
            await self._aicore_handler.__aenter__()
        return self._aicore_handler
    
    async def _get_streaming_client(self):
        """Lazy load streaming client."""
        if self._streaming_client is None:
            from connectors.streaming_client import StreamingServiceClient
            self._streaming_client = StreamingServiceClient()
            await self._streaming_client.__aenter__()
        return self._streaming_client
    
    def select_backend(
        self,
        request: ChatCompletionRequest,
        force_backend: Optional[BackendType] = None,
    ) -> BackendType:
        """
        Select backend for request.
        
        Selection logic:
        1. Force override if specified
        2. If streaming service disabled, use direct
        3. If stream=True and prefer_streaming_for_stream, use streaming service
        4. Otherwise use default
        """
        if force_backend:
            return force_backend
        
        if self.config.default_backend != BackendType.AUTO:
            return self.config.default_backend
        
        # Auto selection logic
        if not self.config.streaming_service_enabled:
            return BackendType.AICORE_DIRECT
        
        if request.stream and self.config.prefer_streaming_for_stream:
            return BackendType.STREAMING_SERVICE
        
        # Default to direct for non-streaming
        return BackendType.AICORE_DIRECT
    
    async def route_completion(
        self,
        request: ChatCompletionRequest,
        xsuaa_token: Optional[str] = None,
        force_backend: Optional[BackendType] = None,
    ) -> ChatCompletionResponse:
        """
        Route non-streaming completion to appropriate backend.
        """
        backend = self.select_backend(request, force_backend)
        
        logger.info(
            "Routing completion request",
            extra={
                "backend": backend.value,
                "model": request.model,
                "stream": request.stream,
            },
        )
        
        try:
            if backend == BackendType.STREAMING_SERVICE:
                return await self._route_to_streaming(request, xsuaa_token)
            else:
                return await self._route_to_aicore(request)
        except Exception as e:
            if self.config.fallback_on_error and backend == BackendType.STREAMING_SERVICE:
                logger.warning(f"Streaming service failed, falling back to direct: {e}")
                return await self._route_to_aicore(request)
            raise
    
    async def route_completion_stream(
        self,
        request: ChatCompletionRequest,
        xsuaa_token: Optional[str] = None,
        force_backend: Optional[BackendType] = None,
    ) -> AsyncIterator[ChatCompletionChunk]:
        """
        Route streaming completion to appropriate backend.
        """
        backend = self.select_backend(request, force_backend)
        
        logger.info(
            "Routing streaming request",
            extra={
                "backend": backend.value,
                "model": request.model,
            },
        )
        
        if backend == BackendType.STREAMING_SERVICE:
            async for chunk in self._stream_from_streaming_service(request, xsuaa_token):
                yield chunk
        else:
            async for chunk in self._stream_from_aicore(request):
                yield chunk
    
    async def _route_to_aicore(
        self,
        request: ChatCompletionRequest,
    ) -> ChatCompletionResponse:
        """Route to SAP AI Core directly."""
        handler = await self._get_aicore_handler()
        return await handler.create_completion(request)
    
    async def _route_to_streaming(
        self,
        request: ChatCompletionRequest,
        xsuaa_token: Optional[str] = None,
    ) -> ChatCompletionResponse:
        """Route to ai-core-streaming service."""
        from openai.models import ChatMessage, Choice, Usage
        
        client = await self._get_streaming_client()
        
        # Convert messages to dict
        messages = []
        for msg in request.messages:
            messages.append({
                "role": msg.role,
                "content": msg.content,
            })
        
        # Build kwargs
        kwargs = {}
        if request.temperature is not None:
            kwargs["temperature"] = request.temperature
        if request.max_tokens is not None:
            kwargs["max_tokens"] = request.max_tokens
        
        # Call streaming service
        response_data = await client.chat_completion(
            messages=messages,
            model=request.model,
            xsuaa_token=xsuaa_token,
            **kwargs,
        )
        
        # Convert response to model
        return self._parse_response(response_data, request.model)
    
    async def _stream_from_aicore(
        self,
        request: ChatCompletionRequest,
    ) -> AsyncIterator[ChatCompletionChunk]:
        """Stream from SAP AI Core directly."""
        handler = await self._get_aicore_handler()
        async for chunk in handler.create_completion_stream(request):
            yield chunk
    
    async def _stream_from_streaming_service(
        self,
        request: ChatCompletionRequest,
        xsuaa_token: Optional[str] = None,
    ) -> AsyncIterator[ChatCompletionChunk]:
        """Stream from ai-core-streaming service."""
        from openai.models import DeltaMessage, StreamChoice
        
        client = await self._get_streaming_client()
        
        # Convert messages
        messages = [{"role": m.role, "content": m.content} for m in request.messages]
        
        kwargs = {}
        if request.temperature is not None:
            kwargs["temperature"] = request.temperature
        if request.max_tokens is not None:
            kwargs["max_tokens"] = request.max_tokens
        
        async for chunk_data in client.stream_chat_completion(
            messages=messages,
            model=request.model,
            xsuaa_token=xsuaa_token,
            **kwargs,
        ):
            yield self._parse_chunk(chunk_data, request.model)
    
    def _parse_response(
        self,
        data: Dict[str, Any],
        model: str,
    ) -> ChatCompletionResponse:
        """Parse response dict to ChatCompletionResponse."""
        from openai.models import ChatMessage, Choice, Usage
        import uuid
        import time
        
        choices = []
        for choice_data in data.get("choices", []):
            message_data = choice_data.get("message", {})
            message = ChatMessage(
                role=message_data.get("role", "assistant"),
                content=message_data.get("content"),
            )
            choices.append(Choice(
                index=choice_data.get("index", 0),
                message=message,
                finish_reason=choice_data.get("finish_reason"),
            ))
        
        usage = None
        if "usage" in data:
            usage_data = data["usage"]
            usage = Usage(
                prompt_tokens=usage_data.get("prompt_tokens", 0),
                completion_tokens=usage_data.get("completion_tokens", 0),
                total_tokens=usage_data.get("total_tokens", 0),
            )
        
        return ChatCompletionResponse(
            id=data.get("id", f"chatcmpl-{uuid.uuid4().hex[:24]}"),
            object="chat.completion",
            created=data.get("created", int(time.time())),
            model=model,
            choices=choices,
            usage=usage,
        )
    
    def _parse_chunk(
        self,
        data: Dict[str, Any],
        model: str,
    ) -> ChatCompletionChunk:
        """Parse chunk dict to ChatCompletionChunk."""
        from openai.models import DeltaMessage, StreamChoice
        import uuid
        import time
        
        choices = []
        for choice_data in data.get("choices", []):
            delta_data = choice_data.get("delta", {})
            delta = DeltaMessage(
                role=delta_data.get("role"),
                content=delta_data.get("content"),
            )
            choices.append(StreamChoice(
                index=choice_data.get("index", 0),
                delta=delta,
                finish_reason=choice_data.get("finish_reason"),
            ))
        
        return ChatCompletionChunk(
            id=data.get("id", f"chatcmpl-{uuid.uuid4().hex[:24]}"),
            object="chat.completion.chunk",
            created=data.get("created", int(time.time())),
            model=model,
            choices=choices,
        )
    
    async def health_check(self) -> Dict[str, Any]:
        """Check health of all backends."""
        results = {
            "aicore_direct": {"status": "unknown"},
            "streaming_service": {"status": "unknown"},
        }
        
        # Check streaming service
        if self.config.streaming_service_enabled:
            try:
                client = await self._get_streaming_client()
                health = await client.health_check()
                results["streaming_service"] = {
                    "status": "healthy",
                    "details": health,
                }
            except Exception as e:
                results["streaming_service"] = {
                    "status": "unhealthy",
                    "error": str(e),
                }
        else:
            results["streaming_service"]["status"] = "disabled"
        
        # Check AI Core direct (basic check)
        if self.config.aicore_direct_enabled:
            try:
                handler = await self._get_aicore_handler()
                results["aicore_direct"] = {
                    "status": "healthy",
                    "details": {"initialized": handler._client is not None},
                }
            except Exception as e:
                results["aicore_direct"] = {
                    "status": "unhealthy",
                    "error": str(e),
                }
        
        return results


# ========================================
# Singleton Instance
# ========================================

_service_router: Optional[ServiceRouter] = None


async def get_service_router() -> ServiceRouter:
    """Get singleton service router."""
    global _service_router
    
    if _service_router is None:
        _service_router = ServiceRouter()
    
    return _service_router


# ========================================
# Exports
# ========================================

__all__ = [
    "ServiceRouter",
    "RoutingConfig",
    "BackendType",
    "get_service_router",
]