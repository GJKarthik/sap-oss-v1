"""
Unit Tests for Batches Endpoint

Day 19 Deliverable: 50 tests for batch processing endpoint

Test Categories:
1. BatchStatus enum tests
2. BatchEndpoint enum tests
3. BatchRequest tests
4. BatchRequestCounts tests
5. BatchObject tests
6. BatchInputLine tests
7. BatchOutputLine tests
8. BatchErrorResponse tests
9. BatchesHandler tests
10. Utility function tests
"""

import pytest
import json
from typing import Dict, Any, List

from openai.batches import (
    BatchStatus,
    BatchEndpoint,
    BatchRequest,
    BatchRequestCounts,
    BatchErrors,
    BatchObject,
    BatchListResponse,
    BatchInputLine,
    BatchOutputLine,
    BatchErrorResponse,
    BatchesHandler,
    get_batches_handler,
    create_batch,
    generate_batch_input,
    parse_batch_output,
    validate_batch_request,
    is_batch_complete,
    get_batch_progress,
    SUPPORTED_ENDPOINTS,
    BATCH_COMPLETION_WINDOWS,
    MAX_REQUESTS_PER_BATCH,
)


# ========================================
# Test Fixtures
# ========================================

@pytest.fixture
def sample_batch_input():
    """Generate sample batch input content."""
    requests = [
        {"model": "gpt-4", "messages": [{"role": "user", "content": f"Question {i}"}]}
        for i in range(5)
    ]
    return generate_batch_input(requests, "/v1/chat/completions")


@pytest.fixture
def handler_with_files(sample_batch_input):
    """Create handler with pre-loaded files."""
    file_store = {
        "file-input123": sample_batch_input,
        "file-empty": "",
    }
    return BatchesHandler(file_store=file_store)


# ========================================
# BatchStatus Enum Tests
# ========================================

class TestBatchStatus:
    """Tests for BatchStatus enum."""
    
    def test_validating_value(self):
        """Test validating status value."""
        assert BatchStatus.VALIDATING.value == "validating"
    
    def test_in_progress_value(self):
        """Test in_progress status value."""
        assert BatchStatus.IN_PROGRESS.value == "in_progress"
    
    def test_completed_value(self):
        """Test completed status value."""
        assert BatchStatus.COMPLETED.value == "completed"
    
    def test_cancelled_value(self):
        """Test cancelled status value."""
        assert BatchStatus.CANCELLED.value == "cancelled"
    
    def test_terminal_states(self):
        """Test terminal states list."""
        terminal = BatchStatus.terminal_states()
        assert BatchStatus.COMPLETED in terminal
        assert BatchStatus.FAILED in terminal
        assert BatchStatus.CANCELLED in terminal
        assert BatchStatus.VALIDATING not in terminal
    
    def test_active_states(self):
        """Test active states list."""
        active = BatchStatus.active_states()
        assert BatchStatus.VALIDATING in active
        assert BatchStatus.IN_PROGRESS in active
        assert BatchStatus.COMPLETED not in active


# ========================================
# BatchEndpoint Enum Tests
# ========================================

class TestBatchEndpoint:
    """Tests for BatchEndpoint enum."""
    
    def test_chat_completions(self):
        """Test chat completions endpoint."""
        assert BatchEndpoint.CHAT_COMPLETIONS.value == "/v1/chat/completions"
    
    def test_embeddings(self):
        """Test embeddings endpoint."""
        assert BatchEndpoint.EMBEDDINGS.value == "/v1/embeddings"
    
    def test_completions(self):
        """Test completions endpoint."""
        assert BatchEndpoint.COMPLETIONS.value == "/v1/completions"


# ========================================
# BatchRequest Tests
# ========================================

