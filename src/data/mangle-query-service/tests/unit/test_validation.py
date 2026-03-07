"""
Unit tests for input validation middleware.

Day 43 - Week 9 Security Hardening
45 tests covering size limits, injection detection, and request validation.
"""

import pytest
from unittest.mock import Mock, patch, AsyncMock

from middleware.validation import (
    SizeLimits,
    ValidationPatterns,
    ValidationErrorType,
    ValidationError,
    InputSanitizer,
    RequestValidator,
    ChatCompletionValidator,
    validate_chat_request,
    get_default_limits,
)


# =============================================================================
# SizeLimits Tests (5 tests)
# =============================================================================

class TestSizeLimits:
    """Tests for SizeLimits configuration."""
    
    def test_default_values(self):
        """Test default size limit values."""
        limits = SizeLimits()
        assert limits.max_request_body == 10 * 1024 * 1024
        assert limits.max_messages_count == 100
    
    def test_custom_values(self):
        """Test custom size limit values."""
        limits = SizeLimits(max_request_body=5 * 1024 * 1024)
        assert limits.max_request_body == 5 * 1024 * 1024
    
    def test_file_upload_limit(self):
        """Test file upload limit."""
        limits = SizeLimits()
        assert limits.max_file_upload == 100 * 1024 * 1024
    
    def test_audio_buffer_limit(self):
        """Test audio buffer limit."""
        limits = SizeLimits()
        assert limits.max_audio_buffer == 15 * 1024 * 1024
    
    def test_prompt_length_limit(self):
        """Test prompt length limit."""
        limits = SizeLimits()
        assert limits.max_prompt_length == 500000


# =============================================================================
# ValidationPatterns Tests (8 tests)
# =============================================================================

class TestValidationPatterns:
    """Tests for validation regex patterns."""
    
    def test_model_id_valid(self):
        """Test valid model IDs."""
        assert ValidationPatterns.MODEL_ID.match("gpt-4")
        assert ValidationPatterns.MODEL_ID.match("claude-3.5-sonnet")
        assert ValidationPatterns.MODEL_ID.match("sap/gpt-4o-mini")
    
    def test_model_id_invalid(self):
        """Test invalid model IDs."""
        assert not ValidationPatterns.MODEL_ID.match("")
        assert not ValidationPatterns.MODEL_ID.match("-invalid")
        assert not ValidationPatterns.MODEL_ID.match("model<script>")
    
    def test_uuid_valid(self):
        """Test valid UUID format."""
        assert ValidationPatterns.UUID.match("550e8400-e29b-41d4-a716-446655440000")
    
    def test_uuid_invalid(self):
        """Test invalid UUID format."""
        assert not ValidationPatterns.UUID.match("not-a-uuid")
        assert not ValidationPatterns.UUID.match("550e8400-e29b-41d4-a716")
    
    def test_sql_injection_detection(self):
        """Test SQL injection pattern detection."""
        assert ValidationPatterns.SQL_INJECTION.search("'; DROP TABLE users;--")
        assert ValidationPatterns.SQL_INJECTION.search("1 OR 1=1")
        assert ValidationPatterns.SQL_INJECTION.search("SELECT * FROM users")
    
    def test_sql_injection_false_positive(self):
        """Test SQL injection doesn't flag normal text."""
        assert not ValidationPatterns.SQL_INJECTION.search("How do I select a good model?")
    
    def test_nosql_injection_detection(self):
        """Test NoSQL injection pattern detection."""
        assert ValidationPatterns.NOSQL_INJECTION.search('{"$where": "1==1"}')
        assert ValidationPatterns.NOSQL_INJECTION.search('{"$gt": 0}')
    
    def test_path_traversal_detection(self):
        """Test path traversal pattern detection."""
        assert ValidationPatterns.PATH_TRAVERSAL.search("../../../etc/passwd")
        assert ValidationPatterns.PATH_TRAVERSAL.search("%2e%2e%2f")


# =============================================================================
# InputSanitizer Tests (8 tests)
# =============================================================================

