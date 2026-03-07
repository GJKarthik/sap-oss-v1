# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""LLM integration module for semantic-rdb-gen.

This module provides centralized LLM session management and database context
serialization for interacting with Large Language Models.

Key Components:
- LLMSessionManager: Central registry and management for LLM sessions
- Session management with conversation history and structured output support

Example Usage:
    ```python
    from definition.llm import LLMSessionManager
    from definition.impl.database.salt import Salt

    # Initialize database and manager
    db = Salt()
    db.load_table_data_from_csv("CUSTOMER", "data/customer.csv")
    manager = LLMSessionManager()

    # Create LLM session
    session_id = manager.register_session(
        config={
            "model_name": "anthropic--claude-4-sonnet",
            "temperature": 0.1,
            "base_url": "your-base-url",
            "auth_url": "your-auth-url",
            "client_id": "your-client-id",
            "client_secret": "your-client-secret"
        }
    )

    # Send message with database context (using direct method)
    context = db.to_llm_schema()
    response = manager.send_message(
        session_id,
        "Analyze the database schema for potential issues",
        context=context
    )

    print(response.content)

    # Clean up
    manager.delete_session(session_id)
    ```
"""

from .models import (
    # Configuration models
    LLMSessionConfig,
    LLMProvider,
    # Message models
    ConversationMessage,
    MessageRole,
    LLMResponse,
    SessionInfo,
    # Database context models
    TableSchema,
)
from .exceptions import (
    LLMModuleError,
    SessionNotFoundError,
    SessionAlreadyExistsError,
    LLMProviderError,
    InvalidConfigurationError,
    StructuredOutputError,
    AuthenticationError,
)

# Import session manager with error handling
try:
    from .session_manager import LLMSessionManager, LLMSession

    _HAS_SESSION_MANAGER = True
    _HAS_DATABASE_CONTEXT = True
except ImportError as e:
    print(f"Warning: Some LLM module features are unavailable due to dependency issues: {e}")
    _HAS_SESSION_MANAGER = False
    _HAS_DATABASE_CONTEXT = False

    # Create placeholder classes/functions
    class LLMSessionManager:
        def __init__(self):
            raise ImportError("LLMSessionManager requires additional dependencies. Check pandas/numpy compatibility.")

    class LLMSession:
        def __init__(self):
            raise ImportError("LLMSession requires additional dependencies. Check pandas/numpy compatibility.")


# Database context functions are now methods on Database, Table, and Check classes
def database_to_context(database, include_tables=None, include_checks=True, database_name=None):
    """Convenience wrapper for Database.to_llm_schema()."""
    if not _HAS_DATABASE_CONTEXT:
        raise ImportError("database_to_context requires additional dependencies. Check pandas/numpy compatibility.")
    return database.to_llm_schema(
        include_tables=include_tables, include_checks=include_checks, database_name=database_name
    )


def table_to_schema(table_name, table_class):
    """Convenience wrapper for Table.to_llm_schema()."""
    if not _HAS_DATABASE_CONTEXT:
        raise ImportError("table_to_schema requires additional dependencies. Check pandas/numpy compatibility.")
    return table_class.to_llm_schema(table_name)


def check_to_schema(check):
    """Convenience wrapper for Check.to_llm_schema()."""
    if not _HAS_DATABASE_CONTEXT:
        raise ImportError("check_to_schema requires additional dependencies. Check pandas/numpy compatibility.")
    return check.to_llm_schema()


def tables_to_context(database, table_names, context_name=None):
    """Convenience wrapper for Database.to_llm_schema()."""
    if not _HAS_DATABASE_CONTEXT:
        raise ImportError("tables_to_context requires additional dependencies. Check pandas/numpy compatibility.")
    return database.to_llm_schema(
        include_tables=table_names,
        include_checks=True,
        database_name=context_name or f"focused_context_{len(table_names)}_tables",
    )


def checks_to_context(checks):
    """Convenience wrapper for Check.to_llm_schema()."""
    if not _HAS_DATABASE_CONTEXT:
        raise ImportError("checks_to_context requires additional dependencies. Check pandas/numpy compatibility.")
    return [check.to_llm_schema() for check in checks]


# Convenience aliases
Manager = LLMSessionManager  # Shorter alias

__all__ = [
    # Core classes
    "LLMSessionManager",
    "LLMSession",
    "Manager",  # Alias
    # Database context functions
    "database_to_context",
    "table_to_schema",
    "check_to_schema",
    "tables_to_context",
    "checks_to_context",
    # Models
    "LLMSessionConfig",
    "LLMProvider",
    "ConversationMessage",
    "MessageRole",
    "LLMResponse",
    "SessionInfo",
    "TableSchema",
    # Exceptions
    "LLMModuleError",
    "SessionNotFoundError",
    "SessionAlreadyExistsError",
    "LLMProviderError",
    "InvalidConfigurationError",
    "StructuredOutputError",
    "AuthenticationError",
]

# Module metadata
__version__ = "0.1.0"
__author__ = "semantic-rdb-gen"
