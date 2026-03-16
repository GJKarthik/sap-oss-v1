"""
OpenAI-compatible Runs API (Part 1)

Day 23 Deliverable: Run execution and lifecycle management

Implements:
- POST /v1/threads/{thread_id}/runs - Create run
- GET /v1/threads/{thread_id}/runs - List runs
- GET /v1/threads/{thread_id}/runs/{run_id} - Retrieve run
- POST /v1/threads/{thread_id}/runs/{run_id} - Modify run
- POST /v1/threads/{thread_id}/runs/{run_id}/cancel - Cancel run
"""

import time
import hashlib
from enum import Enum
from typing import Dict, Any, Optional, List, Union
from dataclasses import dataclass, field


# ========================================
# Constants
# ========================================

MAX_INSTRUCTIONS_LENGTH = 256000
MAX_ADDITIONAL_INSTRUCTIONS_LENGTH = 256000
MAX_TOOL_OUTPUTS_PER_SUBMIT = 100
RUN_TIMEOUT_DEFAULT = 600  # 10 minutes


# ========================================
# Enums
# ========================================

class RunStatus(str, Enum):
    """Run lifecycle statuses."""
    QUEUED = "queued"
    IN_PROGRESS = "in_progress"
    REQUIRES_ACTION = "requires_action"
    CANCELLING = "cancelling"
    CANCELLED = "cancelled"
    FAILED = "failed"
    COMPLETED = "completed"
    INCOMPLETE = "incomplete"
    EXPIRED = "expired"


class RunStepType(str, Enum):
    """Run step types."""
    MESSAGE_CREATION = "message_creation"
    TOOL_CALLS = "tool_calls"


class RunStepStatus(str, Enum):
    """Run step statuses."""
    IN_PROGRESS = "in_progress"
    CANCELLED = "cancelled"
    FAILED = "failed"
    COMPLETED = "completed"
    EXPIRED = "expired"


class RequiredActionType(str, Enum):
    """Types of required actions."""
    SUBMIT_TOOL_OUTPUTS = "submit_tool_outputs"


class IncompleteReason(str, Enum):
    """Reasons for incomplete runs."""
    MAX_COMPLETION_TOKENS = "max_completion_tokens"
    MAX_PROMPT_TOKENS = "max_prompt_tokens"


# ========================================
# Tool Output Models
# ========================================

@dataclass
class ToolOutput:
    """Tool output for submission."""
    tool_call_id: str = ""
    output: str = ""
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "tool_call_id": self.tool_call_id,
            "output": self.output,
        }


@dataclass
class ToolCall:
    """Tool call requiring action."""
    id: str = ""
    type: str = "function"
    function: Dict[str, Any] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "id": self.id,
            "type": self.type,
            "function": self.function,
        }


@dataclass
class RequiredAction:
    """Action required from the user."""
    type: str = RequiredActionType.SUBMIT_TOOL_OUTPUTS.value
    submit_tool_outputs: Dict[str, List[Dict[str, Any]]] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "submit_tool_outputs": self.submit_tool_outputs,
        }


# ========================================
# Error and Usage Models
# ========================================

@dataclass
class LastError:
    """Last error information."""
    code: str = ""
    message: str = ""
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"code": self.code, "message": self.message}


@dataclass
class IncompleteDetails:
    """Details about incomplete runs."""
    reason: str = ""
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"reason": self.reason}


@dataclass
class RunUsage:
    """Token usage for a run."""
    completion_tokens: int = 0
    prompt_tokens: int = 0
    total_tokens: int = 0
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "completion_tokens": self.completion_tokens,
            "prompt_tokens": self.prompt_tokens,
            "total_tokens": self.total_tokens,
        }


@dataclass
class TruncationStrategy:
    """How to truncate thread context."""
    type: str = "auto"  # auto or last_messages
    last_messages: Optional[int] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {"type": self.type}
        if self.last_messages is not None:
            result["last_messages"] = self.last_messages
        return result


# ========================================
# Run Request Models
# ========================================