class TestInputSanitizer:
    """Tests for input sanitization."""
    
    def test_sanitize_string_normal(self):
        """Test sanitizing normal string."""
        result = InputSanitizer.sanitize_string("Hello World")
        assert result == "Hello World"
    
    def test_sanitize_string_null_bytes(self):
        """Test removing null bytes."""
        result = InputSanitizer.sanitize_string("Hello\x00World")
        assert result == "HelloWorld"
    
    def test_sanitize_string_control_chars(self):
        """Test removing control characters."""
        result = InputSanitizer.sanitize_string("Hello\x01\x02World")
        assert result == "HelloWorld"
    
    def test_sanitize_string_preserves_newlines(self):
        """Test preserving newlines and tabs."""
        result = InputSanitizer.sanitize_string("Hello\nWorld\tTest")
        assert result == "Hello\nWorld\tTest"
    
    def test_sanitize_string_truncates(self):
        """Test truncation to max length."""
        result = InputSanitizer.sanitize_string("Hello" * 100, max_length=10)
        assert len(result) == 10
    
    def test_sanitize_model_id(self):
        """Test model ID sanitization."""
        result = InputSanitizer.sanitize_model_id("gpt-4<script>")
        assert result == "gpt-4script"
    
    def test_sanitize_path(self):
        """Test path sanitization removes traversal."""
        result = InputSanitizer.sanitize_path("../../../etc/passwd")
        assert ".." not in result
    
    def test_sanitize_for_logging(self):
        """Test logging sanitization removes secrets."""
        result = InputSanitizer.sanitize_for_logging("Bearer token=abc123secret")
        assert "[REDACTED]" in result


# =============================================================================
# RequestValidator Tests (12 tests)
# =============================================================================

class TestRequestValidator:
    """Tests for request validation."""
    
    @pytest.fixture
    def validator(self):
        """Create request validator."""
        return RequestValidator()
    
    def test_validate_content_length_valid(self, validator):
        """Test valid content length."""
        error = validator.validate_content_length(1024)
        assert error is None
    
    def test_validate_content_length_exceeded(self, validator):
        """Test content length exceeded."""
        error = validator.validate_content_length(100 * 1024 * 1024)
        assert error is not None
        assert error.error_type == ValidationErrorType.SIZE_EXCEEDED
    
    def test_validate_model_id_valid(self, validator):
        """Test valid model ID."""
        error = validator.validate_model_id("gpt-4o")
        assert error is None
    
    def test_validate_model_id_missing(self, validator):
        """Test missing model ID."""
        error = validator.validate_model_id("")
        assert error is not None
        assert error.error_type == ValidationErrorType.MISSING_REQUIRED
    
    def test_validate_model_id_too_long(self, validator):
        """Test model ID too long."""
        error = validator.validate_model_id("x" * 300)
        assert error is not None
        assert error.error_type == ValidationErrorType.SIZE_EXCEEDED
    
    def test_validate_messages_valid(self, validator):
        """Test valid messages array."""
        messages = [{"role": "user", "content": "Hello"}]
        errors = validator.validate_messages(messages)
        assert len(errors) == 0
    
    def test_validate_messages_not_array(self, validator):
        """Test messages not array."""
        errors = validator.validate_messages("not an array")
        assert len(errors) == 1
        assert errors[0].error_type == ValidationErrorType.INVALID_FORMAT
    
    def test_validate_messages_too_many(self, validator):
        """Test too many messages."""
        messages = [{"role": "user", "content": f"msg{i}"} for i in range(150)]
        errors = validator.validate_messages(messages)
        assert any(e.error_type == ValidationErrorType.SIZE_EXCEEDED for e in errors)
    
    def test_validate_messages_invalid_role(self, validator):
        """Test invalid message role."""
        messages = [{"role": "invalid_role", "content": "Hello"}]
        errors = validator.validate_messages(messages)
        assert any(e.error_type == ValidationErrorType.INVALID_VALUE for e in errors)
    
    def test_check_sql_injection(self, validator):
        """Test SQL injection detection."""
        error = validator.check_sql_injection("'; DROP TABLE users;--")
        assert error is not None
        assert error.error_type == ValidationErrorType.INJECTION_DETECTED
    
    def test_validate_url_safe_internal(self, validator):
        """Test SSRF detection for internal URL."""
        error = validator.validate_url_safe("http://localhost:8080/api")
        assert error is not None
        assert error.error_type == ValidationErrorType.SSRF_ATTEMPT
    
    def test_validate_numeric_range(self, validator):
        """Test numeric range validation."""
        error = validator.validate_numeric_range(2.5, "temperature", 0.0, 2.0)
        assert error is not None
        assert error.error_type == ValidationErrorType.INVALID_VALUE


