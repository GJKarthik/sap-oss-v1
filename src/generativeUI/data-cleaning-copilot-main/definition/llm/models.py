# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Pydantic models for LLM module."""

from __future__ import annotations

import os
from typing import Dict, List, Optional, Any, Tuple
from enum import Enum
from pydantic import BaseModel, Field, ConfigDict, field_serializer
import pandera.pandas as pa


class LLMProvider(str, Enum):
    """Supported LLM providers."""

    ANTHROPIC_CLAUDE_3_7 = "anthropic--claude-3.7-sonnet"
    ANTHROPIC_CLAUDE_4 = "anthropic--claude-4-sonnet"


class MessageRole(str, Enum):
    """Message roles in conversation."""

    SYSTEM = "system"
    USER = "user"
    ASSISTANT = "assistant"


class ConversationMessage(BaseModel):
    """A single message in a conversation."""

    model_config = ConfigDict(frozen=True)

    role: MessageRole
    content: str  # Original user text or extracted assistant text
    timestamp: Optional[str] = None


class LLMSessionConfig(BaseModel):
    """Configuration for an LLM session."""

    model_config = ConfigDict(frozen=True)

    model_name: str = Field(default=LLMProvider.ANTHROPIC_CLAUDE_3_7)
    temperature: float = Field(default=0.1, ge=0.0, le=2.0)
    max_tokens: int = Field(default=2048, gt=0)
    system_message: Optional[str] = None
    deployment_id: Optional[str] = None

    # SAP Gen AI Hub specific settings - load from env vars if not provided
    base_url: Optional[str] = Field(default_factory=lambda: os.getenv("AICORE_BASE_URL"))
    auth_url: Optional[str] = Field(default_factory=lambda: os.getenv("AICORE_AUTH_URL"))
    client_id: Optional[str] = Field(default_factory=lambda: os.getenv("AICORE_CLIENT_ID"))
    client_secret: Optional[str] = Field(default_factory=lambda: os.getenv("AICORE_CLIENT_SECRET"))
    resource_group: Optional[str] = Field(default_factory=lambda: os.getenv("AICORE_RESOURCE_GROUP", "default"))


class TableSchema(BaseModel):
    """Schema information for a database table."""

    name: str
    table_schema_json: pa.DataFrameSchema
    primary_keys: List[str] = Field(default_factory=list)
    foreign_keys: Dict[str, Tuple[str, str]] = Field(default_factory=dict)  # column -> (referenced_table, column)

    @field_serializer("table_schema_json")
    def serialize_schema(self, schema: pa.DataFrameSchema) -> str:
        """Serialize DataFrameSchema to JSON string."""
        return schema.to_json()


class LLMResponse(BaseModel):
    """Response from an LLM session."""

    model_config = ConfigDict(frozen=True)

    session_id: str
    output: Any  # Can be string for unstructured output, BaseModel/dict for structured output


class SessionInfo(BaseModel):
    """Information about an LLM session."""

    model_config = ConfigDict(frozen=True)

    session_id: str
    config: LLMSessionConfig
    created_at: str
    message_count: int = 0
    last_activity: Optional[str] = None
