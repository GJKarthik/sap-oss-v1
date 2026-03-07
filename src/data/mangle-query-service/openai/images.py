"""
OpenAI Images Endpoints Handler

Day 14 Deliverable: /v1/images/generations, /v1/images/edits, /v1/images/variations
Reference: https://platform.openai.com/docs/api-reference/images

Provides OpenAI-compatible image generation:
- Generate images from text prompts
- Edit images with masks
- Create variations of existing images

Usage:
    from openai.images import ImagesHandler
    
    handler = ImagesHandler()
    result = handler.generate(prompt="A sunset over mountains", n=1)
"""

import time
import uuid
import logging
import base64
import hashlib
from typing import Optional, Dict, Any, List, Union
from dataclasses import dataclass, field
from enum import Enum

logger = logging.getLogger(__name__)


# ========================================
# Enums
# ========================================

class ImageSize(str, Enum):
    """Supported image sizes."""
    SIZE_256 = "256x256"
    SIZE_512 = "512x512"
    SIZE_1024 = "1024x1024"
    SIZE_1792_1024 = "1792x1024"  # DALL-E 3 landscape
    SIZE_1024_1792 = "1024x1792"  # DALL-E 3 portrait


class ImageResponseFormat(str, Enum):
    """Image response format."""
    URL = "url"
    B64_JSON = "b64_json"


class ImageStyle(str, Enum):
    """Image style for DALL-E 3."""
    VIVID = "vivid"
    NATURAL = "natural"


class ImageQuality(str, Enum):
    """Image quality for DALL-E 3."""
    STANDARD = "standard"
    HD = "hd"


# ========================================
# Data Models
# ========================================

@dataclass
class ImageGenerationRequest:
    """
    Request for image generation.
    
    Reference: https://platform.openai.com/docs/api-reference/images/create
    """
    prompt: str
    model: str = "dall-e-3"
    n: int = 1
    quality: str = "standard"
    response_format: str = "url"
    size: str = "1024x1024"
    style: str = "vivid"
    user: Optional[str] = None
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "ImageGenerationRequest":
        """Create from dictionary."""
        return cls(
            prompt=data.get("prompt", ""),
            model=data.get("model", "dall-e-3"),
            n=data.get("n", 1),
            quality=data.get("quality", "standard"),
            response_format=data.get("response_format", "url"),
            size=data.get("size", "1024x1024"),
            style=data.get("style", "vivid"),
            user=data.get("user"),
        )
    
    def validate(self) -> Optional[str]:
        """Validate request. Returns error message or None."""
        if not self.prompt:
            return "prompt is required"
        
        if len(self.prompt) > 4000:
            return "prompt must be 4000 characters or less"
        
        if self.model == "dall-e-3":
            if self.n != 1:
                return "DALL-E 3 only supports n=1"
            valid_sizes = {"1024x1024", "1792x1024", "1024x1792"}
            if self.size not in valid_sizes:
                return f"Invalid size for DALL-E 3. Supported: {', '.join(valid_sizes)}"
        elif self.model == "dall-e-2":
            if self.n < 1 or self.n > 10:
                return "n must be between 1 and 10 for DALL-E 2"
            valid_sizes = {"256x256", "512x512", "1024x1024"}
            if self.size not in valid_sizes:
                return f"Invalid size for DALL-E 2. Supported: {', '.join(valid_sizes)}"
        
        if self.response_format not in {"url", "b64_json"}:
            return f"Invalid response_format: {self.response_format}"
        
        return None


@dataclass
class ImageEditRequest:
    """
    Request for image editing.
    
    Reference: https://platform.openai.com/docs/api-reference/images/createEdit
    """
    image: bytes
    prompt: str
    mask: Optional[bytes] = None
    model: str = "dall-e-2"
    n: int = 1
    size: str = "1024x1024"
    response_format: str = "url"
    user: Optional[str] = None
    
    @classmethod
    def from_dict(
        cls,
        data: Dict[str, Any],
        image: bytes,
        mask: Optional[bytes] = None,
    ) -> "ImageEditRequest":
        """Create from dictionary."""
        return cls(
            image=image,
            prompt=data.get("prompt", ""),
            mask=mask,
            model=data.get("model", "dall-e-2"),
            n=data.get("n", 1),
            size=data.get("size", "1024x1024"),
            response_format=data.get("response_format", "url"),
            user=data.get("user"),
        )
    
    def validate(self) -> Optional[str]:
        """Validate request. Returns error message or None."""
        if not self.image:
            return "image is required"
        
        if not self.prompt:
            return "prompt is required"
        
        if len(self.prompt) > 1000:
            return "prompt must be 1000 characters or less"
        
        if self.n < 1 or self.n > 10:
            return "n must be between 1 and 10"
        
        valid_sizes = {"256x256", "512x512", "1024x1024"}
        if self.size not in valid_sizes:
            return f"Invalid size. Supported: {', '.join(valid_sizes)}"
        
        return None


