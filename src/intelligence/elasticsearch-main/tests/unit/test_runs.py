"""
Unit Tests for Runs API (Part 1)

Day 23 Deliverable: 55 unit tests for OpenAI Runs API
"""

import pytest
from typing import Dict, Any

from openai.runs import (
    # Constants
    MAX_INSTRUCTIONS_LENGTH,
    MAX_ADDITIONAL_INSTRUCTIONS_LENGTH,
    MAX_TOOL_OUTPUTS_PER_SUBMIT,
    RUN_TIMEOUT_DEFAULT,
    # Enums
    RunStatus,
    RunStepType,
    RunStepStatus,
    RequiredActionType,
    IncompleteReason,
    # Models
    ToolOutput,
    ToolCall,
    RequiredAction,
    LastError,
    IncompleteDetails,
    RunUsage,
    TruncationStrategy,
    CreateRunRequest,
    ModifyRunRequest,
    SubmitToolOutputsRequest,
    RunObject,
    RunListResponse,
    RunErrorResponse,
    # Handler
    RunsHandler,
    # Utilities
    get_runs_handler,
    create_run,
    is_run_terminal,
    is_run_active,
    can_cancel_run,
    requires_tool_outputs,
    get_required_tool_calls,
    create_tool_output,
    estimate_run_cost,
)


# ========================================
# Enum Tests
# ========================================

class TestRunStatus:
    """Tests for RunStatus enum."""
    
    def test_queued_value(self):
        """Test queued status."""
        assert RunStatus.QUEUED.value == "queued"
    
    def test_in_progress_value(self):
        """Test in_progress status."""
        assert RunStatus.IN_PROGRESS.value == "in_progress"
    
    def test_requires_action_value(self):
        """Test requires_action status."""
        assert RunStatus.REQUIRES_ACTION.value == "requires_action"
    
    def test_completed_value(self):
        """Test completed status."""
        assert RunStatus.COMPLETED.value == "completed"
    
    def test_cancelled_value(self):
        """Test cancelled status."""
        assert RunStatus.CANCELLED.value == "cancelled"
    
    def test_failed_value(self):
        """Test failed status."""
        assert RunStatus.FAILED.value == "failed"


class TestRunStepType:
    """Tests for RunStepType enum."""
    
    def test_message_creation(self):
        """Test message_creation type."""
        assert RunStepType.MESSAGE_CREATION.value == "message_creation"
    
    def test_tool_calls(self):
        """Test tool_calls type."""
        assert RunStepType.TOOL_CALLS.value == "tool_calls"


class TestRequiredActionType:
    """Tests for RequiredActionType enum."""
    
    def test_submit_tool_outputs(self):
        """Test submit_tool_outputs type."""
        assert RequiredActionType.SUBMIT_TOOL_OUTPUTS.value == "submit_tool_outputs"


# ========================================
# Model Tests
# ========================================

class TestToolOutput:
    """Tests for ToolOutput."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        output = ToolOutput(tool_call_id="call_123", output="result data")
        result = output.to_dict()
        assert result["tool_call_id"] == "call_123"
        assert result["output"] == "result data"


class TestToolCall:
    """Tests for ToolCall."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        call = ToolCall(
            id="call_abc",
            type="function",
            function={"name": "get_weather", "arguments": '{"city":"NYC"}'}
        )
        result = call.to_dict()
        assert result["id"] == "call_abc"
        assert result["function"]["name"] == "get_weather"


class TestRequiredAction:
    """Tests for RequiredAction."""
    
    def test_default_type(self):
        """Test default type."""
        action = RequiredAction()
        assert action.type == "submit_tool_outputs"


class TestLastError:
    """Tests for LastError."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        error = LastError(code="rate_limit_exceeded", message="Too many requests")
        result = error.to_dict()
        assert result["code"] == "rate_limit_exceeded"


class TestRunUsage:
    """Tests for RunUsage."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        usage = RunUsage(prompt_tokens=100, completion_tokens=50, total_tokens=150)
        result = usage.to_dict()
        assert result["total_tokens"] == 150


