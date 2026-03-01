# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2024 SAP SE
"""Callback interface for agent progress reporting."""

from typing import Protocol, Optional, Any, Dict


class AgentProgressCallback(Protocol):
    """Protocol for agent progress callbacks."""

    def on_iteration_start(self, iteration: int) -> None:
        """Called when a new iteration starts."""
        ...

    def on_tool_call(self, tool_name: str, params: Optional[Dict[str, Any]] = None) -> None:
        """Called when agent makes a tool call."""
        ...

    def on_tool_result(self, tool_name: str, result_summary: str) -> None:
        """Called when tool call returns a result."""
        ...

    def on_items_generated(self, item_type: str, count: int, names: Optional[list] = None) -> None:
        """Called when new items (checks/corruptors) are generated."""
        ...

    def on_completion(self, total_generated: int) -> None:
        """Called when agent completes."""
        ...

    def on_error(self, error: str) -> None:
        """Called when an error occurs."""
        ...
