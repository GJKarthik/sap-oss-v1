"""
Unit Tests for Moderations Endpoint

Day 16 Deliverable: 50 tests for content moderation endpoint

Test Categories:
1. ModerationModel enum tests
2. ModerationCategory enum tests
3. ModerationRequest tests
4. CategoryScores tests
5. CategoryFlags tests
6. ModerationResult tests
7. ModerationResponse tests
8. ModerationErrorResponse tests
9. ModerationsHandler tests
10. Utility function tests
11. Input validation tests
12. OpenAI compliance tests
"""

import pytest
from unittest.mock import Mock, patch
from typing import Dict, Any, List

from openai.moderations import (
    ModerationModel,
    ModerationCategory,
    ModerationRequest,
    CategoryScores,
    CategoryFlags,
    ModerationResult,
    ModerationResponse,
    ModerationErrorResponse,
    ModerationsHandler,
    get_moderations_handler,
    moderate_text,
    is_content_safe,
    get_flagged_categories,
    validate_moderation_input,
    SUPPORTED_MODERATION_MODELS,
    DEFAULT_THRESHOLD,
    TEXT_MODERATION_CATEGORIES,
    OMNI_MODERATION_CATEGORIES,
)


# ========================================
# ModerationModel Enum Tests
# ========================================

class TestModerationModel:
    """Tests for ModerationModel enum."""
    
    def test_text_moderation_latest(self):
        """Test text-moderation-latest value."""
        assert ModerationModel.TEXT_MODERATION_LATEST.value == "text-moderation-latest"
    
    def test_text_moderation_stable(self):
        """Test text-moderation-stable value."""
        assert ModerationModel.TEXT_MODERATION_STABLE.value == "text-moderation-stable"
    
    def test_omni_moderation_latest(self):
        """Test omni-moderation-latest value."""
        assert ModerationModel.OMNI_MODERATION_LATEST.value == "omni-moderation-latest"
    
    def test_get_default(self):
        """Test default model."""
        default = ModerationModel.get_default()
        assert default == ModerationModel.TEXT_MODERATION_LATEST
    
    def test_is_valid_with_valid_model(self):
        """Test is_valid with valid model."""
        assert ModerationModel.is_valid("text-moderation-latest") is True
        assert ModerationModel.is_valid("omni-moderation-latest") is True
    
    def test_is_valid_with_invalid_model(self):
        """Test is_valid with invalid model."""
        assert ModerationModel.is_valid("invalid-model") is False
    
    def test_is_omni_with_omni_model(self):
        """Test is_omni with omni model."""
        assert ModerationModel.is_omni("omni-moderation-latest") is True
        assert ModerationModel.is_omni("omni-moderation-2024-09-26") is True
    
    def test_is_omni_with_text_model(self):
        """Test is_omni with text model."""
        assert ModerationModel.is_omni("text-moderation-latest") is False


# ========================================
# ModerationCategory Enum Tests
# ========================================

class TestModerationCategory:
    """Tests for ModerationCategory enum."""
    
    def test_hate_category(self):
        """Test hate category value."""
        assert ModerationCategory.HATE.value == "hate"
    
    def test_hate_threatening_category(self):
        """Test hate/threatening category value."""
        assert ModerationCategory.HATE_THREATENING.value == "hate/threatening"
    
    def test_self_harm_category(self):
        """Test self-harm category value."""
        assert ModerationCategory.SELF_HARM.value == "self-harm"
    
    def test_sexual_minors_category(self):
        """Test sexual/minors category value."""
        assert ModerationCategory.SEXUAL_MINORS.value == "sexual/minors"
    
    def test_violence_graphic_category(self):
        """Test violence/graphic category value."""
        assert ModerationCategory.VIOLENCE_GRAPHIC.value == "violence/graphic"
    
    def test_illicit_category(self):
        """Test illicit category value (omni-specific)."""
        assert ModerationCategory.ILLICIT.value == "illicit"


# ========================================
# ModerationRequest Tests
# ========================================

