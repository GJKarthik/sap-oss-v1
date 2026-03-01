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

Regulatory Compliance:
- MGF Reference: mgf-for-agentic-ai.pdf, chunk_id: "mgf_004"
- Autonomy Level: L2 (Human-on-loop with monitoring)
- Safety Controls: guardrails, monitoring, emergency_stop
"""

import asyncio
import logging
import os
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Optional, Dict, Any, AsyncIterator, List

from openai.models import (
    ChatCompletionRequest,
    ChatCompletionResponse,
    ChatCompletionChunk,
)

logger = logging.getLogger(__name__)


class AutonomyLevel(Enum):
    """
    MGF Autonomy Levels (mgf-for-agentic-ai.pdf, chunk_id: "mgf_012")
    
    L1: Human-in-the-loop - Human approval for every action
    L2: Human-on-the-loop - Human monitoring with intervention capability
    L3: Human oversight - Periodic human review
    L4: Limited autonomy - Human defines boundaries
    L5: Full autonomy - No human oversight (not recommended)
    """
    L1_HUMAN_IN_LOOP = "L1"      # Human approval for every action
    L2_HUMAN_ON_LOOP = "L2"      # Human monitoring (DEFAULT for mangle-query-service)
    L3_HUMAN_OVERSIGHT = "L3"    # Periodic review
    L4_LIMITED_AUTONOMY = "L4"   # Bounded autonomy
    L5_FULL_AUTONOMY = "L5"      # Not recommended


class BackendType(Enum):
    """Available backends for request routing."""
    AICORE_DIRECT = "aicore_direct"      # Direct to SAP AI Core
    STREAMING_SERVICE = "streaming"       # Via ai-core-streaming Zig service
    AUTO = "auto"                         # Automatic selection


@dataclass
class RoutingConfig:
    """
    Configuration for service routing.
    
    MGF Reference: mgf-for-agentic-ai.pdf, chunk_id: "mgf_008"
    Implements: technical_controls governance dimension
    """
    
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
    
    # Regulatory compliance (MGF, Agent Index)
    autonomy_level: AutonomyLevel = AutonomyLevel.L2_HUMAN_ON_LOOP
    emergency_stop_enabled: bool = True
    
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
    
    Regulatory Compliance:
    - MGF Reference: mgf-for-agentic-ai.pdf, chunk_id: "mgf_004", "mgf_008"
    - Agent Index Reference: 2025-AI-Agent-Index.pdf
    - Autonomy Level: L2 (Human-on-loop)
    - Safety Controls: emergency_stop, guardrails, monitoring
    """
    
    def __init__(self, config: Optional[RoutingConfig] = None):
        self.config = config or RoutingConfig.from_env()
        self._aicore_handler = None
        self._streaming_client = None
        
        # Emergency stop state (MGF safety control: emergency_stop)
        self._emergency_stopped: bool = False
        self._emergency_stop_timestamp: Optional[datetime] = None
        self._emergency_stop_reason: Optional[str] = None
        
        # Request tracking for L2 monitoring
        self._request_count: int = 0
        self._last_request_time: Optional[datetime] = None
    
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
    
    # ========================================
    # Emergency Stop Implementation
    # MGF Reference: mgf-for-agentic-ai.pdf, chunk_id: "mgf_015"
    # Safety Control: emergency_stop
    # ========================================
    
    async def emergency_stop(self, reason: str = "Manual activation") -> Dict[str, Any]:
        """
        Emergency stop all LLM processing.
        
        MGF Reference: mgf-for-agentic-ai.pdf, chunk_id: "mgf_015"
        Implements: safety_control_chunk(_, "emergency_stop")
        
        This immediately halts all request processing until manually reset.
        Used for:
        - Safety incidents
        - Data breach detection
        - Compliance violations
        - Manual operator override
        
        Returns:
            Dict with stop status and timestamp
        """
        self._emergency_stopped = True
        self._emergency_stop_timestamp = datetime.utcnow()
        self._emergency_stop_reason = reason
        
        logger.critical(
            "EMERGENCY STOP activated",
            extra={
                "reason": reason,
                "timestamp": self._emergency_stop_timestamp.isoformat(),
                "request_count_at_stop": self._request_count,
                "mgf_reference": "mgf-for-agentic-ai.pdf, chunk_id: mgf_015",
            },
        )
        
        return {
            "status": "stopped",
            "timestamp": self._emergency_stop_timestamp.isoformat(),
            "reason": reason,
            "autonomy_level": self.config.autonomy_level.value,
        }
    
    async def emergency_reset(self, authorization: str) -> Dict[str, Any]:
        """
        Reset emergency stop state.
        
        Requires authorization token to prevent accidental reset.
        L2 autonomy level requires human approval for reset.
        
        Args:
            authorization: Reset authorization token (from admin)
            
        Returns:
            Dict with reset status
        """
        # Simple authorization check (in production, verify against XSUAA)
        if not authorization or len(authorization) < 8:
            raise ValueError("Invalid authorization token for emergency reset")
        
        previous_state = {
            "was_stopped": self._emergency_stopped,
            "stop_timestamp": self._emergency_stop_timestamp.isoformat() if self._emergency_stop_timestamp else None,
            "stop_reason": self._emergency_stop_reason,
        }
        
        self._emergency_stopped = False
        self._emergency_stop_timestamp = None
        self._emergency_stop_reason = None
        
        logger.warning(
            "EMERGENCY STOP reset",
            extra={
                "previous_state": previous_state,
                "reset_timestamp": datetime.utcnow().isoformat(),
            },
        )
        
        return {
            "status": "reset",
            "previous_state": previous_state,
            "timestamp": datetime.utcnow().isoformat(),
        }
    
    def is_emergency_stopped(self) -> bool:
        """Check if emergency stop is active."""
        return self._emergency_stopped
    
    def get_emergency_status(self) -> Dict[str, Any]:
        """Get current emergency stop status."""
        return {
            "stopped": self._emergency_stopped,
            "timestamp": self._emergency_stop_timestamp.isoformat() if self._emergency_stop_timestamp else None,
            "reason": self._emergency_stop_reason,
            "autonomy_level": self.config.autonomy_level.value,
        }
    
    async def route_completion(
        self,
        request: ChatCompletionRequest,
        xsuaa_token: Optional[str] = None,
        force_backend: Optional[BackendType] = None,
    ) -> ChatCompletionResponse:
        """
        Route non-streaming completion to appropriate backend.
        
        MGF Reference: mgf-for-agentic-ai.pdf, chunk_id: "mgf_004"
        Implements: technical_controls with emergency_stop check
        """
        # Emergency stop check (MGF safety control)
        if self._emergency_stopped:
            raise RuntimeError(
                f"Emergency stop active since {self._emergency_stop_timestamp}: {self._emergency_stop_reason}"
            )
        
        # Update monitoring stats (L2 human-on-loop)
        self._request_count += 1
        self._last_request_time = datetime.utcnow()
        
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
        
        MGF Reference: mgf-for-agentic-ai.pdf, chunk_id: "mgf_004"
        Implements: technical_controls with emergency_stop check
        """
        # Emergency stop check (MGF safety control)
        if self._emergency_stopped:
            raise RuntimeError(
                f"Emergency stop active since {self._emergency_stop_timestamp}: {self._emergency_stop_reason}"
            )
        
        # Update monitoring stats
        self._request_count += 1
        self._last_request_time = datetime.utcnow()
        
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
        """
        Check health of all backends.
        
        MGF Reference: mgf-for-agentic-ai.pdf, chunk_id: "mgf_008"
        Implements: monitoring safety control
        """
        results = {
            "aicore_direct": {"status": "unknown"},
            "streaming_service": {"status": "unknown"},
            "emergency_stop": self.get_emergency_status(),
            "autonomy_level": self.config.autonomy_level.value,
            "regulatory_compliance": {
                "mgf_reference": "mgf-for-agentic-ai.pdf",
                "agent_index_reference": "2025-AI-Agent-Index.pdf",
                "compliance_level": "L2_HUMAN_ON_LOOP",
            },
            "monitoring": {
                "request_count": self._request_count,
                "last_request": self._last_request_time.isoformat() if self._last_request_time else None,
            },
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
# Emergency Stop API Functions
# MGF Reference: mgf-for-agentic-ai.pdf, chunk_id: "mgf_015"
# ========================================

async def activate_emergency_stop(reason: str = "API call") -> Dict[str, Any]:
    """
    Activate emergency stop for all routing.
    
    This is a safety control endpoint that immediately halts
    all LLM request processing.
    
    MGF Reference: mgf-for-agentic-ai.pdf, chunk_id: "mgf_015"
    Safety Control: emergency_stop
    """
    router = await get_service_router()
    return await router.emergency_stop(reason)


async def reset_emergency_stop(authorization: str) -> Dict[str, Any]:
    """
    Reset emergency stop state.
    
    Requires authorization to prevent accidental reset.
    """
    router = await get_service_router()
    return await router.emergency_reset(authorization)


async def get_emergency_status() -> Dict[str, Any]:
    """Get current emergency stop status."""
    router = await get_service_router()
    return router.get_emergency_status()


# ========================================
# Exports
# ========================================

__all__ = [
    "ServiceRouter",
    "RoutingConfig",
    "BackendType",
    "AutonomyLevel",
    "get_service_router",
    "activate_emergency_stop",
    "reset_emergency_stop",
    "get_emergency_status",
]
