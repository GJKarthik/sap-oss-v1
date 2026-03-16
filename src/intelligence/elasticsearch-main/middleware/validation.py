"""
Input Validation Middleware for Security Hardening.

Day 43 Implementation - Week 9 Security Hardening
Provides request validation, size limits, and injection prevention.
"""

import re
import logging
from typing import Optional, Dict, Any, List, Set, Union
from dataclasses import dataclass, field
from enum import Enum
from urllib.parse import urlparse
import ipaddress

from fastapi import Request, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, validator, root_validator
from starlette.middleware.base import BaseHTTPMiddleware

logger = logging.getLogger(__name__)


# =============================================================================
# Size Limits Configuration
# =============================================================================

@dataclass
class SizeLimits:
    """Request size limits configuration."""
    max_request_body: int = 10 * 1024 * 1024  # 10 MB
    max_file_upload: int = 100 * 1024 * 1024  # 100 MB
    max_messages_count: int = 100
    max_single_message: int = 100 * 1024  # 100 KB
    max_tools_count: int = 128
    max_audio_buffer: int = 15 * 1024 * 1024  # 15 MB
    max_prompt_length: int = 500000  # ~125K tokens
    max_model_id_length: int = 256
    max_metadata_size: int = 16 * 1024  # 16 KB
    max_header_size: int = 8 * 1024  # 8 KB
    max_url_length: int = 2048
    max_array_items: int = 1000


# =============================================================================
# Validation Patterns
# =============================================================================