# =============================================================================
# ChatCompletionValidator Tests (10 tests)
# =============================================================================

class TestChatCompletionValidator:
    """Tests for chat completion validation."""
    
    @pytest.fixture
    def chat_validator(self):
        """Create chat completion validator."""
        return ChatCompletionValidator()
    
    def test_valid_request(self, chat_validator):
        """Test valid chat completion request."""
        body = {
            "model": "gpt-4o",
            "messages": [{"role": "user", "content": "Hello"}]
        }
        errors = chat_validator.validate(body)
        assert len(errors) == 0
    
    def test_missing_model(self, chat_validator):
        """Test missing model field."""
        body = {"messages": [{"role": "user", "content": "Hello"}]}
        errors = chat_validator.validate(body)
        assert any(e.field == "model" for e in errors)
    
    def test_missing_messages(self, chat_validator):
        """Test missing messages field."""
        body = {"model": "gpt-4o"}
        errors = chat_validator.validate(body)
        assert any(e.field == "messages" for e in errors)
    
    def test_temperature_too_high(self, chat_validator):
        """Test temperature above limit."""
        body = {
            "model": "gpt-4o",
            "messages": [{"role": "user", "content": "Hello"}],
            "temperature": 3.0
        }
        errors = chat_validator.validate(body)
        assert any(e.field == "temperature" for e in errors)
    
    def test_temperature_valid(self, chat_validator):
        """Test valid temperature."""
        body = {
            "model": "gpt-4o",
            "messages": [{"role": "user", "content": "Hello"}],
            "temperature": 0.7
        }
        errors = chat_validator.validate(body)
        assert not any(e.field == "temperature" for e in errors)
    
    def test_top_p_invalid(self, chat_validator):
        """Test invalid top_p."""
        body = {
            "model": "gpt-4o",
            "messages": [{"role": "user", "content": "Hello"}],
            "top_p": 1.5
        }
        errors = chat_validator.validate(body)
        assert any(e.field == "top_p" for e in errors)
    
    def test_max_tokens_invalid(self, chat_validator):
        """Test invalid max_tokens."""
        body = {
            "model": "gpt-4o",
            "messages": [{"role": "user", "content": "Hello"}],
            "max_tokens": -10
        }
        errors = chat_validator.validate(body)
        assert any(e.field == "max_tokens" for e in errors)
    
    def test_n_invalid(self, chat_validator):
        """Test invalid n value."""
        body = {
            "model": "gpt-4o",
            "messages": [{"role": "user", "content": "Hello"}],
            "n": 500
        }
        errors = chat_validator.validate(body)
        assert any(e.field == "n" for e in errors)
    
    def test_too_many_tools(self, chat_validator):
        """Test too many tools."""
        body = {
            "model": "gpt-4o",
            "messages": [{"role": "user", "content": "Hello"}],
            "tools": [{"type": "function"} for _ in range(200)]
        }
        errors = chat_validator.validate(body)
        assert any(e.field == "tools" for e in errors)
    
    def test_valid_with_all_params(self, chat_validator):
        """Test valid request with all parameters."""
        body = {
            "model": "gpt-4o",
            "messages": [{"role": "user", "content": "Hello"}],
            "temperature": 0.7,
            "top_p": 0.9,
            "max_tokens": 1000,
            "n": 1
        }
        errors = chat_validator.validate(body)
        assert len(errors) == 0


# =============================================================================
# Module Functions Tests (2 tests)
# =============================================================================

class TestModuleFunctions:
    """Tests for module-level functions."""
    
    def test_get_default_limits(self):
        """Test get_default_limits returns SizeLimits."""
        limits = get_default_limits()
        assert isinstance(limits, SizeLimits)
    
    def test_validate_chat_request(self):
        """Test validate_chat_request function."""
        body = {
            "model": "gpt-4o",
            "messages": [{"role": "user", "content": "Hello"}]
        }
        errors = validate_chat_request(body)
        assert len(errors) == 0


# =============================================================================
# Summary
# =============================================================================
# Total: 45 tests
# - SizeLimits: 5 tests
# - ValidationPatterns: 8 tests
# - InputSanitizer: 8 tests
# - RequestValidator: 12 tests
# - ChatCompletionValidator: 10 tests
# - Module Functions: 2 tests