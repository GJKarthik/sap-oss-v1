"""Pydantic models for agent function calls in interactive sessions."""

from typing import Literal, Optional
from pydantic import BaseModel, Field


class CheckGenerationV1(BaseModel):
    """Generate validation checks using CheckGenerationAgentV1 (without tools)."""

    type: Literal["check_generation_v1"] = "check_generation_v1"
    user_message: Optional[str] = Field(default=None, description="Optional user context for check generation")
    force_regenerate: bool = Field(default=False, description="Whether to regenerate existing checks")


class CheckGenerationV2(BaseModel):
    """Generate validation checks using CheckGenerationAgentV2 (with tools)."""

    type: Literal["check_generation_v2"] = "check_generation_v2"
    user_message: Optional[str] = Field(default=None, description="Optional user context for check generation")
    max_iterations: int = Field(default=100, description="Maximum number of iterations for the agent")
    force_regenerate: bool = Field(default=False, description="Whether to regenerate existing checks")


class CheckGenerationV3(BaseModel):
    """Generate validation checks using CheckGenerationAgentV3 (with intelligent routing)."""

    type: Literal["check_generation_v3"] = "check_generation_v3"
    user_message: Optional[str] = Field(default=None, description="Optional user context for check generation")
    max_iterations: int = Field(default=100, description="Maximum number of iterations for the agent")
    force_regenerate: bool = Field(default=False, description="Whether to regenerate existing checks")


class CorruptionGeneration(BaseModel):
    """Generate corruption strategies using CorruptionGenerationAgent."""

    type: Literal["corruption_generation"] = "corruption_generation"
    user_message: str = Field(description="User's requirement for corruption generation")
    num_iterations: int = Field(default=1, description="Number of generation iterations")
    force_regenerate: bool = Field(default=False, description="Whether to regenerate existing corruptors")
