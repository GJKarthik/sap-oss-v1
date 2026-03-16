"""
OpenAI-compatible Runs API (Part 2)

Day 24 Deliverable: Run Steps and advanced run features

Implements:
- GET /v1/threads/{thread_id}/runs/{run_id}/steps - List run steps
- GET /v1/threads/{thread_id}/runs/{run_id}/steps/{step_id} - Retrieve run step
- POST /v1/threads/runs - Create thread and run
- Streaming support for runs
"""

import time
import hashlib
import json
from enum import Enum
from typing import Dict, Any, Optional, List, Union, Generator
from dataclasses import dataclass, field


# ========================================
# Constants
# ========================================

MAX_STREAM_BUFFER_SIZE = 1024 * 1024  # 1MB
STREAM_KEEPALIVE_INTERVAL = 30  # seconds


# ========================================
# Enums
# ========================================

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


class ToolCallType(str, Enum):
    """Tool call types in run steps."""
    CODE_INTERPRETER = "code_interpreter"
    FILE_SEARCH = "file_search"
    FUNCTION = "function"


class StreamEventType(str, Enum):
    """Streaming event types."""
    THREAD_CREATED = "thread.created"
    RUN_CREATED = "thread.run.created"
    RUN_QUEUED = "thread.run.queued"
    RUN_IN_PROGRESS = "thread.run.in_progress"
    RUN_REQUIRES_ACTION = "thread.run.requires_action"
    RUN_COMPLETED = "thread.run.completed"
    RUN_INCOMPLETE = "thread.run.incomplete"
    RUN_FAILED = "thread.run.failed"
    RUN_CANCELLED = "thread.run.cancelled"
    RUN_EXPIRED = "thread.run.expired"
    RUN_STEP_CREATED = "thread.run.step.created"
    RUN_STEP_IN_PROGRESS = "thread.run.step.in_progress"
    RUN_STEP_COMPLETED = "thread.run.step.completed"
    RUN_STEP_FAILED = "thread.run.step.failed"
    RUN_STEP_CANCELLED = "thread.run.step.cancelled"
    RUN_STEP_EXPIRED = "thread.run.step.expired"
    RUN_STEP_DELTA = "thread.run.step.delta"
    MESSAGE_CREATED = "thread.message.created"
    MESSAGE_IN_PROGRESS = "thread.message.in_progress"
    MESSAGE_DELTA = "thread.message.delta"
    MESSAGE_COMPLETED = "thread.message.completed"
    MESSAGE_INCOMPLETE = "thread.message.incomplete"
    ERROR = "error"
    DONE = "done"


# ========================================
# Run Step Detail Models
# ========================================

@dataclass
class MessageCreationStepDetails:
    """Details for message creation step."""
    type: str = "message_creation"
    message_creation: Dict[str, str] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "message_creation": self.message_creation,
        }


@dataclass
class CodeInterpreterOutput:
    """Output from code interpreter."""
    type: str = "logs"  # logs or image
    logs: Optional[str] = None
    image: Optional[Dict[str, str]] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {"type": self.type}
        if self.type == "logs" and self.logs:
            result["logs"] = self.logs
        elif self.type == "image" and self.image:
            result["image"] = self.image
        return result


@dataclass
class CodeInterpreterToolCall:
    """Code interpreter tool call details."""
    id: str = ""
    type: str = "code_interpreter"
    code_interpreter: Dict[str, Any] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "id": self.id,
            "type": self.type,
            "code_interpreter": self.code_interpreter,
        }


@dataclass
class FileSearchToolCall:
    """File search tool call details."""
    id: str = ""
    type: str = "file_search"
    file_search: Dict[str, Any] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "id": self.id,
            "type": self.type,
            "file_search": self.file_search,
        }


@dataclass
class FunctionToolCall:
    """Function tool call details."""
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
class ToolCallsStepDetails:
    """Details for tool calls step."""
    type: str = "tool_calls"
    tool_calls: List[Dict[str, Any]] = field(default_factory=list)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "tool_calls": self.tool_calls,
        }


# ========================================
# Run Step Models
# ========================================