class TestModerationRequest:
    """Tests for ModerationRequest dataclass."""
    
    def test_create_with_string_input(self):
        """Test creating request with string input."""
        request = ModerationRequest(input="Test content")
        assert request.input == "Test content"
        assert request.model == "text-moderation-latest"
    
    def test_create_with_list_input(self):
        """Test creating request with list input."""
        request = ModerationRequest(input=["Text 1", "Text 2"])
        assert request.input == ["Text 1", "Text 2"]
        assert len(request.input_list) == 2
    
    def test_create_with_custom_model(self):
        """Test creating request with custom model."""
        request = ModerationRequest(
            input="Test",
            model="omni-moderation-latest"
        )
        assert request.model == "omni-moderation-latest"
    
    def test_input_list_property_string(self):
        """Test input_list property with string input."""
        request = ModerationRequest(input="Single text")
        assert request.input_list == ["Single text"]
    
    def test_input_list_property_list(self):
        """Test input_list property with list input."""
        request = ModerationRequest(input=["A", "B", "C"])
        assert request.input_list == ["A", "B", "C"]
    
    def test_from_dict(self):
        """Test creating from dictionary."""
        data = {
            "input": "Test content",
            "model": "text-moderation-stable"
        }
        request = ModerationRequest.from_dict(data)
        assert request.input == "Test content"
        assert request.model == "text-moderation-stable"
    
    def test_from_dict_default_model(self):
        """Test from_dict with default model."""
        data = {"input": "Test"}
        request = ModerationRequest.from_dict(data)
        assert request.model == "text-moderation-latest"
    
    def test_to_dict(self):
        """Test converting to dictionary."""
        request = ModerationRequest(input="Test", model="text-moderation-latest")
        result = request.to_dict()
        assert result["input"] == "Test"
        assert result["model"] == "text-moderation-latest"


# ========================================
# CategoryScores Tests
# ========================================

class TestCategoryScores:
    """Tests for CategoryScores dataclass."""
    
    def test_default_scores_zero(self):
        """Test default scores are zero."""
        scores = CategoryScores()
        assert scores.hate == 0.0
        assert scores.violence == 0.0
        assert scores.sexual == 0.0
    
    def test_custom_scores(self):
        """Test custom score values."""
        scores = CategoryScores(
            hate=0.85,
            violence=0.6,
            harassment=0.3
        )
        assert scores.hate == 0.85
        assert scores.violence == 0.6
        assert scores.harassment == 0.3
    
    def test_omni_scores_optional(self):
        """Test omni-specific scores are optional."""
        scores = CategoryScores()
        assert scores.illicit is None
        assert scores.illicit_violent is None
    
    def test_omni_scores_set(self):
        """Test setting omni-specific scores."""
        scores = CategoryScores(illicit=0.5, illicit_violent=0.3)
        assert scores.illicit == 0.5
        assert scores.illicit_violent == 0.3
    
    def test_to_dict(self):
        """Test converting to dictionary."""
        scores = CategoryScores(hate=0.8, violence=0.6)
        result = scores.to_dict()
        
        assert result["hate"] == 0.8
        assert result["violence"] == 0.6
        assert "hate/threatening" in result
        assert "self-harm" in result
    
    def test_to_dict_omni_categories(self):
        """Test to_dict includes omni categories when set."""
        scores = CategoryScores(illicit=0.5)
        result = scores.to_dict()
        
        assert "illicit" in result
        assert result["illicit"] == 0.5


# ========================================
# CategoryFlags Tests
# ========================================