class TestBatchRequest:
    """Tests for BatchRequest dataclass."""
    
    def test_create_request(self):
        """Test creating batch request."""
        request = BatchRequest(
            input_file_id="file-abc123",
            endpoint="/v1/chat/completions"
        )
        assert request.input_file_id == "file-abc123"
        assert request.completion_window == "24h"
    
    def test_validate_valid_request(self):
        """Test validating a valid request."""
        request = BatchRequest(
            input_file_id="file-abc123",
            endpoint="/v1/chat/completions"
        )
        errors = request.validate()
        assert len(errors) == 0
    
    def test_validate_missing_file_id(self):
        """Test validation fails without file ID."""
        request = BatchRequest(
            input_file_id="",
            endpoint="/v1/chat/completions"
        )
        errors = request.validate()
        assert len(errors) > 0
        assert "input_file_id" in errors[0]
    
    def test_validate_invalid_file_id(self):
        """Test validation fails with invalid file ID format."""
        request = BatchRequest(
            input_file_id="invalid-id",
            endpoint="/v1/chat/completions"
        )
        errors = request.validate()
        assert any("file ID" in e for e in errors)
    
    def test_validate_invalid_endpoint(self):
        """Test validation fails with invalid endpoint."""
        request = BatchRequest(
            input_file_id="file-abc123",
            endpoint="/v1/invalid"
        )
        errors = request.validate()
        assert any("endpoint" in e for e in errors)


# ========================================
# BatchRequestCounts Tests
# ========================================

class TestBatchRequestCounts:
    """Tests for BatchRequestCounts dataclass."""
    
    def test_create_counts(self):
        """Test creating request counts."""
        counts = BatchRequestCounts(total=100, completed=50, failed=5)
        assert counts.total == 100
        assert counts.completed == 50
    
    def test_to_dict(self):
        """Test converting to dictionary."""
        counts = BatchRequestCounts(total=10, completed=5, failed=1)
        d = counts.to_dict()
        assert d["total"] == 10
        assert d["completed"] == 5
        assert d["failed"] == 1


# ========================================
# BatchObject Tests
# ========================================

class TestBatchObject:
    """Tests for BatchObject dataclass."""
    
    def test_create_batch_object(self):
        """Test creating batch object."""
        batch = BatchObject(
            id="batch_abc123",
            endpoint="/v1/chat/completions",
            input_file_id="file-xyz",
        )
        assert batch.id == "batch_abc123"
        assert batch.object == "batch"
    
    def test_to_dict_minimal(self):
        """Test to_dict with minimal fields."""
        batch = BatchObject(id="batch_123")
        d = batch.to_dict()
        assert "id" in d
        assert "object" in d
        assert "status" in d
    
    def test_to_dict_with_output(self):
        """Test to_dict with output file."""
        batch = BatchObject(
            id="batch_123",
            output_file_id="file-output-123"
        )
        d = batch.to_dict()
        assert d["output_file_id"] == "file-output-123"
    
    def test_to_dict_with_metadata(self):
        """Test to_dict with metadata."""
        batch = BatchObject(
            id="batch_123",
            metadata={"key": "value"}
        )
        d = batch.to_dict()
        assert d["metadata"]["key"] == "value"


# ========================================
# BatchInputLine Tests
# ========================================

class TestBatchInputLine:
    """Tests for BatchInputLine dataclass."""
    
    def test_create_input_line(self):
        """Test creating input line."""
        line = BatchInputLine(
            custom_id="req-1",
            method="POST",
            url="/v1/chat/completions",
            body={"model": "gpt-4"}
        )
        assert line.custom_id == "req-1"
    
    def test_from_dict(self):
        """Test creating from dictionary."""
        data = {
            "custom_id": "req-2",
            "method": "POST",
            "url": "/v1/embeddings",
            "body": {"input": "text"}
        }
        line = BatchInputLine.from_dict(data)
        assert line.custom_id == "req-2"
        assert line.url == "/v1/embeddings"
    
    def test_validate_valid_line(self):
        """Test validating valid input line."""
        line = BatchInputLine(
            custom_id="req-1",
            method="POST",
            url="/v1/chat/completions",
            body={"model": "gpt-4"}
        )
        errors = line.validate()
        assert len(errors) == 0
    
    def test_validate_missing_custom_id(self):
        """Test validation fails without custom_id."""
        line = BatchInputLine(
            custom_id="",
            url="/v1/chat/completions",
            body={"model": "gpt-4"}
        )
        errors = line.validate()
        assert any("custom_id" in e for e in errors)


# ========================================
# BatchOutputLine Tests
# ========================================

class TestBatchOutputLine:
    """Tests for BatchOutputLine dataclass."""
    
    def test_create_output_line(self):
        """Test creating output line."""
        line = BatchOutputLine(
            id="resp-1",
            custom_id="req-1",
            response={"status_code": 200}
        )
        assert line.id == "resp-1"
    
    def test_to_dict_with_response(self):
        """Test to_dict with response."""
        line = BatchOutputLine(
            id="resp-1",
            custom_id="req-1",
            response={"status_code": 200, "body": {}}
        )
        d = line.to_dict()
        assert d["response"]["status_code"] == 200
    
    def test_to_dict_with_error(self):
        """Test to_dict with error."""
        line = BatchOutputLine(
            id="resp-1",
            custom_id="req-1",
            error={"code": "rate_limit", "message": "Too many requests"}
        )
        d = line.to_dict()
        assert "error" in d


