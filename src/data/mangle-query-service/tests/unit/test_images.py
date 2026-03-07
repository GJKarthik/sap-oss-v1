"""
Unit Tests for Images Endpoints

Day 14 Tests: Comprehensive tests for /v1/images endpoints
Target: 52+ tests for full coverage

Test Categories:
1. ImageSize, ImageResponseFormat, ImageStyle, ImageQuality enums
2. ImageGenerationRequest creation and validation
3. ImageEditRequest creation and validation  
4. ImageVariationRequest creation and validation
5. ImageData and ImagesResponse
6. ImageErrorResponse
7. Image file validation
8. Image utilities
9. ImagesHandler operations
10. OpenAI API compliance
"""

import pytest
import base64
from unittest.mock import Mock

from openai.images import (
    ImageSize,
    ImageResponseFormat,
    ImageStyle,
    ImageQuality,
    ImageGenerationRequest,
    ImageEditRequest,
    ImageVariationRequest,
    ImageData,
    ImagesResponse,
    ImageErrorResponse,
    ImagesHandler,
    get_images_handler,
    generate_image,
    edit_image,
    create_image_variation,
    validate_image_file,
    get_image_dimensions,
    SUPPORTED_IMAGE_FORMATS,
    MAX_IMAGE_SIZE,
)


# ========================================
# Fixtures
# ========================================

@pytest.fixture
def sample_image_data():
    """Create sample image file data."""
    return b"\x89PNG\r\n\x1a\n" + b"\x00" * 1000


@pytest.fixture
def basic_generation_request():
    """Create a basic generation request."""
    return ImageGenerationRequest(prompt="A sunset over mountains")


@pytest.fixture
def dalle3_request():
    """Create a DALL-E 3 request."""
    return ImageGenerationRequest(
        prompt="A futuristic city",
        model="dall-e-3",
        size="1024x1024",
        quality="hd",
        style="vivid",
    )


@pytest.fixture
def handler():
    """Create an images handler in mock mode."""
    return ImagesHandler()


# ========================================
# Test ImageSize Enum
# ========================================

class TestImageSize:
    """Tests for ImageSize enum."""
    
    def test_256(self):
        """Test 256x256 size."""
        assert ImageSize.SIZE_256.value == "256x256"
    
    def test_512(self):
        """Test 512x512 size."""
        assert ImageSize.SIZE_512.value == "512x512"
    
    def test_1024(self):
        """Test 1024x1024 size."""
        assert ImageSize.SIZE_1024.value == "1024x1024"
    
    def test_landscape(self):
        """Test landscape size."""
        assert ImageSize.SIZE_1792_1024.value == "1792x1024"
    
    def test_portrait(self):
        """Test portrait size."""
        assert ImageSize.SIZE_1024_1792.value == "1024x1792"


# ========================================
# Test ImageResponseFormat Enum
# ========================================

class TestImageResponseFormat:
    """Tests for ImageResponseFormat enum."""
    
    def test_url(self):
        """Test URL format."""
        assert ImageResponseFormat.URL.value == "url"
    
    def test_b64_json(self):
        """Test base64 JSON format."""
        assert ImageResponseFormat.B64_JSON.value == "b64_json"


# ========================================
# Test ImageStyle Enum
# ========================================

class TestImageStyle:
    """Tests for ImageStyle enum."""
    
    def test_vivid(self):
        """Test vivid style."""
        assert ImageStyle.VIVID.value == "vivid"
    
    def test_natural(self):
        """Test natural style."""
        assert ImageStyle.NATURAL.value == "natural"


# ========================================
# Test ImageQuality Enum
# ========================================

class TestImageQuality:
    """Tests for ImageQuality enum."""
    
    def test_standard(self):
        """Test standard quality."""
        assert ImageQuality.STANDARD.value == "standard"
    
    def test_hd(self):
        """Test HD quality."""
        assert ImageQuality.HD.value == "hd"


# ========================================
# Test ImageGenerationRequest
# ========================================