@dataclass
class RunStepObject:
    """Run step object."""
    id: str
    thread_id: str
    run_id: str
    assistant_id: str
    object: str = "thread.run.step"
    created_at: int = 0
    type: str = RunStepType.MESSAGE_CREATION.value
    status: str = RunStepStatus.IN_PROGRESS.value
    step_details: Optional[Dict[str, Any]] = None
    last_error: Optional[Dict[str, Any]] = None
    expired_at: Optional[int] = None
    cancelled_at: Optional[int] = None
    failed_at: Optional[int] = None
    completed_at: Optional[int] = None
    metadata: Optional[Dict[str, str]] = None
    usage: Optional[Dict[str, int]] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "id": self.id,
            "object": self.object,
            "created_at": self.created_at,
            "assistant_id": self.assistant_id,
            "thread_id": self.thread_id,
            "run_id": self.run_id,
            "type": self.type,
            "status": self.status,
        }
        
        optional_fields = [
            "step_details", "last_error", "expired_at", "cancelled_at",
            "failed_at", "completed_at", "metadata", "usage"
        ]
        
        for field_name in optional_fields:
            value = getattr(self, field_name)
            if value is not None:
                result[field_name] = value
        
        return result


@dataclass
class RunStepListResponse:
    """Response for list run steps."""
    object: str = "list"
    data: List[RunStepObject] = field(default_factory=list)
    first_id: Optional[str] = None
    last_id: Optional[str] = None
    has_more: bool = False
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "object": self.object,
            "data": [s.to_dict() for s in self.data],
            "first_id": self.first_id,
            "last_id": self.last_id,
            "has_more": self.has_more,
        }


@dataclass
class RunStepDelta:
    """Delta update for run step."""
    id: str = ""
    object: str = "thread.run.step.delta"
    delta: Dict[str, Any] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "id": self.id,
            "object": self.object,
            "delta": self.delta,
        }


# ========================================
# Thread and Run Combined Request
# ========================================

@dataclass
class CreateThreadAndRunRequest:
    """Request to create thread and run together."""
    assistant_id: str = ""
    thread: Optional[Dict[str, Any]] = None  # Thread configuration
    model: Optional[str] = None
    instructions: Optional[str] = None
    tools: Optional[List[Dict[str, Any]]] = None
    tool_resources: Optional[Dict[str, Any]] = None
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
        if self.temperature is not None and (self.temperature < 0 or self.temperature > 2):
            errors.append("temperature must be between 0 and 2")
        return errors


# ========================================
# Streaming Models
# ========================================

@dataclass
class StreamEvent:
    """Streaming event."""
    event: str = ""
    data: Optional[Dict[str, Any]] = None
    
    def to_sse(self) -> str:
        """Convert to SSE format."""
        if self.event == StreamEventType.DONE.value:
            return "event: done\ndata: [DONE]\n\n"
        data_str = json.dumps(self.data) if self.data else "{}"
        return f"event: {self.event}\ndata: {data_str}\n\n"


@dataclass 
class RunStepErrorResponse:
    """Error response for run step operations."""
    error: Dict[str, Any] = field(default_factory=dict)
    
    def __init__(self, message: str, type: str = "invalid_request_error", code: Optional[str] = None):
        self.error = {"message": message, "type": type}
        if code:
            self.error["code"] = code
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"error": self.error}


# ========================================
# Run Steps Handler
# ========================================

