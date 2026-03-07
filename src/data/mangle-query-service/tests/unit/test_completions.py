"""
Unit Tests for Completions Endpoint

Day 11 Tests: Comprehensive tests for /v1/completions endpoint
Target: 45+ tests for full coverage

Test Categories:
1. CompletionRequest creation and validation
2. CompletionResponse formatting
3. CompletionChoice and CompletionLogprobs
4. CompletionChunk streaming
5. CompletionsHandler operations
6. Token estimation utilities
7. Error handling
8. OpenAI API compliance
"""

import pytest
from unittest.mock import Mock, patch
from typing import Generator

from openai.completions import (
    CompletionRequest,
    CompletionResponse,
    CompletionChoice,
    CompletionUsage,
    CompletionLogprobs,
    CompletionChunk,
    CompletionStreamChoice,
    CompletionErrorResponse,
    CompletionsHandler,
    get_completions_handler,
    create_completion,
    estimate_token_count,
    estimate_prompt_tokens,
)


# ========================================
# Fixtures
# ========================================

@pytest.fixture
def basic_request():
    """Create a basic completion request."""
    return CompletionRequest(
        model="gpt-3.5-turbo-instruct",
        prompt="Once upon a time",
    )


@pytest.fixture
def full_request():
    """Create a request with all parameters."""
    return CompletionRequest(
        model="gpt-3.5-turbo-instruct",
        prompt="Hello world",
        max_tokens=100,
        temperature=0.7,
        top_p=0.9,
        n=2,
        stream=False,
        stop=["\n", "END"],
        presence_penalty=0.5,
        frequency_penalty=0.5,
        best_of=3,
        logprobs=3,
        echo=True,
        suffix=" - The End",
        user="test-user",
        seed=42,
    )


@pytest.fixture
def handler():
    """Create a completions handler in mock mode."""
    return CompletionsHandler()


# ========================================
# Test CompletionRequest Creation
# ========================================

class TestCompletionRequestCreation:
    """Tests for CompletionRequest dataclass."""
    
    def test_create_basic(self, basic_request):
        """Test basic request creation."""
        assert basic_request.model == "gpt-3.5-turbo-instruct"
        assert basic_request.prompt == "Once upon a time"
        assert basic_request.max_tokens == 16
        assert basic_request.temperature == 1.0
    
    def test_create_with_all_params(self, full_request):
        """Test creation with all parameters."""
        assert full_request.max_tokens == 100
        assert full_request.temperature == 0.7
        assert full_request.top_p == 0.9
        assert full_request.n == 2
        assert full_request.best_of == 3
        assert full_request.echo is True
        assert full_request.suffix == " - The End"
    
    def test_from_dict_minimal(self):
        """Test creation from minimal dict."""
        data = {"model": "test-model", "prompt": "test prompt"}
        request = CompletionRequest.from_dict(data)
        
        assert request.model == "test-model"
        assert request.prompt == "test prompt"
        assert request.max_tokens == 16
    
    def test_from_dict_full(self):
        """Test creation from full dict."""
        data = {
            "model": "test-model",
            "prompt": "test",
            "max_tokens": 50,
            "temperature": 0.5,
            "n": 2,
            "stream": True,
            "logprobs": 5,
            "echo": True,
        }
        request = CompletionRequest.from_dict(data)
        
        assert request.max_tokens == 50
        assert request.temperature == 0.5
        assert request.n == 2
        assert request.stream is True
        assert request.logprobs == 5
    
    def test_to_dict_minimal(self, basic_request):
        """Test conversion to dict with minimal params."""
        result = basic_request.to_dict()
        
        assert result["model"] == "gpt-3.5-turbo-instruct"
        assert result["prompt"] == "Once upon a time"
        assert "temperature" not in result  # Default not included
    
    def test_to_dict_with_non_defaults(self, full_request):
        """Test conversion includes non-default values."""
        result = full_request.to_dict()
        
        assert result["max_tokens"] == 100
        assert result["temperature"] == 0.7
        assert result["n"] == 2
        assert result["echo"] is True
        assert result["suffix"] == " - The End"


# ========================================
# Test CompletionRequest Validation
# ========================================

