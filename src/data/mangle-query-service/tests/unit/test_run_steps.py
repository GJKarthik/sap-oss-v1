"""
Unit Tests for Run Steps API (Part 2)

Day 24 Deliverable: 55 unit tests for OpenAI Run Steps API
"""

import pytest
from typing import Dict, Any

from openai.run_steps import (
    # Constants
    MAX_STREAM_BUFFER_SIZE,
    STREAM_KEEPALIVE_INTERVAL,
    # Enums
    RunStepType,
    RunStepStatus,
    ToolCallType,
    StreamEventType,
    # Models
    MessageCreationStepDetails,
    CodeInterpreterOutput,
    CodeInterpreterToolCall,
    FileSearchToolCall,
    FunctionToolCall,
    ToolCallsStepDetails,
    RunStepObject,
    RunStepListResponse,
    RunStepDelta,
    CreateThreadAndRunRequest,
    StreamEvent,
    RunStepErrorResponse,
    # Handlers
    RunStepsHandler,
    RunStreamHandler,
    AdvancedRunsHandler,
    # Utilities
    get_run_steps_handler,
    get_advanced_runs_handler,
    create_message_step_details,
    create_tool_calls_step_details,
    create_code_interpreter_tool_call,
    create_file_search_tool_call,
    create_function_tool_call,
    is_step_terminal,
    parse_stream_events,
)


# ========================================
# Enum Tests
# ========================================

class TestRunStepType:
    """Tests for RunStepType enum."""
    
    def test_message_creation(self):
        """Test message_creation type."""
        assert RunStepType.MESSAGE_CREATION.value == "message_creation"
    
    def test_tool_calls(self):
        """Test tool_calls type."""
        assert RunStepType.TOOL_CALLS.value == "tool_calls"


class TestRunStepStatus:
    """Tests for RunStepStatus enum."""
    
    def test_in_progress(self):
        """Test in_progress status."""
        assert RunStepStatus.IN_PROGRESS.value == "in_progress"
    
    def test_completed(self):
        """Test completed status."""
        assert RunStepStatus.COMPLETED.value == "completed"
    
    def test_failed(self):
        """Test failed status."""
        assert RunStepStatus.FAILED.value == "failed"
    
    def test_cancelled(self):
        """Test cancelled status."""
        assert RunStepStatus.CANCELLED.value == "cancelled"


class TestToolCallType:
    """Tests for ToolCallType enum."""
    
    def test_code_interpreter(self):
        """Test code_interpreter type."""
        assert ToolCallType.CODE_INTERPRETER.value == "code_interpreter"
    
    def test_file_search(self):
        """Test file_search type."""
        assert ToolCallType.FILE_SEARCH.value == "file_search"
    
    def test_function(self):
        """Test function type."""
        assert ToolCallType.FUNCTION.value == "function"


class TestStreamEventType:
    """Tests for StreamEventType enum."""
    
    def test_run_created(self):
        """Test run.created event."""
        assert StreamEventType.RUN_CREATED.value == "thread.run.created"
    
    def test_run_completed(self):
        """Test run.completed event."""
        assert StreamEventType.RUN_COMPLETED.value == "thread.run.completed"
    
    def test_step_created(self):
        """Test step.created event."""
        assert StreamEventType.RUN_STEP_CREATED.value == "thread.run.step.created"
    
    def test_done(self):
        """Test done event."""
        assert StreamEventType.DONE.value == "done"


# ========================================
# Model Tests
# ========================================

