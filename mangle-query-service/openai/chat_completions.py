"""
OpenAI-Compatible Chat Completions Endpoint Handler

Day 6 Deliverable: Chat completions endpoint with backend forwarding
- Request validation
- Backend forwarding via ResilientHTTPClient
- Response transformation
- Error handling

Usage:
    from openai.chat_completions import ChatCompletionsHandler
    
    handler = ChatCompletionsHandler()
    response = await handler.create_completion(request)
"""

import json
import logging
import uuid
from typing import Optional, Dict, Any, AsyncIterator

from openai.models import (
    ChatCompletionRequest,
    ChatCompletionResponse,
    ChatCompletionChunk,
    ChatMessage,
    Choice,
    Usage,
    ErrorResponse,
)
from middleware.resilient_client import ResilientHTTPClient, get_llm_client
from config.settings import get_settings

logger = logging.getLogger(__name__)


# ========================================
# Validation Errors
# ========================================

class ValidationError(Exception):
    """Request validation error."""
    
    def __init__(self, message: str, param: Optional[str] = None):
        self.message = message
        self.param = param
        super().__init__(message)
    
    def to_error_response(self) -> ErrorResponse:
        return ErrorResponse.create(
            message=self.message,
            error_type="invalid_request_error",
            param=self.param,
        )


class BackendError(Exception):
    """Backend communication error."""
    
    def __init__(self, message: str, status_code: int = 500):
        self.message = message
        self.status_code = status_code
        super().__init__(message)
    
    def to_error_response(self) -> ErrorResponse:
        return ErrorResponse.create(
            message=self.message,
            error_type="server_error",
        )


# ========================================
# Request Validator
# ========================================

class RequestValidator:
    """Validates chat completion requests."""
    
    # Allowed models (can be extended via config)
    DEFAULT_ALLOWED_MODELS = {
        "gpt-4",
        "gpt-4-turbo",
        "gpt-4-turbo-preview",
        "gpt-4o",
        "gpt-4o-mini",
        "gpt-3.5-turbo",
        "gpt-3.5-turbo-16k",
        "claude-3-opus",
        "claude-3-sonnet",
        "claude-3-haiku",
        "gemini-pro",
        "gemini-1.5-pro",
    }
    
    def __init__(self, allowed_models: Optional[set] = None):
        self.allowed_models = allowed_models or self.DEFAULT_ALLOWED_MODELS
    
    def validate(self, request: ChatCompletionRequest) -> None:
        """
        Validate request, raise ValidationError if invalid.
        
        Validates:
        - Required fields (model, messages)
        - Parameter ranges (temperature, top_p, etc.)
        - Message format
        """
        # Model validation
        if not request.model:
            raise ValidationError("model is required", param="model")
        
        # Messages validation
        if not request.messages:
            raise ValidationError("messages is required and cannot be empty", param="messages")
        
        for i, msg in enumerate(request.messages):
            self._validate_message(msg, i)
        
        # Temperature validation
        if request.temperature is not None:
            if request.temperature < 0 or request.temperature > 2:
                raise ValidationError(
                    "temperature must be between 0 and 2",
                    param="temperature",
                )
        
        # Top-p validation
        if request.top_p is not None:
            if request.top_p < 0 or request.top_p > 1:
                raise ValidationError(
                    "top_p must be between 0 and 1",
                    param="top_p",
                )
        
        # N validation
        if request.n is not None:
            if request.n < 1 or request.n > 128:
                raise ValidationError(
                    "n must be between 1 and 128",
                    param="n",
                )
        
        # Max tokens validation
        if request.max_tokens is not None:
            if request.max_tokens < 1:
                raise ValidationError(
                    "max_tokens must be at least 1",
                    param="max_tokens",
                )
        
        # Penalties validation
        if request.presence_penalty is not None:
            if request.presence_penalty < -2 or request.presence_penalty > 2:
                raise ValidationError(
                    "presence_penalty must be between -2 and 2",
                    param="presence_penalty",
                )
        
        if request.frequency_penalty is not None:
            if request.frequency_penalty < -2 or request.frequency_penalty > 2:
                raise ValidationError(
                    "frequency_penalty must be between -2 and 2",
                    param="frequency_penalty",
                )
        
        # Logprobs validation
        if request.top_logprobs is not None:
            if request.top_logprobs < 0 or request.top_logprobs > 20:
                raise ValidationError(
                    "top_logprobs must be between 0 and 20",
                    param="top_logprobs",
                )
    
    def _validate_message(self, msg: ChatMessage, index: int) -> None:
        """Validate a single message."""
        valid_roles = {"system", "user", "assistant", "tool", "function"}
        
        if msg.role not in valid_roles:
            raise ValidationError(
                f"messages[{index}].role must be one of {valid_roles}",
                param=f"messages[{index}].role",
            )
        
        # User/system messages must have content
        if msg.role in ("user", "system") and msg.content is None:
            raise ValidationError(
                f"messages[{index}].content is required for role '{msg.role}'",
                param=f"messages[{index}].content",
            )
        
        # Tool messages must have tool_call_id
        if msg.role == "tool" and not msg.tool_call_id:
            raise ValidationError(
                f"messages[{index}].tool_call_id is required for tool messages",
                param=f"messages[{index}].tool_call_id",
            )


