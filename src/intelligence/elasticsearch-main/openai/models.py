"""
OpenAI API Compatible Request/Response Models

Day 6 Deliverable: Pydantic-style models matching OpenAI API specification
Reference: https://platform.openai.com/docs/api-reference/chat

Usage:
    from openai.models import ChatCompletionRequest, ChatCompletionResponse
    
    request = ChatCompletionRequest(
        model="gpt-4",
        messages=[{"role": "user", "content": "Hello"}],
    )
"""

import time
import uuid
from typing import Optional, List, Dict, Any, Union, Literal
from dataclasses import dataclass, field
from enum import Enum


# ========================================
# Enums
# ========================================

class Role(str, Enum):
    """Message roles."""
    SYSTEM = "system"
    USER = "user"
    ASSISTANT = "assistant"
    TOOL = "tool"
    FUNCTION = "function"


class FinishReason(str, Enum):
    """Completion finish reasons."""
    STOP = "stop"
    LENGTH = "length"
    TOOL_CALLS = "tool_calls"
    CONTENT_FILTER = "content_filter"
    FUNCTION_CALL = "function_call"


class ResponseFormat(str, Enum):
    """Response format types."""
    TEXT = "text"
    JSON_OBJECT = "json_object"


# ========================================
# Message Types
# ========================================

@dataclass
class FunctionCall:
    """Function call in assistant message."""
    name: str
    arguments: str  # JSON string


@dataclass
class ToolCall:
    """Tool call in assistant message."""
    id: str
    type: str = "function"
    function: Optional[FunctionCall] = None


@dataclass
class ChatMessage:
    """
    Chat message in OpenAI format.
    
    Supports all message roles: system, user, assistant, tool, function.
    """
    role: str
    content: Optional[str] = None
    name: Optional[str] = None
    tool_calls: Optional[List[ToolCall]] = None
    tool_call_id: Optional[str] = None
    function_call: Optional[FunctionCall] = None
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "ChatMessage":
        """Create from dictionary."""
        tool_calls = None
        if "tool_calls" in data and data["tool_calls"]:
            tool_calls = [
                ToolCall(
                    id=tc.get("id", ""),
                    type=tc.get("type", "function"),
                    function=FunctionCall(
                        name=tc["function"]["name"],
                        arguments=tc["function"]["arguments"],
                    ) if "function" in tc else None,
                )
                for tc in data["tool_calls"]
            ]
        
        function_call = None
        if "function_call" in data and data["function_call"]:
            function_call = FunctionCall(
                name=data["function_call"]["name"],
                arguments=data["function_call"]["arguments"],
            )
        
        return cls(
            role=data["role"],
            content=data.get("content"),
            name=data.get("name"),
            tool_calls=tool_calls,
            tool_call_id=data.get("tool_call_id"),
            function_call=function_call,
        )
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {"role": self.role}
        
        if self.content is not None:
            result["content"] = self.content
        if self.name is not None:
            result["name"] = self.name
        if self.tool_call_id is not None:
            result["tool_call_id"] = self.tool_call_id
        if self.tool_calls:
            result["tool_calls"] = [
                {
                    "id": tc.id,
                    "type": tc.type,
                    "function": {
                        "name": tc.function.name,
                        "arguments": tc.function.arguments,
                    } if tc.function else None,
                }
                for tc in self.tool_calls
            ]
        if self.function_call:
            result["function_call"] = {
                "name": self.function_call.name,
                "arguments": self.function_call.arguments,
            }
        
        return result


# ========================================
# Tool/Function Definitions
# ========================================

@dataclass
class FunctionDefinition:
    """Function definition for tools."""
    name: str
    description: Optional[str] = None
    parameters: Optional[Dict[str, Any]] = None
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "FunctionDefinition":
        return cls(
            name=data["name"],
            description=data.get("description"),
            parameters=data.get("parameters"),
        )


@dataclass
class Tool:
    """Tool definition."""
    type: str = "function"
    function: Optional[FunctionDefinition] = None
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "Tool":
        func = None
        if "function" in data:
            func = FunctionDefinition.from_dict(data["function"])
        return cls(type=data.get("type", "function"), function=func)


# ========================================
# Request Models
# ========================================

@dataclass
class ResponseFormatSpec:
    """Response format specification."""
    type: str = "text"  # "text" or "json_object"