class TestMessageCreationStepDetails:
    """Tests for MessageCreationStepDetails."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        details = MessageCreationStepDetails(
            message_creation={"message_id": "msg_123"}
        )
        result = details.to_dict()
        assert result["type"] == "message_creation"
        assert result["message_creation"]["message_id"] == "msg_123"


class TestCodeInterpreterOutput:
    """Tests for CodeInterpreterOutput."""
    
    def test_logs_output(self):
        """Test logs output."""
        output = CodeInterpreterOutput(type="logs", logs="Hello world")
        result = output.to_dict()
        assert result["logs"] == "Hello world"
    
    def test_image_output(self):
        """Test image output."""
        output = CodeInterpreterOutput(
            type="image",
            image={"file_id": "file_123"}
        )
        result = output.to_dict()
        assert result["image"]["file_id"] == "file_123"


class TestCodeInterpreterToolCall:
    """Tests for CodeInterpreterToolCall."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        call = CodeInterpreterToolCall(
            id="call_123",
            code_interpreter={"input": "print('hello')"}
        )
        result = call.to_dict()
        assert result["id"] == "call_123"
        assert result["type"] == "code_interpreter"


class TestFileSearchToolCall:
    """Tests for FileSearchToolCall."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        call = FileSearchToolCall(
            id="call_456",
            file_search={"results": []}
        )
        result = call.to_dict()
        assert result["type"] == "file_search"


class TestFunctionToolCall:
    """Tests for FunctionToolCall."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        call = FunctionToolCall(
            id="call_789",
            function={"name": "get_weather", "arguments": "{}"}
        )
        result = call.to_dict()
        assert result["function"]["name"] == "get_weather"


class TestToolCallsStepDetails:
    """Tests for ToolCallsStepDetails."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        details = ToolCallsStepDetails(
            tool_calls=[{"id": "call_1", "type": "function"}]
        )
        result = details.to_dict()
        assert result["type"] == "tool_calls"
        assert len(result["tool_calls"]) == 1


class TestRunStepObject:
    """Tests for RunStepObject."""
    
    def test_required_fields(self):
        """Test required fields."""
        step = RunStepObject(
            id="step_123",
            thread_id="thread_456",
            run_id="run_789",
            assistant_id="asst_abc"
        )
        assert step.object == "thread.run.step"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        step = RunStepObject(
            id="step_123",
            thread_id="thread_456",
            run_id="run_789",
            assistant_id="asst_abc",
            status=RunStepStatus.COMPLETED.value
        )
        result = step.to_dict()
        assert result["status"] == "completed"


class TestRunStepListResponse:
    """Tests for RunStepListResponse."""
    
    def test_empty_list(self):
        """Test empty list."""
        response = RunStepListResponse()
        result = response.to_dict()
        assert result["object"] == "list"
        assert result["data"] == []


class TestRunStepDelta:
    """Tests for RunStepDelta."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        delta = RunStepDelta(id="step_123", delta={"step_details": {}})
        result = delta.to_dict()
        assert result["object"] == "thread.run.step.delta"


class TestCreateThreadAndRunRequest:
    """Tests for CreateThreadAndRunRequest."""
    
    def test_missing_assistant_id(self):
        """Test missing assistant_id validation."""
        request = CreateThreadAndRunRequest()
        errors = request.validate()
        assert any("assistant_id" in e for e in errors)
    
    def test_valid_request(self):
        """Test valid request."""
        request = CreateThreadAndRunRequest(assistant_id="asst_123")
        errors = request.validate()
        assert len(errors) == 0
    
    def test_temperature_bounds(self):
        """Test temperature validation."""
        request = CreateThreadAndRunRequest(assistant_id="asst_1", temperature=3.0)
        errors = request.validate()
        assert any("temperature" in e for e in errors)


class TestStreamEvent:
    """Tests for StreamEvent."""
    
    def test_to_sse(self):
        """Test SSE conversion."""
        event = StreamEvent(
            event=StreamEventType.RUN_CREATED.value,
            data={"id": "run_123"}
        )
        sse = event.to_sse()
        assert "event: thread.run.created" in sse
        assert '"id": "run_123"' in sse
    
    def test_done_event(self):
        """Test done event."""
        event = StreamEvent(event=StreamEventType.DONE.value)
        sse = event.to_sse()
        assert "[DONE]" in sse