class RunStepsHandler:
    """Handler for run step operations."""
    
    def __init__(self, mock_mode: bool = True):
        """Initialize handler."""
        self.mock_mode = mock_mode
        # run_id -> {step_id -> step}
        self._steps: Dict[str, Dict[str, RunStepObject]] = {}
    
    def add_step(
        self,
        thread_id: str,
        run_id: str,
        assistant_id: str,
        step_type: str,
        step_details: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Add a step to a run."""
        step_id = f"step_{hashlib.md5(f'{time.time()}'.encode()).hexdigest()[:24]}"
        now = int(time.time())
        
        step = RunStepObject(
            id=step_id,
            thread_id=thread_id,
            run_id=run_id,
            assistant_id=assistant_id,
            created_at=now,
            type=step_type,
            status=RunStepStatus.IN_PROGRESS.value,
            step_details=step_details,
        )
        
        if run_id not in self._steps:
            self._steps[run_id] = {}
        self._steps[run_id][step_id] = step
        
        return step.to_dict()
    
    def list_steps(
        self,
        thread_id: str,
        run_id: str,
        limit: int = 20,
        order: str = "desc",
        after: Optional[str] = None,
        before: Optional[str] = None,
    ) -> Dict[str, Any]:
        """List run steps."""
        steps = list(self._steps.get(run_id, {}).values())
        
        # Filter by thread_id
        steps = [s for s in steps if s.thread_id == thread_id]
        
        # Sort
        steps = sorted(steps, key=lambda s: s.created_at, reverse=(order == "desc"))
        
        # Apply cursor pagination
        if after:
            found_idx = -1
            for i, step in enumerate(steps):
                if step.id == after:
                    found_idx = i
                    break
            if found_idx >= 0:
                steps = steps[found_idx + 1:]
        
        if before:
            found_idx = -1
            for i, step in enumerate(steps):
                if step.id == before:
                    found_idx = i
                    break
            if found_idx >= 0:
                steps = steps[:found_idx]
        
        has_more = len(steps) > limit
        steps = steps[:limit]
        
        return RunStepListResponse(
            data=steps,
            first_id=steps[0].id if steps else None,
            last_id=steps[-1].id if steps else None,
            has_more=has_more,
        ).to_dict()
    
    def retrieve_step(self, thread_id: str, run_id: str, step_id: str) -> Dict[str, Any]:
        """Retrieve a run step."""
        if step_id not in self._steps.get(run_id, {}):
            return RunStepErrorResponse(
                f"No run step found with id '{step_id}'",
                code="step_not_found"
            ).to_dict()
        
        step = self._steps[run_id][step_id]
        if step.thread_id != thread_id:
            return RunStepErrorResponse(
                f"Step thread_id mismatch",
                code="invalid_request"
            ).to_dict()
        
        return step.to_dict()
    
    def complete_step(self, run_id: str, step_id: str) -> Dict[str, Any]:
        """Complete a run step."""
        if step_id not in self._steps.get(run_id, {}):
            return RunStepErrorResponse(
                f"No run step found with id '{step_id}'",
                code="step_not_found"
            ).to_dict()
        
        step = self._steps[run_id][step_id]
        step.status = RunStepStatus.COMPLETED.value
        step.completed_at = int(time.time())
        step.usage = {"prompt_tokens": 50, "completion_tokens": 25, "total_tokens": 75}
        
        return step.to_dict()
    
    def fail_step(self, run_id: str, step_id: str, code: str, message: str) -> Dict[str, Any]:
        """Fail a run step."""
        if step_id not in self._steps.get(run_id, {}):
            return RunStepErrorResponse(
                f"No run step found with id '{step_id}'",
                code="step_not_found"
            ).to_dict()
        
        step = self._steps[run_id][step_id]
        step.status = RunStepStatus.FAILED.value
        step.failed_at = int(time.time())
        step.last_error = {"code": code, "message": message}
        
        return step.to_dict()


# ========================================
# Streaming Handler
# ========================================

class RunStreamHandler:
    """Handler for streaming run execution."""
    
    def __init__(self, run_steps_handler: RunStepsHandler):
        """Initialize handler."""
        self.steps_handler = run_steps_handler
    
    def stream_run(
        self,
        thread_id: str,
        run_id: str,
        assistant_id: str,
    ) -> Generator[str, None, None]:
        """Stream run events."""
        now = int(time.time())
        
        # Emit run created event
        yield StreamEvent(
            event=StreamEventType.RUN_CREATED.value,
            data={
                "id": run_id,
                "object": "thread.run",
                "created_at": now,
                "thread_id": thread_id,
                "assistant_id": assistant_id,
                "status": "queued",
            }
        ).to_sse()
        
        # Emit run queued -> in_progress
        yield StreamEvent(
            event=StreamEventType.RUN_IN_PROGRESS.value,
            data={
                "id": run_id,
                "object": "thread.run",
                "created_at": now,
                "thread_id": thread_id,
                "assistant_id": assistant_id,
                "status": "in_progress",
            }
        ).to_sse()
        
        # Create message step
        step = self.steps_handler.add_step(
            thread_id=thread_id,
            run_id=run_id,
            assistant_id=assistant_id,
            step_type=RunStepType.MESSAGE_CREATION.value,
            step_details={
                "type": "message_creation",
                "message_creation": {"message_id": f"msg_{hashlib.md5(str(now).encode()).hexdigest()[:24]}"}
            }
        )
        
        yield StreamEvent(
            event=StreamEventType.RUN_STEP_CREATED.value,
            data=step
        ).to_sse()
        
        # Complete step
        self.steps_handler.complete_step(run_id, step["id"])
        
        yield StreamEvent(
            event=StreamEventType.RUN_STEP_COMPLETED.value,
            data=self.steps_handler.retrieve_step(thread_id, run_id, step["id"])
        ).to_sse()
        
        # Emit run completed
        yield StreamEvent(
            event=StreamEventType.RUN_COMPLETED.value,
            data={
                "id": run_id,
                "object": "thread.run",
                "created_at": now,
                "thread_id": thread_id,
                "assistant_id": assistant_id,
                "status": "completed",
                "completed_at": int(time.time()),
            }
        ).to_sse()
        
        # Done
        yield StreamEvent(event=StreamEventType.DONE.value).to_sse()
    
    def stream_thread_and_run(
        self,
        request: CreateThreadAndRunRequest,
    ) -> Generator[str, None, None]:
        """Stream thread and run creation."""
        now = int(time.time())
        
        # Create thread
        thread_id = f"thread_{hashlib.md5(str(now).encode()).hexdigest()[:24]}"
        yield StreamEvent(
            event=StreamEventType.THREAD_CREATED.value,
            data={
                "id": thread_id,
                "object": "thread",
                "created_at": now,
            }
        ).to_sse()
        
        # Create and stream run
        run_id = f"run_{hashlib.md5(f'{now}_run'.encode()).hexdigest()[:24]}"
        for event in self.stream_run(thread_id, run_id, request.assistant_id):
            yield event


# ========================================
# Combined Handler
# ========================================

class AdvancedRunsHandler:
    """Advanced runs handler with steps and streaming."""
    
    def __init__(self, mock_mode: bool = True):
        """Initialize handler."""
        self.mock_mode = mock_mode
        self.steps_handler = RunStepsHandler(mock_mode=mock_mode)
        self.stream_handler = RunStreamHandler(self.steps_handler)
    
    def create_thread_and_run(self, request: CreateThreadAndRunRequest) -> Dict[str, Any]:
        """Create thread and run together."""
        errors = request.validate()
        if errors:
            return RunStepErrorResponse("; ".join(errors)).to_dict()
        
        now = int(time.time())
        thread_id = f"thread_{hashlib.md5(str(now).encode()).hexdigest()[:24]}"
        run_id = f"run_{hashlib.md5(f'{now}_run'.encode()).hexdigest()[:24]}"
        
        return {
            "id": run_id,
            "object": "thread.run",
            "created_at": now,
            "thread_id": thread_id,
            "assistant_id": request.assistant_id,
            "status": "in_progress" if self.mock_mode else "queued",
            "model": request.model or "gpt-4o",
            "instructions": request.instructions,
            "tools": request.tools or [],
            "metadata": request.metadata,
            "temperature": request.temperature,
            "top_p": request.top_p,
            "max_prompt_tokens": request.max_prompt_tokens,
            "max_completion_tokens": request.max_completion_tokens,
            "truncation_strategy": request.truncation_strategy or {"type": "auto"},
            "tool_choice": request.tool_choice,
            "parallel_tool_calls": request.parallel_tool_calls,
            "response_format": request.response_format,
        }
    
    def create_thread_and_run_streaming(
        self,
        request: CreateThreadAndRunRequest,
    ) -> Generator[str, None, None]:
        """Create thread and run with streaming."""
        errors = request.validate()
        if errors:
            yield StreamEvent(
                event=StreamEventType.ERROR.value,
                data={"error": {"message": "; ".join(errors)}}
            ).to_sse()
            return
        
        for event in self.stream_handler.stream_thread_and_run(request):
            yield event
    
    def list_run_steps(
        self,
        thread_id: str,
        run_id: str,
        **kwargs
    ) -> Dict[str, Any]:
        """List run steps."""
        return self.steps_handler.list_steps(thread_id, run_id, **kwargs)
    
    def retrieve_run_step(
        self,
        thread_id: str,
        run_id: str,
        step_id: str,
    ) -> Dict[str, Any]:
        """Retrieve a run step."""
        return self.steps_handler.retrieve_step(thread_id, run_id, step_id)


# ========================================
# Factory and Utilities
# ========================================

def get_run_steps_handler(mock_mode: bool = True) -> RunStepsHandler:
    """Factory function for run steps handler."""
    return RunStepsHandler(mock_mode=mock_mode)


def get_advanced_runs_handler(mock_mode: bool = True) -> AdvancedRunsHandler:
    """Factory function for advanced runs handler."""
    return AdvancedRunsHandler(mock_mode=mock_mode)


def create_message_step_details(message_id: str) -> Dict[str, Any]:
    """Create message creation step details."""
    return MessageCreationStepDetails(
        message_creation={"message_id": message_id}
    ).to_dict()


def create_tool_calls_step_details(tool_calls: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Create tool calls step details."""
    return ToolCallsStepDetails(tool_calls=tool_calls).to_dict()


def create_code_interpreter_tool_call(
    call_id: str,
    input_code: str,
    outputs: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """Create code interpreter tool call."""
    return CodeInterpreterToolCall(
        id=call_id,
        code_interpreter={"input": input_code, "outputs": outputs}
    ).to_dict()


def create_file_search_tool_call(
    call_id: str,
    results: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """Create file search tool call."""
    return FileSearchToolCall(
        id=call_id,
        file_search={"results": results}
    ).to_dict()


def create_function_tool_call(
    call_id: str,
    name: str,
    arguments: str,
    output: Optional[str] = None,
) -> Dict[str, Any]:
    """Create function tool call."""
    function = {"name": name, "arguments": arguments}
    if output is not None:
        function["output"] = output
    return FunctionToolCall(id=call_id, function=function).to_dict()


def is_step_terminal(status: str) -> bool:
    """Check if step status is terminal."""
    terminal = [
        RunStepStatus.COMPLETED.value,
        RunStepStatus.FAILED.value,
        RunStepStatus.CANCELLED.value,
        RunStepStatus.EXPIRED.value,
    ]
    return status in terminal


def parse_stream_events(stream_data: str) -> List[Dict[str, Any]]:
    """Parse SSE stream data into events."""
    events = []
    current_event = None
    current_data = None
    
    for line in stream_data.split('\n'):
        if line.startswith('event: '):
            current_event = line[7:]
        elif line.startswith('data: '):
            data_str = line[6:]
            if data_str == '[DONE]':
                current_data = None
            else:
                try:
                    current_data = json.loads(data_str)
                except json.JSONDecodeError:
                    current_data = data_str
        elif line == '' and current_event:
            events.append({"event": current_event, "data": current_data})
            current_event = None
            current_data = None
    
    return events


# ========================================
# Exports
# ========================================

__all__ = [
    # Constants
    "MAX_STREAM_BUFFER_SIZE",
    "STREAM_KEEPALIVE_INTERVAL",
    # Enums
    "RunStepType",
    "RunStepStatus",
    "ToolCallType",
    "StreamEventType",
    # Models
    "MessageCreationStepDetails",
    "CodeInterpreterOutput",
    "CodeInterpreterToolCall",
    "FileSearchToolCall",
    "FunctionToolCall",
    "ToolCallsStepDetails",
    "RunStepObject",
    "RunStepListResponse",
    "RunStepDelta",
    "CreateThreadAndRunRequest",
    "StreamEvent",
    "RunStepErrorResponse",
    # Handlers
    "RunStepsHandler",
    "RunStreamHandler",
    "AdvancedRunsHandler",
    # Utilities
    "get_run_steps_handler",
    "get_advanced_runs_handler",
    "create_message_step_details",
    "create_tool_calls_step_details",
    "create_code_interpreter_tool_call",
    "create_file_search_tool_call",
    "create_function_tool_call",
    "is_step_terminal",
    "parse_stream_events",
]