class TestTruncationStrategy:
    """Tests for TruncationStrategy."""
    
    def test_default_type(self):
        """Test default type is auto."""
        strategy = TruncationStrategy()
        assert strategy.type == "auto"
    
    def test_with_last_messages(self):
        """Test with last_messages."""
        strategy = TruncationStrategy(type="last_messages", last_messages=10)
        result = strategy.to_dict()
        assert result["last_messages"] == 10


# ========================================
# Request Model Tests
# ========================================

class TestCreateRunRequest:
    """Tests for CreateRunRequest."""
    
    def test_missing_assistant_id(self):
        """Test missing assistant_id validation."""
        request = CreateRunRequest()
        errors = request.validate()
        assert any("assistant_id" in e for e in errors)
    
    def test_valid_request(self):
        """Test valid request."""
        request = CreateRunRequest(assistant_id="asst_123")
        errors = request.validate()
        assert len(errors) == 0
    
    def test_temperature_bounds(self):
        """Test temperature validation."""
        request = CreateRunRequest(assistant_id="asst_123", temperature=2.5)
        errors = request.validate()
        assert any("temperature" in e for e in errors)
    
    def test_top_p_bounds(self):
        """Test top_p validation."""
        request = CreateRunRequest(assistant_id="asst_123", top_p=1.5)
        errors = request.validate()
        assert any("top_p" in e for e in errors)


class TestModifyRunRequest:
    """Tests for ModifyRunRequest."""
    
    def test_empty_valid(self):
        """Test empty request is valid."""
        request = ModifyRunRequest()
        errors = request.validate()
        assert len(errors) == 0


class TestSubmitToolOutputsRequest:
    """Tests for SubmitToolOutputsRequest."""
    
    def test_empty_outputs(self):
        """Test empty tool_outputs fails."""
        request = SubmitToolOutputsRequest()
        errors = request.validate()
        assert any("tool_outputs" in e for e in errors)
    
    def test_missing_tool_call_id(self):
        """Test missing tool_call_id fails."""
        request = SubmitToolOutputsRequest(tool_outputs=[{"output": "data"}])
        errors = request.validate()
        assert any("tool_call_id" in e for e in errors)
    
    def test_valid_outputs(self):
        """Test valid tool outputs."""
        request = SubmitToolOutputsRequest(
            tool_outputs=[{"tool_call_id": "call_1", "output": "data"}]
        )
        errors = request.validate()
        assert len(errors) == 0


# ========================================
# Response Model Tests
# ========================================

class TestRunObject:
    """Tests for RunObject."""
    
    def test_required_fields(self):
        """Test required fields."""
        run = RunObject(id="run_123", thread_id="thread_456", assistant_id="asst_789")
        assert run.id == "run_123"
        assert run.object == "thread.run"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        run = RunObject(
            id="run_123",
            thread_id="thread_456",
            assistant_id="asst_789",
            status=RunStatus.COMPLETED.value
        )
        result = run.to_dict()
        assert result["status"] == "completed"


class TestRunListResponse:
    """Tests for RunListResponse."""
    
    def test_empty_list(self):
        """Test empty list."""
        response = RunListResponse()
        result = response.to_dict()
        assert result["object"] == "list"
        assert result["data"] == []


class TestRunErrorResponse:
    """Tests for RunErrorResponse."""
    
    def test_error_with_code(self):
        """Test error with code."""
        response = RunErrorResponse("Run not found", code="run_not_found")
        result = response.to_dict()
        assert result["error"]["code"] == "run_not_found"


# ========================================
# Handler Tests
# ========================================

