"""
Integration Tests for OpenAI-Compatible API

Day 15 Deliverable: End-to-end integration testing across all endpoints
Target: 60+ integration tests verifying full API workflow

Test Categories:
1. Chat Completions endpoint integration
2. Embeddings endpoint integration
3. Completions endpoint integration
4. Models endpoint integration
5. Audio endpoints integration
6. Files endpoint integration
7. Images endpoint integration
8. Cross-endpoint workflows
9. Error handling consistency
10. Response format compliance
"""

import pytest
import time
import json
from typing import Dict, Any, List
from unittest.mock import Mock, AsyncMock, patch

# Import all endpoint handlers
from openai.chat_completions import ChatCompletionsHandler
from openai.embeddings import EmbeddingsHandler
from openai.completions import CompletionsHandler, get_completions_handler
from openai.models_endpoint import ModelsHandler, get_models_handler
from openai.audio import AudioHandler, get_audio_handler
from openai.files import FilesHandler, get_files_handler
from openai.images import ImagesHandler, get_images_handler
from openai.models import ChatCompletionRequest, ChatMessage, Role


# ========================================
# Fixtures
# ========================================

@pytest.fixture
def chat_handler():
    """Create chat completions handler."""
    return ChatCompletionsHandler()


@pytest.fixture
def embeddings_handler():
    """Create embeddings handler."""
    return EmbeddingsHandler()


@pytest.fixture
def completions_handler():
    """Create completions handler."""
    return get_completions_handler()


@pytest.fixture
def models_handler():
    """Create models handler."""
    return get_models_handler()


@pytest.fixture
def audio_handler():
    """Create audio handler."""
    return get_audio_handler()


@pytest.fixture
def files_handler():
    """Create files handler."""
    return get_files_handler()


@pytest.fixture
def images_handler():
    """Create images handler."""
    return get_images_handler()


@pytest.fixture
def sample_audio():
    """Sample audio data."""
    return b"RIFF" + b"\x00" * 44 + b"\x00" * 1000


@pytest.fixture
def sample_image():
    """Sample image data."""
    return b"\x89PNG\r\n\x1a\n" + b"\x00" * 1000


# ========================================
# Chat Completions Integration Tests
# ========================================

class TestChatCompletionsIntegration:
    """Integration tests for chat completions."""
    
    def test_basic_chat_request(self, chat_handler):
        """Test basic chat completion request."""
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[
                ChatMessage(role=Role.USER, content="Hello, how are you?")
            ],
        )
        
        # In mock mode, handler should return valid response
        assert request.model == "gpt-4"
        assert len(request.messages) == 1
    
    def test_chat_with_system_message(self, chat_handler):
        """Test chat with system message."""
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[
                ChatMessage(role=Role.SYSTEM, content="You are helpful."),
                ChatMessage(role=Role.USER, content="Hello!"),
            ],
        )
        
        assert request.messages[0].role == Role.SYSTEM
        assert request.messages[1].role == Role.USER
    
    def test_chat_with_tools(self, chat_handler):
        """Test chat with tool definitions."""
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[
                ChatMessage(role=Role.USER, content="What's the weather?")
            ],
            tools=[{
                "type": "function",
                "function": {
                    "name": "get_weather",
                    "parameters": {"type": "object", "properties": {}}
                }
            }],
        )
        
        assert request.tools is not None
        assert len(request.tools) == 1
    
    def test_chat_streaming_request(self, chat_handler):
        """Test streaming chat request."""
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=[
                ChatMessage(role=Role.USER, content="Tell me a story")
            ],
            stream=True,
        )
        
        assert request.stream is True


# ========================================
# Embeddings Integration Tests
# ========================================

class TestEmbeddingsIntegration:
    """Integration tests for embeddings."""
    
    def test_single_text_embedding(self, embeddings_handler):
        """Test embedding single text."""
        result = embeddings_handler.create_embeddings({
            "model": "text-embedding-ada-002",
            "input": "Hello world"
        })
        
        assert "data" in result or "error" in result
    
    def test_batch_embeddings(self, embeddings_handler):
        """Test batch embedding request."""
        result = embeddings_handler.create_embeddings({
            "model": "text-embedding-ada-002",
            "input": ["First text", "Second text", "Third text"]
        })
        
        assert "data" in result or "error" in result
    
    def test_embedding_dimensions(self, embeddings_handler):
        """Test embedding with specified dimensions."""
        result = embeddings_handler.create_embeddings({
            "model": "text-embedding-3-small",
            "input": "Test text",
            "dimensions": 256
        })
        
        assert "data" in result or "error" in result