# ========================================
# Chat Completions Handler
# ========================================

class ChatCompletionsHandler:
    """
    Handles OpenAI-compatible chat completion requests.
    
    Responsibilities:
    - Request validation
    - Backend selection and forwarding
    - Response transformation
    - Error handling
    """
    
    def __init__(
        self,
        http_client: Optional[ResilientHTTPClient] = None,
        validator: Optional[RequestValidator] = None,
    ):
        self._http_client = http_client
        self._owns_client = http_client is None
        self.validator = validator or RequestValidator()
        self.settings = get_settings()
    
    async def __aenter__(self) -> "ChatCompletionsHandler":
        if self._http_client is None:
            self._http_client = get_llm_client()
            await self._http_client.__aenter__()
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        if self._owns_client and self._http_client:
            await self._http_client.__aexit__(exc_type, exc_val, exc_tb)
    
    @property
    def http_client(self) -> ResilientHTTPClient:
        if self._http_client is None:
            raise RuntimeError("Handler not initialized. Use async context manager.")
        return self._http_client
    
    async def create_completion(
        self,
        request: ChatCompletionRequest,
    ) -> ChatCompletionResponse:
        """
        Create a chat completion (non-streaming).
        
        Args:
            request: Chat completion request
        
        Returns:
            Chat completion response
        
        Raises:
            ValidationError: If request is invalid
            BackendError: If backend communication fails
        """
        # Validate request
        self.validator.validate(request)
        
        # Ensure non-streaming
        request.stream = False
        
        # Get backend URL
        backend_url = self._get_backend_url()
        
        logger.info(
            "Creating chat completion",
            extra={
                "model": request.model,
                "message_count": len(request.messages),
                "backend": backend_url,
            },
        )
        
        try:
            # Forward to backend
            response = await self.http_client.post(
                f"{backend_url}/chat/completions",
                json=request.to_dict(),
            )
            
            # Check response status
            if response.status_code >= 400:
                error_body = response.json() if response.content else {}
                raise BackendError(
                    message=error_body.get("error", {}).get("message", "Backend error"),
                    status_code=response.status_code,
                )
            
            # Parse response
            response_data = response.json()
            return self._parse_response(response_data)
        
        except BackendError:
            raise
        except Exception as e:
            logger.exception("Backend communication failed")
            raise BackendError(f"Backend communication failed: {str(e)}")
    
    async def create_completion_stream(
        self,
        request: ChatCompletionRequest,
    ) -> AsyncIterator[ChatCompletionChunk]:
        """
        Create a streaming chat completion.
        
        Args:
            request: Chat completion request
        
        Yields:
            Chat completion chunks
        
        Raises:
            ValidationError: If request is invalid
            BackendError: If backend communication fails
        """
        # Validate request
        self.validator.validate(request)
        
        # Enable streaming
        request.stream = True
        
        # Get backend URL
        backend_url = self._get_backend_url()
        completion_id = f"chatcmpl-{uuid.uuid4().hex[:24]}"
        
        logger.info(
            "Creating streaming chat completion",
            extra={
                "model": request.model,
                "message_count": len(request.messages),
                "completion_id": completion_id,
            },
        )
        
        try:
            # Forward to backend with streaming
            async for chunk in self.http_client.stream_post(
                f"{backend_url}/chat/completions",
                json=request.to_dict(),
            ):
                parsed_chunk = self._parse_stream_chunk(chunk, completion_id, request.model)
                if parsed_chunk:
                    yield parsed_chunk
        
        except Exception as e:
            logger.exception("Streaming failed")
            raise BackendError(f"Streaming failed: {str(e)}")
    
    def _get_backend_url(self) -> str:
        """Get backend URL from settings."""
        return self.settings.llm.base_url.rstrip("/")
    
    def _parse_response(self, data: Dict[str, Any]) -> ChatCompletionResponse:
        """Parse backend response into ChatCompletionResponse."""
        choices = []
        for choice_data in data.get("choices", []):
            message_data = choice_data.get("message", {})
            message = ChatMessage.from_dict(message_data)
            
            choices.append(Choice(
                index=choice_data.get("index", 0),
                message=message,
                finish_reason=choice_data.get("finish_reason"),
                logprobs=choice_data.get("logprobs"),
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
            object=data.get("object", "chat.completion"),
            created=data.get("created", 0),
            model=data.get("model", ""),
            choices=choices,
            usage=usage,
            system_fingerprint=data.get("system_fingerprint"),
            service_tier=data.get("service_tier"),
        )
    
    def _parse_stream_chunk(
        self,
        chunk: bytes,
        completion_id: str,
        model: str,
    ) -> Optional[ChatCompletionChunk]:
        """Parse SSE chunk into ChatCompletionChunk."""
        try:
            # Decode chunk
            text = chunk.decode("utf-8").strip()
            
            # Skip empty lines and SSE comments
            if not text or text.startswith(":"):
                return None
            
            # Handle SSE data prefix
            if text.startswith("data: "):
                text = text[6:]
            
            # Handle [DONE] marker
            if text == "[DONE]":
                return None
            
            # Parse JSON
            data = json.loads(text)
            
            # Create chunk from parsed data
            from openai.models import StreamChoice, DeltaMessage
            
            choices = []
            for choice_data in data.get("choices", []):
                delta_data = choice_data.get("delta", {})
                delta = DeltaMessage(
                    role=delta_data.get("role"),
                    content=delta_data.get("content"),
                    tool_calls=delta_data.get("tool_calls"),
                    function_call=delta_data.get("function_call"),
                )
                
                choices.append(StreamChoice(
                    index=choice_data.get("index", 0),
                    delta=delta,
                    finish_reason=choice_data.get("finish_reason"),
                    logprobs=choice_data.get("logprobs"),
                ))
            
            return ChatCompletionChunk(
                id=data.get("id", completion_id),
                object=data.get("object", "chat.completion.chunk"),
                created=data.get("created", 0),
                model=data.get("model", model),
                choices=choices,
                system_fingerprint=data.get("system_fingerprint"),
            )
        
        except json.JSONDecodeError:
            logger.warning(f"Failed to parse chunk: {chunk[:100]}")
            return None
        except Exception as e:
            logger.warning(f"Error parsing chunk: {e}")
            return None


# ========================================
# Convenience Functions
# ========================================

async def create_chat_completion(
    request: ChatCompletionRequest,
) -> ChatCompletionResponse:
    """
    Create a chat completion.
    
    Convenience function for one-off requests.
    
    Args:
        request: Chat completion request
    
    Returns:
        Chat completion response
    """
    async with ChatCompletionsHandler() as handler:
        return await handler.create_completion(request)


async def create_chat_completion_from_dict(
    data: Dict[str, Any],
) -> Dict[str, Any]:
    """
    Create a chat completion from dictionary.
    
    Convenience function for direct JSON handling.
    
    Args:
        data: Request dictionary
    
    Returns:
        Response dictionary
    """
    request = ChatCompletionRequest.from_dict(data)
    response = await create_chat_completion(request)
    return response.to_dict()


# ========================================
# Exports
# ========================================

__all__ = [
    "ChatCompletionsHandler",
    "RequestValidator",
    "ValidationError",
    "BackendError",
    "create_chat_completion",
    "create_chat_completion_from_dict",
]