class ValidationPatterns:
    """Regex patterns for validation."""
    
    # Model ID: alphanumeric, hyphens, underscores, slashes, colons, dots
    MODEL_ID = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9\-_\.:/]{0,255}$')
    
    # Safe string: no control characters
    SAFE_STRING = re.compile(r'^[^\x00-\x08\x0B\x0C\x0E-\x1F]*$')
    
    # UUID format
    UUID = re.compile(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
    
    # File ID format
    FILE_ID = re.compile(r'^file-[a-zA-Z0-9]{24,64}$')
    
    # Assistant/Thread/Vector Store ID
    RESOURCE_ID = re.compile(r'^(asst|thread|vs|run|step|msg|batch)_[a-zA-Z0-9]{24,64}$')
    
    # SQL injection patterns
    SQL_INJECTION = re.compile(
        r"(?i)(\b(SELECT|INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|TRUNCATE|EXEC|UNION|"
        r"DECLARE|CAST|CONVERT|WAITFOR|DELAY)\b.*\b(FROM|INTO|SET|VALUES|TABLE|WHERE|"
        r"DATABASE|SCHEMA)\b)|"
        r"(--|#|/\*|\*/|;|\bOR\b\s+\d+\s*=\s*\d+|\bAND\b\s+\d+\s*=\s*\d+)",
        re.IGNORECASE
    )
    
    # NoSQL injection patterns
    NOSQL_INJECTION = re.compile(
        r'(\$where|\$gt|\$lt|\$ne|\$eq|\$regex|\$or|\$and|\$not|\$nor|\$exists|'
        r'\$type|\$mod|\$text|\$search|\$meta|\$slice|\$elemMatch|\$size)',
        re.IGNORECASE
    )
    
    # Path traversal patterns
    PATH_TRAVERSAL = re.compile(r'(\.\./|\.\.\\|%2e%2e%2f|%2e%2e/|\.%2e/|%2e\./)');
    
    # SSRF dangerous hosts
    SSRF_DANGEROUS = re.compile(
        r'^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|'
        r'169\.254\.|0\.|::1|fc00:|fe80:|fd00:)',
        re.IGNORECASE
    )


# =============================================================================
# Validation Error Types
# =============================================================================

class ValidationErrorType(str, Enum):
    """Types of validation errors."""
    SIZE_EXCEEDED = "size_exceeded"
    INVALID_FORMAT = "invalid_format"
    INJECTION_DETECTED = "injection_detected"
    SSRF_ATTEMPT = "ssrf_attempt"
    PATH_TRAVERSAL = "path_traversal"
    INVALID_CONTENT_TYPE = "invalid_content_type"
    MISSING_REQUIRED = "missing_required"
    INVALID_VALUE = "invalid_value"
    RATE_LIMITED = "rate_limited"


@dataclass
class ValidationError:
    """Validation error details."""
    error_type: ValidationErrorType
    field: str
    message: str
    value: Optional[str] = None  # Sanitized value for logging


# =============================================================================
# Input Sanitizers
# =============================================================================

class InputSanitizer:
    """Sanitizes input values to prevent injection attacks."""
    
    @staticmethod
    def sanitize_string(value: str, max_length: int = 10000) -> str:
        """Sanitize a string value."""
        if not isinstance(value, str):
            return str(value)[:max_length]
        
        # Truncate to max length
        value = value[:max_length]
        
        # Remove null bytes
        value = value.replace('\x00', '')
        
        # Remove other control characters except newlines and tabs
        value = re.sub(r'[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]', '', value)
        
        return value
    
    @staticmethod
    def sanitize_model_id(model_id: str) -> str:
        """Sanitize model ID."""
        if not isinstance(model_id, str):
            return ""
        
        # Allow only safe characters
        return re.sub(r'[^a-zA-Z0-9\-_\.:/]', '', model_id)[:256]
    
    @staticmethod
    def sanitize_path(path: str) -> str:
        """Sanitize file path to prevent traversal."""
        if not isinstance(path, str):
            return ""
        
        # Remove path traversal sequences
        path = re.sub(r'\.\./', '', path)
        path = re.sub(r'\.\.\\', '', path)
        path = re.sub(r'%2e%2e%2f', '', path, flags=re.IGNORECASE)
        
        # Remove leading slashes
        path = path.lstrip('/\\')
        
        return path[:1024]
    
    @staticmethod
    def sanitize_url(url: str) -> Optional[str]:
        """Sanitize and validate URL."""
        if not isinstance(url, str):
            return None
        
        url = url.strip()[:2048]
        
        try:
            parsed = urlparse(url)
            
            # Only allow http/https
            if parsed.scheme not in ('http', 'https'):
                return None
            
            # Check for SSRF dangerous hosts
            if ValidationPatterns.SSRF_DANGEROUS.match(parsed.netloc):
                return None
            
            return url
        except Exception:
            return None
    
    @staticmethod
    def sanitize_for_logging(value: Any, max_length: int = 100) -> str:
        """Sanitize value for safe logging."""
        if value is None:
            return "None"
        
        s = str(value)
        
        # Remove sensitive patterns
        s = re.sub(r'(bearer|token|key|password|secret)\s*[:=]\s*\S+', '[REDACTED]', s, flags=re.IGNORECASE)
        
        # Truncate
        if len(s) > max_length:
            return s[:max_length] + "..."
        
        return s


# =============================================================================
# Request Validators
# =============================================================================

class RequestValidator:
    """Validates incoming requests."""
    
    def __init__(self, limits: SizeLimits = None):
        self.limits = limits or SizeLimits()
        self.sanitizer = InputSanitizer()
    
    def validate_content_length(self, content_length: Optional[int]) -> Optional[ValidationError]:
        """Validate Content-Length header."""
        if content_length is None:
            return None
        
        if content_length > self.limits.max_request_body:
            return ValidationError(
                error_type=ValidationErrorType.SIZE_EXCEEDED,
                field="Content-Length",
                message=f"Request body exceeds maximum size of {self.limits.max_request_body} bytes",
                value=str(content_length)
            )
        
        return None
    
    def validate_model_id(self, model_id: str) -> Optional[ValidationError]:
        """Validate model ID format."""
        if not model_id:
            return ValidationError(
                error_type=ValidationErrorType.MISSING_REQUIRED,
                field="model",
                message="Model ID is required"
            )
        
        if len(model_id) > self.limits.max_model_id_length:
            return ValidationError(
                error_type=ValidationErrorType.SIZE_EXCEEDED,
                field="model",
                message=f"Model ID exceeds maximum length of {self.limits.max_model_id_length}",
                value=self.sanitizer.sanitize_for_logging(model_id)
            )
        
        if not ValidationPatterns.MODEL_ID.match(model_id):
            return ValidationError(
                error_type=ValidationErrorType.INVALID_FORMAT,
                field="model",
                message="Model ID contains invalid characters",
                value=self.sanitizer.sanitize_for_logging(model_id)
            )
        
        return None
    
    def validate_messages(self, messages: List[Dict]) -> List[ValidationError]:
        """Validate messages array."""
        errors = []
        
        if not isinstance(messages, list):
            errors.append(ValidationError(
                error_type=ValidationErrorType.INVALID_FORMAT,
                field="messages",
                message="Messages must be an array"
            ))
            return errors
        
        if len(messages) > self.limits.max_messages_count:
            errors.append(ValidationError(
                error_type=ValidationErrorType.SIZE_EXCEEDED,
                field="messages",
                message=f"Messages array exceeds maximum of {self.limits.max_messages_count} items"
            ))
        
        valid_roles = {'system', 'user', 'assistant', 'tool', 'function'}
        
        for i, msg in enumerate(messages):
            if not isinstance(msg, dict):
                errors.append(ValidationError(
                    error_type=ValidationErrorType.INVALID_FORMAT,
                    field=f"messages[{i}]",
                    message="Message must be an object"
                ))
                continue
            
            role = msg.get('role')
            if role not in valid_roles:
                errors.append(ValidationError(
                    error_type=ValidationErrorType.INVALID_VALUE,
                    field=f"messages[{i}].role",
                    message=f"Invalid role: {self.sanitizer.sanitize_for_logging(role)}",
                    value=str(role)
                ))
            
            content = msg.get('content')
            if content:
                content_size = len(str(content).encode('utf-8'))
                if content_size > self.limits.max_single_message:
                    errors.append(ValidationError(
                        error_type=ValidationErrorType.SIZE_EXCEEDED,
                        field=f"messages[{i}].content",
                        message=f"Message content exceeds {self.limits.max_single_message} bytes"
                    ))
        
        return errors
    
    def _check_pattern(self, pattern: re.Pattern, error_type: ValidationErrorType, message: str, value: str) -> Optional[ValidationError]:
        """Check value against a security pattern."""
        if pattern.search(value):
            return ValidationError(
                error_type=error_type,
                field="input",
                message=message,
                value=self.sanitizer.sanitize_for_logging(value)
            )
        return None

    def check_sql_injection(self, value: str) -> Optional[ValidationError]:
        """Check for SQL injection patterns."""
        return self._check_pattern(ValidationPatterns.SQL_INJECTION, ValidationErrorType.INJECTION_DETECTED, "Potential SQL injection detected", value)

    def check_nosql_injection(self, value: str) -> Optional[ValidationError]:
        """Check for NoSQL injection patterns."""
        return self._check_pattern(ValidationPatterns.NOSQL_INJECTION, ValidationErrorType.INJECTION_DETECTED, "Potential NoSQL injection detected", value)

    def check_path_traversal(self, value: str) -> Optional[ValidationError]:
        """Check for path traversal attempts."""
        return self._check_pattern(ValidationPatterns.PATH_TRAVERSAL, ValidationErrorType.PATH_TRAVERSAL, "Path traversal attempt detected", value)
    
    def validate_url_safe(self, url: str) -> Optional[ValidationError]:
        """Validate URL is safe (no SSRF)."""
        if not url:
            return None
        
        try:
            parsed = urlparse(url)
            
            # Check scheme
            if parsed.scheme not in ('http', 'https'):
                return ValidationError(
                    error_type=ValidationErrorType.INVALID_VALUE,
                    field="url",
                    message="Only http/https URLs are allowed"
                )
            
            # Check for internal IPs
            hostname = parsed.hostname or ''
            
            # Check SSRF patterns
            if ValidationPatterns.SSRF_DANGEROUS.match(hostname):
                return ValidationError(
                    error_type=ValidationErrorType.SSRF_ATTEMPT,
                    field="url",
                    message="Internal URLs are not allowed"
                )
            
            # Try to resolve as IP
            try:
                ip = ipaddress.ip_address(hostname)
                if ip.is_private or ip.is_loopback or ip.is_reserved:
                    return ValidationError(
                        error_type=ValidationErrorType.SSRF_ATTEMPT,
                        field="url",
                        message="Private/reserved IP addresses are not allowed"
                    )
            except ValueError:
                pass  # Not an IP, hostname is fine
            
        except Exception:
            return ValidationError(
                error_type=ValidationErrorType.INVALID_FORMAT,
                field="url",
                message="Invalid URL format"
            )
        
        return None
    
    def validate_numeric_range(
        self,
        value: Any,
        field: str,
        min_val: float = None,
        max_val: float = None
    ) -> Optional[ValidationError]:
        """Validate numeric value is within range."""
        if value is None:
            return None
        
        try:
            num = float(value)
        except (TypeError, ValueError):
            return ValidationError(
                error_type=ValidationErrorType.INVALID_VALUE,
                field=field,
                message=f"{field} must be a number"
            )
        
        if min_val is not None and num < min_val:
            return ValidationError(
                error_type=ValidationErrorType.INVALID_VALUE,
                field=field,
                message=f"{field} must be >= {min_val}"
            )
        
        if max_val is not None and num > max_val:
            return ValidationError(
                error_type=ValidationErrorType.INVALID_VALUE,
                field=field,
                message=f"{field} must be <= {max_val}"
            )
        
        return None


# =============================================================================
# Chat Completion Request Validation
# =============================================================================

class ChatCompletionValidator:
    """Validates chat completion requests."""
    
    def __init__(self, validator: RequestValidator = None):
        self.validator = validator or RequestValidator()
    
    def validate(self, body: Dict[str, Any]) -> List[ValidationError]:
        """Validate chat completion request body."""
        errors = []
        
        # Model validation
        model_error = self.validator.validate_model_id(body.get('model', ''))
        if model_error:
            errors.append(model_error)
        
        # Messages validation
        messages = body.get('messages')
        if messages is None:
            errors.append(ValidationError(
                error_type=ValidationErrorType.MISSING_REQUIRED,
                field="messages",
                message="Messages array is required"
            ))
        else:
            errors.extend(self.validator.validate_messages(messages))
        
        # Temperature validation
        temp_error = self.validator.validate_numeric_range(
            body.get('temperature'), 'temperature', 0.0, 2.0
        )
        if temp_error:
            errors.append(temp_error)
        
        # Top_p validation
        top_p_error = self.validator.validate_numeric_range(
            body.get('top_p'), 'top_p', 0.0, 1.0
        )
        if top_p_error:
            errors.append(top_p_error)
        
        # Max_tokens validation
        max_tokens_error = self.validator.validate_numeric_range(
            body.get('max_tokens'), 'max_tokens', 1, 128000
        )
        if max_tokens_error:
            errors.append(max_tokens_error)
        
        # N validation
        n_error = self.validator.validate_numeric_range(
            body.get('n'), 'n', 1, 128
        )
        if n_error:
            errors.append(n_error)
        
        # Tools validation
        tools = body.get('tools')
        if tools and len(tools) > self.validator.limits.max_tools_count:
            errors.append(ValidationError(
                error_type=ValidationErrorType.SIZE_EXCEEDED,
                field="tools",
                message=f"Tools array exceeds maximum of {self.validator.limits.max_tools_count}"
            ))
        
        return errors


# =============================================================================
# Validation Middleware
# =============================================================================

class ValidationMiddleware(BaseHTTPMiddleware):
    """FastAPI middleware for request validation."""
    
    def __init__(self, app, limits: SizeLimits = None):
        super().__init__(app)
        self.limits = limits or SizeLimits()
        self.validator = RequestValidator(self.limits)
        self.chat_validator = ChatCompletionValidator(self.validator)
    
    async def dispatch(self, request: Request, call_next):
        """Process request through validation."""
        errors = []
        
        # Validate Content-Length
        content_length = request.headers.get('content-length')
        if content_length:
            try:
                length = int(content_length)
                error = self.validator.validate_content_length(length)
                if error:
                    errors.append(error)
            except ValueError:
                pass
        
        # Validate path for traversal
        path_error = self.validator.check_path_traversal(request.url.path)
        if path_error:
            errors.append(path_error)
        
        # Return early if header validation fails
        if errors:
            return self._error_response(errors, 400)
        
        # For POST/PUT/PATCH, validate body
        if request.method in ('POST', 'PUT', 'PATCH'):
            try:
                body = await request.json()
                
                # Endpoint-specific validation
                path = request.url.path
                
                if '/chat/completions' in path:
                    errors.extend(self.chat_validator.validate(body))
                elif '/embeddings' in path:
                    errors.extend(self._validate_embeddings(body))
                
            except Exception as e:
                logger.debug("Request body parsing skipped: %s", e)
        
        if errors:
            return self._error_response(errors, 400)
        
        return await call_next(request)
    
    def _validate_embeddings(self, body: Dict) -> List[ValidationError]:
        """Validate embeddings request."""
        errors = []
        
        model_error = self.validator.validate_model_id(body.get('model', ''))
        if model_error:
            errors.append(model_error)
        
        input_data = body.get('input')
        if input_data is None:
            errors.append(ValidationError(
                error_type=ValidationErrorType.MISSING_REQUIRED,
                field="input",
                message="Input is required"
            ))
        
        return errors
    
    def _error_response(self, errors: List[ValidationError], status_code: int) -> JSONResponse:
        """Create error response."""
        return JSONResponse(
            status_code=status_code,
            content={
                "error": {
                    "message": "Request validation failed",
                    "type": "invalid_request_error",
                    "code": "validation_error",
                    "details": [
                        {
                            "type": e.error_type.value,
                            "field": e.field,
                            "message": e.message,
                        }
                        for e in errors
                    ]
                }
            }
        )


# =============================================================================
# Factory Functions
# =============================================================================

def create_validation_middleware(
    limits: SizeLimits = None
) -> ValidationMiddleware:
    """Create validation middleware with custom limits."""
    return ValidationMiddleware(None, limits)


def get_default_limits() -> SizeLimits:
    """Get default size limits."""
    return SizeLimits()


def validate_chat_request(body: Dict[str, Any]) -> List[ValidationError]:
    """Validate a chat completion request."""
    validator = ChatCompletionValidator()
    return validator.validate(body)