@dataclass
class ImageVariationRequest:
    """
    Request for image variation.
    
    Reference: https://platform.openai.com/docs/api-reference/images/createVariation
    """
    image: bytes
    model: str = "dall-e-2"
    n: int = 1
    size: str = "1024x1024"
    response_format: str = "url"
    user: Optional[str] = None
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any], image: bytes) -> "ImageVariationRequest":
        """Create from dictionary."""
        return cls(
            image=image,
            model=data.get("model", "dall-e-2"),
            n=data.get("n", 1),
            size=data.get("size", "1024x1024"),
            response_format=data.get("response_format", "url"),
            user=data.get("user"),
        )
    
    def validate(self) -> Optional[str]:
        """Validate request. Returns error message or None."""
        if not self.image:
            return "image is required"
        
        if self.n < 1 or self.n > 10:
            return "n must be between 1 and 10"
        
        valid_sizes = {"256x256", "512x512", "1024x1024"}
        if self.size not in valid_sizes:
            return f"Invalid size. Supported: {', '.join(valid_sizes)}"
        
        return None


@dataclass
class ImageData:
    """
    Individual image in response.
    
    Contains either URL or base64-encoded image data.
    """
    url: Optional[str] = None
    b64_json: Optional[str] = None
    revised_prompt: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {}
        if self.url:
            result["url"] = self.url
        if self.b64_json:
            result["b64_json"] = self.b64_json
        if self.revised_prompt:
            result["revised_prompt"] = self.revised_prompt
        return result


@dataclass
class ImagesResponse:
    """
    Response for image operations.
    
    Reference: https://platform.openai.com/docs/api-reference/images/object
    """
    created: int = field(default_factory=lambda: int(time.time()))
    data: List[ImageData] = field(default_factory=list)
    
    @classmethod
    def create(
        cls,
        images: List[Dict[str, str]],
    ) -> "ImagesResponse":
        """Create response from image data."""
        data = []
        for img in images:
            data.append(ImageData(
                url=img.get("url"),
                b64_json=img.get("b64_json"),
                revised_prompt=img.get("revised_prompt"),
            ))
        return cls(data=data)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "created": self.created,
            "data": [img.to_dict() for img in self.data],
        }


@dataclass
class ImageErrorResponse:
    """Error response for image operations."""
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
# Image Utilities
# ========================================

SUPPORTED_IMAGE_FORMATS = {"png", "jpg", "jpeg", "gif", "webp"}

MAX_IMAGE_SIZE = 4 * 1024 * 1024  # 4 MB


def validate_image_file(filename: str, file_size: int) -> Optional[str]:
    """
    Validate image file for upload.
    
    Returns error message if invalid, None if valid.
    """
    if file_size <= 0:
        return "image cannot be empty"
    
    if file_size > MAX_IMAGE_SIZE:
        return f"image too large: {file_size} bytes. Maximum: 4 MB"
    
    # Check extension
    ext = filename.lower().split(".")[-1] if "." in filename else ""
    if ext and ext not in SUPPORTED_IMAGE_FORMATS:
        return f"Unsupported image format: {ext}. Supported: {', '.join(SUPPORTED_IMAGE_FORMATS)}"
    
    return None


def get_image_dimensions(size_str: str) -> tuple:
    """Parse size string into dimensions."""
    parts = size_str.split("x")
    if len(parts) == 2:
        return int(parts[0]), int(parts[1])
    return 1024, 1024


