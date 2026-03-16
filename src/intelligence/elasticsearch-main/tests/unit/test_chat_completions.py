"""
Unit Tests for Chat Completions Endpoint

Day 6 Deliverable: Tests for models and chat completions handler
Target: >80% code coverage
"""

import pytest
import json
from unittest.mock import AsyncMock, MagicMock, patch

from openai.models import (
    Role,
    FinishReason,
    ChatMessage,
    FunctionCall,
    ToolCall,
    Tool,
    FunctionDefinition,
    ChatCompletionRequest,
    ChatCompletionResponse,
    ChatCompletionChunk,
    Choice,
    Usage,
    DeltaMessage,
    StreamChoice,
    ErrorResponse,
)
from openai.chat_completions import (
    ChatCompletionsHandler,
    RequestValidator,
    ValidationError,
    BackendError,
)


# ========================================
# Model Tests
# ========================================

class TestRole:
    """Tests for Role enum."""
    
    def test_role_values(self):
        assert Role.SYSTEM.value == "system"
        assert Role.USER.value == "user"
        assert Role.ASSISTANT.value == "assistant"
        assert Role.TOOL.value == "tool"


class TestFinishReason:
    """Tests for FinishReason enum."""
    
    def test_finish_reason_values(self):
        assert FinishReason.STOP.value == "stop"
        assert FinishReason.LENGTH.value == "length"
        assert FinishReason.TOOL_CALLS.value == "tool_calls"


class TestChatMessage:
    """Tests for ChatMessage."""
    
    def test_simple_user_message(self):
        msg = ChatMessage(role="user", content="Hello")
        assert msg.role == "user"
        assert msg.content == "Hello"
    
    def test_from_dict(self):
        data = {"role": "user", "content": "Hello"}
        msg = ChatMessage.from_dict(data)
        assert msg.role == "user"
        assert msg.content == "Hello"
    
    def test_to_dict(self):
        msg = ChatMessage(role="assistant", content="Hi there")
        result = msg.to_dict()
        assert result == {"role": "assistant", "content": "Hi there"}
    
    def test_with_tool_calls(self):
        data = {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "id": "call_123",
                    "type": "function",
                    "function": {
                        "name": "get_weather",
                        "arguments": '{"location": "NYC"}',
                    },
                }
            ],
        }
        msg = ChatMessage.from_dict(data)
        assert msg.tool_calls is not None
        assert len(msg.tool_calls) == 1
        assert msg.tool_calls[0].id == "call_123"
    
    def test_with_function_call(self):
        data = {
            "role": "assistant",
            "function_call": {
                "name": "get_weather",
                "arguments": '{"location": "NYC"}',
            },
        }
        msg = ChatMessage.from_dict(data)
        assert msg.function_call is not None
        assert msg.function_call.name == "get_weather"


class TestTool:
    """Tests for Tool."""
    
    def test_from_dict(self):
        data = {
            "type": "function",
            "function": {
                "name": "get_weather",
                "description": "Get weather info",
                "parameters": {"type": "object"},
            },
        }
        tool = Tool.from_dict(data)
        assert tool.type == "function"
        assert tool.function.name == "get_weather"


# ========================================
# Request Tests
# ========================================