# ========================================
# BatchErrorResponse Tests
# ========================================

class TestBatchErrorResponse:
    """Tests for BatchErrorResponse dataclass."""
    
    def test_create_error(self):
        """Test creating error response."""
        error = BatchErrorResponse("Something went wrong")
        d = error.to_dict()
        assert d["error"]["message"] == "Something went wrong"
    
    def test_error_with_code(self):
        """Test error with code."""
        error = BatchErrorResponse("Not found", code="batch_not_found")
        d = error.to_dict()
        assert d["error"]["code"] == "batch_not_found"


# ========================================
# BatchesHandler Tests
# ========================================

class TestBatchesHandler:
    """Tests for BatchesHandler class."""
    
    def test_create_handler(self):
        """Test creating handler."""
        handler = BatchesHandler()
        assert handler.mock_mode is True
    
    def test_create_batch_success(self, handler_with_files):
        """Test creating batch successfully."""
        request = BatchRequest(
            input_file_id="file-input123",
            endpoint="/v1/chat/completions"
        )
        result = handler_with_files.create_batch(request)
        assert "id" in result
        assert result["status"] == "validating"
    
    def test_create_batch_file_not_found(self):
        """Test creating batch with missing file."""
        handler = BatchesHandler()
        request = BatchRequest(
            input_file_id="file-nonexistent",
            endpoint="/v1/chat/completions"
        )
        result = handler.create_batch(request)
        assert "error" in result
    
    def test_list_batches_empty(self):
        """Test listing batches when empty."""
        handler = BatchesHandler()
        result = handler.list_batches()
        assert result["object"] == "list"
        assert len(result["data"]) == 0
    
    def test_list_batches_with_data(self, handler_with_files):
        """Test listing batches with data."""
        # Create a batch first
        request = BatchRequest(
            input_file_id="file-input123",
            endpoint="/v1/chat/completions"
        )
        handler_with_files.create_batch(request)
        
        result = handler_with_files.list_batches()
        assert len(result["data"]) == 1
    
    def test_retrieve_batch(self, handler_with_files):
        """Test retrieving a batch."""
        request = BatchRequest(
            input_file_id="file-input123",
            endpoint="/v1/chat/completions"
        )
        created = handler_with_files.create_batch(request)
        batch_id = created["id"]
        
        result = handler_with_files.retrieve_batch(batch_id)
        assert result["id"] == batch_id
    
    def test_retrieve_batch_not_found(self):
        """Test retrieving non-existent batch."""
        handler = BatchesHandler()
        result = handler.retrieve_batch("batch_nonexistent")
        assert "error" in result
    
    def test_cancel_batch(self, handler_with_files):
        """Test cancelling a batch."""
        request = BatchRequest(
            input_file_id="file-input123",
            endpoint="/v1/chat/completions"
        )
        created = handler_with_files.create_batch(request)
        batch_id = created["id"]
        
        result = handler_with_files.cancel_batch(batch_id)
        assert result["status"] == "cancelling"
    
    def test_advance_batch(self, handler_with_files):
        """Test advancing batch through states."""
        request = BatchRequest(
            input_file_id="file-input123",
            endpoint="/v1/chat/completions"
        )
        created = handler_with_files.create_batch(request)
        batch_id = created["id"]
        
        # Advance from validating to in_progress
        result = handler_with_files.advance_batch(batch_id)
        assert result["status"] == "in_progress"
    
    def test_handle_request_create(self, handler_with_files):
        """Test handle_request for create."""
        result = handler_with_files.handle_request(
            "POST",
            "/v1/batches",
            data={
                "input_file_id": "file-input123",
                "endpoint": "/v1/chat/completions"
            }
        )
        assert "id" in result


# ========================================
# Utility Function Tests
# ========================================