@dataclass
class CreateRunRequest:
    """Request to create a run."""
    assistant_id: str = ""
    model: Optional[str] = None
    instructions: Optional[str] = None
    additional_instructions: Optional[str] = None
    additional_messages: Optional[List[Dict[str, Any]]] = None
    tools: Optional[List[Dict[str, Any]]] = None
    metadata: Optional[Dict[str, str]] = None
    temperature: Optional[float] = None
    top_p: Optional[float] = None
    max_prompt_tokens: Optional[int] = None
    max_completion_tokens: Optional[int] = None
    truncation_strategy: Optional[Dict[str, Any]] = None
    tool_choice: Optional[Union[str, Dict[str, Any]]] = None
    parallel_tool_calls: bool = True
    response_format: Optional[Union[str, Dict[str, Any]]] = None
    stream: bool = False
    
    def validate(self) -> List[str]:
        """Validate the request."""
        errors = []
        
        if not self.assistant_id:
            errors.append("assistant_id is required")
        
        if self.instructions and len(self.instructions) > MAX_INSTRUCTIONS_LENGTH:
            errors.append(f"instructions must be {MAX_INSTRUCTIONS_LENGTH} characters or less")
        
        if self.additional_instructions and len(self.additional_instructions) > MAX_ADDITIONAL_INSTRUCTIONS_LENGTH:
            errors.append(f"additional_instructions must be {MAX_ADDITIONAL_INSTRUCTIONS_LENGTH} characters or less")
        
        if self.temperature is not None and (self.temperature < 0 or self.temperature > 2):
            errors.append("temperature must be between 0 and 2")
        
        if self.top_p is not None and (self.top_p < 0 or self.top_p > 1):
            errors.append("top_p must be between 0 and 1")
        
        return errors


@dataclass
class ModifyRunRequest:
    """Request to modify a run."""
    metadata: Optional[Dict[str, str]] = None
    
    def validate(self) -> List[str]:
        """Validate the request."""
        return []


@dataclass
class SubmitToolOutputsRequest:
    """Request to submit tool outputs."""
    tool_outputs: List[Dict[str, Any]] = field(default_factory=list)
    stream: bool = False
    
    def validate(self) -> List[str]:
        """Validate the request."""
        errors = []
        
        if not self.tool_outputs:
            errors.append("tool_outputs is required")
        elif len(self.tool_outputs) > MAX_TOOL_OUTPUTS_PER_SUBMIT:
            errors.append(f"tool_outputs cannot exceed {MAX_TOOL_OUTPUTS_PER_SUBMIT}")
        
        for i, output in enumerate(self.tool_outputs):
            if "tool_call_id" not in output:
                errors.append(f"tool_outputs[{i}].tool_call_id is required")
        
        return errors


# ========================================
# Run Object Model
# ========================================

@dataclass
class RunObject:
    """Run object response."""
    id: str
    thread_id: str
    assistant_id: str
    object: str = "thread.run"
    created_at: int = 0
    status: str = RunStatus.QUEUED.value
    required_action: Optional[Dict[str, Any]] = None
    last_error: Optional[Dict[str, Any]] = None
    expires_at: Optional[int] = None
    started_at: Optional[int] = None
    cancelled_at: Optional[int] = None
    failed_at: Optional[int] = None
    completed_at: Optional[int] = None
    incomplete_details: Optional[Dict[str, Any]] = None
    model: str = "gpt-4o"
    instructions: Optional[str] = None
    tools: List[Dict[str, Any]] = field(default_factory=list)
    metadata: Optional[Dict[str, str]] = None
    usage: Optional[Dict[str, int]] = None
    temperature: Optional[float] = None
    top_p: Optional[float] = None
    max_prompt_tokens: Optional[int] = None
    max_completion_tokens: Optional[int] = None
    truncation_strategy: Optional[Dict[str, Any]] = None
    tool_choice: Optional[Union[str, Dict[str, Any]]] = None
    parallel_tool_calls: bool = True
    response_format: Optional[Union[str, Dict[str, Any]]] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "id": self.id,
            "object": self.object,
            "created_at": self.created_at,
            "thread_id": self.thread_id,
            "assistant_id": self.assistant_id,
            "status": self.status,
            "model": self.model,
            "tools": self.tools,
            "parallel_tool_calls": self.parallel_tool_calls,
        }
        
        # Add optional fields
        optional_fields = [
            "required_action", "last_error", "expires_at", "started_at",
            "cancelled_at", "failed_at", "completed_at", "incomplete_details",
            "instructions", "metadata", "usage", "temperature", "top_p",
            "max_prompt_tokens", "max_completion_tokens", "truncation_strategy",
            "tool_choice", "response_format"
        ]
        
        for field_name in optional_fields:
            value = getattr(self, field_name)
            if value is not None:
                result[field_name] = value
        
        return result