class TestChatCompletionRequest:
    """Tests for ChatCompletionRequest."""
    
    def test_basic_request(self):
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[ChatMessage(role="user", content="Hello")],
        )
        assert request.model == "gpt-4"
        assert len(request.messages) == 1
    
    def test_from_dict(self):
        data = {
            "model": "gpt-4",
            "messages": [{"role": "user", "content": "Hello"}],
            "temperature": 0.7,
            "max_tokens": 100,
        }
        request = ChatCompletionRequest.from_dict(data)
        assert request.model == "gpt-4"
        assert request.temperature == 0.7
        assert request.max_tokens == 100
    
    def test_to_dict(self):
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[ChatMessage(role="user", content="Hello")],
            temperature=0.5,
        )
        result = request.to_dict()
        assert result["model"] == "gpt-4"
        assert result["temperature"] == 0.5
        assert len(result["messages"]) == 1
    
    def test_with_tools(self):
        data = {
            "model": "gpt-4",
            "messages": [{"role": "user", "content": "What's the weather?"}],
            "tools": [
                {
                    "type": "function",
                    "function": {
                        "name": "get_weather",
                        "description": "Get weather",
                    },
                }
            ],
        }
        request = ChatCompletionRequest.from_dict(data)
        assert request.tools is not None
        assert len(request.tools) == 1
    
    def test_streaming_flag(self):
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[ChatMessage(role="user", content="Hello")],
            stream=True,
        )
        assert request.stream is True


# ========================================
# Response Tests
# ========================================

class TestUsage:
    """Tests for Usage."""
    
    def test_to_dict(self):
        usage = Usage(prompt_tokens=10, completion_tokens=20, total_tokens=30)
        result = usage.to_dict()
        assert result["prompt_tokens"] == 10
        assert result["completion_tokens"] == 20
        assert result["total_tokens"] == 30


class TestChoice:
    """Tests for Choice."""
    
    def test_to_dict(self):
        choice = Choice(
            index=0,
            message=ChatMessage(role="assistant", content="Hi"),
            finish_reason="stop",
        )
        result = choice.to_dict()
        assert result["index"] == 0
        assert result["finish_reason"] == "stop"


class TestChatCompletionResponse:
    """Tests for ChatCompletionResponse."""
    
    def test_create(self):
        response = ChatCompletionResponse.create(
            model="gpt-4",
            message=ChatMessage(role="assistant", content="Hello!"),
            prompt_tokens=5,
            completion_tokens=2,
        )
        assert response.model == "gpt-4"
        assert len(response.choices) == 1
        assert response.usage.total_tokens == 7
    
    def test_to_dict(self):
        response = ChatCompletionResponse.create(
            model="gpt-4",
            message=ChatMessage(role="assistant", content="Hi"),
        )
        result = response.to_dict()
        assert result["object"] == "chat.completion"
        assert result["model"] == "gpt-4"
        assert "choices" in result


# ========================================
# Streaming Tests
# ========================================

class TestDeltaMessage:
    """Tests for DeltaMessage."""
    
    def test_to_dict_empty(self):
        delta = DeltaMessage()
        assert delta.to_dict() == {}
    
    def test_to_dict_with_content(self):
        delta = DeltaMessage(content="Hello")
        assert delta.to_dict() == {"content": "Hello"}
    
    def test_to_dict_with_role(self):
        delta = DeltaMessage(role="assistant")
        assert delta.to_dict() == {"role": "assistant"}


class TestChatCompletionChunk:
    """Tests for ChatCompletionChunk."""
    
    def test_create_start(self):
        chunk = ChatCompletionChunk.create_start("gpt-4", "chat-123")
        assert chunk.id == "chat-123"
        assert chunk.choices[0].delta.role == "assistant"
    
    def test_create_content(self):
        chunk = ChatCompletionChunk.create_content("gpt-4", "chat-123", "Hello")
        assert chunk.choices[0].delta.content == "Hello"
    
    def test_create_end(self):
        chunk = ChatCompletionChunk.create_end("gpt-4", "chat-123", "stop")
        assert chunk.choices[0].finish_reason == "stop"
    
    def test_to_sse(self):
        chunk = ChatCompletionChunk.create_content("gpt-4", "chat-123", "Hi")
        sse = chunk.to_sse()
        assert sse.startswith("data: ")
        assert "Hi" in sse


# ========================================
# Error Response Tests
# ========================================