class TestRunStepErrorResponse:
    """Tests for RunStepErrorResponse."""
    
    def test_error_with_code(self):
        """Test error with code."""
        response = RunStepErrorResponse("Step not found", code="step_not_found")
        result = response.to_dict()
        assert result["error"]["code"] == "step_not_found"


# ========================================
# Handler Tests
# ========================================

class TestRunStepsHandler:
    """Tests for RunStepsHandler."""
    
    def test_add_step(self):
        """Test adding a step."""
        handler = RunStepsHandler()
        result = handler.add_step(
            thread_id="thread_1",
            run_id="run_1",
            assistant_id="asst_1",
            step_type=RunStepType.MESSAGE_CREATION.value
        )
        assert result["id"].startswith("step_")
    
    def test_list_steps(self):
        """Test listing steps."""
        handler = RunStepsHandler()
        handler.add_step("thread_1", "run_1", "asst_1", RunStepType.MESSAGE_CREATION.value)
        handler.add_step("thread_1", "run_1", "asst_1", RunStepType.TOOL_CALLS.value)
        
        result = handler.list_steps("thread_1", "run_1")
        assert len(result["data"]) == 2
    
    def test_retrieve_step(self):
        """Test retrieving a step."""
        handler = RunStepsHandler()
        created = handler.add_step("thread_1", "run_1", "asst_1", RunStepType.MESSAGE_CREATION.value)
        
        result = handler.retrieve_step("thread_1", "run_1", created["id"])
        assert result["id"] == created["id"]
    
    def test_retrieve_nonexistent(self):
        """Test retrieving nonexistent step."""
        handler = RunStepsHandler()
        result = handler.retrieve_step("thread_1", "run_1", "step_nonexistent")
        assert "error" in result
    
    def test_complete_step(self):
        """Test completing a step."""
        handler = RunStepsHandler()
        created = handler.add_step("thread_1", "run_1", "asst_1", RunStepType.MESSAGE_CREATION.value)
        
        result = handler.complete_step("run_1", created["id"])
        assert result["status"] == "completed"
        assert "usage" in result
    
    def test_fail_step(self):
        """Test failing a step."""
        handler = RunStepsHandler()
        created = handler.add_step("thread_1", "run_1", "asst_1", RunStepType.MESSAGE_CREATION.value)
        
        result = handler.fail_step("run_1", created["id"], "rate_limit", "Too many requests")
        assert result["status"] == "failed"
        assert result["last_error"]["code"] == "rate_limit"


class TestRunStreamHandler:
    """Tests for RunStreamHandler."""
    
    def test_stream_run(self):
        """Test streaming run."""
        steps_handler = RunStepsHandler()
        stream_handler = RunStreamHandler(steps_handler)
        
        events = list(stream_handler.stream_run("thread_1", "run_1", "asst_1"))
        assert len(events) > 0
        assert any("thread.run.created" in e for e in events)
        assert any("[DONE]" in e for e in events)
    
    def test_stream_thread_and_run(self):
        """Test streaming thread and run creation."""
        steps_handler = RunStepsHandler()
        stream_handler = RunStreamHandler(steps_handler)
        
        request = CreateThreadAndRunRequest(assistant_id="asst_1")
        events = list(stream_handler.stream_thread_and_run(request))
        
        assert any("thread.created" in e for e in events)


class TestAdvancedRunsHandler:
    """Tests for AdvancedRunsHandler."""
    
    def test_create_thread_and_run(self):
        """Test creating thread and run."""
        handler = AdvancedRunsHandler()
        request = CreateThreadAndRunRequest(assistant_id="asst_123")
        
        result = handler.create_thread_and_run(request)
        assert "thread_id" in result
        assert result["assistant_id"] == "asst_123"
    
    def test_create_thread_and_run_streaming(self):
        """Test streaming thread and run creation."""
        handler = AdvancedRunsHandler()
        request = CreateThreadAndRunRequest(assistant_id="asst_123")
        
        events = list(handler.create_thread_and_run_streaming(request))
        assert len(events) > 0
    
    def test_list_run_steps(self):
        """Test listing run steps."""
        handler = AdvancedRunsHandler()
        handler.steps_handler.add_step("thread_1", "run_1", "asst_1", RunStepType.MESSAGE_CREATION.value)
        
        result = handler.list_run_steps("thread_1", "run_1")
        assert len(result["data"]) == 1


