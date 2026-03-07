"""
SAP AI Core Adapter

Handles request/response transformation for different model types on SAP AI Core:
- Anthropic/Claude models: bedrock-2023-05-31 format via /invoke
- OpenAI models: Standard OpenAI format via /chat/completions
- Embedding models: /embeddings endpoint

Day 10 Fix: Proper integration with SAP AI Core foundation-models
"""

import json
import logging
import time
from typing import Optional, Dict, Any, List, AsyncIterator
from dataclasses import dataclass
from enum import Enum

import httpx

logger = logging.getLogger(__name__)


# ========================================
# Model Families
# ========================================

class ModelFamily(str, Enum):
    """Model family determines API format."""
    ANTHROPIC = "anthropic"  # Claude models via bedrock format
    OPENAI = "openai"        # GPT models via OpenAI format
    GEMINI = "gemini"        # Google models
    MISTRAL = "mistral"      # Mistral models


# ========================================
# Model Family Detection
# ========================================

MODEL_FAMILY_MAP = {
    # Claude models
    "claude-3-opus": ModelFamily.ANTHROPIC,
    "claude-3-sonnet": ModelFamily.ANTHROPIC,
    "claude-3-haiku": ModelFamily.ANTHROPIC,
    "claude-3.5-sonnet": ModelFamily.ANTHROPIC,
    "claude-3-5-sonnet": ModelFamily.ANTHROPIC,
    "anthropic--claude": ModelFamily.ANTHROPIC,
    
    # OpenAI models
    "gpt-4": ModelFamily.OPENAI,
    "gpt-4o": ModelFamily.OPENAI,
    "gpt-4-turbo": ModelFamily.OPENAI,
    "gpt-3.5-turbo": ModelFamily.OPENAI,
    
    # Google models
    "gemini": ModelFamily.GEMINI,
    
    # Mistral models
    "mistral": ModelFamily.MISTRAL,
}


def detect_model_family(model_id: str) -> ModelFamily:
    """Detect model family from model ID."""
    model_lower = model_id.lower()
    
    # Check exact matches first
    for prefix, family in MODEL_FAMILY_MAP.items():
        if model_lower.startswith(prefix.lower()):
            return family
    
    # Default to OpenAI format
    return ModelFamily.OPENAI


# ========================================
# Anthropic/Bedrock Format Adapter
# ========================================

class AnthropicBedrockAdapter:
    """
    Transforms OpenAI format to/from Anthropic Bedrock format.
    
    SAP AI Core uses bedrock-2023-05-31 API version for Claude models.
    """
    
    ANTHROPIC_VERSION = "bedrock-2023-05-31"
    
    @staticmethod
    def transform_request(
        messages: List[Dict[str, Any]],
        model: str,
        max_tokens: int = 4096,
        temperature: float = 0.7,
        **kwargs,
    ) -> Dict[str, Any]:
        """
        Transform OpenAI chat request to Anthropic bedrock format.
        
        OpenAI format:
            {"model": "gpt-4", "messages": [{"role": "user", "content": "hi"}]}
        
        Anthropic bedrock format:
            {"anthropic_version": "bedrock-2023-05-31", "max_tokens": 4096,
             "messages": [{"role": "user", "content": "hi"}]}
        """
        # Extract system message if present
        system_content = None
        filtered_messages = []
        
        for msg in messages:
            if msg.get("role") == "system":
                # Combine system messages
                if system_content:
                    system_content += "\n" + msg.get("content", "")
                else:
                    system_content = msg.get("content", "")
            else:
                # Transform content format if needed
                content = msg.get("content")
                if isinstance(content, str):
                    filtered_messages.append({
                        "role": msg["role"],
                        "content": content,
                    })
                elif isinstance(content, list):
                    # Handle multimodal content
                    filtered_messages.append({
                        "role": msg["role"],
                        "content": content,
                    })
        
        request = {
            "anthropic_version": AnthropicBedrockAdapter.ANTHROPIC_VERSION,
            "max_tokens": max_tokens,
            "messages": filtered_messages,
        }
        
        # Add system prompt if present
        if system_content:
            request["system"] = system_content
        
        # Add optional parameters
        if temperature is not None:
            request["temperature"] = temperature
        
        if kwargs.get("top_p") is not None:
            request["top_p"] = kwargs["top_p"]
        
        if kwargs.get("stop"):
            request["stop_sequences"] = kwargs["stop"] if isinstance(kwargs["stop"], list) else [kwargs["stop"]]
        
        return request
    
    @staticmethod
    def transform_response(
        response: Dict[str, Any],
        model: str,
        request_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        """
        Transform Anthropic response to OpenAI chat completion format.
        
        Anthropic response:
            {"id": "...", "type": "message", "content": [{"type": "text", "text": "..."}]}
        
        OpenAI format:
            {"id": "...", "choices": [{"message": {"role": "assistant", "content": "..."}}]}
        """
        # Extract content
        content_blocks = response.get("content", [])
        content = ""
        for block in content_blocks:
            if block.get("type") == "text":
                content += block.get("text", "")
        
        # Build OpenAI-format response
        created = int(time.time())
        
        return {
            "id": request_id or response.get("id", f"chatcmpl-{created}"),
            "object": "chat.completion",
            "created": created,
            "model": model,
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": content,
                },
                "finish_reason": _map_stop_reason(response.get("stop_reason")),
            }],
            "usage": {
                "prompt_tokens": response.get("usage", {}).get("input_tokens", 0),
                "completion_tokens": response.get("usage", {}).get("output_tokens", 0),
                "total_tokens": (
                    response.get("usage", {}).get("input_tokens", 0) +
                    response.get("usage", {}).get("output_tokens", 0)
                ),
            },
        }