class TestErrorResponse:
    """Tests for ErrorResponse."""
    
    def test_create(self):
        error = ErrorResponse.create(
            message="Invalid request",
            error_type="invalid_request_error",
            param="model",
        )
        assert error.error.message == "Invalid request"
        assert error.error.type == "invalid_request_error"
    
    def test_to_dict(self):
        error = ErrorResponse.create("Error message")
        result = error.to_dict()
        assert "error" in result
        assert result["error"]["message"] == "Error message"


# ========================================
# Validator Tests
# ========================================

class TestRequestValidator:
    """Tests for RequestValidator."""
    
    def setup_method(self):
        self.validator = RequestValidator()
    
    def test_valid_request(self):
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[ChatMessage(role="user", content="Hello")],
        )
        # Should not raise
        self.validator.validate(request)
    
    def test_missing_model(self):
        request = ChatCompletionRequest(
            model="",
            messages=[ChatMessage(role="user", content="Hello")],
        )
        with pytest.raises(ValidationError) as exc:
            self.validator.validate(request)
        assert "model is required" in str(exc.value)
    
    def test_empty_messages(self):
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[],
        )
        with pytest.raises(ValidationError) as exc:
            self.validator.validate(request)
        assert "messages" in str(exc.value)
    
    def test_invalid_temperature_high(self):
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[ChatMessage(role="user", content="Hello")],
            temperature=3.0,
        )
        with pytest.raises(ValidationError) as exc:
            self.validator.validate(request)
        assert "temperature" in str(exc.value)
    
    def test_invalid_temperature_low(self):
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[ChatMessage(role="user", content="Hello")],
            temperature=-1.0,
        )
        with pytest.raises(ValidationError) as exc:
            self.validator.validate(request)
        assert "temperature" in str(exc.value)
    
    def test_invalid_top_p(self):
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[ChatMessage(role="user", content="Hello")],
            top_p=1.5,
        )
        with pytest.raises(ValidationError) as exc:
            self.validator.validate(request)
        assert "top_p" in str(exc.value)
    
    def test_invalid_n(self):
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[ChatMessage(role="user", content="Hello")],
            n=200,
        )
        with pytest.raises(ValidationError) as exc:
            self.validator.validate(request)
        assert "n" in str(exc.value)
    
    def test_invalid_max_tokens(self):
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[ChatMessage(role="user", content="Hello")],
            max_tokens=0,
        )
        with pytest.raises(ValidationError) as exc:
            self.validator.validate(request)
        assert "max_tokens" in str(exc.value)
    
    def test_invalid_presence_penalty(self):
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[ChatMessage(role="user", content="Hello")],
            presence_penalty=3.0,
        )
        with pytest.raises(ValidationError) as exc:
            self.validator.validate(request)
        assert "presence_penalty" in str(exc.value)
    
    def test_invalid_role(self):
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[ChatMessage(role="invalid", content="Hello")],
        )
        with pytest.raises(ValidationError) as exc:
            self.validator.validate(request)
        assert "role" in str(exc.value)
    
    def test_user_message_without_content(self):
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[ChatMessage(role="user", content=None)],
        )
        with pytest.raises(ValidationError) as exc:
            self.validator.validate(request)
        assert "content" in str(exc.value)
    
    def test_tool_message_without_id(self):
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[ChatMessage(role="tool", content="result")],
        )
        with pytest.raises(ValidationError) as exc:
            self.validator.validate(request)
        assert "tool_call_id" in str(exc.value)


# ========================================
# Error Classes Tests
# ========================================

class TestValidationError:
    """Tests for ValidationError."""
    
    def test_to_error_response(self):
        error = ValidationError("Invalid param", param="temperature")
        response = error.to_error_response()
        assert response.error.type == "invalid_request_error"
        assert response.error.param == "temperature"


class TestBackendError:
    """Tests for BackendError."""
    
    def test_to_error_response(self):
        error = BackendError("Server error", status_code=500)
        response = error.to_error_response()
        assert response.error.type == "server_error"


# ========================================
# Run Tests
# ========================================

if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])