class TestCompletionRequestValidation:
    """Tests for request validation."""
    
    def test_valid_request(self, basic_request):
        """Test valid request passes validation."""
        assert basic_request.validate() is None
    
    def test_missing_model(self):
        """Test validation fails without model."""
        request = CompletionRequest(model="", prompt="test")
        assert request.validate() == "model is required"
    
    def test_missing_prompt(self):
        """Test validation fails without prompt."""
        request = CompletionRequest(model="test", prompt=None)
        assert request.validate() == "prompt is required"
    
    def test_invalid_temperature_high(self):
        """Test temperature > 2 is invalid."""
        request = CompletionRequest(
            model="test",
            prompt="test",
            temperature=2.5,
        )
        assert "temperature" in request.validate()
    
    def test_invalid_temperature_low(self):
        """Test temperature < 0 is invalid."""
        request = CompletionRequest(
            model="test",
            prompt="test",
            temperature=-0.5,
        )
        assert "temperature" in request.validate()
    
    def test_invalid_top_p(self):
        """Test top_p > 1 is invalid."""
        request = CompletionRequest(
            model="test",
            prompt="test",
            top_p=1.5,
        )
        assert "top_p" in request.validate()
    
    def test_invalid_n(self):
        """Test n < 1 is invalid."""
        request = CompletionRequest(
            model="test",
            prompt="test",
            n=0,
        )
        assert "n" in request.validate()
    
    def test_invalid_best_of(self):
        """Test best_of < n is invalid."""
        request = CompletionRequest(
            model="test",
            prompt="test",
            n=3,
            best_of=2,
        )
        assert "best_of" in request.validate()
    
    def test_invalid_max_tokens(self):
        """Test max_tokens < 1 is invalid."""
        request = CompletionRequest(
            model="test",
            prompt="test",
            max_tokens=0,
        )
        assert "max_tokens" in request.validate()
    
    def test_invalid_logprobs(self):
        """Test logprobs > 5 is invalid."""
        request = CompletionRequest(
            model="test",
            prompt="test",
            logprobs=10,
        )
        assert "logprobs" in request.validate()


# ========================================
# Test CompletionResponse
# ========================================

class TestCompletionResponse:
    """Tests for CompletionResponse dataclass."""
    
    def test_create_response(self):
        """Test response creation."""
        response = CompletionResponse.create(
            model="test-model",
            text="This is completion text",
            prompt_tokens=5,
            completion_tokens=10,
        )
        
        assert response.model == "test-model"
        assert response.object == "text_completion"
        assert len(response.choices) == 1
        assert response.choices[0].text == "This is completion text"
        assert response.usage.total_tokens == 15
    
    def test_response_id_format(self):
        """Test response ID format."""
        response = CompletionResponse.create(
            model="test",
            text="test",
        )
        assert response.id.startswith("cmpl-")
    
    def test_to_dict(self):
        """Test dict conversion."""
        response = CompletionResponse.create(
            model="test-model",
            text="completion",
            prompt_tokens=3,
            completion_tokens=5,
        )
        result = response.to_dict()
        
        assert result["object"] == "text_completion"
        assert result["model"] == "test-model"
        assert len(result["choices"]) == 1
        assert result["usage"]["total_tokens"] == 8
    
    def test_response_with_multiple_choices(self):
        """Test response with multiple choices."""
        response = CompletionResponse(
            id="cmpl-test",
            model="test",
            choices=[
                CompletionChoice(text="choice 1", index=0),
                CompletionChoice(text="choice 2", index=1),
            ],
        )
        result = response.to_dict()
        
        assert len(result["choices"]) == 2
        assert result["choices"][0]["text"] == "choice 1"
        assert result["choices"][1]["text"] == "choice 2"


# ========================================
# Test CompletionChoice
# ========================================

class TestCompletionChoice:
    """Tests for CompletionChoice dataclass."""
    
    def test_basic_choice(self):
        """Test basic choice creation."""
        choice = CompletionChoice(
            text="Hello world",
            index=0,
            finish_reason="stop",
        )
        
        assert choice.text == "Hello world"
        assert choice.index == 0
        assert choice.finish_reason == "stop"
    
    def test_to_dict(self):
        """Test dict conversion."""
        choice = CompletionChoice(
            text="test",
            index=0,
            finish_reason="length",
        )
        result = choice.to_dict()
        
        assert result["text"] == "test"
        assert result["index"] == 0
        assert result["finish_reason"] == "length"
        assert result["logprobs"] is None
    
    def test_with_logprobs(self):
        """Test choice with logprobs."""
        logprobs = CompletionLogprobs(
            tokens=["Hello", "world"],
            token_logprobs=[-0.1, -0.2],
        )
        choice = CompletionChoice(
            text="Hello world",
            index=0,
            logprobs=logprobs,
        )
        result = choice.to_dict()
        
        assert result["logprobs"] is not None
        assert result["logprobs"]["tokens"] == ["Hello", "world"]