@dataclass
class RunListResponse:
    """Response for list runs."""
    object: str = "list"
    data: List[RunObject] = field(default_factory=list)
    first_id: Optional[str] = None
    last_id: Optional[str] = None
    has_more: bool = False
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "object": self.object,
            "data": [r.to_dict() for r in self.data],
            "first_id": self.first_id,
            "last_id": self.last_id,
            "has_more": self.has_more,
        }


@dataclass
class RunErrorResponse:
    """Error response for run operations."""
    error: Dict[str, Any] = field(default_factory=dict)
    
    def __init__(self, message: str, type: str = "invalid_request_error", code: Optional[str] = None):
        self.error = {"message": message, "type": type}
        if code:
            self.error["code"] = code
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"error": self.error}


# ========================================
# Runs Handler
# ========================================

class RunsHandler:
    """Handler for run operations."""
    
    def __init__(self, mock_mode: bool = True):
        """Initialize handler."""
        self.mock_mode = mock_mode
        self._runs: Dict[str, Dict[str, RunObject]] = {}  # thread_id -> {run_id -> run}
        self._assistants: Dict[str, Dict[str, Any]] = {}  # mock assistant store
    
    def set_assistant(self, assistant_id: str, assistant: Dict[str, Any]) -> None:
        """Set assistant data for testing."""
        self._assistants[assistant_id] = assistant
    
    def create_run(self, thread_id: str, request: CreateRunRequest) -> Dict[str, Any]:
        """Create a new run."""
        errors = request.validate()
        if errors:
            return RunErrorResponse("; ".join(errors)).to_dict()
        
        # Check assistant exists (in mock mode, just allow any ID)
        if not self.mock_mode and request.assistant_id not in self._assistants:
            return RunErrorResponse(
                f"No assistant found with id '{request.assistant_id}'",
                code="assistant_not_found"
            ).to_dict()
        
        run_id = f"run_{hashlib.md5(f'{time.time()}'.encode()).hexdigest()[:24]}"
        now = int(time.time())
        
        # Get assistant data (or mock it)
        assistant = self._assistants.get(request.assistant_id, {
            "model": "gpt-4o",
            "instructions": None,
            "tools": [],
        })
        
        run = RunObject(
            id=run_id,
            thread_id=thread_id,
            assistant_id=request.assistant_id,
            created_at=now,
            status=RunStatus.QUEUED.value,
            expires_at=now + RUN_TIMEOUT_DEFAULT,
            model=request.model or assistant.get("model", "gpt-4o"),
            instructions=request.instructions or assistant.get("instructions"),
            tools=request.tools or assistant.get("tools", []),
            metadata=request.metadata,
            temperature=request.temperature,
            top_p=request.top_p,
            max_prompt_tokens=request.max_prompt_tokens,
            max_completion_tokens=request.max_completion_tokens,
            truncation_strategy=request.truncation_strategy,
            tool_choice=request.tool_choice,
            parallel_tool_calls=request.parallel_tool_calls,
            response_format=request.response_format,
        )
        
        if thread_id not in self._runs:
            self._runs[thread_id] = {}
        self._runs[thread_id][run_id] = run
        
        # Simulate immediate transition to in_progress (in mock mode)
        if self.mock_mode:
            run.status = RunStatus.IN_PROGRESS.value
            run.started_at = now
        
        return run.to_dict()
    
    def list_runs(
        self,
        thread_id: str,
        limit: int = 20,
        order: str = "desc",
        after: Optional[str] = None,
        before: Optional[str] = None,
    ) -> Dict[str, Any]:
        """List runs in a thread."""
        runs = list(self._runs.get(thread_id, {}).values())
        
        # Sort
        runs = sorted(runs, key=lambda r: r.created_at, reverse=(order == "desc"))
        
        # Apply cursor pagination
        if after:
            found_idx = -1
            for i, run in enumerate(runs):
                if run.id == after:
                    found_idx = i
                    break
            if found_idx >= 0:
                runs = runs[found_idx + 1:]
        
        if before:
            found_idx = -1
            for i, run in enumerate(runs):
                if run.id == before:
                    found_idx = i
                    break
            if found_idx >= 0:
                runs = runs[:found_idx]
        
        has_more = len(runs) > limit
        runs = runs[:limit]
        
        return RunListResponse(
            data=runs,
            first_id=runs[0].id if runs else None,
            last_id=runs[-1].id if runs else None,
            has_more=has_more,
        ).to_dict()
    
    def retrieve_run(self, thread_id: str, run_id: str) -> Dict[str, Any]:
        """Retrieve a run."""
        if run_id not in self._runs.get(thread_id, {}):
            return RunErrorResponse(
                f"No run found with id '{run_id}'",
                code="run_not_found"
            ).to_dict()
        return self._runs[thread_id][run_id].to_dict()
    
    def modify_run(self, thread_id: str, run_id: str, request: ModifyRunRequest) -> Dict[str, Any]:
        """Modify a run."""
        if run_id not in self._runs.get(thread_id, {}):
            return RunErrorResponse(
                f"No run found with id '{run_id}'",
                code="run_not_found"
            ).to_dict()
        
        run = self._runs[thread_id][run_id]
        
        if request.metadata is not None:
            run.metadata = request.metadata
        
        return run.to_dict()
    
    def cancel_run(self, thread_id: str, run_id: str) -> Dict[str, Any]:
        """Cancel a run."""
        if run_id not in self._runs.get(thread_id, {}):
            return RunErrorResponse(
                f"No run found with id '{run_id}'",
                code="run_not_found"
            ).to_dict()
        
        run = self._runs[thread_id][run_id]
        
        # Check if run can be cancelled
        cancellable_statuses = [RunStatus.QUEUED.value, RunStatus.IN_PROGRESS.value, RunStatus.REQUIRES_ACTION.value]
        if run.status not in cancellable_statuses:
            return RunErrorResponse(
                f"Run with status '{run.status}' cannot be cancelled",
                code="invalid_run_status"
            ).to_dict()
        
        run.status = RunStatus.CANCELLING.value
        
        # In mock mode, immediately complete cancellation
        if self.mock_mode:
            run.status = RunStatus.CANCELLED.value
            run.cancelled_at = int(time.time())
        
        return run.to_dict()
    
    def submit_tool_outputs(
        self,
        thread_id: str,
        run_id: str,
        request: SubmitToolOutputsRequest,
    ) -> Dict[str, Any]:
        """Submit tool outputs to a run."""
        if run_id not in self._runs.get(thread_id, {}):
            return RunErrorResponse(
                f"No run found with id '{run_id}'",
                code="run_not_found"
            ).to_dict()
        
        run = self._runs[thread_id][run_id]
        
        # Check if run requires action
        if run.status != RunStatus.REQUIRES_ACTION.value:
            return RunErrorResponse(
                f"Run does not require action (status: {run.status})",
                code="invalid_run_status"
            ).to_dict()
        
        errors = request.validate()
        if errors:
            return RunErrorResponse("; ".join(errors)).to_dict()
        
        # Clear required action and continue
        run.required_action = None
        run.status = RunStatus.IN_PROGRESS.value
        
        # In mock mode, complete the run
        if self.mock_mode:
            run.status = RunStatus.COMPLETED.value
            run.completed_at = int(time.time())
            run.usage = RunUsage(
                completion_tokens=150,
                prompt_tokens=200,
                total_tokens=350
            ).to_dict()
        
        return run.to_dict()
    
    def set_requires_action(
        self,
        thread_id: str,
        run_id: str,
        tool_calls: List[Dict[str, Any]],
    ) -> Dict[str, Any]:
        """Set a run to require action (for testing)."""
        if run_id not in self._runs.get(thread_id, {}):
            return RunErrorResponse(
                f"No run found with id '{run_id}'",
                code="run_not_found"
            ).to_dict()
        
        run = self._runs[thread_id][run_id]
        run.status = RunStatus.REQUIRES_ACTION.value
        run.required_action = {
            "type": RequiredActionType.SUBMIT_TOOL_OUTPUTS.value,
            "submit_tool_outputs": {"tool_calls": tool_calls}
        }
        
        return run.to_dict()
    
    def complete_run(self, thread_id: str, run_id: str) -> Dict[str, Any]:
        """Complete a run (for testing)."""
        if run_id not in self._runs.get(thread_id, {}):
            return RunErrorResponse(
                f"No run found with id '{run_id}'",
                code="run_not_found"
            ).to_dict()
        
        run = self._runs[thread_id][run_id]
        run.status = RunStatus.COMPLETED.value
        run.completed_at = int(time.time())
        run.usage = RunUsage(
            completion_tokens=100,
            prompt_tokens=150,
            total_tokens=250
        ).to_dict()
        
        return run.to_dict()
    
    def fail_run(self, thread_id: str, run_id: str, code: str, message: str) -> Dict[str, Any]:
        """Fail a run (for testing)."""
        if run_id not in self._runs.get(thread_id, {}):
            return RunErrorResponse(
                f"No run found with id '{run_id}'",
                code="run_not_found"
            ).to_dict()
        
        run = self._runs[thread_id][run_id]
        run.status = RunStatus.FAILED.value
        run.failed_at = int(time.time())
        run.last_error = LastError(code=code, message=message).to_dict()
        
        return run.to_dict()