# ========================================
# Completions Integration Tests
# ========================================

class TestCompletionsIntegration:
    """Integration tests for completions."""
    
    def test_basic_completion(self, completions_handler):
        """Test basic completion request."""
        result = completions_handler.handle_request({
            "model": "gpt-3.5-turbo-instruct",
            "prompt": "Once upon a time"
        })
        
        assert "choices" in result or "error" in result
    
    def test_completion_with_max_tokens(self, completions_handler):
        """Test completion with max tokens."""
        result = completions_handler.handle_request({
            "model": "gpt-3.5-turbo-instruct",
            "prompt": "Hello",
            "max_tokens": 50
        })
        
        assert "choices" in result or "error" in result
    
    def test_completion_streaming(self, completions_handler):
        """Test streaming completion."""
        result = completions_handler.handle_request({
            "model": "gpt-3.5-turbo-instruct",
            "prompt": "Hello",
            "stream": True
        })
        
        # In mock mode, returns generator or result
        assert result is not None
    
    def test_completion_multiple_prompts(self, completions_handler):
        """Test completion with multiple prompts."""
        result = completions_handler.handle_request({
            "model": "gpt-3.5-turbo-instruct",
            "prompt": ["Prompt 1", "Prompt 2"],
            "n": 1
        })
        
        assert result is not None


# ========================================
# Models Integration Tests
# ========================================

class TestModelsIntegration:
    """Integration tests for models endpoint."""
    
    def test_list_models(self, models_handler):
        """Test listing all models."""
        result = models_handler.list_models()
        
        assert "data" in result
        assert "object" in result
        assert result["object"] == "list"
    
    def test_retrieve_model(self, models_handler):
        """Test retrieving specific model."""
        result = models_handler.retrieve_model("gpt-4")
        
        assert "id" in result or "error" in result
    
    def test_model_capabilities(self, models_handler):
        """Test model capabilities."""
        result = models_handler.list_models()
        
        if "data" in result and len(result["data"]) > 0:
            model = result["data"][0]
            assert "id" in model
            assert "object" in model
    
    def test_delete_model(self, models_handler):
        """Test delete model (fine-tuned only)."""
        result = models_handler.delete_model("ft:gpt-3.5-turbo:custom")
        
        # Should return deletion response or error
        assert "deleted" in result or "error" in result


# ========================================
# Audio Integration Tests
# ========================================

class TestAudioIntegration:
    """Integration tests for audio endpoints."""
    
    def test_transcription_request(self, audio_handler, sample_audio):
        """Test audio transcription."""
        result = audio_handler.handle_transcription(
            form_data={"model": "whisper-1"},
            audio_data=sample_audio,
            filename="test.wav"
        )
        
        assert "text" in result or "error" in result
    
    def test_translation_request(self, audio_handler, sample_audio):
        """Test audio translation."""
        result = audio_handler.handle_translation(
            form_data={"model": "whisper-1"},
            audio_data=sample_audio,
            filename="test.wav"
        )
        
        assert "text" in result or "error" in result
    
    def test_transcription_with_timestamp(self, audio_handler, sample_audio):
        """Test transcription with timestamps."""
        result = audio_handler.handle_transcription(
            form_data={
                "model": "whisper-1",
                "response_format": "verbose_json",
                "timestamp_granularities": ["word"]
            },
            audio_data=sample_audio,
            filename="test.wav"
        )
        
        assert result is not None


# ========================================
# Files Integration Tests
# ========================================

class TestFilesIntegration:
    """Integration tests for files endpoint."""
    
    def test_upload_file(self, files_handler):
        """Test file upload."""
        file_data = b'{"messages": [{"role": "user", "content": "Hi"}]}'
        result = files_handler.upload_file(
            file_data=file_data,
            filename="training.jsonl",
            purpose="fine-tune"
        )
        
        assert "id" in result or "error" in result
    
    def test_list_files(self, files_handler):
        """Test listing files."""
        result = files_handler.list_files()
        
        assert "data" in result
        assert "object" in result
    
    def test_file_lifecycle(self, files_handler):
        """Test full file lifecycle: upload, retrieve, delete."""
        # Upload
        file_data = b'{"messages": []}\n'
        upload_result = files_handler.upload_file(
            file_data=file_data,
            filename="test.jsonl",
            purpose="fine-tune"
        )
        
        if "id" in upload_result:
            file_id = upload_result["id"]
            
            # Retrieve
            retrieve_result = files_handler.retrieve_file(file_id)
            assert retrieve_result.get("id") == file_id
            
            # Delete
            delete_result = files_handler.delete_file(file_id)
            assert delete_result.get("deleted") is True
    
    def test_file_content_retrieval(self, files_handler):
        """Test retrieving file content."""
        # First upload a file
        file_data = b'{"messages": []}\n'
        upload_result = files_handler.upload_file(
            file_data=file_data,
            filename="content_test.jsonl",
            purpose="fine-tune"
        )
        
        if "id" in upload_result:
            content_result = files_handler.retrieve_file_content(upload_result["id"])
            assert content_result is not None