class TestImageGenerationRequest:
    """Tests for ImageGenerationRequest dataclass."""
    
    def test_create_basic(self, basic_generation_request):
        """Test basic request creation."""
        assert basic_generation_request.prompt == "A sunset over mountains"
        assert basic_generation_request.model == "dall-e-3"
        assert basic_generation_request.n == 1
    
    def test_defaults(self, basic_generation_request):
        """Test default values."""
        assert basic_generation_request.quality == "standard"
        assert basic_generation_request.response_format == "url"
        assert basic_generation_request.size == "1024x1024"
        assert basic_generation_request.style == "vivid"
    
    def test_from_dict_minimal(self):
        """Test creation from minimal dict."""
        data = {"prompt": "Test prompt"}
        request = ImageGenerationRequest.from_dict(data)
        
        assert request.prompt == "Test prompt"
        assert request.model == "dall-e-3"
    
    def test_from_dict_full(self):
        """Test creation from full dict."""
        data = {
            "prompt": "Test prompt",
            "model": "dall-e-2",
            "n": 3,
            "size": "512x512",
            "response_format": "b64_json",
        }
        request = ImageGenerationRequest.from_dict(data)
        
        assert request.model == "dall-e-2"
        assert request.n == 3
        assert request.size == "512x512"
    
    def test_validate_valid(self, basic_generation_request):
        """Test valid request passes validation."""
        assert basic_generation_request.validate() is None
    
    def test_validate_missing_prompt(self):
        """Test validation fails without prompt."""
        request = ImageGenerationRequest(prompt="")
        assert "prompt is required" in request.validate()
    
    def test_validate_prompt_too_long(self):
        """Test prompt length validation."""
        request = ImageGenerationRequest(prompt="x" * 5000)
        assert "4000 characters" in request.validate()
    
    def test_validate_dalle3_n(self):
        """Test DALL-E 3 only supports n=1."""
        request = ImageGenerationRequest(
            prompt="Test",
            model="dall-e-3",
            n=2,
        )
        assert "only supports n=1" in request.validate()
    
    def test_validate_dalle3_size(self):
        """Test DALL-E 3 size validation."""
        request = ImageGenerationRequest(
            prompt="Test",
            model="dall-e-3",
            size="256x256",
        )
        assert "Invalid size" in request.validate()
    
    def test_validate_dalle2_n_range(self):
        """Test DALL-E 2 n range validation."""
        request = ImageGenerationRequest(
            prompt="Test",
            model="dall-e-2",
            n=15,
        )
        assert "between 1 and 10" in request.validate()
    
    def test_validate_invalid_response_format(self):
        """Test invalid response format."""
        request = ImageGenerationRequest(
            prompt="Test",
            response_format="invalid",
        )
        assert "Invalid response_format" in request.validate()


# ========================================
# Test ImageEditRequest
# ========================================

class TestImageEditRequest:
    """Tests for ImageEditRequest dataclass."""
    
    def test_create_basic(self, sample_image_data):
        """Test basic request creation."""
        request = ImageEditRequest(
            image=sample_image_data,
            prompt="Add a rainbow",
        )
        assert request.prompt == "Add a rainbow"
        assert request.image == sample_image_data
    
    def test_from_dict(self, sample_image_data):
        """Test creation from dict."""
        data = {
            "prompt": "Edit prompt",
            "n": 2,
            "size": "512x512",
        }
        request = ImageEditRequest.from_dict(data, sample_image_data)
        
        assert request.prompt == "Edit prompt"
        assert request.n == 2
    
    def test_validate_valid(self, sample_image_data):
        """Test valid request passes."""
        request = ImageEditRequest(
            image=sample_image_data,
            prompt="Edit",
        )
        assert request.validate() is None
    
    def test_validate_missing_image(self):
        """Test validation fails without image."""
        request = ImageEditRequest(image=b"", prompt="Edit")
        assert "image is required" in request.validate()
    
    def test_validate_missing_prompt(self, sample_image_data):
        """Test validation fails without prompt."""
        request = ImageEditRequest(image=sample_image_data, prompt="")
        assert "prompt is required" in request.validate()
    
    def test_validate_prompt_too_long(self, sample_image_data):
        """Test prompt length validation."""
        request = ImageEditRequest(
            image=sample_image_data,
            prompt="x" * 1500,
        )
        assert "1000 characters" in request.validate()
    
    def test_validate_n_range(self, sample_image_data):
        """Test n range validation."""
        request = ImageEditRequest(
            image=sample_image_data,
            prompt="Edit",
            n=15,
        )
        assert "between 1 and 10" in request.validate()