# ========================================
# Factory and Utilities
# ========================================

def get_runs_handler(mock_mode: bool = True) -> RunsHandler:
    """Factory function to create runs handler."""
    return RunsHandler(mock_mode=mock_mode)


def create_run(thread_id: str, assistant_id: str, **kwargs) -> Dict[str, Any]:
    """Convenience function to create a run."""
    handler = get_runs_handler()
    request = CreateRunRequest(assistant_id=assistant_id, **kwargs)
    return handler.create_run(thread_id, request)


def is_run_terminal(status: str) -> bool:
    """Check if run status is terminal."""
    terminal_statuses = [
        RunStatus.CANCELLED.value,
        RunStatus.COMPLETED.value,
        RunStatus.FAILED.value,
        RunStatus.EXPIRED.value,
        RunStatus.INCOMPLETE.value,
    ]
    return status in terminal_statuses


def is_run_active(status: str) -> bool:
    """Check if run is still active."""
    active_statuses = [
        RunStatus.QUEUED.value,
        RunStatus.IN_PROGRESS.value,
        RunStatus.REQUIRES_ACTION.value,
        RunStatus.CANCELLING.value,
    ]
    return status in active_statuses


def can_cancel_run(status: str) -> bool:
    """Check if run can be cancelled."""
    cancellable_statuses = [
        RunStatus.QUEUED.value,
        RunStatus.IN_PROGRESS.value,
        RunStatus.REQUIRES_ACTION.value,
    ]
    return status in cancellable_statuses