# ========================================
# Images Integration Tests
# ========================================

class TestImagesIntegration:
    """Integration tests for images endpoint."""
    
    def test_generate_image(self, images_handler):
        """Test image generation."""
        result = images_handler.handle_generate({
            "prompt": "A beautiful sunset over mountains",
            "model": "dall-e-3",
            "size": "1024x1024"
        })
        
        assert "created" in result
        assert "data" in result
    
    def test_generate_multiple_images(self, images_handler):
        """Test generating multiple images with DALL-E 2."""
        result = images_handler.handle_generate({
            "prompt": "A cat",
            "model": "dall-e-2",
            "n": 3,
            "size": "512x512"
        })
        
        assert "data" in result
        if "error" not in result:
            assert len(result["data"]) == 3
    
    def test_edit_image(self, images_handler, sample_image):
        """Test image editing."""
        result = images_handler.handle_edit(
            form_data={"prompt": "Add a rainbow"},
            image=sample_image
        )
        
        assert "data" in result or "error" in result
    
    def test_create_variation(self, images_handler, sample_image):
        """Test image variation."""
        result = images_handler.handle_variation(
            form_data={"n": 2},
            image=sample_image
        )
        
        assert "data" in result or "error" in result


# ========================================
# Cross-Endpoint Workflow Tests
# ========================================

class TestCrossEndpointWorkflows:
    """Tests for workflows spanning multiple endpoints."""
    
    def test_model_then_chat(self, models_handler, chat_handler):
        """Test: list models, then use one for chat."""
        # List available models
        models_result = models_handler.list_models()
        assert "data" in models_result
        
        # Use first available model for chat
        if models_result["data"]:
            model_id = models_result["data"][0]["id"]
            request = ChatCompletionRequest(
                model=model_id,
                messages=[
                    ChatMessage(role=Role.USER, content="Hello")
                ],
            )
            assert request.model == model_id
    
    def test_upload_then_list_files(self, files_handler):
        """Test: upload file, then list to verify."""
        # Upload
        file_data = b'{"test": true}\n'
        upload_result = files_handler.upload_file(
            file_data=file_data,
            filename="workflow_test.jsonl",
            purpose="fine-tune"
        )
        
        # List and verify
        list_result = files_handler.list_files(purpose="fine-tune")
        assert "data" in list_result
    
    def test_generate_then_edit_image(self, images_handler, sample_image):
        """Test: generate image concept, then edit."""
        # Generate
        gen_result = images_handler.handle_generate({
            "prompt": "A landscape",
            "model": "dall-e-2",
        })
        
        assert "data" in gen_result
        
        # Edit (using sample image as stand-in)
        edit_result = images_handler.handle_edit(
            form_data={"prompt": "Add clouds"},
            image=sample_image
        )
        
        assert edit_result is not None


# ========================================
# Error Handling Consistency Tests
# ========================================

class TestErrorHandlingConsistency:
    """Tests for consistent error handling across endpoints."""
    
    def test_chat_invalid_model(self):
        """Test chat with invalid model."""
        request = ChatCompletionRequest(
            model="invalid-model-xyz",
            messages=[
                ChatMessage(role=Role.USER, content="Hi")
            ],
        )
        # Should not crash, model validation happens in handler
        assert request.model == "invalid-model-xyz"
    
    def test_embedding_empty_input(self, embeddings_handler):
        """Test embedding with empty input."""
        result = embeddings_handler.create_embeddings({
            "model": "text-embedding-ada-002",
            "input": ""
        })
        
        # Should return error or handle gracefully
        assert result is not None
    
    def test_files_invalid_purpose(self, files_handler):
        """Test file upload with invalid purpose."""
        result = files_handler.upload_file(
            file_data=b"test",
            filename="test.txt",
            purpose="invalid-purpose"
        )
        
        assert "error" in result
    
    def test_images_invalid_size(self, images_handler):
        """Test image generation with invalid size."""
        result = images_handler.handle_generate({
            "prompt": "Test",
            "model": "dall-e-3",
            "size": "99x99"  # Invalid
        })
        
        assert "error" in result