class TestRunsHandler:
    """Tests for RunsHandler."""
    
    def test_create_run(self):
        """Test creating a run."""
        handler = RunsHandler()
        request = CreateRunRequest(assistant_id="asst_123")
        result = handler.create_run("thread_456", request)
        assert "id" in result
        assert result["id"].startswith("run_")
    
    def test_create_run_with_overrides(self):
        """Test creating run with parameter overrides."""
        handler = RunsHandler()
        request = CreateRunRequest(
            assistant_id="asst_123",
            model="gpt-4-turbo",
            temperature=0.5
        )
        result = handler.create_run("thread_456", request)
        assert result["model"] == "gpt-4-turbo"
        assert result["temperature"] == 0.5
    
    def test_list_runs(self):
        """Test listing runs."""
        handler = RunsHandler()
        thread_id = "thread_123"
        
        # Create multiple runs
        for _ in range(3):
            handler.create_run(thread_id, CreateRunRequest(assistant_id="asst_1"))
        
        result = handler.list_runs(thread_id)
        assert len(result["data"]) == 3
    
    def test_retrieve_run(self):
        """Test retrieving a run."""
        handler = RunsHandler()
        created = handler.create_run("thread_1", CreateRunRequest(assistant_id="asst_1"))
        
        result = handler.retrieve_run("thread_1", created["id"])
        assert result["id"] == created["id"]
    
    def test_retrieve_nonexistent(self):
        """Test retrieving nonexistent run."""
        handler = RunsHandler()
        result = handler.retrieve_run("thread_1", "run_nonexistent")
        assert "error" in result
    
    def test_modify_run(self):
        """Test modifying a run."""
        handler = RunsHandler()
        created = handler.create_run("thread_1", CreateRunRequest(assistant_id="asst_1"))
        
        modify = ModifyRunRequest(metadata={"key": "value"})
        result = handler.modify_run("thread_1", created["id"], modify)
        assert result["metadata"]["key"] == "value"
    
    def test_cancel_run(self):
        """Test cancelling a run."""
        handler = RunsHandler()
        created = handler.create_run("thread_1", CreateRunRequest(assistant_id="asst_1"))
        
        result = handler.cancel_run("thread_1", created["id"])
        assert result["status"] == "cancelled"
    
    def test_cancel_completed_run_fails(self):
        """Test cancelling completed run fails."""
        handler = RunsHandler()
        created = handler.create_run("thread_1", CreateRunRequest(assistant_id="asst_1"))
        handler.complete_run("thread_1", created["id"])
        
        result = handler.cancel_run("thread_1", created["id"])
        assert "error" in result
    
    def test_submit_tool_outputs(self):
        """Test submitting tool outputs."""
        handler = RunsHandler()
        created = handler.create_run("thread_1", CreateRunRequest(assistant_id="asst_1"))
        
        # Set to requires_action
        handler.set_requires_action("thread_1", created["id"], [
            {"id": "call_1", "type": "function", "function": {"name": "test"}}
        ])
        
        # Submit outputs
        request = SubmitToolOutputsRequest(
            tool_outputs=[{"tool_call_id": "call_1", "output": "result"}]
        )
        result = handler.submit_tool_outputs("thread_1", created["id"], request)
        assert result["status"] == "completed"
    
    def test_complete_run(self):
        """Test completing a run."""
        handler = RunsHandler()
        created = handler.create_run("thread_1", CreateRunRequest(assistant_id="asst_1"))
        
        result = handler.complete_run("thread_1", created["id"])
        assert result["status"] == "completed"
        assert "usage" in result
    
    def test_fail_run(self):
        """Test failing a run."""
        handler = RunsHandler()
        created = handler.create_run("thread_1", CreateRunRequest(assistant_id="asst_1"))
        
        result = handler.fail_run("thread_1", created["id"], "rate_limit", "Too many requests")
        assert result["status"] == "failed"
        assert result["last_error"]["code"] == "rate_limit"


# ========================================
# Utility Function Tests
# ========================================