# ========================================
# Test CompletionLogprobs
# ========================================

class TestCompletionLogprobs:
    """Tests for CompletionLogprobs dataclass."""
    
    def test_basic_logprobs(self):
        """Test basic logprobs creation."""
        logprobs = CompletionLogprobs(
            tokens=["a", "b"],
            token_logprobs=[-0.1, -0.2],
            top_logprobs=[{"a": -0.1}, {"b": -0.2}],
            text_offset=[0, 2],
        )
        
        assert len(logprobs.tokens) == 2
        assert logprobs.token_logprobs[0] == -0.1
    
    def test_to_dict(self):
        """Test dict conversion."""
        logprobs = CompletionLogprobs(
            tokens=["test"],
            token_logprobs=[-0.5],
            top_logprobs=[{"test": -0.5}],
            text_offset=[0],
        )
        result = logprobs.to_dict()
        
        assert result["tokens"] == ["test"]
        assert result["text_offset"] == [0]


# ========================================
# Test CompletionUsage
# ========================================

class TestCompletionUsage:
    """Tests for CompletionUsage dataclass."""
    
    def test_usage_creation(self):
        """Test usage creation."""
        usage = CompletionUsage(
            prompt_tokens=10,
            completion_tokens=20,
            total_tokens=30,
        )
        
        assert usage.prompt_tokens == 10
        assert usage.completion_tokens == 20
        assert usage.total_tokens == 30
    
    def test_to_dict(self):
        """Test dict conversion."""
        usage = CompletionUsage(5, 10, 15)
        result = usage.to_dict()
        
        assert result["prompt_tokens"] == 5
        assert result["completion_tokens"] == 10
        assert result["total_tokens"] == 15


# ========================================
# Test CompletionChunk (Streaming)
# ========================================

class TestCompletionChunk:
    """Tests for streaming completion chunks."""
    
    def test_create_text_chunk(self):
        """Test text chunk creation."""
        chunk = CompletionChunk.create_text(
            completion_id="cmpl-123",
            model="test-model",
            text="Hello",
        )
        
        assert chunk.id == "cmpl-123"
        assert chunk.model == "test-model"
        assert chunk.choices[0].text == "Hello"
    
    def test_create_end_chunk(self):
        """Test end chunk creation."""
        chunk = CompletionChunk.create_end(
            completion_id="cmpl-123",
            model="test-model",
            finish_reason="stop",
        )
        
        assert chunk.choices[0].text == ""
        assert chunk.choices[0].finish_reason == "stop"
    
    def test_to_sse(self):
        """Test SSE format conversion."""
        chunk = CompletionChunk.create_text(
            completion_id="cmpl-123",
            model="test",
            text="Hi",
        )
        sse = chunk.to_sse()
        
        assert sse.startswith("data: ")
        assert sse.endswith("\n\n")
        assert '"text": "Hi"' in sse


# ========================================
# Test CompletionStreamChoice
# ========================================

class TestCompletionStreamChoice:
    """Tests for streaming choice."""
    
    def test_stream_choice(self):
        """Test stream choice creation."""
        choice = CompletionStreamChoice(
            text="test",
            index=0,
        )
        result = choice.to_dict()
        
        assert result["text"] == "test"
        assert result["finish_reason"] is None


# ========================================
# Test CompletionErrorResponse
# ========================================

class TestCompletionErrorResponse:
    """Tests for error response."""
    
    def test_basic_error(self):
        """Test basic error creation."""
        error = CompletionErrorResponse(message="Test error")
        result = error.to_dict()
        
        assert result["error"]["message"] == "Test error"
        assert result["error"]["type"] == "invalid_request_error"
    
    def test_full_error(self):
        """Test error with all fields."""
        error = CompletionErrorResponse(
            message="Invalid param",
            type="validation_error",
            param="temperature",
            code="invalid_value",
        )
        result = error.to_dict()
        
        assert result["error"]["param"] == "temperature"
        assert result["error"]["code"] == "invalid_value"


