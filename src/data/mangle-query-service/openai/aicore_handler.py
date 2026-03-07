"""
SAP AI Core Chat Completions Handler

Day 11: Production handler that uses SAPAICoreClient for automatic routing
- Uses aicore_adapter for model-specific format transformation
- Automatic OAuth2 authentication
- Support for Claude (Anthropic), GPT (OpenAI), and other model families
- Streaming and non-streaming modes

Usage:
    from openai.aicore_handler import AICoreCompletionsHandler
    
    async with AICoreCompletionsHandler() as handler:
        response = await handler.create_completion(request)
"""

import json
import logging
import uuid
import time
from typing import Optional, Dict, Any, List, AsyncIterator

from openai.models import (
    ChatCompletionRequest,
    ChatCompletionResponse,
    ChatCompletionChunk,
    ChatMessage,
    Choice,
    Usage,
    ErrorResponse,
    StreamChoice,
    DeltaMessage,
)
from connectors.aicore_adapter import (
    SAPAICoreClient,
    AICoreConfig,
    detect_model_family,
    ModelFamily,
    get_aicore_client,
)
from routing.model_registry import get_model_registry, ModelProvider

logger = logging.getLogger(__name__)


# ========================================
# Deployment Resolver
# ========================================

class DeploymentResolver:
    """
    Resolves model IDs to SAP AI Core deployment IDs.
    
    Maps user-facing model names (e.g., "claude-3-sonnet") to
    SAP AI Core deployment IDs.
    """
    
    def __init__(self):
        self._cache: Dict[str, str] = {}
        self._deployments: Optional[List[Dict[str, Any]]] = None
    
    async def resolve(
        self,
        model: str,
        client: SAPAICoreClient,
    ) -> Optional[str]:
        """
        Resolve model to deployment ID.
        
        First checks cache, then queries AI Core API.
        """
        # Check cache
        if model in self._cache:
            return self._cache[model]
        
        # Get deployments if not cached
        if self._deployments is None:
            await self._load_deployments(client)
        
        # Find matching deployment
        deployment_id = self._find_deployment(model)
        if deployment_id:
            self._cache[model] = deployment_id
        
        return deployment_id
    
    async def _load_deployments(self, client: SAPAICoreClient) -> None:
        """Load deployments from AI Core."""
        try:
            token = await client._ensure_token()
            response = await client._http_client.get(
                f"{client.config.base_url}/v2/lm/deployments",
                headers={
                    "Authorization": f"Bearer {token}",
                    "AI-Resource-Group": client.config.resource_group,
                },
            )
            response.raise_for_status()
            data = response.json()
            self._deployments = data.get("resources", [])
            logger.info(f"Loaded {len(self._deployments)} deployments")
        except Exception as e:
            logger.error(f"Failed to load deployments: {e}")
            self._deployments = []
    
    def _find_deployment(self, model: str) -> Optional[str]:
        """Find deployment matching model."""
        if not self._deployments:
            return None
        
        model_lower = model.lower()
        
        for deployment in self._deployments:
            if deployment.get("status") != "RUNNING":
                continue
            
            # Check deployment details
            details = deployment.get("details", {})
            resources = details.get("resources", {})
            
            # Check backend details
            backend = resources.get("backendDetails", {})
            if backend:
                model_info = backend.get("model", {})
                model_name = model_info.get("name", "").lower()
                model_version = model_info.get("version", "").lower()
                
                # Match by name or version
                if model_lower in model_name or model_lower in model_version:
                    return deployment.get("id")
                
                # Match Claude variants
                if "claude" in model_lower and "claude" in model_name:
                    return deployment.get("id")
                
                # Match GPT variants
                if "gpt" in model_lower and "gpt" in model_name:
                    return deployment.get("id")
            
            # Check scenario details
            scenario_id = deployment.get("scenarioId", "")
            if model_lower in scenario_id.lower():
                return deployment.get("id")
        
        # Return first running deployment as fallback for foundation-models
        for deployment in self._deployments:
            if deployment.get("status") == "RUNNING":
                scenario = deployment.get("scenarioId", "")
                if "foundation-models" in scenario:
                    return deployment.get("id")
        
        return None
    
    def set_deployment(self, model: str, deployment_id: str) -> None:
        """Manually set deployment mapping."""
        self._cache[model] = deployment_id


# ========================================
# AI Core Completions Handler
# ========================================