class TestUtilityFunctions:
    """Tests for utility functions."""
    
    def test_get_batches_handler(self):
        """Test factory function."""
        handler = get_batches_handler()
        assert isinstance(handler, BatchesHandler)
    
    def test_generate_batch_input(self):
        """Test generating batch input."""
        requests = [
            {"model": "gpt-4", "messages": [{"role": "user", "content": "Hi"}]}
        ]
        content = generate_batch_input(requests)
        lines = content.strip().split('\n')
        assert len(lines) == 1
        
        data = json.loads(lines[0])
        assert data["custom_id"] == "request-0"
        assert data["url"] == "/v1/chat/completions"
    
    def test_parse_batch_output(self):
        """Test parsing batch output."""
        content = json.dumps({
            "id": "resp-1",
            "custom_id": "req-1",
            "response": {"status_code": 200, "body": {}}
        })
        
        results = parse_batch_output(content)
        assert len(results) == 1
        assert results[0].custom_id == "req-1"
    
    def test_validate_batch_request(self):
        """Test validate_batch_request function."""
        request = BatchRequest(
            input_file_id="file-abc",
            endpoint="/v1/chat/completions"
        )
        errors = validate_batch_request(request)
        assert len(errors) == 0
    
    def test_is_batch_complete_completed(self):
        """Test is_batch_complete for completed batch."""
        batch = {"status": "completed"}
        assert is_batch_complete(batch) is True
    
    def test_is_batch_complete_in_progress(self):
        """Test is_batch_complete for in-progress batch."""
        batch = {"status": "in_progress"}
        assert is_batch_complete(batch) is False
    
    def test_get_batch_progress_zero(self):
        """Test get_batch_progress with no progress."""
        batch = {"request_counts": {"total": 100, "completed": 0}}
        assert get_batch_progress(batch) == 0.0
    
    def test_get_batch_progress_partial(self):
        """Test get_batch_progress with partial progress."""
        batch = {"request_counts": {"total": 100, "completed": 50}}
        assert get_batch_progress(batch) == 0.5
    
    def test_get_batch_progress_complete(self):
        """Test get_batch_progress when complete."""
        batch = {"request_counts": {"total": 100, "completed": 100}}
        assert get_batch_progress(batch) == 1.0


# ========================================
# Constants Tests
# ========================================

class TestConstants:
    """Tests for module constants."""
    
    def test_supported_endpoints(self):
        """Test supported endpoints list."""
        assert "/v1/chat/completions" in SUPPORTED_ENDPOINTS
        assert "/v1/embeddings" in SUPPORTED_ENDPOINTS
        assert len(SUPPORTED_ENDPOINTS) >= 3
    
    def test_completion_windows(self):
        """Test completion windows."""
        assert "24h" in BATCH_COMPLETION_WINDOWS
    
    def test_max_requests(self):
        """Test max requests constant."""
        assert MAX_REQUESTS_PER_BATCH == 50000


# ========================================
# Integration Tests
# ========================================

class TestIntegration:
    """Integration tests for batch processing."""
    
    def test_full_batch_lifecycle(self, sample_batch_input):
        """Test complete batch lifecycle."""
        file_store = {"file-input": sample_batch_input}
        handler = BatchesHandler(file_store=file_store)
        
        # Create batch
        request = BatchRequest(
            input_file_id="file-input",
            endpoint="/v1/chat/completions"
        )
        batch = handler.create_batch(request)
        batch_id = batch["id"]
        
        # Advance through states
        handler.advance_batch(batch_id)  # validating -> in_progress
        
        # Simulate processing
        for _ in range(5):  # Process 5 requests
            handler.advance_batch(batch_id)
        
        # Finalize
        handler.advance_batch(batch_id)  # finalizing -> completed
        
        # Check final state
        final = handler.retrieve_batch(batch_id)
        assert final["status"] == "completed"
        assert final["output_file_id"] is not None
    
    def test_batch_cancellation_flow(self, sample_batch_input):
        """Test batch cancellation flow."""
        file_store = {"file-input": sample_batch_input}
        handler = BatchesHandler(file_store=file_store)
        
        # Create batch
        request = BatchRequest(
            input_file_id="file-input",
            endpoint="/v1/chat/completions"
        )
        batch = handler.create_batch(request)
        batch_id = batch["id"]
        
        # Start processing
        handler.advance_batch(batch_id)
        
        # Cancel
        cancelled = handler.cancel_batch(batch_id)
        assert cancelled["status"] == "cancelling"
        
        # Advance to cancelled
        final = handler.advance_batch(batch_id)
        assert final["status"] == "cancelled"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])