class TestCategoryFlags:
    """Tests for CategoryFlags dataclass."""
    
    def test_default_flags_false(self):
        """Test default flags are False."""
        flags = CategoryFlags()
        assert flags.hate is False
        assert flags.violence is False
        assert flags.sexual is False
    
    def test_from_scores_below_threshold(self):
        """Test from_scores with scores below threshold."""
        scores = CategoryScores(hate=0.3, violence=0.2)
        flags = CategoryFlags.from_scores(scores, threshold=0.5)
        
        assert flags.hate is False
        assert flags.violence is False
    
    def test_from_scores_above_threshold(self):
        """Test from_scores with scores above threshold."""
        scores = CategoryScores(hate=0.8, violence=0.6)
        flags = CategoryFlags.from_scores(scores, threshold=0.5)
        
        assert flags.hate is True
        assert flags.violence is True
    
    def test_from_scores_at_threshold(self):
        """Test from_scores with scores at threshold."""
        scores = CategoryScores(hate=0.5)
        flags = CategoryFlags.from_scores(scores, threshold=0.5)
        
        assert flags.hate is True
    
    def test_is_flagged_when_flagged(self):
        """Test is_flagged returns True when any category flagged."""
        flags = CategoryFlags(violence=True)
        assert flags.is_flagged() is True
    
    def test_is_flagged_when_not_flagged(self):
        """Test is_flagged returns False when no category flagged."""
        flags = CategoryFlags()
        assert flags.is_flagged() is False
    
    def test_to_dict(self):
        """Test converting to dictionary."""
        flags = CategoryFlags(hate=True, violence=False)
        result = flags.to_dict()
        
        assert result["hate"] is True
        assert result["violence"] is False
        assert "hate/threatening" in result


# ========================================
# ModerationResult Tests
# ========================================

class TestModerationResult:
    """Tests for ModerationResult dataclass."""
    
    def test_create_result(self):
        """Test creating moderation result."""
        scores = CategoryScores(hate=0.8)
        flags = CategoryFlags(hate=True)
        result = ModerationResult(
            flagged=True,
            categories=flags,
            category_scores=scores
        )
        
        assert result.flagged is True
    
    def test_to_dict(self):
        """Test converting to dictionary."""
        scores = CategoryScores(hate=0.8)
        flags = CategoryFlags(hate=True)
        result = ModerationResult(
            flagged=True,
            categories=flags,
            category_scores=scores
        )
        
        result_dict = result.to_dict()
        assert result_dict["flagged"] is True
        assert "categories" in result_dict
        assert "category_scores" in result_dict


# ========================================
# ModerationResponse Tests
# ========================================

class TestModerationResponse:
    """Tests for ModerationResponse dataclass."""
    
    def test_create_response(self):
        """Test creating moderation response."""
        result = ModerationResult(
            flagged=False,
            categories=CategoryFlags(),
            category_scores=CategoryScores()
        )
        response = ModerationResponse(
            id="modr-123",
            model="text-moderation-latest",
            results=[result]
        )
        
        assert response.id == "modr-123"
        assert response.model == "text-moderation-latest"
        assert len(response.results) == 1
    
    def test_to_dict(self):
        """Test converting to dictionary."""
        result = ModerationResult(
            flagged=False,
            categories=CategoryFlags(),
            category_scores=CategoryScores()
        )
        response = ModerationResponse(
            id="modr-abc",
            model="text-moderation-latest",
            results=[result]
        )
        
        response_dict = response.to_dict()
        assert response_dict["id"] == "modr-abc"
        assert response_dict["model"] == "text-moderation-latest"
        assert len(response_dict["results"]) == 1


# ========================================
# ModerationErrorResponse Tests
# ========================================

class TestModerationErrorResponse:
    """Tests for ModerationErrorResponse dataclass."""
    
    def test_create_error(self):
        """Test creating error response."""
        error = ModerationErrorResponse(message="Invalid input")
        assert error.message == "Invalid input"
        assert error.type == "invalid_request_error"
    
    def test_to_dict(self):
        """Test converting to dictionary."""
        error = ModerationErrorResponse(
            message="Missing input",
            param="input",
            code="missing_required_parameter"
        )
        
        result = error.to_dict()
        assert "error" in result
        assert result["error"]["message"] == "Missing input"
        assert result["error"]["param"] == "input"
        assert result["error"]["code"] == "missing_required_parameter"