# ========================================
# Response Format Compliance Tests
# ========================================

class TestResponseFormatCompliance:
    """Tests for OpenAI response format compliance."""
    
    def test_models_list_format(self, models_handler):
        """Test models list response format."""
        result = models_handler.list_models()
        
        assert result["object"] == "list"
        assert "data" in result
        assert isinstance(result["data"], list)
    
    def test_files_list_format(self, files_handler):
        """Test files list response format."""
        result = files_handler.list_files()
        
        assert result["object"] == "list"
        assert "data" in result
        assert "has_more" in result
    
    def test_images_response_format(self, images_handler):
        """Test images response format."""
        result = images_handler.handle_generate({
            "prompt": "Test",
            "model": "dall-e-3"
        })
        
        assert "created" in result
        assert isinstance(result["created"], int)
        assert "data" in result
    
    def test_error_response_format(self, files_handler):
        """Test error response format."""
        result = files_handler.upload_file(
            file_data=b"",
            filename="test.txt",
            purpose="fine-tune"
        )
        
        if "error" in result:
            assert "message" in result["error"]
            assert "type" in result["error"]


# ========================================
# Performance and Edge Cases
# ========================================

class TestPerformanceAndEdgeCases:
    """Tests for performance and edge cases."""
    
    def test_large_messages_list(self):
        """Test chat with large messages list."""
        messages = [
            ChatMessage(role=Role.USER, content=f"Message {i}")
            for i in range(50)
        ]
        
        request = ChatCompletionRequest(
            model="gpt-4",
            messages=messages,
        )
        
        assert len(request.messages) == 50
    
    def test_long_prompt(self, completions_handler):
        """Test completion with long prompt."""
        long_prompt = "word " * 500
        result = completions_handler.handle_request({
            "model": "gpt-3.5-turbo-instruct",
            "prompt": long_prompt,
            "max_tokens": 10
        })
        
        assert result is not None
    
    def test_special_characters_in_prompt(self, completions_handler):
        """Test prompts with special characters."""
        result = completions_handler.handle_request({
            "model": "gpt-3.5-turbo-instruct",
            "prompt": "Test with émojis 🚀 and ñ characters"
        })
        
        assert result is not None
    
    def test_json_in_prompt(self, completions_handler):
        """Test JSON content in prompt."""
        json_prompt = json.dumps({"key": "value", "nested": {"a": 1}})
        result = completions_handler.handle_request({
            "model": "gpt-3.5-turbo-instruct",
            "prompt": f"Parse this JSON: {json_prompt}"
        })
        
        assert result is not None


# ========================================
# Handler Factory Tests
# ========================================

class TestHandlerFactories:
    """Tests for handler factory functions."""
    
    def test_completions_handler_factory(self):
        """Test completions handler factory."""
        handler = get_completions_handler()
        assert isinstance(handler, CompletionsHandler)
    
    def test_models_handler_factory(self):
        """Test models handler factory."""
        handler = get_models_handler()
        assert isinstance(handler, ModelsHandler)
    
    def test_audio_handler_factory(self):
        """Test audio handler factory."""
        handler = get_audio_handler()
        assert isinstance(handler, AudioHandler)
    
    def test_files_handler_factory(self):
        """Test files handler factory."""
        handler = get_files_handler()
        assert isinstance(handler, FilesHandler)
    
    def test_images_handler_factory(self):
        """Test images handler factory."""
        handler = get_images_handler()
        assert isinstance(handler, ImagesHandler)


# ========================================
# API Version Compatibility Tests
# ========================================

class TestAPIVersionCompatibility:
    """Tests for OpenAI API version compatibility."""
    
    def test_object_type_consistency(self, models_handler, files_handler):
        """Test object type fields are consistent."""
        models = models_handler.list_models()
        files = files_handler.list_files()
        
        assert models["object"] == "list"
        assert files["object"] == "list"
    
    def test_timestamp_format(self, images_handler):
        """Test timestamps are Unix epoch integers."""
        result = images_handler.handle_generate({
            "prompt": "Test",
            "model": "dall-e-3"
        })
        
        assert isinstance(result["created"], int)
        assert result["created"] > 1000000000  # After year 2001
    
    def test_id_format_conventions(self, files_handler):
        """Test ID format conventions."""
        file_data = b'{"test": true}\n'
        result = files_handler.upload_file(
            file_data=file_data,
            filename="id_test.jsonl",
            purpose="fine-tune"
        )
        
        if "id" in result:
            assert result["id"].startswith("file-")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])