@dataclass
class ChatCompletionRequest:
    """
    OpenAI-compatible chat completion request.
    
    Matches: POST /v1/chat/completions
    Reference: https://platform.openai.com/docs/api-reference/chat/create
    """
    model: str
    messages: List[ChatMessage]
    
    # Generation parameters
    temperature: Optional[float] = None  # 0-2, default 1
    top_p: Optional[float] = None  # 0-1, default 1
    n: Optional[int] = None  # Number of completions, default 1
    max_tokens: Optional[int] = None
    max_completion_tokens: Optional[int] = None  # Newer parameter
    
    # Streaming
    stream: bool = False
    stream_options: Optional[Dict[str, Any]] = None
    
    # Stopping
    stop: Optional[Union[str, List[str]]] = None
    
    # Penalties
    presence_penalty: Optional[float] = None  # -2 to 2
    frequency_penalty: Optional[float] = None  # -2 to 2
    
    # Logprobs
    logprobs: Optional[bool] = None
    top_logprobs: Optional[int] = None
    
    # Tools
    tools: Optional[List[Tool]] = None
    tool_choice: Optional[Union[str, Dict[str, Any]]] = None
    parallel_tool_calls: Optional[bool] = None
    
    # Response format
    response_format: Optional[ResponseFormatSpec] = None
    
    # Other
    seed: Optional[int] = None
    user: Optional[str] = None
    logit_bias: Optional[Dict[str, float]] = None
    
    # Deprecated
    functions: Optional[List[FunctionDefinition]] = None
    function_call: Optional[Union[str, Dict[str, str]]] = None
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "ChatCompletionRequest":
        """Create request from dictionary (JSON body)."""
        messages = [
            ChatMessage.from_dict(m) if isinstance(m, dict) else m
            for m in data.get("messages", [])
        ]
        
        tools = None
        if "tools" in data and data["tools"]:
            tools = [Tool.from_dict(t) for t in data["tools"]]
        
        functions = None
        if "functions" in data and data["functions"]:
            functions = [FunctionDefinition.from_dict(f) for f in data["functions"]]
        
        response_format = None
        if "response_format" in data and data["response_format"]:
            response_format = ResponseFormatSpec(
                type=data["response_format"].get("type", "text")
            )
        
        return cls(
            model=data["model"],
            messages=messages,
            temperature=data.get("temperature"),
            top_p=data.get("top_p"),
            n=data.get("n"),
            max_tokens=data.get("max_tokens"),
            max_completion_tokens=data.get("max_completion_tokens"),
            stream=data.get("stream", False),
            stream_options=data.get("stream_options"),
            stop=data.get("stop"),
            presence_penalty=data.get("presence_penalty"),
            frequency_penalty=data.get("frequency_penalty"),
            logprobs=data.get("logprobs"),
            top_logprobs=data.get("top_logprobs"),
            tools=tools,
            tool_choice=data.get("tool_choice"),
            parallel_tool_calls=data.get("parallel_tool_calls"),
            response_format=response_format,
            seed=data.get("seed"),
            user=data.get("user"),
            logit_bias=data.get("logit_bias"),
            functions=functions,
            function_call=data.get("function_call"),
        )
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for forwarding."""
        result = {
            "model": self.model,
            "messages": [m.to_dict() for m in self.messages],
        }
        
        # Add optional parameters if set
        optionals = [
            ("temperature", self.temperature),
            ("top_p", self.top_p),
            ("n", self.n),
            ("max_tokens", self.max_tokens),
            ("max_completion_tokens", self.max_completion_tokens),
            ("stream", self.stream),
            ("stream_options", self.stream_options),
            ("stop", self.stop),
            ("presence_penalty", self.presence_penalty),
            ("frequency_penalty", self.frequency_penalty),
            ("logprobs", self.logprobs),
            ("top_logprobs", self.top_logprobs),
            ("tool_choice", self.tool_choice),
            ("parallel_tool_calls", self.parallel_tool_calls),
            ("seed", self.seed),
            ("user", self.user),
            ("logit_bias", self.logit_bias),
            ("function_call", self.function_call),
        ]
        
        for key, value in optionals:
            if value is not None:
                result[key] = value
        
        if self.tools:
            result["tools"] = [
                {
                    "type": t.type,
                    "function": {
                        "name": t.function.name,
                        "description": t.function.description,
                        "parameters": t.function.parameters,
                    } if t.function else None,
                }
                for t in self.tools
            ]
        
        if self.response_format:
            result["response_format"] = {"type": self.response_format.type}
        
        return result


# ========================================
# Response Models
# ========================================

@dataclass
class Usage:
    """Token usage statistics."""
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int
    
    def to_dict(self) -> Dict[str, int]:
        return {
            "prompt_tokens": self.prompt_tokens,
            "completion_tokens": self.completion_tokens,
            "total_tokens": self.total_tokens,
        }


@dataclass
class Choice:
    """Completion choice."""
    index: int
    message: ChatMessage
    finish_reason: Optional[str] = None
    logprobs: Optional[Dict[str, Any]] = None
    
    def to_dict(self) -> Dict[str, Any]:
        result = {
            "index": self.index,
            "message": self.message.to_dict(),
            "finish_reason": self.finish_reason,
        }
        if self.logprobs:
            result["logprobs"] = self.logprobs
        return result


@dataclass
class ChatCompletionResponse:
    """
    OpenAI-compatible chat completion response.
    
    Reference: https://platform.openai.com/docs/api-reference/chat/object
    """
    id: str
    object: str = "chat.completion"
    created: int = field(default_factory=lambda: int(time.time()))
    model: str = ""
    choices: List[Choice] = field(default_factory=list)
    usage: Optional[Usage] = None
    system_fingerprint: Optional[str] = None
    service_tier: Optional[str] = None
    
    @classmethod
    def create(
        cls,
        model: str,
        message: ChatMessage,
        finish_reason: str = "stop",
        prompt_tokens: int = 0,
        completion_tokens: int = 0,
    ) -> "ChatCompletionResponse":
        """Create a response with a single choice."""
        return cls(
            id=f"chatcmpl-{uuid.uuid4().hex[:24]}",
            model=model,
            choices=[
                Choice(
                    index=0,
                    message=message,
                    finish_reason=finish_reason,
                )
            ],
            usage=Usage(
                prompt_tokens=prompt_tokens,
                completion_tokens=completion_tokens,
                total_tokens=prompt_tokens + completion_tokens,
            ),
        )
    
    def to_dict(self) -> Dict[str, Any]:
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
        if self.service_tier:
            result["service_tier"] = self.service_tier
        
        return result


# ========================================
# Streaming Response Models
# ========================================

@dataclass
class DeltaMessage:
    """Delta message for streaming."""
    role: Optional[str] = None
    content: Optional[str] = None
    tool_calls: Optional[List[Dict[str, Any]]] = None
    function_call: Optional[Dict[str, str]] = None
    
    def to_dict(self) -> Dict[str, Any]:
        result = {}
        if self.role is not None:
            result["role"] = self.role
        if self.content is not None:
            result["content"] = self.content
        if self.tool_calls is not None:
            result["tool_calls"] = self.tool_calls
        if self.function_call is not None:
            result["function_call"] = self.function_call
        return result


@dataclass
class StreamChoice:
    """Streaming completion choice."""
    index: int
    delta: DeltaMessage
    finish_reason: Optional[str] = None
    logprobs: Optional[Dict[str, Any]] = None
    
    def to_dict(self) -> Dict[str, Any]:
        result = {
            "index": self.index,
            "delta": self.delta.to_dict(),
            "finish_reason": self.finish_reason,
        }
        if self.logprobs:
            result["logprobs"] = self.logprobs
        return result


@dataclass
class ChatCompletionChunk:
    """
    OpenAI-compatible streaming chunk.
    
    Reference: https://platform.openai.com/docs/api-reference/chat/streaming
    """
    id: str
    object: str = "chat.completion.chunk"
    created: int = field(default_factory=lambda: int(time.time()))
    model: str = ""
    choices: List[StreamChoice] = field(default_factory=list)
    system_fingerprint: Optional[str] = None
    usage: Optional[Usage] = None  # Only in final chunk with stream_options
    
    @classmethod
    def create_start(cls, model: str, completion_id: str) -> "ChatCompletionChunk":
        """Create initial chunk with role."""
        return cls(
            id=completion_id,
            model=model,
            choices=[
                StreamChoice(
                    index=0,
                    delta=DeltaMessage(role="assistant"),
                )
            ],
        )
    
    @classmethod
    def create_content(
        cls,
        model: str,
        completion_id: str,
        content: str,
    ) -> "ChatCompletionChunk":
        """Create content delta chunk."""
        return cls(
            id=completion_id,
            model=model,
            choices=[
                StreamChoice(
                    index=0,
                    delta=DeltaMessage(content=content),
                )
            ],
        )
    
    @classmethod
    def create_end(
        cls,
        model: str,
        completion_id: str,
        finish_reason: str = "stop",
    ) -> "ChatCompletionChunk":
        """Create final chunk with finish reason."""
        return cls(
            id=completion_id,
            model=model,
            choices=[
                StreamChoice(
                    index=0,
                    delta=DeltaMessage(),
                    finish_reason=finish_reason,
                )
            ],
        )
    
    def to_dict(self) -> Dict[str, Any]:
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
# Error Models
# ========================================

@dataclass
class ErrorDetail:
    """Error detail."""
    message: str
    type: str
    param: Optional[str] = None
    code: Optional[str] = None


@dataclass
class ErrorResponse:
    """OpenAI-compatible error response."""
    error: ErrorDetail
    
    @classmethod
    def create(
        cls,
        message: str,
        error_type: str = "invalid_request_error",
        param: Optional[str] = None,
        code: Optional[str] = None,
    ) -> "ErrorResponse":
        return cls(
            error=ErrorDetail(
                message=message,
                type=error_type,
                param=param,
                code=code,
            )
        )
    
    def to_dict(self) -> Dict[str, Any]:
        result = {
            "error": {
                "message": self.error.message,
                "type": self.error.type,
            }
        }
        if self.error.param:
            result["error"]["param"] = self.error.param
        if self.error.code:
            result["error"]["code"] = self.error.code
        return result


# ========================================
# Exports
# ========================================

__all__ = [
    # Enums
    "Role",
    "FinishReason",
    "ResponseFormat",
    # Messages
    "ChatMessage",
    "FunctionCall",
    "ToolCall",
    # Tools
    "FunctionDefinition",
    "Tool",
    # Request
    "ChatCompletionRequest",
    "ResponseFormatSpec",
    # Response
    "ChatCompletionResponse",
    "Choice",
    "Usage",
    # Streaming
    "ChatCompletionChunk",
    "StreamChoice",
    "DeltaMessage",
    # Errors
    "ErrorResponse",
    "ErrorDetail",
]