def requires_tool_outputs(run: Dict[str, Any]) -> bool:
    """Check if run requires tool outputs."""
    return (
        run.get("status") == RunStatus.REQUIRES_ACTION.value and
        run.get("required_action", {}).get("type") == RequiredActionType.SUBMIT_TOOL_OUTPUTS.value
    )


def get_required_tool_calls(run: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Get required tool calls from a run."""
    if not requires_tool_outputs(run):
        return []
    return run.get("required_action", {}).get("submit_tool_outputs", {}).get("tool_calls", [])


def create_tool_output(tool_call_id: str, output: str) -> Dict[str, Any]:
    """Create a tool output object."""
    return ToolOutput(tool_call_id=tool_call_id, output=output).to_dict()


def estimate_run_cost(usage: Dict[str, int], model: str = "gpt-4o") -> float:
    """Estimate cost for a run based on usage."""
    # Simplified pricing (per 1M tokens)
    pricing = {
        "gpt-4o": {"input": 2.50, "output": 10.00},
        "gpt-4o-mini": {"input": 0.15, "output": 0.60},
        "gpt-4-turbo": {"input": 10.00, "output": 30.00},
    }
    
    model_pricing = pricing.get(model, pricing["gpt-4o"])
    prompt_cost = (usage.get("prompt_tokens", 0) / 1_000_000) * model_pricing["input"]
    completion_cost = (usage.get("completion_tokens", 0) / 1_000_000) * model_pricing["output"]
    
    return prompt_cost + completion_cost


# ========================================
# Exports
# ========================================

__all__ = [
    # Constants
    "MAX_INSTRUCTIONS_LENGTH",
    "MAX_ADDITIONAL_INSTRUCTIONS_LENGTH",
    "MAX_TOOL_OUTPUTS_PER_SUBMIT",
    "RUN_TIMEOUT_DEFAULT",
    # Enums
    "RunStatus",
    "RunStepType",
    "RunStepStatus",
    "RequiredActionType",
    "IncompleteReason",
    # Models
    "ToolOutput",
    "ToolCall",
    "RequiredAction",
    "LastError",
    "IncompleteDetails",
    "RunUsage",
    "TruncationStrategy",
    "CreateRunRequest",
    "ModifyRunRequest",
    "SubmitToolOutputsRequest",
    "RunObject",
    "RunListResponse",
    "RunErrorResponse",
    # Handler
    "RunsHandler",
    # Utilities
    "get_runs_handler",
    "create_run",
    "is_run_terminal",
    "is_run_active",
    "can_cancel_run",
    "requires_tool_outputs",
    "get_required_tool_calls",
    "create_tool_output",
    "estimate_run_cost",
]