# ========================================
# ModerationsHandler Tests
# ========================================

class TestModerationsHandler:
    """Tests for ModerationsHandler class."""
    
    @pytest.fixture
    def handler(self):
        """Create handler fixture."""
        return ModerationsHandler()
    
    def test_handler_default_mock_mode(self, handler):
        """Test handler default mock mode."""
        assert handler.mock_mode is True
    
    def test_create_moderation_single_input(self, handler):
        """Test moderation with single input."""
        request = ModerationRequest(input="Hello world")
        response = handler.create_moderation(request)
        
        assert "id" in response
        assert "model" in response
        assert "results" in response
        assert len(response["results"]) == 1
    
    def test_create_moderation_multiple_inputs(self, handler):
        """Test moderation with multiple inputs."""
        request = ModerationRequest(input=["Text 1", "Text 2", "Text 3"])
        response = handler.create_moderation(request)
        
        assert len(response["results"]) == 3
    
    def test_create_moderation_safe_content(self, handler):
        """Test moderation with safe content."""
        request = ModerationRequest(input="The weather is nice today.")
        response = handler.create_moderation(request)
        
        assert response["results"][0]["flagged"] is False
    
    def test_create_moderation_flagged_content_violence(self, handler):
        """Test moderation flags violence content."""
        request = ModerationRequest(input="I want to kill someone")
        response = handler.create_moderation(request)
        
        assert response["results"][0]["flagged"] is True
        assert response["results"][0]["categories"]["violence"] is True
    
    def test_create_moderation_flagged_content_hate(self, handler):
        """Test moderation flags hate content."""
        request = ModerationRequest(input="This is hate speech against people")
        response = handler.create_moderation(request)
        
        assert response["results"][0]["flagged"] is True
        assert response["results"][0]["categories"]["hate"] is True
    
    def test_handle_request_valid(self, handler):
        """Test handle_request with valid data."""
        data = {"input": "Test content"}
        response = handler.handle_request(data)
        
        assert "results" in response
        assert "error" not in response
    
    def test_handle_request_missing_input(self, handler):
        """Test handle_request with missing input."""
        data = {}
        response = handler.handle_request(data)
        
        assert "error" in response
        assert "input" in response["error"]["message"].lower()
    
    def test_handle_request_empty_input(self, handler):
        """Test handle_request with empty input."""
        data = {"input": ""}
        response = handler.handle_request(data)
        
        assert "error" in response
    
    def test_response_id_format(self, handler):
        """Test response ID format."""
        request = ModerationRequest(input="Test")
        response = handler.create_moderation(request)
        
        assert response["id"].startswith("modr-")
    
    def test_omni_model_categories(self):
        """Test omni model includes additional categories."""
        handler = ModerationsHandler()
        request = ModerationRequest(
            input="Test illegal weapon",
            model="omni-moderation-latest"
        )
        response = handler.create_moderation(request)
        
        assert "illicit" in response["results"][0]["category_scores"]


# ========================================
# Utility Function Tests
# ========================================

class TestModerationUtilities:
    """Tests for moderation utility functions."""
    
    def test_get_moderations_handler(self):
        """Test factory function."""
        handler = get_moderations_handler()
        assert isinstance(handler, ModerationsHandler)
    
    def test_get_moderations_handler_custom_mock(self):
        """Test factory with custom mock mode."""
        handler = get_moderations_handler(mock_mode=False)
        assert handler.mock_mode is False
    
    def test_moderate_text_single(self):
        """Test moderate_text with single text."""
        response = moderate_text("Hello world")
        
        assert "results" in response
        assert len(response["results"]) == 1
    
    def test_moderate_text_multiple(self):
        """Test moderate_text with multiple texts."""
        response = moderate_text(["Text 1", "Text 2"])
        
        assert len(response["results"]) == 2
    
    def test_is_content_safe_safe(self):
        """Test is_content_safe with safe content."""
        assert is_content_safe("The weather is beautiful") is True
    
    def test_is_content_safe_unsafe(self):
        """Test is_content_safe with unsafe content."""
        assert is_content_safe("I want to kill someone") is False
    
    def test_get_flagged_categories_none(self):
        """Test get_flagged_categories with safe content."""
        categories = get_flagged_categories("Hello world")
        assert categories == []
    
    def test_get_flagged_categories_some(self):
        """Test get_flagged_categories with flagged content."""
        categories = get_flagged_categories("This is hate speech")
        assert "hate" in categories


