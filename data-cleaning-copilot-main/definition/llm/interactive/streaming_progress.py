"""Thread-safe progress collector for real-time streaming."""

import threading
from typing import Optional, Dict, Any, List


class StreamingProgressCollector:
    """Progress collector with thread-safe streaming support."""

    def __init__(self):
        self.lines: List[str] = []
        self._lock = threading.Lock()
        self._update_event = threading.Event()
        self.executed_queries: List[Dict[str, Any]] = []  # Store executed queries

    def on_iteration_start(self, iteration: int) -> None:
        """Called when a new iteration starts."""
        with self._lock:
            self.lines.append(f"**Iteration {iteration}**")
            self._update_event.set()

    def on_tool_call(self, tool_name: str, params: Optional[Dict[str, Any]] = None) -> None:
        """Called when agent makes a tool call."""
        with self._lock:
            if params and any(v is not None for v in params.values()):
                param_str = ", ".join(f"{k}={v}" for k, v in params.items() if v is not None)
                line = f"  - Calling {tool_name}({param_str})"
            else:
                line = f"  - Calling {tool_name}()"
            self.lines.append(line)
            self._update_event.set()

    def on_tool_result(self, tool_name: str, result_summary: str) -> None:
        """Called when tool call returns a result."""
        with self._lock:
            self.lines.append(f"    Result: {result_summary}")
            self._update_event.set()

    def on_items_generated(self, item_type: str, count: int, names: Optional[list] = None) -> None:
        """Called when new items are generated."""
        with self._lock:
            self.lines.append(f"  - Generated {count} {item_type}")
            if names:
                for name in names[:3]:
                    self.lines.append(f"    - {name}")
                if len(names) > 3:
                    self.lines.append(f"    - ... and {len(names) - 3} more")
            self._update_event.set()

    def on_completion(self, total_generated: int) -> None:
        """Called when agent completes."""
        with self._lock:
            self.lines.append(f"**Completed**: Generated {total_generated} items total")
            self._update_event.set()

    def on_error(self, error: str) -> None:
        """Called when an error occurs."""
        with self._lock:
            self.lines.append(f"**Error**: {error}")
            self._update_event.set()

    def on_query_executed(self, query_name: str, query_json: Dict[str, Any]) -> None:
        """Called when an ExecuteQuery is performed."""
        with self._lock:
            self.executed_queries.append({"name": query_name, "query": query_json})
            self.lines.append(f"  - Executed query: {query_name}")
            self._update_event.set()

    def get_formatted_progress(self) -> str:
        """Get formatted progress as markdown."""
        with self._lock:
            return "\n\n".join(self.lines) if self.lines else "*No agent activity*"

    def wait_for_update(self, timeout: float = 0.1) -> bool:
        """Wait for an update with timeout. Returns True if update occurred."""
        result = self._update_event.wait(timeout)
        self._update_event.clear()
        return result

    def clear(self):
        """Clear all progress."""
        with self._lock:
            self.lines = []
            self._update_event.clear()