# ========================================
# Test ImageVariationRequest
# ========================================

class TestImageVariationRequest:
    """Tests for ImageVariationRequest dataclass."""
    
    def test_create_basic(self, sample_image_data):
        """Test basic request creation."""
        request = ImageVariationRequest(image=sample_image_data)
        assert request.image == sample_image_data
        assert request.n == 1
    
    def test_from_dict(self, sample_image_data):
        """Test creation from dict."""
        data = {"n": 3, "size": "512x512"}
        request = ImageVariationRequest.from_dict(data, sample_image_data)
        
        assert request.n == 3
        assert request.size == "512x512"
    
    def test_validate_valid(self, sample_image_data):
        """Test valid request passes."""
        request = ImageVariationRequest(image=sample_image_data)
        assert request.validate() is None
    
    def test_validate_missing_image(self):
        """Test validation fails without image."""
        request = ImageVariationRequest(image=b"")
        assert "image is required" in request.validate()
    
    def test_validate_n_range(self, sample_image_data):
        """Test n range validation."""
        request = ImageVariationRequest(
            image=sample_image_data,
            n=15,
        )
        assert "between 1 and 10" in request.validate()


# ========================================
# Test ImageData
# ========================================

class TestImageData:
    """Tests for ImageData dataclass."""
    
    def test_create_with_url(self):
        """Test creation with URL."""
        data = ImageData(url="https://example.com/image.png")
        assert data.url == "https://example.com/image.png"
    
    def test_create_with_b64(self):
        """Test creation with base64."""
        data = ImageData(b64_json="YWJjMTIz")
        assert data.b64_json == "YWJjMTIz"
    
    def test_to_dict_url(self):
        """Test dict conversion with URL."""
        data = ImageData(url="https://example.com/image.png")
        result = data.to_dict()
        
        assert result["url"] == "https://example.com/image.png"
        assert "b64_json" not in result
    
    def test_to_dict_with_revised_prompt(self):
        """Test dict with revised prompt."""
        data = ImageData(
            url="https://example.com/image.png",
            revised_prompt="Enhanced prompt",
        )
        result = data.to_dict()
        
        assert result["revised_prompt"] == "Enhanced prompt"


# ========================================
# Test ImagesResponse
# ========================================

class TestImagesResponse:
    """Tests for ImagesResponse dataclass."""
    
    def test_create_empty(self):
        """Test empty response."""
        response = ImagesResponse()
        assert response.data == []
        assert response.created > 0
    
    def test_create_factory(self):
        """Test factory method."""
        images = [
            {"url": "https://example.com/1.png"},
            {"url": "https://example.com/2.png"},
        ]
        response = ImagesResponse.create(images)
        
        assert len(response.data) == 2
        assert response.data[0].url == "https://example.com/1.png"
    
    def test_to_dict(self):
        """Test dict conversion."""
        images = [{"url": "https://example.com/test.png"}]
        response = ImagesResponse.create(images)
        result = response.to_dict()
        
        assert "created" in result
        assert "data" in result
        assert len(result["data"]) == 1


# ========================================
# Test ImageErrorResponse
# ========================================

class TestImageErrorResponse:
    """Tests for ImageErrorResponse dataclass."""
    
    def test_basic_error(self):
        """Test basic error."""
        error = ImageErrorResponse(message="Test error")
        result = error.to_dict()
        
        assert result["error"]["message"] == "Test error"
        assert result["error"]["type"] == "invalid_request_error"
    
    def test_full_error(self):
        """Test error with all fields."""
        error = ImageErrorResponse(
            message="Invalid prompt",
            type="validation_error",
            param="prompt",
            code="invalid_prompt",
        )
        result = error.to_dict()
        
        assert result["error"]["param"] == "prompt"
        assert result["error"]["code"] == "invalid_prompt"