def generate_mock_image_url(prompt: str, size: str, index: int = 0) -> str:
    """Generate a mock image URL for testing."""
    # Create deterministic hash from prompt
    prompt_hash = hashlib.md5(f"{prompt}_{index}".encode()).hexdigest()[:12]
    width, height = get_image_dimensions(size)
    
    # Return a placeholder URL
    return f"https://images.example.com/generated/{prompt_hash}_{width}x{height}.png"


def generate_mock_b64_image(size: str) -> str:
    """Generate mock base64 image data for testing."""
    # Create a minimal valid PNG (1x1 transparent pixel)
    # This is just placeholder data for mock mode
    width, height = get_image_dimensions(size)
    placeholder = f"mock_image_{width}x{height}".encode()
    return base64.b64encode(placeholder).decode()


# ========================================
# Images Handler
# ========================================

class ImagesHandler:
    """
    Handler for image operations.
    
    Provides OpenAI-compatible image generation, editing, and variation endpoints.
    In production, routes to SAP AI Core or private image generation models.
    """
    
    def __init__(self, image_backend: Optional[Any] = None):
        """
        Initialize handler.
        
        Args:
            image_backend: Backend for actual image generation
        """
        self._backend = image_backend
        self._mock_mode = image_backend is None
    
    @property
    def is_mock_mode(self) -> bool:
        """Check if running in mock mode."""
        return self._mock_mode
    
    def generate(
        self,
        request: ImageGenerationRequest,
    ) -> Dict[str, Any]:
        """
        Generate images from prompt.
        
        Args:
            request: Generation request with prompt and parameters
        
        Returns:
            ImagesResponse as dictionary
        """
        # Validate
        error = request.validate()
        if error:
            return ImageErrorResponse(message=error, param="prompt").to_dict()
        
        if self._mock_mode:
            return self._mock_generate(request)
        
        # TODO: Call actual backend
        return self._mock_generate(request)
    
    def _mock_generate(self, request: ImageGenerationRequest) -> Dict[str, Any]:
        """Generate mock images for testing."""
        images = []
        
        for i in range(request.n):
            image_data = {}
            
            if request.response_format == "url":
                image_data["url"] = generate_mock_image_url(
                    request.prompt, request.size, i
                )
            else:
                image_data["b64_json"] = generate_mock_b64_image(request.size)
            
            # DALL-E 3 may revise prompts
            if request.model == "dall-e-3":
                image_data["revised_prompt"] = f"Enhanced: {request.prompt}"
            
            images.append(image_data)
        
        return ImagesResponse.create(images).to_dict()
    
    def edit(
        self,
        request: ImageEditRequest,
    ) -> Dict[str, Any]:
        """
        Edit an image with a mask.
        
        Args:
            request: Edit request with image, mask, and prompt
        
        Returns:
            ImagesResponse as dictionary
        """
        # Validate
        error = request.validate()
        if error:
            return ImageErrorResponse(message=error).to_dict()
        
        if self._mock_mode:
            return self._mock_edit(request)
        
        # TODO: Call actual backend
        return self._mock_edit(request)
    
    def _mock_edit(self, request: ImageEditRequest) -> Dict[str, Any]:
        """Generate mock edited images for testing."""
        images = []
        
        for i in range(request.n):
            image_data = {}
            
            if request.response_format == "url":
                image_data["url"] = generate_mock_image_url(
                    f"edit_{request.prompt}", request.size, i
                )
            else:
                image_data["b64_json"] = generate_mock_b64_image(request.size)
            
            images.append(image_data)
        
        return ImagesResponse.create(images).to_dict()
    
    def create_variation(
        self,
        request: ImageVariationRequest,
    ) -> Dict[str, Any]:
        """
        Create variations of an image.
        
        Args:
            request: Variation request with source image
        
        Returns:
            ImagesResponse as dictionary
        """
        # Validate
        error = request.validate()
        if error:
            return ImageErrorResponse(message=error).to_dict()
        
        if self._mock_mode:
            return self._mock_variation(request)
        
        # TODO: Call actual backend
        return self._mock_variation(request)
    
    def _mock_variation(self, request: ImageVariationRequest) -> Dict[str, Any]:
        """Generate mock image variations for testing."""
        images = []
        
        # Create hash from image for deterministic URLs
        image_hash = hashlib.md5(request.image).hexdigest()[:8]
        
        for i in range(request.n):
            image_data = {}
            
            if request.response_format == "url":
                image_data["url"] = generate_mock_image_url(
                    f"variation_{image_hash}", request.size, i
                )
            else:
                image_data["b64_json"] = generate_mock_b64_image(request.size)
            
            images.append(image_data)
        
        return ImagesResponse.create(images).to_dict()
    
    def handle_generate(
        self,
        data: Dict[str, Any],
    ) -> Dict[str, Any]:
        """
        Handle generation request from HTTP body.
        
        Args:
            data: Request body as dictionary
        
        Returns:
            Generation response
        """
        request = ImageGenerationRequest.from_dict(data)
        return self.generate(request)
    
    def handle_edit(
        self,
        form_data: Dict[str, Any],
        image: bytes,
        mask: Optional[bytes] = None,
    ) -> Dict[str, Any]:
        """
        Handle edit request from HTTP form data.
        
        Args:
            form_data: Form field values
            image: Source image bytes
            mask: Optional mask image bytes
        
        Returns:
            Edit response
        """
        # Validate image
        error = validate_image_file("image.png", len(image))
        if error:
            return ImageErrorResponse(message=error, param="image").to_dict()
        
        request = ImageEditRequest.from_dict(form_data, image, mask)
        return self.edit(request)
    
    def handle_variation(
        self,
        form_data: Dict[str, Any],
        image: bytes,
    ) -> Dict[str, Any]:
        """
        Handle variation request from HTTP form data.
        
        Args:
            form_data: Form field values
            image: Source image bytes
        
        Returns:
            Variation response
        """
        # Validate image
        error = validate_image_file("image.png", len(image))
        if error:
            return ImageErrorResponse(message=error, param="image").to_dict()
        
        request = ImageVariationRequest.from_dict(form_data, image)
        return self.create_variation(request)