# ========================================
# Test Token Estimation
# ========================================

class TestTokenEstimation:
    """Tests for token estimation utilities."""
    
    def test_estimate_token_count_empty(self):
        """Test token count for empty string."""
        assert estimate_token_count("") == 0
    
    def test_estimate_token_count_short(self):
        """Test token count for short text."""
        assert estimate_token_count("hi") == 1  # Min 1
    
    def test_estimate_token_count_medium(self):
        """Test token count for medium text."""
        # ~4 chars per token
        result = estimate_token_count("This is a test sentence")
        assert result > 0
        assert result < len("This is a test sentence")
    
    def test_estimate_prompt_tokens_string(self):
        """Test prompt tokens for string."""
        result = estimate_prompt_tokens("Hello world")
        assert result > 0
    
    def test_estimate_prompt_tokens_list_string(self):
        """Test prompt tokens for list of strings."""
        result = estimate_prompt_tokens(["Hello", "World"])
        assert result > 0
    
    def test_estimate_prompt_tokens_token_ids(self):
        """Test prompt tokens for token IDs."""
        result = estimate_prompt_tokens([1, 2, 3, 4, 5])
        assert result == 5
    
    def test_estimate_prompt_tokens_batch_ids(self):
        """Test prompt tokens for batch token IDs."""
        result = estimate_prompt_tokens([[1, 2, 3], [4, 5]])
        assert result == 5
    
    def test_estimate_prompt_tokens_empty(self):
        """Test prompt tokens for empty input."""
        assert estimate_prompt_tokens([]) == 0


# ========================================
# Test CompletionsHandler
# ========================================

class TestCompletionsHandler:
    """Tests for CompletionsHandler."""
    
    def test_mock_mode(self, handler):
        """Test handler is in mock mode."""
        assert handler.is_mock_mode is True
    
    def test_create_completion_basic(self, handler, basic_request):
        """Test basic completion creation."""
        result = handler.create_completion(basic_request)
        
        assert "id" in result
        assert "choices" in result
        assert result["object"] == "text_completion"
    
    def test_create_completion_validation_error(self, handler):
        """Test validation error response."""
        request = CompletionRequest(model="", prompt="test")
        result = handler.create_completion(request)
        
        assert "error" in result
        assert "model is required" in result["error"]["message"]
    
    def test_completion_with_multiple_n(self, handler):
        """Test completion with n > 1."""
        request = CompletionRequest(
            model="test",
            prompt="test",
            n=3,
            best_of=3,
        )
        result = handler.create_completion(request)
        
        assert len(result["choices"]) == 3
    
    def test_completion_with_echo(self, handler):
        """Test completion with echo enabled."""
        request = CompletionRequest(
            model="test",
            prompt="Hello",
            echo=True,
        )
        result = handler.create_completion(request)
        
        # Text should include prompt when echo is True
        text = result["choices"][0]["text"]
        assert "Hello" in text
    
    def test_completion_with_suffix(self, handler):
        """Test completion with suffix."""
        request = CompletionRequest(
            model="test",
            prompt="test",
            suffix=" - END",
        )
        result = handler.create_completion(request)
        
        text = result["choices"][0]["text"]
        assert text.endswith(" - END")
    
    def test_completion_with_logprobs(self, handler):
        """Test completion with logprobs requested."""
        request = CompletionRequest(
            model="test",
            prompt="test",
            logprobs=3,
        )
        result = handler.create_completion(request)
        
        logprobs = result["choices"][0]["logprobs"]
        assert logprobs is not None
        assert "tokens" in logprobs


# ========================================
# Test Streaming Completions
# ========================================

class TestStreamingCompletions:
    """Tests for streaming completion functionality."""
    
    def test_streaming_returns_generator(self, handler):
        """Test streaming returns a generator."""
        request = CompletionRequest(
            model="test",
            prompt="test",
            stream=True,
        )
        result = handler.create_completion(request)
        
        assert isinstance(result, Generator)
    
    def test_streaming_chunks(self, handler):
        """Test streaming produces valid chunks."""
        request = CompletionRequest(
            model="test",
            prompt="test",
            stream=True,
        )
        result = handler.create_completion(request)
        chunks = list(result)
        
        assert len(chunks) > 0
        assert chunks[-1] == "data: [DONE]\n\n"
    
    def test_streaming_sse_format(self, handler):
        """Test streaming chunks are SSE formatted."""
        request = CompletionRequest(
            model="test",
            prompt="test",
            stream=True,
        )
        result = handler.create_completion(request)
        chunks = list(result)
        
        for chunk in chunks[:-1]:  # Exclude [DONE]
            assert chunk.startswith("data: ")


