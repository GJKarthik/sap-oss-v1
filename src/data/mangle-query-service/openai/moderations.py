"""
OpenAI-compatible Moderations Endpoint Handler

Day 16 Deliverable: Content moderation for text safety checking

POST /v1/moderations - Classify text for potential harmful content
"""

import time
import hashlib
from enum import Enum
from typing import Dict, Any, Optional, List, Union
from dataclasses import dataclass, field


# ========================================
# Enums and Constants
# ========================================

class ModerationModel(str, Enum):
    """Supported moderation models."""
    TEXT_MODERATION_LATEST = "text-moderation-latest"
    TEXT_MODERATION_STABLE = "text-moderation-stable"
    TEXT_MODERATION_007 = "text-moderation-007"
    OMNI_MODERATION_LATEST = "omni-moderation-latest"
    OMNI_MODERATION_2024_09_26 = "omni-moderation-2024-09-26"
    
    @classmethod
    def get_default(cls) -> "ModerationModel":
        """Get default model."""
        return cls.TEXT_MODERATION_LATEST
    
    @classmethod
    def is_valid(cls, model: str) -> bool:
        """Check if model name is valid."""
        return model in [m.value for m in cls]
    
    @classmethod
    def is_omni(cls, model: str) -> bool:
        """Check if model is omni (multimodal) model."""
        return "omni" in model.lower()


class ModerationCategory(str, Enum):
    """Content moderation categories."""
    HATE = "hate"
    HATE_THREATENING = "hate/threatening"
    HARASSMENT = "harassment"
    HARASSMENT_THREATENING = "harassment/threatening"
    SELF_HARM = "self-harm"
    SELF_HARM_INTENT = "self-harm/intent"
    SELF_HARM_INSTRUCTIONS = "self-harm/instructions"
    SEXUAL = "sexual"
    SEXUAL_MINORS = "sexual/minors"
    VIOLENCE = "violence"
    VIOLENCE_GRAPHIC = "violence/graphic"
    # Omni-specific categories
    ILLICIT = "illicit"
    ILLICIT_VIOLENT = "illicit/violent"


# Category list for text models
TEXT_MODERATION_CATEGORIES = [
    ModerationCategory.HATE,
    ModerationCategory.HATE_THREATENING,
    ModerationCategory.HARASSMENT,
    ModerationCategory.HARASSMENT_THREATENING,
    ModerationCategory.SELF_HARM,
    ModerationCategory.SELF_HARM_INTENT,
    ModerationCategory.SELF_HARM_INSTRUCTIONS,
    ModerationCategory.SEXUAL,
    ModerationCategory.SEXUAL_MINORS,
    ModerationCategory.VIOLENCE,
    ModerationCategory.VIOLENCE_GRAPHIC,
]

# Additional categories for omni models
OMNI_MODERATION_CATEGORIES = TEXT_MODERATION_CATEGORIES + [
    ModerationCategory.ILLICIT,
    ModerationCategory.ILLICIT_VIOLENT,
]

# Threshold for flagging content
DEFAULT_THRESHOLD = 0.5


# ========================================
# Request/Response Models
# ========================================

@dataclass
class ModerationRequest:
    """Request model for moderation endpoint."""
    input: Union[str, List[str]]
    model: str = ModerationModel.TEXT_MODERATION_LATEST.value
    
    def __post_init__(self):
        """Validate request."""
        # Normalize input to list
        if isinstance(self.input, str):
            self._input_list = [self.input]
        else:
            self._input_list = list(self.input)
        
        # Validate model
        if not ModerationModel.is_valid(self.model):
            # Allow model aliases
            if self.model in ["text-moderation", "omni-moderation"]:
                self.model = f"{self.model}-latest"
    
    @property
    def input_list(self) -> List[str]:
        """Get input as list."""
        return self._input_list
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "ModerationRequest":
        """Create from dictionary."""
        return cls(
            input=data.get("input", ""),
            model=data.get("model", ModerationModel.TEXT_MODERATION_LATEST.value),
        )
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "input": self.input,
            "model": self.model,
        }


