"""
Unit Tests for Embeddings Endpoint

Day 9: OpenAI-compatible embeddings API tests
"""

import pytest
import asyncio
import base64
import struct
from unittest.mock import Mock, patch, AsyncMock

import sys
sys.path.insert(0, "/Users/user/Documents/sap-oss/mangle-query-service")

from openai.embeddings import (
    EncodingFormat,
    EmbeddingRequest,
    EmbeddingData,
    EmbeddingUsage,
    EmbeddingResponse,
    EmbeddingsHandler,
    get_embeddings_handler,
    estimate_tokens,
    encode_base64,
    generate_mock_embedding,
    truncate_embedding,
)


# ========================================
# EncodingFormat Tests
# ========================================

class TestEncodingFormat:
    """Tests for EncodingFormat enum."""
    
    def test_float_format(self):
        """Test float encoding format."""
        assert EncodingFormat.FLOAT == "float"
        assert EncodingFormat.FLOAT.value == "float"
    
    def test_base64_format(self):
        """Test base64 encoding format."""
        assert EncodingFormat.BASE64 == "base64"
        assert EncodingFormat.BASE64.value == "base64"
    
    def test_from_string(self):
        """Test creating from string."""
        assert EncodingFormat("float") == EncodingFormat.FLOAT
        assert EncodingFormat("base64") == EncodingFormat.BASE64


# ========================================
# EmbeddingRequest Tests
# ========================================

class TestEmbeddingRequest:
    """Tests for EmbeddingRequest."""
    
    def test_create_with_string_input(self):
        """Test creating request with string input."""
        request = EmbeddingRequest(
            input="Hello world",
            model="text-embedding-3-small",
        )
        assert request.input == "Hello world"
        assert request.model == "text-embedding-3-small"
        assert request.encoding_format == EncodingFormat.FLOAT
        assert request.dimensions is None
    
    def test_create_with_list_input(self):
        """Test creating request with list input."""
        request = EmbeddingRequest(
            input=["Hello", "World"],
            model="text-embedding-3-large",
        )
        assert request.input == ["Hello", "World"]
        assert len(request.get_input_texts()) == 2
    
    def test_create_with_dimensions(self):
        """Test creating request with custom dimensions."""
        request = EmbeddingRequest(
            input="Test",
            model="text-embedding-3-small",
            dimensions=512,
        )
        assert request.dimensions == 512
    
    def test_create_with_base64_encoding(self):
        """Test creating request with base64 encoding."""
        request = EmbeddingRequest(
            input="Test",
            model="text-embedding-3-small",
            encoding_format=EncodingFormat.BASE64,
        )
        assert request.encoding_format == EncodingFormat.BASE64
    
    def test_from_dict_minimal(self):
        """Test creating from minimal dictionary."""
        data = {
            "input": "Hello",
            "model": "text-embedding-ada-002",
        }
        request = EmbeddingRequest.from_dict(data)
        assert request.input == "Hello"
        assert request.model == "text-embedding-ada-002"
    
    def test_from_dict_complete(self):
        """Test creating from complete dictionary."""
        data = {
            "input": ["Text 1", "Text 2"],
            "model": "text-embedding-3-large",
            "encoding_format": "base64",
            "dimensions": 1024,
            "user": "test-user",
        }
        request = EmbeddingRequest.from_dict(data)
        assert request.input == ["Text 1", "Text 2"]
        assert request.model == "text-embedding-3-large"
        assert request.encoding_format == EncodingFormat.BASE64
        assert request.dimensions == 1024
        assert request.user == "test-user"
    
    def test_validate_valid_request(self):
        """Test validation of valid request."""
        request = EmbeddingRequest(
            input="Valid text",
            model="text-embedding-3-small",
        )
        errors = request.validate()
        assert len(errors) == 0
    
    def test_validate_empty_input(self):
        """Test validation catches empty input."""
        request = EmbeddingRequest(
            input="",
            model="text-embedding-3-small",
        )
        errors = request.validate()
        assert any("input" in e for e in errors)
    
    def test_validate_empty_model(self):
        """Test validation catches empty model."""
        request = EmbeddingRequest(
            input="Test",
            model="",
        )
        errors = request.validate()
        assert any("model" in e for e in errors)
    
    def test_validate_invalid_dimensions_low(self):
        """Test validation catches invalid low dimensions."""
        request = EmbeddingRequest(
            input="Test",
            model="test",
            dimensions=0,
        )
        errors = request.validate()
        assert any("dimensions" in e for e in errors)
    
    def test_validate_invalid_dimensions_high(self):
        """Test validation catches invalid high dimensions."""
        request = EmbeddingRequest(
            input="Test",
            model="test",
            dimensions=5000,
        )
        errors = request.validate()
        assert any("3072" in e for e in errors)
    
    def test_validate_batch_too_large(self):
        """Test validation catches batch size exceeding limit."""
        request = EmbeddingRequest(
            input=["text"] * 3000,
            model="test",
        )
        errors = request.validate()
        assert any("2048" in e for e in errors)
    
    def test_get_input_texts_string(self):
        """Test get_input_texts with string input."""
        request = EmbeddingRequest(
            input="Single text",
            model="test",
        )
        texts = request.get_input_texts()
        assert texts == ["Single text"]
    
    def test_get_input_texts_list(self):
        """Test get_input_texts with list input."""
        request = EmbeddingRequest(
            input=["Text 1", "Text 2", "Text 3"],
            model="test",
        )
        texts = request.get_input_texts()
        assert len(texts) == 3
        assert texts[0] == "Text 1"
    
    def test_get_input_texts_empty_list(self):
        """Test get_input_texts with empty list."""
        request = EmbeddingRequest(
            input=[],
            model="test",
        )
        texts = request.get_input_texts()
        assert texts == []