# ========================================
# Test Image File Validation
# ========================================

class TestImageValidation:
    """Tests for image file validation."""
    
    def test_valid_image(self):
        """Test valid image."""
        error = validate_image_file("test.png", 1024)
        assert error is None
    
    def test_empty_image(self):
        """Test empty image."""
        error = validate_image_file("test.png", 0)
        assert "cannot be empty" in error
    
    def test_image_too_large(self):
        """Test image too large."""
        error = validate_image_file("test.png", 5 * 1024 * 1024)
        assert "too large" in error
    
    def test_unsupported_format(self):
        """Test unsupported format."""
        error = validate_image_file("test.bmp", 1024)
        assert "Unsupported" in error
    
    def test_supported_formats(self):
        """Test all supported formats pass."""
        for fmt in ["png", "jpg", "jpeg", "gif", "webp"]:
            error = validate_image_file(f"test.{fmt}", 1024)
            assert error is None


# ========================================
# Test Image Utilities
# ========================================

class TestImageUtilities:
    """Tests for image utility functions."""
    
    def test_get_dimensions_1024(self):
        """Test parsing 1024x1024."""
        w, h = get_image_dimensions("1024x1024")
        assert w == 1024
        assert h == 1024
    
    def test_get_dimensions_landscape(self):
        """Test parsing landscape size."""
        w, h = get_image_dimensions("1792x1024")
        assert w == 1792
        assert h == 1024
    
    def test_get_dimensions_portrait(self):
        """Test parsing portrait size."""
        w, h = get_image_dimensions("1024x1792")
        assert w == 1024
        assert h == 1792
    
    def test_get_dimensions_invalid(self):
        """Test invalid size returns default."""
        w, h = get_image_dimensions("invalid")
        assert w == 1024
        assert h == 1024


# ========================================
# Test ImagesHandler Generation
# ========================================

class TestImagesHandlerGenerate:
    """Tests for ImagesHandler generate operations."""
    
    def test_mock_mode(self, handler):
        """Test handler is in mock mode."""
        assert handler.is_mock_mode is True
    
    def test_generate_basic(self, handler, basic_generation_request):
        """Test basic generation."""
        result = handler.generate(basic_generation_request)
        
        assert "created" in result
        assert "data" in result
        assert len(result["data"]) == 1
    
    def test_generate_url_format(self, handler):
        """Test generation with URL format."""
        request = ImageGenerationRequest(
            prompt="Test",
            response_format="url",
        )
        result = handler.generate(request)
        
        assert "url" in result["data"][0]
    
    def test_generate_b64_format(self, handler):
        """Test generation with base64 format."""
        request = ImageGenerationRequest(
            prompt="Test",
            response_format="b64_json",
        )
        result = handler.generate(request)
        
        assert "b64_json" in result["data"][0]
    
    def test_generate_dalle3_revised_prompt(self, handler, dalle3_request):
        """Test DALL-E 3 includes revised prompt."""
        result = handler.generate(dalle3_request)
        
        assert "revised_prompt" in result["data"][0]
    
    def test_generate_validation_error(self, handler):
        """Test generation validation error."""
        request = ImageGenerationRequest(prompt="")
        result = handler.generate(request)
        
        assert "error" in result
    
    def test_generate_multiple_dalle2(self, handler):
        """Test generating multiple images with DALL-E 2."""
        request = ImageGenerationRequest(
            prompt="Test",
            model="dall-e-2",
            n=3,
        )
        result = handler.generate(request)
        
        assert len(result["data"]) == 3


# ========================================
# Test ImagesHandler Edit
# ========================================