@dataclass
class CategoryScores:
    """Category scores for a moderation result."""
    hate: float = 0.0
    hate_threatening: float = 0.0
    harassment: float = 0.0
    harassment_threatening: float = 0.0
    self_harm: float = 0.0
    self_harm_intent: float = 0.0
    self_harm_instructions: float = 0.0
    sexual: float = 0.0
    sexual_minors: float = 0.0
    violence: float = 0.0
    violence_graphic: float = 0.0
    # Omni-specific
    illicit: Optional[float] = None
    illicit_violent: Optional[float] = None
    
    def to_dict(self) -> Dict[str, float]:
        """Convert to dictionary with API field names."""
        result = {
            "hate": self.hate,
            "hate/threatening": self.hate_threatening,
            "harassment": self.harassment,
            "harassment/threatening": self.harassment_threatening,
            "self-harm": self.self_harm,
            "self-harm/intent": self.self_harm_intent,
            "self-harm/instructions": self.self_harm_instructions,
            "sexual": self.sexual,
            "sexual/minors": self.sexual_minors,
            "violence": self.violence,
            "violence/graphic": self.violence_graphic,
        }
        # Add omni-specific categories if present
        if self.illicit is not None:
            result["illicit"] = self.illicit
        if self.illicit_violent is not None:
            result["illicit/violent"] = self.illicit_violent
        return result


@dataclass
class CategoryFlags:
    """Category flags for a moderation result."""
    hate: bool = False
    hate_threatening: bool = False
    harassment: bool = False
    harassment_threatening: bool = False
    self_harm: bool = False
    self_harm_intent: bool = False
    self_harm_instructions: bool = False
    sexual: bool = False
    sexual_minors: bool = False
    violence: bool = False
    violence_graphic: bool = False
    # Omni-specific
    illicit: Optional[bool] = None
    illicit_violent: Optional[bool] = None
    
    @classmethod
    def from_scores(cls, scores: CategoryScores, threshold: float = DEFAULT_THRESHOLD) -> "CategoryFlags":
        """Create flags from scores using threshold."""
        return cls(
            hate=scores.hate >= threshold,
            hate_threatening=scores.hate_threatening >= threshold,
            harassment=scores.harassment >= threshold,
            harassment_threatening=scores.harassment_threatening >= threshold,
            self_harm=scores.self_harm >= threshold,
            self_harm_intent=scores.self_harm_intent >= threshold,
            self_harm_instructions=scores.self_harm_instructions >= threshold,
            sexual=scores.sexual >= threshold,
            sexual_minors=scores.sexual_minors >= threshold,
            violence=scores.violence >= threshold,
            violence_graphic=scores.violence_graphic >= threshold,
            illicit=scores.illicit >= threshold if scores.illicit is not None else None,
            illicit_violent=scores.illicit_violent >= threshold if scores.illicit_violent is not None else None,
        )
    
    def is_flagged(self) -> bool:
        """Check if any category is flagged."""
        flags = [
            self.hate, self.hate_threatening, self.harassment,
            self.harassment_threatening, self.self_harm, self.self_harm_intent,
            self.self_harm_instructions, self.sexual, self.sexual_minors,
            self.violence, self.violence_graphic,
        ]
        # Add omni-specific flags
        if self.illicit is not None:
            flags.append(self.illicit)
        if self.illicit_violent is not None:
            flags.append(self.illicit_violent)
        return any(flags)
    
    def to_dict(self) -> Dict[str, bool]:
        """Convert to dictionary with API field names."""
        result = {
            "hate": self.hate,
            "hate/threatening": self.hate_threatening,
            "harassment": self.harassment,
            "harassment/threatening": self.harassment_threatening,
            "self-harm": self.self_harm,
            "self-harm/intent": self.self_harm_intent,
            "self-harm/instructions": self.self_harm_instructions,
            "sexual": self.sexual,
            "sexual/minors": self.sexual_minors,
            "violence": self.violence,
            "violence/graphic": self.violence_graphic,
        }
        # Add omni-specific categories if present
        if self.illicit is not None:
            result["illicit"] = self.illicit
        if self.illicit_violent is not None:
            result["illicit/violent"] = self.illicit_violent
        return result


@dataclass
class ModerationResult:
    """Single moderation result for one input."""
    flagged: bool
    categories: CategoryFlags
    category_scores: CategoryScores
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "flagged": self.flagged,
            "categories": self.categories.to_dict(),
            "category_scores": self.category_scores.to_dict(),
        }


@dataclass
class ModerationResponse:
    """Full response for moderation endpoint."""
    id: str
    model: str
    results: List[ModerationResult]
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "id": self.id,
            "model": self.model,
            "results": [r.to_dict() for r in self.results],
        }


