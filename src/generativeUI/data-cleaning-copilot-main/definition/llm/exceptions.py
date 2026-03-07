# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Custom exceptions for the LLM module."""


class LLMModuleError(Exception):
    """Base exception for all LLM module errors."""

    pass


class SessionNotFoundError(LLMModuleError):
    """Raised when trying to access a non-existent session."""

    def __init__(self, session_id: str):
        super().__init__(f"Session '{session_id}' not found")
        self.session_id = session_id


class SessionAlreadyExistsError(LLMModuleError):
    """Raised when trying to create a session with an ID that already exists."""

    def __init__(self, session_id: str):
        super().__init__(f"Session '{session_id}' already exists")
        self.session_id = session_id


class LLMProviderError(LLMModuleError):
    """Raised when there's an issue with the LLM provider (e.g., API errors)."""

    def __init__(self, message: str, provider: str = None, original_error: Exception = None):
        super().__init__(message)
        self.provider = provider
        self.original_error = original_error


class InvalidConfigurationError(LLMModuleError):
    """Raised when session configuration is invalid."""

    def __init__(self, message: str, config_field: str = None):
        super().__init__(message)
        self.config_field = config_field


class StructuredOutputError(LLMModuleError):
    """Raised when there's an issue with structured output parsing."""

    def __init__(self, message: str, raw_output: str = None):
        super().__init__(message)
        self.raw_output = raw_output


class AuthenticationError(LLMModuleError):
    """Raised when authentication with LLM provider fails."""

    def __init__(self, message: str, provider: str = None):
        super().__init__(message)
        self.provider = provider