class TestImagesHandlerEdit:
    """Tests for ImagesHandler edit operations."""
    
    def test_edit_basic(self, handler, sample_image_data):
        """Test basic edit."""
        request = ImageEditRequest(
            image=sample_image_data,
            prompt="Add clouds",
        )
        result = handler.edit(request)
        
        assert "data" in result
        assert len(result["data"]) == 1
    
    def test_edit_validation_error(self, handler):
        """Test edit validation error."""
        request = ImageEditRequest(image=b"", prompt="Edit")
        result = handler.edit(request)
        
        assert "error" in result
    
    def test_edit_multiple(self, handler, sample_image_data):
        """Test editing with multiple outputs."""
        request = ImageEditRequest(
            image=sample_image_data,
            prompt="Add clouds",
            n=3,
        )
        result = handler.edit(request)
        
        assert len(result["data"]) == 3


# ========================================
# Test ImagesHandler Variation
# ========================================

class TestImagesHandlerVariation:
    """Tests for ImagesHandler variation operations."""
    
    def test_variation_basic(self, handler, sample_image_data):
        """Test basic variation."""
        request = ImageVariationRequest(image=sample_image_data)
        result = handler.create_variation(request)
        
        assert "data" in result
        assert len(result["data"]) == 1
    
    def test_variation_validation_error(self, handler):
        """Test variation validation error."""
        request = ImageVariationRequest(image=b"")
        result = handler.create_variation(request)
        
        assert "error" in result
    
    def test_variation_multiple(self, handler, sample_image_data):
        """Test creating multiple variations."""
        request = ImageVariationRequest(
            image=sample_image_data,
            n=4,
        )
        result = handler.create_variation(request)
        
        assert len(result["data"]) == 4


# ========================================
# Test Handler HTTP Methods
# ========================================

class TestHandlerHTTPMethods:
    """Tests for HTTP handler methods."""
    
    def test_handle_generate(self, handler):
        """Test handle_generate."""
        data = {"prompt": "A beautiful landscape"}
        result = handler.handle_generate(data)
        
        assert "data" in result
    
    def test_handle_edit(self, handler, sample_image_data):
        """Test handle_edit."""
        form_data = {"prompt": "Add sunset"}
        result = handler.handle_edit(form_data, sample_image_data)
        
        assert "data" in result
    
    def test_handle_variation(self, handler, sample_image_data):
        """Test handle_variation."""
        form_data = {"n": 2}
        result = handler.handle_variation(form_data, sample_image_data)
        
        assert "data" in result


# ========================================
# Test Utility Functions
# ========================================

class TestUtilityFunctions:
    """Tests for module-level utility functions."""
    
    def test_get_images_handler(self):
        """Test handler factory."""
        handler = get_images_handler()
        assert isinstance(handler, ImagesHandler)
    
    def test_generate_image_function(self):
        """Test convenience generate function."""
        result = generate_image("A sunset")
        assert "data" in result
    
    def test_edit_image_function(self, sample_image_data):
        """Test convenience edit function."""
        result = edit_image(sample_image_data, "Add clouds")
        assert "data" in result
    
    def test_create_variation_function(self, sample_image_data):
        """Test convenience variation function."""
        result = create_image_variation(sample_image_data)
        assert "data" in result


# ========================================
# Test OpenAI API Compliance
# ========================================

class TestOpenAICompliance:
    """Tests for OpenAI API compliance."""
    
    def test_response_format(self, handler, basic_generation_request):
        """Test response matches OpenAI format."""
        result = handler.generate(basic_generation_request)
        
        assert "created" in result
        assert isinstance(result["created"], int)
        assert "data" in result
        assert isinstance(result["data"], list)
    
    def test_image_object_format(self, handler, basic_generation_request):
        """Test image object format."""
        result = handler.generate(basic_generation_request)
        
        assert len(result["data"]) > 0
        image = result["data"][0]
        assert "url" in image or "b64_json" in image
    
    def test_dalle3_revised_prompt(self, handler, dalle3_request):
        """Test DALL-E 3 revised prompt in response."""
        result = handler.generate(dalle3_request)
        
        assert "revised_prompt" in result["data"][0]


if __name__ == "__main__":
    pytest.main([__file__, "-v"])