class AICoreCompletionsHandler:
    """
    Handles OpenAI-compatible chat completion requests via SAP AI Core.
    
    Features:
    - Automatic model family detection
    - Request/response format transformation
    - OAuth2 token management
    - Streaming support
    - Deployment resolution
    """
    
    def __init__(
        self,
        client: Optional[SAPAICoreClient] = None,
        deployment_resolver: Optional[DeploymentResolver] = None,
    ):
        self._client = client
        self._owns_client = client is None
        self._resolver = deployment_resolver or DeploymentResolver()
    
    async def __aenter__(self) -> "AICoreCompletionsHandler":
        if self._client is None:
            self._client = await get_aicore_client()
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        # Don't close shared client
        pass
    
    @property
    def client(self) -> SAPAICoreClient:
        if self._client is None:
            raise RuntimeError("Handler not initialized. Use async context manager.")
        return self._client
    
    async def create_completion(
        self,
        request: ChatCompletionRequest,
    ) -> ChatCompletionResponse:
        """
        Create a chat completion via SAP AI Core.
        
        Args:
            request: OpenAI-format chat completion request
        
        Returns:
            OpenAI-format chat completion response
        """
        # Resolve deployment
        deployment_id = await self._resolver.resolve(request.model, self.client)
        if not deployment_id:
            raise ValueError(f"No deployment found for model: {request.model}")
        
        logger.info(
            "Creating chat completion",
            extra={
                "model": request.model,
                "deployment_id": deployment_id,
                "message_count": len(request.messages),
            },
        )
        
        # Convert messages to dict format
        messages = [self._message_to_dict(m) for m in request.messages]
        
        # Build kwargs
        kwargs = {}
        if request.temperature is not None:
            kwargs["temperature"] = request.temperature
        if request.max_tokens is not None:
            kwargs["max_tokens"] = request.max_tokens
        if request.top_p is not None:
            kwargs["top_p"] = request.top_p
        if request.stop is not None:
            kwargs["stop"] = request.stop
        
        # Call AI Core
        response_data = await self.client.chat_completion(
            model=request.model,
            messages=messages,
            deployment_id=deployment_id,
            stream=False,
            **kwargs,
        )
        
        return self._parse_response(response_data, request.model)
    
    async def create_completion_stream(
        self,
        request: ChatCompletionRequest,
    ) -> AsyncIterator[ChatCompletionChunk]:
        """
        Create a streaming chat completion via SAP AI Core.
        
        Args:
            request: OpenAI-format chat completion request
        
        Yields:
            OpenAI-format chat completion chunks
        """
        # Resolve deployment
        deployment_id = await self._resolver.resolve(request.model, self.client)
        if not deployment_id:
            raise ValueError(f"No deployment found for model: {request.model}")
        
        logger.info(
            "Creating streaming chat completion",
            extra={
                "model": request.model,
                "deployment_id": deployment_id,
            },
        )
        
        # Convert messages to dict format
        messages = [self._message_to_dict(m) for m in request.messages]
        
        # Build kwargs
        kwargs = {}
        if request.temperature is not None:
            kwargs["temperature"] = request.temperature
        if request.max_tokens is not None:
            kwargs["max_tokens"] = request.max_tokens
        if request.top_p is not None:
            kwargs["top_p"] = request.top_p
        
        # Stream from AI Core
        async for chunk_data in self.client.stream_chat_completion(
            model=request.model,
            messages=messages,
            deployment_id=deployment_id,
            **kwargs,
        ):
            yield self._parse_chunk(chunk_data, request.model)
    
    def _message_to_dict(self, message: ChatMessage) -> Dict[str, Any]:
        """Convert ChatMessage to dict."""
        result = {"role": message.role}
        if message.content is not None:
            result["content"] = message.content
        if message.name:
            result["name"] = message.name
        if message.tool_calls:
            result["tool_calls"] = message.tool_calls
        if message.tool_call_id:
            result["tool_call_id"] = message.tool_call_id
        return result
    
    def _parse_response(
        self,
        data: Dict[str, Any],
        model: str,
    ) -> ChatCompletionResponse:
        """Parse response dict to ChatCompletionResponse."""
        choices = []
        for choice_data in data.get("choices", []):
            message_data = choice_data.get("message", {})
            message = ChatMessage(
                role=message_data.get("role", "assistant"),
                content=message_data.get("content"),
                tool_calls=message_data.get("tool_calls"),
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
        choices = []
        for choice_data in data.get("choices", []):
            delta_data = choice_data.get("delta", {})
            delta = DeltaMessage(
                role=delta_data.get("role"),
                content=delta_data.get("content"),
                tool_calls=delta_data.get("tool_calls"),
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
    
    def set_deployment(self, model: str, deployment_id: str) -> None:
        """Manually set model to deployment mapping."""
        self._resolver.set_deployment(model, deployment_id)


# ========================================
# Convenience Functions
# ========================================

async def create_aicore_completion(
    request: ChatCompletionRequest,
) -> ChatCompletionResponse:
    """
    Create a chat completion via SAP AI Core.
    
    Convenience function for one-off requests.
    """
    async with AICoreCompletionsHandler() as handler:
        return await handler.create_completion(request)


async def create_aicore_completion_from_dict(
    data: Dict[str, Any],
) -> Dict[str, Any]:
    """
    Create a chat completion from dictionary via SAP AI Core.
    """
    request = ChatCompletionRequest.from_dict(data)
    response = await create_aicore_completion(request)
    return response.to_dict()


# ========================================
# Exports
# ========================================

__all__ = [
    "AICoreCompletionsHandler",
    "DeploymentResolver",
    "create_aicore_completion",
    "create_aicore_completion_from_dict",
]