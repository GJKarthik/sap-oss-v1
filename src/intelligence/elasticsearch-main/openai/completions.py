"""
OpenAI Completions Endpoint Handler

Day 11 Deliverable: /v1/completions endpoint for legacy text completion API
Reference: https://platform.openai.com/docs/api-reference/completions

Note: This is the legacy completions API. For new applications,
the chat completions API (/v1/chat/completions) is recommended.

Usage:
    from openai.completions import CompletionsHandler
    
    handler = CompletionsHandler()
    response = handler.create_completion(request)
"""

import time
import uuid
import logging
from typing import Optional, Dict, Any, List, Union, Generator
from dataclasses import dataclass, field
from enum import Enum

logger = logging.getLogger(__name__)


# ========================================
# Request Models
# ========================================

@dataclass
class CompletionRequest:
    """
    OpenAI-compatible completion request.
    
    Reference: https://platform.openai.com/docs/api-reference/completions/create
    """
    model: str
    prompt: Union[str, List[str], List[int], List[List[int]]]
    
    # Generation parameters
    max_tokens: Optional[int] = 16
    temperature: Optional[float] = 1.0
    top_p: Optional[float] = 1.0
    n: int = 1
    
    # Streaming
    stream: bool = False
    stream_options: Optional[Dict[str, Any]] = None
    
    # Stopping
    stop: Optional[Union[str, List[str]]] = None
    
    # Penalties and sampling
    presence_penalty: float = 0.0
    frequency_penalty: float = 0.0
    best_of: int = 1
    logit_bias: Optional[Dict[str, float]] = None
    
    # Logprobs
    logprobs: Optional[int] = None
    echo: bool = False
    
    # Other
    suffix: Optional[str] = None
    user: Optional[str] = None
    seed: Optional[int] = None
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "CompletionRequest":
        """Create request from dictionary."""
        return cls(
            model=data["model"],
            prompt=data.get("prompt", ""),
            max_tokens=data.get("max_tokens", 16),
            temperature=data.get("temperature", 1.0),
            top_p=data.get("top_p", 1.0),
            n=data.get("n", 1),
            stream=data.get("stream", False),
            stream_options=data.get("stream_options"),
            stop=data.get("stop"),
            presence_penalty=data.get("presence_penalty", 0.0),
            frequency_penalty=data.get("frequency_penalty", 0.0),
            best_of=data.get("best_of", 1),
            logit_bias=data.get("logit_bias"),
            logprobs=data.get("logprobs"),
            echo=data.get("echo", False),
            suffix=data.get("suffix"),
            user=data.get("user"),
            seed=data.get("seed"),
        )
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for forwarding."""
        result = {
            "model": self.model,
            "prompt": self.prompt,
        }
        
        # Add optional parameters if not default
        if self.max_tokens != 16:
            result["max_tokens"] = self.max_tokens
        if self.temperature != 1.0:
            result["temperature"] = self.temperature
        if self.top_p != 1.0:
            result["top_p"] = self.top_p
        if self.n != 1:
            result["n"] = self.n
        if self.stream:
            result["stream"] = self.stream
        if self.stream_options:
            result["stream_options"] = self.stream_options
        if self.stop:
            result["stop"] = self.stop
        if self.presence_penalty != 0.0:
            result["presence_penalty"] = self.presence_penalty
        if self.frequency_penalty != 0.0:
            result["frequency_penalty"] = self.frequency_penalty
        if self.best_of != 1:
            result["best_of"] = self.best_of
        if self.logit_bias:
            result["logit_bias"] = self.logit_bias
        if self.logprobs is not None:
            result["logprobs"] = self.logprobs
        if self.echo:
            result["echo"] = self.echo
        if self.suffix:
            result["suffix"] = self.suffix
        if self.user:
            result["user"] = self.user
        if self.seed is not None:
            result["seed"] = self.seed
        
        return result
    
    def validate(self) -> Optional[str]:
        """
        Validate request parameters.
        
        Returns error message if invalid, None if valid.
        """
        if not self.model:
            return "model is required"
        
        if self.prompt is None:
            return "prompt is required"
        
        if self.temperature is not None and not (0 <= self.temperature <= 2):
            return "temperature must be between 0 and 2"
        
        if self.top_p is not None and not (0 <= self.top_p <= 1):
            return "top_p must be between 0 and 1"
        
        if self.n < 1:
            return "n must be at least 1"
        
        if self.best_of < self.n:
            return "best_of must be greater than or equal to n"
        
        if self.max_tokens is not None and self.max_tokens < 1:
            return "max_tokens must be at least 1"
        
        if self.logprobs is not None and not (0 <= self.logprobs <= 5):
            return "logprobs must be between 0 and 5"
        
        return None


# ========================================
# Response Models
# ========================================

@dataclass
class CompletionLogprobs:
    """Log probability information for completion tokens."""
    tokens: List[str] = field(default_factory=list)
    token_logprobs: List[Optional[float]] = field(default_factory=list)
    top_logprobs: List[Optional[Dict[str, float]]] = field(default_factory=list)
    text_offset: List[int] = field(default_factory=list)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "tokens": self.tokens,
            "token_logprobs": self.token_logprobs,
            "top_logprobs": self.top_logprobs,
            "text_offset": self.text_offset,
        }


@dataclass
class CompletionChoice:
    """A single completion choice."""
    text: str
    index: int
    logprobs: Optional[CompletionLogprobs] = None
    finish_reason: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "text": self.text,
            "index": self.index,
            "finish_reason": self.finish_reason,
        }
        if self.logprobs:
            result["logprobs"] = self.logprobs.to_dict()
        else:
            result["logprobs"] = None
        return result


@dataclass
class CompletionUsage:
    """Token usage statistics."""
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int
    
    def to_dict(self) -> Dict[str, int]:
        """Convert to dictionary."""
        return {
            "prompt_tokens": self.prompt_tokens,
            "completion_tokens": self.completion_tokens,
            "total_tokens": self.total_tokens,
        }


@dataclass
class CompletionResponse:
    """
    OpenAI-compatible completion response.
    
    Reference: https://platform.openai.com/docs/api-reference/completions/object
    """
    id: str
    object: str = "text_completion"
    created: int = field(default_factory=lambda: int(time.time()))
    model: str = ""
    choices: List[CompletionChoice] = field(default_factory=list)
    usage: Optional[CompletionUsage] = None
    system_fingerprint: Optional[str] = None
    
    @classmethod
    def create(
        cls,
        model: str,
        text: str,
        finish_reason: str = "stop",
        prompt_tokens: int = 0,
        completion_tokens: int = 0,
    ) -> "CompletionResponse":
        """Create a response with a single choice."""
        return cls(
            id=f"cmpl-{uuid.uuid4().hex[:24]}",
            model=model,
            choices=[
                CompletionChoice(
                    text=text,
                    index=0,
                    finish_reason=finish_reason,
                )
            ],
            usage=CompletionUsage(
                prompt_tokens=prompt_tokens,
                completion_tokens=completion_tokens,
                total_tokens=prompt_tokens + completion_tokens,
            ),
        )
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "id": self.id,
            "object": self.object,
            "created": self.created,
            "model": self.model,
            "choices": [c.to_dict() for c in self.choices],
        }
        
        if self.usage:
            result["usage"] = self.usage.to_dict()
        if self.system_fingerprint:
            result["system_fingerprint"] = self.system_fingerprint
        
        return result


# ========================================
# Streaming Response Models
# ========================================

@dataclass
class CompletionStreamChoice:
    """A streaming completion choice."""
    text: str
    index: int
    logprobs: Optional[CompletionLogprobs] = None
    finish_reason: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "text": self.text,
            "index": self.index,
            "finish_reason": self.finish_reason,
        }
        if self.logprobs:
            result["logprobs"] = self.logprobs.to_dict()
        else:
            result["logprobs"] = None
        return result


@dataclass
class CompletionChunk:
    """
    Streaming completion chunk.
    
    Reference: https://platform.openai.com/docs/api-reference/completions/create#completions-create-stream
    """
    id: str
    object: str = "text_completion"
    created: int = field(default_factory=lambda: int(time.time()))
    model: str = ""
    choices: List[CompletionStreamChoice] = field(default_factory=list)
    system_fingerprint: Optional[str] = None
    usage: Optional[CompletionUsage] = None  # Final chunk only
    
    @classmethod
    def create_text(
        cls,
        completion_id: str,
        model: str,
        text: str,
        index: int = 0,
    ) -> "CompletionChunk":
        """Create a text chunk."""
        return cls(
            id=completion_id,
            model=model,
            choices=[
                CompletionStreamChoice(
                    text=text,
                    index=index,
                )
            ],
        )
    
    @classmethod
    def create_end(
        cls,
        completion_id: str,
        model: str,
        finish_reason: str = "stop",
        index: int = 0,
    ) -> "CompletionChunk":
        """Create final chunk with finish reason."""
        return cls(
            id=completion_id,
            model=model,
            choices=[
                CompletionStreamChoice(
                    text="",
                    index=index,
                    finish_reason=finish_reason,
                )
            ],
        )
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "id": self.id,
            "object": self.object,
            "created": self.created,
            "model": self.model,
            "choices": [c.to_dict() for c in self.choices],
        }
        
        if self.system_fingerprint:
            result["system_fingerprint"] = self.system_fingerprint
        if self.usage:
            result["usage"] = self.usage.to_dict()
        
        return result
    
    def to_sse(self) -> str:
        """Convert to Server-Sent Events format."""
        import json
        return f"data: {json.dumps(self.to_dict())}\n\n"


# ========================================
# Error Response
# ========================================

@dataclass
class CompletionErrorResponse:
    """Error response for completion endpoint."""
    message: str
    type: str = "invalid_request_error"
    param: Optional[str] = None
    code: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "error": {
                "message": self.message,
                "type": self.type,
            }
        }
        if self.param:
            result["error"]["param"] = self.param
        if self.code:
            result["error"]["code"] = self.code
        return result


# ========================================
# Token Estimation
# ========================================

def estimate_token_count(text: str) -> int:
    """
    Estimate token count for text.
    
    Uses a simple approximation of ~4 chars per token.
    For production, use tiktoken or similar.
    """
    if not text:
        return 0
    return max(1, len(text) // 4)


def estimate_prompt_tokens(prompt: Union[str, List[str], List[int], List[List[int]]]) -> int:
    """
    Estimate tokens for prompt input.
    
    Handles all prompt input formats:
    - String: single prompt
    - List[str]: batch of prompts
    - List[int]: token IDs
    - List[List[int]]: batch of token IDs
    """
    if isinstance(prompt, str):
        return estimate_token_count(prompt)
    elif isinstance(prompt, list):
        if not prompt:
            return 0
        if isinstance(prompt[0], str):
            return sum(estimate_token_count(p) for p in prompt)
        elif isinstance(prompt[0], int):
            return len(prompt)
        elif isinstance(prompt[0], list):
            return sum(len(p) for p in prompt)
    return 0


# ========================================
# Completions Handler
# ========================================

class CompletionsHandler:
    """
    Handler for /v1/completions endpoint.
    
    Provides OpenAI-compatible text completions.
    Routes requests through SAP AI Core or private vLLM.
    
    Note: This is the legacy completion API. Chat completions
    (/v1/chat/completions) is recommended for new applications.
    """
    
    def __init__(self, http_client: Optional[Any] = None):
        """
        Initialize handler.
        
        Args:
            http_client: HTTP client for backend calls. If None,
                        uses mock completions for testing.
        """
        self._http_client = http_client
        self._mock_mode = http_client is None
    
    @property
    def is_mock_mode(self) -> bool:
        """Check if running in mock mode."""
        return self._mock_mode
    
    def create_completion(
        self,
        request: CompletionRequest,
    ) -> Union[Dict[str, Any], Generator[str, None, None]]:
        """
        Create a completion.
        
        Args:
            request: Completion request
        
        Returns:
            Completion response dict or SSE generator for streaming
        """
        # Validate request
        error = request.validate()
        if error:
            return CompletionErrorResponse(
                message=error,
                param="request",
            ).to_dict()
        
        if request.stream:
            return self._stream_completion(request)
        else:
            return self._create_completion(request)
    
    def _create_completion(self, request: CompletionRequest) -> Dict[str, Any]:
        """Create non-streaming completion."""
        if self._mock_mode:
            return self._mock_completion(request)
        
        # Forward to backend (SAP AI Core or vLLM)
        # TODO: Implement actual backend call
        return self._mock_completion(request)
    
    def _stream_completion(
        self,
        request: CompletionRequest,
    ) -> Generator[str, None, None]:
        """Create streaming completion."""
        completion_id = f"cmpl-{uuid.uuid4().hex[:24]}"
        model = request.model
        
        if self._mock_mode:
            # Generate mock streaming response
            text = self._generate_mock_text(request)
            
            # Stream in chunks
            chunk_size = 5
            for i in range(0, len(text), chunk_size):
                chunk_text = text[i:i + chunk_size]
                chunk = CompletionChunk.create_text(
                    completion_id=completion_id,
                    model=model,
                    text=chunk_text,
                )
                yield chunk.to_sse()
            
            # Final chunk
            end_chunk = CompletionChunk.create_end(
                completion_id=completion_id,
                model=model,
                finish_reason="stop",
            )
            yield end_chunk.to_sse()
            yield "data: [DONE]\n\n"
        else:
            # TODO: Implement actual streaming from backend
            yield from self._stream_completion_mock(request, completion_id)
    
    def _stream_completion_mock(
        self,
        request: CompletionRequest,
        completion_id: str,
    ) -> Generator[str, None, None]:
        """Mock streaming for testing."""
        text = self._generate_mock_text(request)
        model = request.model
        
        for i, char in enumerate(text):
            chunk = CompletionChunk.create_text(
                completion_id=completion_id,
                model=model,
                text=char,
            )
            yield chunk.to_sse()
        
        end_chunk = CompletionChunk.create_end(
            completion_id=completion_id,
            model=model,
        )
        yield end_chunk.to_sse()
        yield "data: [DONE]\n\n"
    
    def _mock_completion(self, request: CompletionRequest) -> Dict[str, Any]:
        """Generate mock completion for testing."""
        prompt = self._normalize_prompt(request.prompt)
        prompt_tokens = estimate_prompt_tokens(request.prompt)
        
        # Generate completions
        choices = []
        total_completion_tokens = 0
        
        for i in range(request.n):
            text = self._generate_mock_text(request, index=i)
            completion_tokens = estimate_token_count(text)
            total_completion_tokens += completion_tokens
            
            choice = CompletionChoice(
                text=text,
                index=i,
                finish_reason="stop" if len(text) < (request.max_tokens or 16) else "length",
            )
            
            if request.logprobs is not None:
                choice.logprobs = self._generate_mock_logprobs(text)
            
            choices.append(choice)
        
        # Select best completions if best_of > n
        if request.best_of > request.n:
            choices = choices[:request.n]
        
        response = CompletionResponse(
            id=f"cmpl-{uuid.uuid4().hex[:24]}",
            model=request.model,
            choices=choices,
            usage=CompletionUsage(
                prompt_tokens=prompt_tokens,
                completion_tokens=total_completion_tokens,
                total_tokens=prompt_tokens + total_completion_tokens,
            ),
        )
        
        return response.to_dict()
    
    def _normalize_prompt(
        self,
        prompt: Union[str, List[str], List[int], List[List[int]]],
    ) -> str:
        """Normalize prompt to single string."""
        if isinstance(prompt, str):
            return prompt
        elif isinstance(prompt, list):
            if not prompt:
                return ""
            if isinstance(prompt[0], str):
                return prompt[0]  # Use first prompt for mock
            elif isinstance(prompt[0], int):
                return f"<token_ids:{len(prompt)}>"
            elif isinstance(prompt[0], list):
                return f"<batch_token_ids:{len(prompt)}>"
        return ""
    
    def _generate_mock_text(
        self,
        request: CompletionRequest,
        index: int = 0,
    ) -> str:
        """Generate deterministic mock completion text."""
        prompt = self._normalize_prompt(request.prompt)
        max_tokens = request.max_tokens or 16
        
        # Generate based on prompt hash for determinism
        import hashlib
        seed = int(hashlib.md5(f"{prompt}:{index}".encode()).hexdigest()[:8], 16)
        
        # Simple pattern-based mock completion
        patterns = [
            " is a useful concept in software development.",
            " can be implemented using various approaches.",
            " provides significant benefits for applications.",
            " is commonly used in enterprise systems.",
            " enables efficient data processing workflows.",
        ]
        
        pattern = patterns[seed % len(patterns)]
        
        # Prepend echo if requested
        if request.echo:
            text = prompt + pattern
        else:
            text = pattern
        
        # Truncate to max_tokens (approximate)
        max_chars = max_tokens * 4
        if len(text) > max_chars:
            text = text[:max_chars]
        
        # Append suffix if provided
        if request.suffix:
            text = text + request.suffix
        
        return text
    
    def _generate_mock_logprobs(self, text: str) -> CompletionLogprobs:
        """Generate mock log probabilities."""
        import hashlib
        
        tokens = text.split()
        logprobs = CompletionLogprobs()
        
        offset = 0
        for token in tokens:
            logprobs.tokens.append(token)
            
            # Deterministic mock log probability
            seed = int(hashlib.md5(token.encode()).hexdigest()[:4], 16)
            log_prob = -0.1 - (seed % 100) / 100.0
            logprobs.token_logprobs.append(log_prob)
            
            # Mock top logprobs
            logprobs.top_logprobs.append({
                token: log_prob,
                f"{token}s": log_prob - 0.5,
            })
            
            logprobs.text_offset.append(offset)
            offset += len(token) + 1
        
        return logprobs
    
    def handle_request(
        self,
        request_data: Dict[str, Any],
    ) -> Union[Dict[str, Any], Generator[str, None, None]]:
        """
        Handle completion request from HTTP endpoint.
        
        Args:
            request_data: Raw request dictionary
        
        Returns:
            Completion response or streaming generator
        """
        try:
            request = CompletionRequest.from_dict(request_data)
            return self.create_completion(request)
        except KeyError as e:
            return CompletionErrorResponse(
                message=f"Missing required field: {e}",
                param=str(e),
            ).to_dict()
        except Exception as e:
            logger.error(f"Error handling completion request: {e}")
            return CompletionErrorResponse(
                message=str(e),
                type="server_error",
            ).to_dict()


# ========================================
# Utility Functions
# ========================================

def get_completions_handler(http_client: Optional[Any] = None) -> CompletionsHandler:
    """Get a CompletionsHandler instance."""
    return CompletionsHandler(http_client=http_client)


def create_completion(
    model: str,
    prompt: str,
    max_tokens: int = 16,
    **kwargs,
) -> Dict[str, Any]:
    """
    Convenience function for creating completions.
    
    Args:
        model: Model ID
        prompt: Text prompt
        max_tokens: Maximum tokens to generate
        **kwargs: Additional parameters
    
    Returns:
        Completion response dictionary
    """
    handler = get_completions_handler()
    request = CompletionRequest(
        model=model,
        prompt=prompt,
        max_tokens=max_tokens,
        **kwargs,
    )
    result = handler.create_completion(request)
    if isinstance(result, Generator):
        # Consume generator and return final response
        chunks = list(result)
        return {"streaming": True, "chunks": len(chunks)}
    return result


# ========================================
# Exports
# ========================================

__all__ = [
    # Request/Response
    "CompletionRequest",
    "CompletionResponse",
    "CompletionChoice",
    "CompletionUsage",
    "CompletionLogprobs",
    # Streaming
    "CompletionChunk",
    "CompletionStreamChoice",
    # Error
    "CompletionErrorResponse",
    # Handler
    "CompletionsHandler",
    # Utilities
    "get_completions_handler",
    "create_completion",
    "estimate_token_count",
    "estimate_prompt_tokens",
]