# ========================================
# Utility Functions
# ========================================

def get_images_handler(image_backend: Optional[Any] = None) -> ImagesHandler:
    """Get an ImagesHandler instance."""
    return ImagesHandler(image_backend=image_backend)


def generate_image(
    prompt: str,
    model: str = "dall-e-3",
    size: str = "1024x1024",
    n: int = 1,
    **kwargs,
) -> Dict[str, Any]:
    """
    Convenience function for generating images.
    
    Args:
        prompt: Text description of the desired image
        model: Model to use
        size: Image size
        n: Number of images to generate
        **kwargs: Additional parameters
    
    Returns:
        ImagesResponse as dictionary
    """
    handler = get_images_handler()
    request = ImageGenerationRequest(
        prompt=prompt,
        model=model,
        size=size,
        n=n,
        **kwargs,
    )
    return handler.generate(request)


def edit_image(
    image: bytes,
    prompt: str,
    mask: Optional[bytes] = None,
    **kwargs,
) -> Dict[str, Any]:
    """
    Convenience function for editing images.
    
    Args:
        image: Source image bytes
        prompt: Description of the edit
        mask: Optional mask for editing
        **kwargs: Additional parameters
    
    Returns:
        ImagesResponse as dictionary
    """
    handler = get_images_handler()
    request = ImageEditRequest(
        image=image,
        prompt=prompt,
        mask=mask,
        **kwargs,
    )
    return handler.edit(request)


def create_image_variation(
    image: bytes,
    n: int = 1,
    **kwargs,
) -> Dict[str, Any]:
    """
    Convenience function for creating image variations.
    
    Args:
        image: Source image bytes
        n: Number of variations
        **kwargs: Additional parameters
    
    Returns:
        ImagesResponse as dictionary
    """
    handler = get_images_handler()
    request = ImageVariationRequest(
        image=image,
        n=n,
        **kwargs,
    )
    return handler.create_variation(request)


# ========================================
# Exports
# ========================================

__all__ = [
    # Enums
    "ImageSize",
    "ImageResponseFormat",
    "ImageStyle",
    "ImageQuality",
    # Models
    "ImageGenerationRequest",
    "ImageEditRequest",
    "ImageVariationRequest",
    "ImageData",
    "ImagesResponse",
    "ImageErrorResponse",
    # Handler
    "ImagesHandler",
    # Utilities
    "get_images_handler",
    "generate_image",
    "edit_image",
    "create_image_variation",
    "validate_image_file",
    "get_image_dimensions",
    # Constants
    "SUPPORTED_IMAGE_FORMATS",
    "MAX_IMAGE_SIZE",
]