# ========================================
# Test Handle Request
# ========================================

class TestHandleRequest:
    """Tests for handle_request method."""
    
    def test_handle_valid_request(self, handler):
        """Test handling valid request dict."""
        data = {"model": "test", "prompt": "Hello"}
        result = handler.handle_request(data)
        
        assert "choices" in result
    
    def test_handle_missing_field(self, handler):
        """Test handling request with missing field."""
        data = {"prompt": "Hello"}  # Missing model
        result = handler.handle_request(data)
        
        assert "error" in result
    
    def test_handle_streaming_request(self, handler):
        """Test handling streaming request."""
        data = {"model": "test", "prompt": "Hello", "stream": True}
        result = handler.handle_request(data)
        
        assert isinstance(result, Generator)


# ========================================
# Test Utility Functions
# ========================================

class TestUtilityFunctions:
    """Tests for module-level utility functions."""
    
    def test_get_completions_handler(self):
        """Test handler factory."""
        handler = get_completions_handler()
        assert isinstance(handler, CompletionsHandler)
    
    def test_create_completion_function(self):
        """Test convenience function."""
        result = create_completion(
            model="test",
            prompt="Hello",
        )
        assert "choices" in result or "streaming" in result


# ========================================
# Test OpenAI API Compliance
# ========================================

class TestOpenAICompliance:
    """Tests for OpenAI API compliance."""
    
    def test_response_object_type(self, handler, basic_request):
        """Test response has correct object type."""
        result = handler.create_completion(basic_request)
        assert result["object"] == "text_completion"
    
    def test_response_has_id(self, handler, basic_request):
        """Test response has ID."""
        result = handler.create_completion(basic_request)
        assert "id" in result
        assert result["id"].startswith("cmpl-")
    
    def test_response_has_created(self, handler, basic_request):
        """Test response has created timestamp."""
        result = handler.create_completion(basic_request)
        assert "created" in result
        assert isinstance(result["created"], int)
    
    def test_response_has_model(self, handler, basic_request):
        """Test response has model."""
        result = handler.create_completion(basic_request)
        assert "model" in result
        assert result["model"] == basic_request.model
    
    def test_response_has_usage(self, handler, basic_request):
        """Test response has usage statistics."""
        result = handler.create_completion(basic_request)
        assert "usage" in result
        assert "prompt_tokens" in result["usage"]
        assert "completion_tokens" in result["usage"]
        assert "total_tokens" in result["usage"]
    
    def test_choice_has_text(self, handler, basic_request):
        """Test choice has text field."""
        result = handler.create_completion(basic_request)
        assert "text" in result["choices"][0]
    
    def test_choice_has_index(self, handler, basic_request):
        """Test choice has index field."""
        result = handler.create_completion(basic_request)
        assert "index" in result["choices"][0]
        assert result["choices"][0]["index"] == 0
    
    def test_choice_has_finish_reason(self, handler, basic_request):
        """Test choice has finish_reason."""
        result = handler.create_completion(basic_request)
        assert "finish_reason" in result["choices"][0]


# ========================================
# Test Prompt Formats
# ========================================

class TestPromptFormats:
    """Tests for different prompt input formats."""
    
    def test_string_prompt(self, handler):
        """Test string prompt."""
        request = CompletionRequest(model="test", prompt="Hello")
        result = handler.create_completion(request)
        assert "choices" in result
    
    def test_list_string_prompt(self, handler):
        """Test list of string prompts."""
        request = CompletionRequest(model="test", prompt=["Hello", "World"])
        result = handler.create_completion(request)
        assert "choices" in result
    
    def test_empty_list_prompt(self, handler):
        """Test empty list prompt."""
        request = CompletionRequest(model="test", prompt=[])
        result = handler.create_completion(request)
        assert "choices" in result


if __name__ == "__main__":
    pytest.main([__file__, "-v"])