class TestUtilityFunctions:
    """Tests for utility functions."""
    
    def test_get_runs_handler(self):
        """Test factory function."""
        handler = get_runs_handler()
        assert isinstance(handler, RunsHandler)
    
    def test_is_run_terminal_completed(self):
        """Test terminal status detection."""
        assert is_run_terminal("completed") is True
        assert is_run_terminal("cancelled") is True
        assert is_run_terminal("failed") is True
    
    def test_is_run_terminal_active(self):
        """Test active status not terminal."""
        assert is_run_terminal("queued") is False
        assert is_run_terminal("in_progress") is False
    
    def test_is_run_active(self):
        """Test active status detection."""
        assert is_run_active("queued") is True
        assert is_run_active("in_progress") is True
        assert is_run_active("completed") is False
    
    def test_can_cancel_run(self):
        """Test cancellable status detection."""
        assert can_cancel_run("queued") is True
        assert can_cancel_run("in_progress") is True
        assert can_cancel_run("completed") is False
    
    def test_requires_tool_outputs(self):
        """Test tool outputs check."""
        run_requiring = {
            "status": "requires_action",
            "required_action": {"type": "submit_tool_outputs"}
        }
        assert requires_tool_outputs(run_requiring) is True
        
        run_completed = {"status": "completed"}
        assert requires_tool_outputs(run_completed) is False
    
    def test_get_required_tool_calls(self):
        """Test getting tool calls."""
        run = {
            "status": "requires_action",
            "required_action": {
                "type": "submit_tool_outputs",
                "submit_tool_outputs": {
                    "tool_calls": [{"id": "call_1"}]
                }
            }
        }
        calls = get_required_tool_calls(run)
        assert len(calls) == 1
    
    def test_create_tool_output(self):
        """Test creating tool output."""
        output = create_tool_output("call_123", "result data")
        assert output["tool_call_id"] == "call_123"
        assert output["output"] == "result data"
    
    def test_estimate_run_cost(self):
        """Test cost estimation."""
        usage = {"prompt_tokens": 1000, "completion_tokens": 500}
        cost = estimate_run_cost(usage, "gpt-4o")
        assert cost > 0


# ========================================
# Integration Tests
# ========================================

class TestRunsIntegration:
    """Integration tests for runs."""
    
    def test_full_run_lifecycle(self):
        """Test full run lifecycle."""
        handler = RunsHandler()
        
        # Create run
        created = handler.create_run(
            "thread_123",
            CreateRunRequest(assistant_id="asst_abc")
        )
        assert created["status"] == "in_progress"
        
        # Complete run
        completed = handler.complete_run("thread_123", created["id"])
        assert completed["status"] == "completed"
    
    def test_tool_call_flow(self):
        """Test tool call flow."""
        handler = RunsHandler()
        
        # Create run
        created = handler.create_run(
            "thread_123",
            CreateRunRequest(
                assistant_id="asst_abc",
                tools=[{"type": "function", "function": {"name": "test"}}]
            )
        )
        
        # Set requires action
        handler.set_requires_action("thread_123", created["id"], [
            {"id": "call_1", "type": "function", "function": {"name": "test"}}
        ])
        
        # Verify requires action
        retrieved = handler.retrieve_run("thread_123", created["id"])
        assert retrieved["status"] == "requires_action"
        
        # Submit tool outputs
        result = handler.submit_tool_outputs(
            "thread_123",
            created["id"],
            SubmitToolOutputsRequest(
                tool_outputs=[{"tool_call_id": "call_1", "output": "test result"}]
            )
        )
        assert result["status"] == "completed"


class TestConstants:
    """Tests for constants."""
    
    def test_instructions_limit(self):
        """Test instructions limit."""
        assert MAX_INSTRUCTIONS_LENGTH == 256000
    
    def test_tool_outputs_limit(self):
        """Test tool outputs limit."""
        assert MAX_TOOL_OUTPUTS_PER_SUBMIT == 100
    
    def test_timeout_default(self):
        """Test default timeout."""
        assert RUN_TIMEOUT_DEFAULT == 600