# ========================================
# Utility Function Tests
# ========================================

class TestUtilityFunctions:
    """Tests for utility functions."""
    
    def test_get_run_steps_handler(self):
        """Test factory function."""
        handler = get_run_steps_handler()
        assert isinstance(handler, RunStepsHandler)
    
    def test_get_advanced_runs_handler(self):
        """Test factory function."""
        handler = get_advanced_runs_handler()
        assert isinstance(handler, AdvancedRunsHandler)
    
    def test_create_message_step_details(self):
        """Test creating message step details."""
        details = create_message_step_details("msg_123")
        assert details["type"] == "message_creation"
        assert details["message_creation"]["message_id"] == "msg_123"
    
    def test_create_tool_calls_step_details(self):
        """Test creating tool calls step details."""
        details = create_tool_calls_step_details([{"id": "call_1"}])
        assert details["type"] == "tool_calls"
        assert len(details["tool_calls"]) == 1
    
    def test_create_code_interpreter_tool_call(self):
        """Test creating code interpreter call."""
        call = create_code_interpreter_tool_call(
            "call_1",
            "print('hello')",
            [{"type": "logs", "logs": "hello"}]
        )
        assert call["type"] == "code_interpreter"
    
    def test_create_file_search_tool_call(self):
        """Test creating file search call."""
        call = create_file_search_tool_call("call_2", [{"file_id": "file_1"}])
        assert call["type"] == "file_search"
    
    def test_create_function_tool_call(self):
        """Test creating function call."""
        call = create_function_tool_call("call_3", "get_weather", '{"city":"NYC"}')
        assert call["function"]["name"] == "get_weather"
    
    def test_is_step_terminal_completed(self):
        """Test terminal status detection."""
        assert is_step_terminal("completed") is True
        assert is_step_terminal("failed") is True
        assert is_step_terminal("in_progress") is False
    
    def test_parse_stream_events(self):
        """Test parsing stream events."""
        stream_data = 'event: thread.run.created\ndata: {"id": "run_1"}\n\n'
        events = parse_stream_events(stream_data)
        assert len(events) == 1
        assert events[0]["event"] == "thread.run.created"


class TestConstants:
    """Tests for constants."""
    
    def test_stream_buffer_size(self):
        """Test stream buffer size."""
        assert MAX_STREAM_BUFFER_SIZE == 1024 * 1024
    
    def test_keepalive_interval(self):
        """Test keepalive interval."""
        assert STREAM_KEEPALIVE_INTERVAL == 30


# ========================================
# Integration Tests
# ========================================

class TestIntegration:
    """Integration tests for run steps."""
    
    def test_full_step_lifecycle(self):
        """Test full step lifecycle."""
        handler = RunStepsHandler()
        
        # Add step
        step = handler.add_step(
            "thread_1", "run_1", "asst_1",
            RunStepType.MESSAGE_CREATION.value,
            create_message_step_details("msg_1")
        )
        assert step["status"] == "in_progress"
        
        # Complete step
        completed = handler.complete_step("run_1", step["id"])
        assert completed["status"] == "completed"
    
    def test_streaming_integration(self):
        """Test streaming integration."""
        handler = AdvancedRunsHandler()
        request = CreateThreadAndRunRequest(
            assistant_id="asst_123",
            model="gpt-4o",
            instructions="Be helpful"
        )
        
        events = list(handler.create_thread_and_run_streaming(request))
        
        # Should have thread created, run events, step events, done
        event_types = [e for e in events if "event:" in e]
        assert len(event_types) >= 4  # At minimum: thread.created, run.created, run.completed, done