@dataclass
class ModerationErrorResponse:
    """Error response for moderation endpoint."""
    message: str
    type: str = "invalid_request_error"
    param: Optional[str] = None
    code: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to error response format."""
        error = {
            "message": self.message,
            "type": self.type,
        }
        if self.param:
            error["param"] = self.param
        if self.code:
            error["code"] = self.code
        return {"error": error}


# ========================================
# Moderation Handler
# ========================================

class ModerationsHandler:
    """Handler for moderation requests."""
    
    def __init__(
        self,
        moderation_backend: Optional[Any] = None,
        mock_mode: bool = True,
        threshold: float = DEFAULT_THRESHOLD,
    ):
        """
        Initialize handler.
        
        Args:
            moderation_backend: Backend for actual moderation calls
            mock_mode: If True, return mock results
            threshold: Score threshold for flagging
        """
        self.backend = moderation_backend
        self.mock_mode = mock_mode
        self.threshold = threshold
        
        # Mock patterns for testing
        self._flagged_patterns = {
            "hate": ["hate speech", "racial slur", "discriminat"],
            "harassment": ["harass", "bully", "threaten"],
            "violence": ["kill", "murder", "attack", "weapon"],
            "sexual": ["explicit", "nude", "pornograph"],
            "self_harm": ["suicide", "self-harm", "cut myself"],
        }
    
    def create_moderation(self, request: ModerationRequest) -> Dict[str, Any]:
        """
        Create moderation for input text(s).
        
        Args:
            request: Moderation request
            
        Returns:
            Moderation response dictionary
        """
        if self.mock_mode:
            return self._mock_moderation(request)
        
        # Real moderation would go here
        return self._real_moderation(request)
    
    def handle_request(self, data: Dict[str, Any]) -> Dict[str, Any]:
        """
        Handle raw request data.
        
        Args:
            data: Request data dictionary
            
        Returns:
            Response dictionary
        """
        # Validate input
        if "input" not in data:
            return ModerationErrorResponse(
                message="'input' is a required property",
                param="input",
                code="missing_required_parameter",
            ).to_dict()
        
        input_val = data.get("input")
        if not input_val:
            return ModerationErrorResponse(
                message="'input' must not be empty",
                param="input",
                code="invalid_value",
            ).to_dict()
        
        try:
            request = ModerationRequest.from_dict(data)
            return self.create_moderation(request)
        except Exception as e:
            return ModerationErrorResponse(
                message=str(e),
                code="internal_error",
            ).to_dict()
    
    def _mock_moderation(self, request: ModerationRequest) -> Dict[str, Any]:
        """Generate mock moderation results."""
        results = []
        is_omni = ModerationModel.is_omni(request.model)
        
        for text in request.input_list:
            scores = self._compute_mock_scores(text, is_omni)
            flags = CategoryFlags.from_scores(scores, self.threshold)
            
            result = ModerationResult(
                flagged=flags.is_flagged(),
                categories=flags,
                category_scores=scores,
            )
            results.append(result)
        
        # Generate deterministic ID
        input_hash = hashlib.md5(
            "".join(request.input_list).encode()
        ).hexdigest()[:12]
        
        response = ModerationResponse(
            id=f"modr-{input_hash}",
            model=request.model,
            results=results,
        )
        
        return response.to_dict()
    
    def _compute_mock_scores(self, text: str, is_omni: bool = False) -> CategoryScores:
        """Compute mock category scores based on text content."""
        text_lower = text.lower()
        
        # Base scores (all low)
        scores = CategoryScores()
        
        # Check for flagged patterns
        for category, patterns in self._flagged_patterns.items():
            for pattern in patterns:
                if pattern in text_lower:
                    # Set high score for matching category
                    if category == "hate":
                        scores.hate = 0.85
                        scores.hate_threatening = 0.3 if "threat" in text_lower else 0.1
                    elif category == "harassment":
                        scores.harassment = 0.8
                        scores.harassment_threatening = 0.4 if "threat" in text_lower else 0.1
                    elif category == "violence":
                        scores.violence = 0.9
                        scores.violence_graphic = 0.5 if "blood" in text_lower or "gore" in text_lower else 0.2
                    elif category == "sexual":
                        scores.sexual = 0.85
                        scores.sexual_minors = 0.1  # Low by default
                    elif category == "self_harm":
                        scores.self_harm = 0.9
                        scores.self_harm_intent = 0.6 if "want to" in text_lower else 0.2
                        scores.self_harm_instructions = 0.3 if "how to" in text_lower else 0.1
        
        # Add omni-specific categories
        if is_omni:
            scores.illicit = 0.3 if "illegal" in text_lower else 0.05
            scores.illicit_violent = 0.2 if "weapon" in text_lower else 0.03
        
        return scores
    
    def _real_moderation(self, request: ModerationRequest) -> Dict[str, Any]:
        """Call real moderation backend."""
        # This would be implemented with actual backend calls
        # For now, fall back to mock
        return self._mock_moderation(request)


# ========================================
# Factory and Utilities
# ========================================

def get_moderations_handler(
    moderation_backend: Optional[Any] = None,
    mock_mode: bool = True,
) -> ModerationsHandler:
    """
    Factory function to create moderations handler.
    
    Args:
        moderation_backend: Optional backend service
        mock_mode: If True, use mock responses
        
    Returns:
        Configured ModerationsHandler instance
    """
    return ModerationsHandler(
        moderation_backend=moderation_backend,
        mock_mode=mock_mode,
    )


def moderate_text(
    text: Union[str, List[str]],
    model: str = ModerationModel.TEXT_MODERATION_LATEST.value,
) -> Dict[str, Any]:
    """
    Convenience function to moderate text.
    
    Args:
        text: Text or list of texts to moderate
        model: Model to use for moderation
        
    Returns:
        Moderation response dictionary
    """
    handler = get_moderations_handler()
    request = ModerationRequest(input=text, model=model)
    return handler.create_moderation(request)


def is_content_safe(text: str, threshold: float = DEFAULT_THRESHOLD) -> bool:
    """
    Quick check if content is safe.
    
    Args:
        text: Text to check
        threshold: Score threshold for flagging
        
    Returns:
        True if content is safe (not flagged)
    """
    handler = ModerationsHandler(threshold=threshold)
    request = ModerationRequest(input=text)
    response = handler.create_moderation(request)
    
    if "results" in response and response["results"]:
        return not response["results"][0]["flagged"]
    return True


def get_flagged_categories(text: str) -> List[str]:
    """
    Get list of flagged categories for text.
    
    Args:
        text: Text to moderate
        
    Returns:
        List of flagged category names
    """
    handler = get_moderations_handler()
    request = ModerationRequest(input=text)
    response = handler.create_moderation(request)
    
    flagged = []
    if "results" in response and response["results"]:
        categories = response["results"][0].get("categories", {})
        for category, is_flagged in categories.items():
            if is_flagged:
                flagged.append(category)
    
    return flagged


def validate_moderation_input(input_data: Any) -> Optional[str]:
    """
    Validate moderation input.
    
    Args:
        input_data: Input to validate
        
    Returns:
        Error message if invalid, None if valid
    """
    if input_data is None:
        return "input is required"
    
    if isinstance(input_data, str):
        if not input_data.strip():
            return "input must not be empty"
        if len(input_data) > 100000:  # 100k character limit
            return "input exceeds maximum length of 100000 characters"
    elif isinstance(input_data, list):
        if not input_data:
            return "input list must not be empty"
        if len(input_data) > 32:  # Max 32 items
            return "input list exceeds maximum of 32 items"
        for i, item in enumerate(input_data):
            if not isinstance(item, str):
                return f"input[{i}] must be a string"
            if not item.strip():
                return f"input[{i}] must not be empty"
    else:
        return "input must be a string or array of strings"
    
    return None


# ========================================
# Exports
# ========================================

SUPPORTED_MODERATION_MODELS = [m.value for m in ModerationModel]

__all__ = [
    # Enums
    "ModerationModel",
    "ModerationCategory",
    # Request/Response
    "ModerationRequest",
    "CategoryScores",
    "CategoryFlags",
    "ModerationResult",
    "ModerationResponse",
    "ModerationErrorResponse",
    # Handler
    "ModerationsHandler",
    # Utilities
    "get_moderations_handler",
    "moderate_text",
    "is_content_safe",
    "get_flagged_categories",
    "validate_moderation_input",
    # Constants
    "SUPPORTED_MODERATION_MODELS",
    "DEFAULT_THRESHOLD",
    "TEXT_MODERATION_CATEGORIES",
    "OMNI_MODERATION_CATEGORIES",
]