# ========================================
# Input Validation Tests
# ========================================

class TestInputValidation:
    """Tests for input validation."""
    
    def test_validate_none_input(self):
        """Test validation with None input."""
        error = validate_moderation_input(None)
        assert error is not None
        assert "required" in error.lower()
    
    def test_validate_empty_string(self):
        """Test validation with empty string."""
        error = validate_moderation_input("")
        assert error is not None
        assert "empty" in error.lower()
    
    def test_validate_whitespace_string(self):
        """Test validation with whitespace string."""
        error = validate_moderation_input("   ")
        assert error is not None
    
    def test_validate_valid_string(self):
        """Test validation with valid string."""
        error = validate_moderation_input("Valid content")
        assert error is None
    
    def test_validate_empty_list(self):
        """Test validation with empty list."""
        error = validate_moderation_input([])
        assert error is not None
        assert "empty" in error.lower()
    
    def test_validate_valid_list(self):
        """Test validation with valid list."""
        error = validate_moderation_input(["Text 1", "Text 2"])
        assert error is None
    
    def test_validate_list_with_empty_item(self):
        """Test validation with empty item in list."""
        error = validate_moderation_input(["Valid", ""])
        assert error is not None
    
    def test_validate_non_string_in_list(self):
        """Test validation with non-string in list."""
        error = validate_moderation_input(["Valid", 123])
        assert error is not None
        assert "string" in error.lower()


# ========================================
# Constants Tests
# ========================================

class TestConstants:
    """Tests for module constants."""
    
    def test_supported_models_list(self):
        """Test supported models list."""
        assert "text-moderation-latest" in SUPPORTED_MODERATION_MODELS
        assert "omni-moderation-latest" in SUPPORTED_MODERATION_MODELS
    
    def test_default_threshold(self):
        """Test default threshold value."""
        assert DEFAULT_THRESHOLD == 0.5
    
    def test_text_moderation_categories_count(self):
        """Test text moderation categories count."""
        assert len(TEXT_MODERATION_CATEGORIES) == 11
    
    def test_omni_moderation_categories_count(self):
        """Test omni moderation categories count."""
        assert len(OMNI_MODERATION_CATEGORIES) == 13


# ========================================
# OpenAI Compliance Tests
# ========================================

class TestOpenAICompliance:
    """Tests for OpenAI API compliance."""
    
    def test_response_structure(self):
        """Test response matches OpenAI structure."""
        handler = get_moderations_handler()
        response = handler.handle_request({"input": "Test"})
        
        # Required fields
        assert "id" in response
        assert "model" in response
        assert "results" in response
    
    def test_result_structure(self):
        """Test result matches OpenAI structure."""
        handler = get_moderations_handler()
        response = handler.handle_request({"input": "Test"})
        
        result = response["results"][0]
        assert "flagged" in result
        assert "categories" in result
        assert "category_scores" in result
    
    def test_category_names_match_api(self):
        """Test category names match OpenAI API."""
        handler = get_moderations_handler()
        response = handler.handle_request({"input": "Test"})
        
        categories = response["results"][0]["categories"]
        
        # Check slash notation
        assert "hate" in categories
        assert "hate/threatening" in categories
        assert "self-harm" in categories
        assert "self-harm/intent" in categories
    
    def test_id_prefix(self):
        """Test ID prefix format."""
        handler = get_moderations_handler()
        response = handler.handle_request({"input": "Test"})
        
        assert response["id"].startswith("modr-")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])