# ========================================
# EmbeddingData Tests
# ========================================

class TestEmbeddingData:
    """Tests for EmbeddingData."""
    
    def test_create_with_float_embedding(self):
        """Test creating with float array embedding."""
        data = EmbeddingData(
            embedding=[0.1, 0.2, 0.3],
            index=0,
        )
        assert data.embedding == [0.1, 0.2, 0.3]
        assert data.index == 0
        assert data.object == "embedding"
    
    def test_create_with_base64_embedding(self):
        """Test creating with base64 string embedding."""
        data = EmbeddingData(
            embedding="SGVsbG8=",
            index=1,
        )
        assert data.embedding == "SGVsbG8="
        assert data.index == 1
    
    def test_to_dict(self):
        """Test conversion to dictionary."""
        data = EmbeddingData(
            embedding=[0.5, 0.5],
            index=2,
        )
        result = data.to_dict()
        assert result["object"] == "embedding"
        assert result["embedding"] == [0.5, 0.5]
        assert result["index"] == 2


# ========================================
# EmbeddingUsage Tests
# ========================================

class TestEmbeddingUsage:
    """Tests for EmbeddingUsage."""
    
    def test_create(self):
        """Test creating usage object."""
        usage = EmbeddingUsage(
            prompt_tokens=100,
            total_tokens=100,
        )
        assert usage.prompt_tokens == 100
        assert usage.total_tokens == 100
    
    def test_to_dict(self):
        """Test conversion to dictionary."""
        usage = EmbeddingUsage(
            prompt_tokens=50,
            total_tokens=50,
        )
        result = usage.to_dict()
        assert result["prompt_tokens"] == 50
        assert result["total_tokens"] == 50


# ========================================
# EmbeddingResponse Tests
# ========================================

class TestEmbeddingResponse:
    """Tests for EmbeddingResponse."""
    
    def test_create(self):
        """Test creating response."""
        response = EmbeddingResponse(
            data=[
                EmbeddingData(embedding=[0.1], index=0),
            ],
            model="text-embedding-3-small",
            usage=EmbeddingUsage(prompt_tokens=5, total_tokens=5),
        )
        assert response.object == "list"
        assert len(response.data) == 1
        assert response.model == "text-embedding-3-small"
    
    def test_to_dict(self):
        """Test conversion to dictionary."""
        response = EmbeddingResponse(
            data=[
                EmbeddingData(embedding=[0.1, 0.2], index=0),
                EmbeddingData(embedding=[0.3, 0.4], index=1),
            ],
            model="test-model",
            usage=EmbeddingUsage(prompt_tokens=10, total_tokens=10),
        )
        result = response.to_dict()
        
        assert result["object"] == "list"
        assert len(result["data"]) == 2
        assert result["model"] == "test-model"
        assert result["usage"]["prompt_tokens"] == 10


# ========================================
# Utility Function Tests
# ========================================

class TestEstimateTokens:
    """Tests for estimate_tokens function."""
    
    def test_empty_string(self):
        """Test with empty string."""
        assert estimate_tokens("") == 1  # Minimum 1
    
    def test_short_string(self):
        """Test with short string."""
        result = estimate_tokens("Hi")
        assert result >= 1
    
    def test_medium_string(self):
        """Test with medium string."""
        text = "Hello world, this is a test"
        result = estimate_tokens(text)
        # ~27 chars / 4 = ~6-7 tokens
        assert 5 <= result <= 10
    
    def test_long_string(self):
        """Test with longer string."""
        text = "A" * 1000
        result = estimate_tokens(text)
        # 1000 / 4 = 250 tokens
        assert result == 250