def _map_stop_reason(anthropic_reason: Optional[str]) -> str:
    """Map Anthropic stop reason to OpenAI finish reason."""
    mapping = {
        "end_turn": "stop",
        "stop_sequence": "stop",
        "max_tokens": "length",
    }
    return mapping.get(anthropic_reason, "stop")


# ========================================
# SAP AI Core Client
# ========================================

@dataclass
class AICoreConfig:
    """SAP AI Core configuration."""
    base_url: str
    client_id: str
    client_secret: str
    auth_url: str
    resource_group: str = "default"
    
    @classmethod
    def from_env(cls) -> "AICoreConfig":
        """Load config from environment."""
        import os
        return cls(
            base_url=os.environ.get("AICORE_BASE_URL", ""),
            client_id=os.environ.get("AICORE_CLIENT_ID", ""),
            client_secret=os.environ.get("AICORE_CLIENT_SECRET", ""),
            auth_url=os.environ.get("AICORE_AUTH_URL", ""),
            resource_group=os.environ.get("AICORE_RESOURCE_GROUP", "default"),
        )


class SAPAICoreClient:
    """
    Production SAP AI Core client with proper model-specific adapters.
    
    Handles:
    - OAuth2 authentication
    - Model-specific request transformation
    - Streaming support
    - Response normalization to OpenAI format
    """
    
    def __init__(self, config: Optional[AICoreConfig] = None):
        self.config = config or AICoreConfig.from_env()
        self._access_token: Optional[str] = None
        self._token_expires: float = 0
        self._http_client: Optional[httpx.AsyncClient] = None
    
    async def __aenter__(self) -> "SAPAICoreClient":
        self._http_client = httpx.AsyncClient(timeout=60.0)
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        if self._http_client:
            await self._http_client.aclose()
    
    async def _ensure_token(self) -> str:
        """Get or refresh OAuth2 token."""
        if self._access_token and time.time() < self._token_expires - 60:
            return self._access_token
        
        if not self._http_client:
            raise RuntimeError("Client not initialized")
        
        response = await self._http_client.post(
            f"{self.config.auth_url}/oauth/token",
            data={
                "grant_type": "client_credentials",
                "client_id": self.config.client_id,
                "client_secret": self.config.client_secret,
            },
        )
        response.raise_for_status()
        
        token_data = response.json()
        self._access_token = token_data["access_token"]
        self._token_expires = time.time() + token_data.get("expires_in", 3600)
        
        return self._access_token
    
    async def chat_completion(
        self,
        model: str,
        messages: List[Dict[str, Any]],
        deployment_id: str,
        stream: bool = False,
        **kwargs,
    ) -> Dict[str, Any]:
        """
        Create chat completion with automatic format adaptation.
        
        Detects model family and uses appropriate API format:
        - Anthropic models: /invoke with bedrock format
        - OpenAI models: /chat/completions with OpenAI format
        """
        token = await self._ensure_token()
        family = detect_model_family(model)
        
        headers = {
            "Authorization": f"Bearer {token}",
            "AI-Resource-Group": self.config.resource_group,
            "Content-Type": "application/json",
        }
        
        if family == ModelFamily.ANTHROPIC:
            return await self._anthropic_completion(
                model=model,
                messages=messages,
                deployment_id=deployment_id,
                headers=headers,
                stream=stream,
                **kwargs,
            )
        else:
            return await self._openai_completion(
                model=model,
                messages=messages,
                deployment_id=deployment_id,
                headers=headers,
                stream=stream,
                **kwargs,
            )
    
    async def _anthropic_completion(
        self,
        model: str,
        messages: List[Dict[str, Any]],
        deployment_id: str,
        headers: Dict[str, str],
        stream: bool = False,
        **kwargs,
    ) -> Dict[str, Any]:
        """Call Anthropic model via bedrock format."""
        # Transform request to Anthropic format
        request_body = AnthropicBedrockAdapter.transform_request(
            messages=messages,
            model=model,
            max_tokens=kwargs.get("max_tokens", 4096),
            temperature=kwargs.get("temperature", 0.7),
            **kwargs,
        )
        
        # Call /invoke endpoint
        url = f"{self.config.base_url}/v2/inference/deployments/{deployment_id}/invoke"
        
        logger.info(f"Calling Anthropic model via {url}")
        
        response = await self._http_client.post(
            url,
            headers=headers,
            json=request_body,
        )
        response.raise_for_status()
        
        # Transform response to OpenAI format
        anthropic_response = response.json()
        return AnthropicBedrockAdapter.transform_response(
            response=anthropic_response,
            model=model,
        )
    
    async def _openai_completion(
        self,
        model: str,
        messages: List[Dict[str, Any]],
        deployment_id: str,
        headers: Dict[str, str],
        stream: bool = False,
        **kwargs,
    ) -> Dict[str, Any]:
        """Call OpenAI-compatible model."""
        request_body = {
            "model": model,
            "messages": messages,
            "stream": stream,
            **{k: v for k, v in kwargs.items() if v is not None},
        }
        
        url = f"{self.config.base_url}/v2/inference/deployments/{deployment_id}/chat/completions"
        
        logger.info(f"Calling OpenAI-compatible model via {url}")
        
        response = await self._http_client.post(
            url,
            headers=headers,
            json=request_body,
        )
        response.raise_for_status()
        
        return response.json()
    
    async def stream_chat_completion(
        self,
        model: str,
        messages: List[Dict[str, Any]],
        deployment_id: str,
        **kwargs,
    ) -> AsyncIterator[Dict[str, Any]]:
        """Stream chat completion with SSE."""
        token = await self._ensure_token()
        family = detect_model_family(model)
        
        headers = {
            "Authorization": f"Bearer {token}",
            "AI-Resource-Group": self.config.resource_group,
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        }
        
        if family == ModelFamily.ANTHROPIC:
            async for chunk in self._stream_anthropic(
                model=model,
                messages=messages,
                deployment_id=deployment_id,
                headers=headers,
                **kwargs,
            ):
                yield chunk
        else:
            async for chunk in self._stream_openai(
                model=model,
                messages=messages,
                deployment_id=deployment_id,
                headers=headers,
                **kwargs,
            ):
                yield chunk
    
    async def _stream_anthropic(
        self,
        model: str,
        messages: List[Dict[str, Any]],
        deployment_id: str,
        headers: Dict[str, str],
        **kwargs,
    ) -> AsyncIterator[Dict[str, Any]]:
        """Stream Anthropic model response."""
        request_body = AnthropicBedrockAdapter.transform_request(
            messages=messages,
            model=model,
            max_tokens=kwargs.get("max_tokens", 4096),
            temperature=kwargs.get("temperature", 0.7),
            **kwargs,
        )
        request_body["stream"] = True
        
        url = f"{self.config.base_url}/v2/inference/deployments/{deployment_id}/invoke-with-response-stream"
        
        async with self._http_client.stream(
            "POST",
            url,
            headers=headers,
            json=request_body,
        ) as response:
            response.raise_for_status()
            
            async for line in response.aiter_lines():
                if not line or line.startswith(":"):
                    continue
                if line.startswith("data: "):
                    data = line[6:]
                    if data == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data)
                        yield self._transform_anthropic_stream_chunk(chunk, model)
                    except json.JSONDecodeError:
                        continue
    
    async def _stream_openai(
        self,
        model: str,
        messages: List[Dict[str, Any]],
        deployment_id: str,
        headers: Dict[str, str],
        **kwargs,
    ) -> AsyncIterator[Dict[str, Any]]:
        """Stream OpenAI-compatible model response."""
        request_body = {
            "model": model,
            "messages": messages,
            "stream": True,
            **{k: v for k, v in kwargs.items() if v is not None},
        }
        
        url = f"{self.config.base_url}/v2/inference/deployments/{deployment_id}/chat/completions"
        
        async with self._http_client.stream(
            "POST",
            url,
            headers=headers,
            json=request_body,
        ) as response:
            response.raise_for_status()
            
            async for line in response.aiter_lines():
                if not line or line.startswith(":"):
                    continue
                if line.startswith("data: "):
                    data = line[6:]
                    if data == "[DONE]":
                        break
                    try:
                        yield json.loads(data)
                    except json.JSONDecodeError:
                        continue
    
    def _transform_anthropic_stream_chunk(
        self,
        chunk: Dict[str, Any],
        model: str,
    ) -> Dict[str, Any]:
        """Transform Anthropic stream chunk to OpenAI format."""
        chunk_type = chunk.get("type")
        
        if chunk_type == "content_block_delta":
            delta = chunk.get("delta", {})
            text = delta.get("text", "")
            
            return {
                "id": f"chatcmpl-{int(time.time())}",
                "object": "chat.completion.chunk",
                "created": int(time.time()),
                "model": model,
                "choices": [{
                    "index": 0,
                    "delta": {
                        "content": text,
                    },
                    "finish_reason": None,
                }],
            }
        
        elif chunk_type == "message_stop":
            return {
                "id": f"chatcmpl-{int(time.time())}",
                "object": "chat.completion.chunk",
                "created": int(time.time()),
                "model": model,
                "choices": [{
                    "index": 0,
                    "delta": {},
                    "finish_reason": "stop",
                }],
            }
        
        # Return empty chunk for other types
        return {
            "id": f"chatcmpl-{int(time.time())}",
            "object": "chat.completion.chunk",
            "created": int(time.time()),
            "model": model,
            "choices": [{
                "index": 0,
                "delta": {},
                "finish_reason": None,
            }],
        }


# ========================================
# Global Client Instance
# ========================================

_aicore_client: Optional[SAPAICoreClient] = None


async def get_aicore_client() -> SAPAICoreClient:
    """Get or create the global AI Core client."""
    global _aicore_client
    if _aicore_client is None:
        _aicore_client = SAPAICoreClient()
        await _aicore_client.__aenter__()
    return _aicore_client


async def close_aicore_client() -> None:
    """Close the global AI Core client."""
    global _aicore_client
    if _aicore_client is not None:
        await _aicore_client.__aexit__(None, None, None)
        _aicore_client = None


# ========================================
# Exports
# ========================================

__all__ = [
    "ModelFamily",
    "detect_model_family",
    "AnthropicBedrockAdapter",
    "AICoreConfig",
    "SAPAICoreClient",
    "get_aicore_client",
    "close_aicore_client",
]