class TestEncodeBase64:
    """Tests for encode_base64 function."""
    
    def test_encode_simple(self):
        """Test encoding simple embedding."""
        embedding = [1.0, 2.0, 3.0]
        result = encode_base64(embedding)
        
        # Should be base64 string
        assert isinstance(result, str)
        
        # Should be decodable
        decoded = base64.b64decode(result)
        floats = struct.unpack("3f", decoded)
        assert floats == (1.0, 2.0, 3.0)
    
    def test_encode_negative(self):
        """Test encoding with negative values."""
        embedding = [-0.5, 0.0, 0.5]
        result = encode_base64(embedding)
        
        decoded = base64.b64decode(result)
        floats = struct.unpack("3f", decoded)
        assert floats[0] == pytest.approx(-0.5)
        assert floats[2] == pytest.approx(0.5)


class TestGenerateMockEmbedding:
    """Tests for generate_mock_embedding function."""
    
    def test_default_dimensions(self):
        """Test with default dimensions."""
        embedding = generate_mock_embedding("test")
        assert len(embedding) == 1536
    
    def test_custom_dimensions(self):
        """Test with custom dimensions."""
        embedding = generate_mock_embedding("test", dimensions=512)
        assert len(embedding) == 512
    
    def test_deterministic(self):
        """Test that same text produces same embedding."""
        emb1 = generate_mock_embedding("hello world")
        emb2 = generate_mock_embedding("hello world")
        assert emb1 == emb2
    
    def test_different_texts(self):
        """Test that different texts produce different embeddings."""
        emb1 = generate_mock_embedding("hello")
        emb2 = generate_mock_embedding("world")
        assert emb1 != emb2
    
    def test_normalized(self):
        """Test that embedding is normalized (unit vector)."""
        embedding = generate_mock_embedding("test", dimensions=100)
        magnitude = sum(x * x for x in embedding) ** 0.5
        assert magnitude == pytest.approx(1.0, abs=0.001)
    
    def test_custom_seed(self):
        """Test with custom seed."""
        emb1 = generate_mock_embedding("test", seed=42)
        emb2 = generate_mock_embedding("different", seed=42)
        # Same seed should give same base randomness
        assert emb1 == emb2


class TestTruncateEmbedding:
    """Tests for truncate_embedding function."""
    
    def test_truncate_smaller(self):
        """Test truncating to smaller dimensions."""
        embedding = [0.1, 0.2, 0.3, 0.4, 0.5]
        result = truncate_embedding(embedding, 3)
        assert len(result) == 3
    
    def test_truncate_same(self):
        """Test with same dimensions."""
        embedding = [0.1, 0.2, 0.3]
        result = truncate_embedding(embedding, 3)
        assert result == embedding
    
    def test_truncate_larger(self):
        """Test with larger dimensions (no change)."""
        embedding = [0.1, 0.2, 0.3]
        result = truncate_embedding(embedding, 10)
        assert result == embedding
    
    def test_truncate_normalized(self):
        """Test that truncated embedding is normalized."""
        # Create a normalized embedding
        embedding = [0.6, 0.8, 0.0]  # magnitude = 1.0
        result = truncate_embedding(embedding, 2)
        
        # Check normalization
        magnitude = sum(x * x for x in result) ** 0.5
        assert magnitude == pytest.approx(1.0, abs=0.001)


# ========================================
# EmbeddingsHandler Tests
# ========================================

class TestEmbeddingsHandler:
    """Tests for EmbeddingsHandler."""
    
    @pytest.fixture
    def handler(self):
        """Create handler with mocked dependencies."""
        with patch("openai.embeddings.get_model_registry") as mock_registry, \
             patch("openai.embeddings.get_model_router") as mock_router:
            
            # Setup mock model
            mock_model = Mock()
            mock_model.id = "text-embedding-3-small"
            
            # Setup mock decision
            mock_decision = Mock()
            mock_decision.model = mock_model
            
            mock_router.return_value.route_embedding.return_value = mock_decision
            
            handler = EmbeddingsHandler()
            yield handler
    
    @pytest.mark.asyncio
    async def test_create_single_embedding(self, handler):
        """Test creating single embedding."""
        request = EmbeddingRequest(
            input="Hello world",
            model="text-embedding-3-small",
        )
        
        response = await handler.create_embeddings(request)
        
        assert response.object == "list"
        assert len(response.data) == 1
        assert response.data[0].index == 0
        assert len(response.data[0].embedding) == 1536
    
    @pytest.mark.asyncio
    async def test_create_batch_embeddings(self, handler):
        """Test creating batch embeddings."""
        request = EmbeddingRequest(
            input=["Text 1", "Text 2", "Text 3"],
            model="text-embedding-3-small",
        )
        
        response = await handler.create_embeddings(request)
        
        assert len(response.data) == 3
        assert response.data[0].index == 0
        assert response.data[1].index == 1
        assert response.data[2].index == 2
    
    @pytest.mark.asyncio
    async def test_create_with_custom_dimensions(self, handler):
        """Test creating with custom dimensions."""
        request = EmbeddingRequest(
            input="Test",
            model="text-embedding-3-small",
            dimensions=256,
        )
        
        response = await handler.create_embeddings(request)
        
        assert len(response.data[0].embedding) == 256
    
    @pytest.mark.asyncio
    async def test_create_with_base64_encoding(self, handler):
        """Test creating with base64 encoding."""
        request = EmbeddingRequest(
            input="Test",
            model="text-embedding-3-small",
            encoding_format=EncodingFormat.BASE64,
        )
        
        response = await handler.create_embeddings(request)
        
        # Should be a base64 string
        assert isinstance(response.data[0].embedding, str)
    
    @pytest.mark.asyncio
    async def test_invalid_request(self, handler):
        """Test handling invalid request."""
        request = EmbeddingRequest(
            input="",
            model="",
        )
        
        with pytest.raises(ValueError) as exc_info:
            await handler.create_embeddings(request)
        
        assert "Invalid request" in str(exc_info.value)
    
    @pytest.mark.asyncio
    async def test_model_not_found(self):
        """Test handling model not found."""
        with patch("openai.embeddings.get_model_registry"), \
             patch("openai.embeddings.get_model_router") as mock_router:
            
            mock_router.return_value.route_embedding.return_value = None
            
            handler = EmbeddingsHandler()
            request = EmbeddingRequest(
                input="Test",
                model="unknown-model",
            )
            
            with pytest.raises(ValueError) as exc_info:
                await handler.create_embeddings(request)
            
            assert "not found" in str(exc_info.value)
    
    def test_get_default_dimensions(self, handler):
        """Test getting default dimensions."""
        assert handler.get_default_dimensions("text-embedding-3-small") == 1536
        assert handler.get_default_dimensions("text-embedding-3-large") == 3072
        assert handler.get_default_dimensions("unknown") == 1536


# ========================================
# Global Handler Tests
# ========================================

class TestGetEmbeddingsHandler:
    """Tests for get_embeddings_handler function."""
    
    def test_returns_handler(self):
        """Test that it returns a handler."""
        with patch("openai.embeddings.get_model_registry"), \
             patch("openai.embeddings.get_model_router"):
            
            import openai.embeddings as module
            module._handler = None  # Reset singleton
            
            handler = get_embeddings_handler()
            assert isinstance(handler, EmbeddingsHandler)
    
    def test_singleton(self):
        """Test that it returns same instance."""
        with patch("openai.embeddings.get_model_registry"), \
             patch("openai.embeddings.get_model_router"):
            
            import openai.embeddings as module
            module._handler = None
            
            handler1 = get_embeddings_handler()
            handler2 = get_embeddings_handler()
            assert handler1 is handler2


# ========================================
# Integration Tests
# ========================================

class TestEmbeddingsIntegration:
    """Integration tests for embeddings."""
    
    @pytest.mark.asyncio
    async def test_full_flow(self):
        """Test complete embedding flow."""
        with patch("openai.embeddings.get_model_registry"), \
             patch("openai.embeddings.get_model_router") as mock_router:
            
            mock_model = Mock()
            mock_model.id = "text-embedding-ada-002"
            mock_decision = Mock()
            mock_decision.model = mock_model
            mock_router.return_value.route_embedding.return_value = mock_decision
            
            handler = EmbeddingsHandler()
            
            request = EmbeddingRequest.from_dict({
                "input": ["Document about SAP", "Financial report Q4"],
                "model": "text-embedding-ada-002",
            })
            
            response = await handler.create_embeddings(request)
            result = response.to_dict()
            
            assert result["object"] == "list"
            assert len(result["data"]) == 2
            assert result["model"] == "text-embedding-ada-002"
            assert "usage" in result


if __name__ == "__main__":
    pytest.main([__file__, "-v"])