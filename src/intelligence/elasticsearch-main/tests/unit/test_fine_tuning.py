"""
Unit Tests for Fine-tuning Endpoint

Day 17 Deliverable: 50 tests for fine-tuning job management

Test Categories:
1. FineTuningStatus enum tests
2. FineTuningEventLevel/Type enum tests
3. Hyperparameters tests
4. WandbIntegration tests
5. FineTuningJobRequest tests
6. FineTuningJobObject tests
7. FineTuningEvent tests
8. FineTuningCheckpoint tests
9. List response tests
10. FineTuningErrorResponse tests
11. FineTuningHandler tests
12. Utility function tests
13. OpenAI compliance tests
"""

import pytest
import time
from unittest.mock import Mock, patch
from typing import Dict, Any, List

from openai.fine_tuning import (
    FineTuningStatus,
    FineTuningEventLevel,
    FineTuningEventType,
    Hyperparameters,
    WandbIntegration,
    FineTuningJobRequest,
    ListJobsRequest,
    ListEventsRequest,
    FineTuningError,
    FineTuningJobObject,
    FineTuningEvent,
    FineTuningCheckpoint,
    FineTuningJobListResponse,
    FineTuningEventListResponse,
    FineTuningCheckpointListResponse,
    FineTuningErrorResponse,
    FineTuningHandler,
    get_fine_tuning_handler,
    create_fine_tuning_job,
    validate_training_file_id,
    is_finetune_model,
    get_base_model,
    FINETUNE_BASE_MODELS,
    DEFAULT_N_EPOCHS,
    DEFAULT_BATCH_SIZE,
    DEFAULT_LEARNING_RATE_MULTIPLIER,
    MAX_SUFFIX_LENGTH,
)


# ========================================
# FineTuningStatus Enum Tests
# ========================================

class TestFineTuningStatus:
    """Tests for FineTuningStatus enum."""
    
    def test_validating_files_status(self):
        """Test validating_files value."""
        assert FineTuningStatus.VALIDATING_FILES.value == "validating_files"
    
    def test_running_status(self):
        """Test running value."""
        assert FineTuningStatus.RUNNING.value == "running"
    
    def test_succeeded_status(self):
        """Test succeeded value."""
        assert FineTuningStatus.SUCCEEDED.value == "succeeded"
    
    def test_cancelled_status(self):
        """Test cancelled value."""
        assert FineTuningStatus.CANCELLED.value == "cancelled"
    
    def test_is_terminal_succeeded(self):
        """Test is_terminal for succeeded."""
        assert FineTuningStatus.is_terminal("succeeded") is True
    
    def test_is_terminal_failed(self):
        """Test is_terminal for failed."""
        assert FineTuningStatus.is_terminal("failed") is True
    
    def test_is_terminal_running(self):
        """Test is_terminal for running."""
        assert FineTuningStatus.is_terminal("running") is False
    
    def test_is_active_running(self):
        """Test is_active for running."""
        assert FineTuningStatus.is_active("running") is True
    
    def test_is_active_succeeded(self):
        """Test is_active for succeeded."""
        assert FineTuningStatus.is_active("succeeded") is False


# ========================================
# Event Enum Tests
# ========================================

class TestFineTuningEventEnums:
    """Tests for event level and type enums."""
    
    def test_info_level(self):
        """Test info level value."""
        assert FineTuningEventLevel.INFO.value == "info"
    
    def test_warn_level(self):
        """Test warn level value."""
        assert FineTuningEventLevel.WARN.value == "warn"
    
    def test_error_level(self):
        """Test error level value."""
        assert FineTuningEventLevel.ERROR.value == "error"
    
    def test_message_type(self):
        """Test message type value."""
        assert FineTuningEventType.MESSAGE.value == "message"
    
    def test_metrics_type(self):
        """Test metrics type value."""
        assert FineTuningEventType.METRICS.value == "metrics"


# ========================================
# Hyperparameters Tests
# ========================================

class TestHyperparameters:
    """Tests for Hyperparameters dataclass."""
    
    def test_default_values(self):
        """Test default hyperparameters."""
        hp = Hyperparameters()
        assert hp.n_epochs == "auto"
        assert hp.batch_size == "auto"
        assert hp.learning_rate_multiplier == "auto"
    
    def test_custom_values(self):
        """Test custom hyperparameters."""
        hp = Hyperparameters(n_epochs=5, batch_size=8, learning_rate_multiplier=0.1)
        assert hp.n_epochs == 5
        assert hp.batch_size == 8
        assert hp.learning_rate_multiplier == 0.1
    
    def test_to_dict(self):
        """Test converting to dictionary."""
        hp = Hyperparameters(n_epochs=3)
        result = hp.to_dict()
        assert result["n_epochs"] == 3
        assert "batch_size" in result
    
    def test_from_dict(self):
        """Test creating from dictionary."""
        data = {"n_epochs": 10, "batch_size": 16}
        hp = Hyperparameters.from_dict(data)
        assert hp.n_epochs == 10
        assert hp.batch_size == 16
    
    def test_from_dict_none(self):
        """Test from_dict with None returns defaults."""
        hp = Hyperparameters.from_dict(None)
        assert hp.n_epochs == "auto"


# ========================================
# WandbIntegration Tests
# ========================================

class TestWandbIntegration:
    """Tests for WandbIntegration dataclass."""
    
    def test_default_type(self):
        """Test default type is wandb."""
        wb = WandbIntegration()
        assert wb.type == "wandb"
    
    def test_custom_project(self):
        """Test custom project name."""
        wb = WandbIntegration(project="my-project")
        assert wb.project == "my-project"
    
    def test_to_dict(self):
        """Test converting to dictionary."""
        wb = WandbIntegration(project="test", entity="org")
        result = wb.to_dict()
        assert result["project"] == "test"
        assert result["entity"] == "org"
    
    def test_from_dict(self):
        """Test creating from dictionary."""
        data = {"project": "test-proj", "tags": ["tag1", "tag2"]}
        wb = WandbIntegration.from_dict(data)
        assert wb.project == "test-proj"
        assert wb.tags == ["tag1", "tag2"]


# ========================================
# FineTuningJobRequest Tests
# ========================================

class TestFineTuningJobRequest:
    """Tests for FineTuningJobRequest dataclass."""
    
    def test_create_basic_request(self):
        """Test creating basic request."""
        req = FineTuningJobRequest(
            training_file="file-abc123",
            model="gpt-3.5-turbo-0125"
        )
        assert req.training_file == "file-abc123"
        assert req.model == "gpt-3.5-turbo-0125"
    
    def test_default_hyperparameters(self):
        """Test default hyperparameters are set."""
        req = FineTuningJobRequest(training_file="file-abc", model="gpt-3.5-turbo-0125")
        assert req.hyperparameters is not None
        assert req.hyperparameters.n_epochs == "auto"
    
    def test_optional_validation_file(self):
        """Test optional validation file."""
        req = FineTuningJobRequest(
            training_file="file-train",
            model="gpt-3.5-turbo-0125",
            validation_file="file-val"
        )
        assert req.validation_file == "file-val"
    
    def test_suffix_validation(self):
        """Test suffix length validation."""
        with pytest.raises(ValueError):
            FineTuningJobRequest(
                training_file="file-abc",
                model="gpt-3.5-turbo-0125",
                suffix="x" * (MAX_SUFFIX_LENGTH + 1)
            )
    
    def test_from_dict(self):
        """Test creating from dictionary."""
        data = {
            "training_file": "file-123",
            "model": "gpt-4o-2024-08-06",
            "suffix": "custom"
        }
        req = FineTuningJobRequest.from_dict(data)
        assert req.training_file == "file-123"
        assert req.suffix == "custom"
    
    def test_to_dict(self):
        """Test converting to dictionary."""
        req = FineTuningJobRequest(
            training_file="file-abc",
            model="gpt-3.5-turbo-0125"
        )
        result = req.to_dict()
        assert result["training_file"] == "file-abc"
        assert result["model"] == "gpt-3.5-turbo-0125"


# ========================================
# ListRequests Tests
# ========================================

class TestListRequests:
    """Tests for list request dataclasses."""
    
    def test_list_jobs_default_limit(self):
        """Test default limit."""
        req = ListJobsRequest()
        assert req.limit == 20
    
    def test_list_jobs_limit_min(self):
        """Test limit minimum clamping."""
        req = ListJobsRequest(limit=0)
        assert req.limit == 1
    
    def test_list_jobs_limit_max(self):
        """Test limit maximum clamping."""
        req = ListJobsRequest(limit=500)
        assert req.limit == 100
    
    def test_list_events_job_id(self):
        """Test events request requires job_id."""
        req = ListEventsRequest(fine_tuning_job_id="ftjob-123")
        assert req.fine_tuning_job_id == "ftjob-123"


# ========================================
# FineTuningJobObject Tests
# ========================================

class TestFineTuningJobObject:
    """Tests for FineTuningJobObject dataclass."""
    
    def test_create_job_object(self):
        """Test creating job object."""
        job = FineTuningJobObject(id="ftjob-abc123")
        assert job.id == "ftjob-abc123"
        assert job.object == "fine_tuning.job"
    
    def test_default_status(self):
        """Test default status is validating_files."""
        job = FineTuningJobObject(id="ftjob-abc")
        assert job.status == "validating_files"
    
    def test_created_at_auto_set(self):
        """Test created_at is auto-set."""
        job = FineTuningJobObject(id="ftjob-abc")
        assert job.created_at > 0
    
    def test_to_dict(self):
        """Test converting to dictionary."""
        job = FineTuningJobObject(
            id="ftjob-test",
            model="gpt-3.5-turbo-0125",
            training_file="file-train"
        )
        result = job.to_dict()
        assert result["id"] == "ftjob-test"
        assert result["object"] == "fine_tuning.job"
        assert result["model"] == "gpt-3.5-turbo-0125"


# ========================================
# FineTuningEvent Tests
# ========================================

class TestFineTuningEvent:
    """Tests for FineTuningEvent dataclass."""
    
    def test_create_event(self):
        """Test creating event."""
        event = FineTuningEvent(
            id="ftevent-123",
            message="Job started"
        )
        assert event.id == "ftevent-123"
        assert event.message == "Job started"
    
    def test_default_level(self):
        """Test default level is info."""
        event = FineTuningEvent(id="ftevent-123")
        assert event.level == "info"
    
    def test_to_dict(self):
        """Test converting to dictionary."""
        event = FineTuningEvent(
            id="ftevent-abc",
            level="warn",
            message="Warning occurred"
        )
        result = event.to_dict()
        assert result["id"] == "ftevent-abc"
        assert result["level"] == "warn"


# ========================================
# FineTuningCheckpoint Tests
# ========================================

class TestFineTuningCheckpoint:
    """Tests for FineTuningCheckpoint dataclass."""
    
    def test_create_checkpoint(self):
        """Test creating checkpoint."""
        cp = FineTuningCheckpoint(
            id="ftckpt-123",
            fine_tuning_job_id="ftjob-abc",
            step_number=100
        )
        assert cp.id == "ftckpt-123"
        assert cp.step_number == 100
    
    def test_metrics(self):
        """Test checkpoint metrics."""
        cp = FineTuningCheckpoint(
            id="ftckpt-123",
            metrics={"loss": 0.5, "accuracy": 0.95}
        )
        assert cp.metrics["loss"] == 0.5
    
    def test_to_dict(self):
        """Test converting to dictionary."""
        cp = FineTuningCheckpoint(
            id="ftckpt-abc",
            fine_tuned_model_checkpoint="ft:gpt-3.5:org:name:step-100"
        )
        result = cp.to_dict()
        assert result["object"] == "fine_tuning.job.checkpoint"


# ========================================
# List Response Tests
# ========================================

class TestListResponses:
    """Tests for list response dataclasses."""
    
    def test_job_list_response(self):
        """Test job list response."""
        job = FineTuningJobObject(id="ftjob-123")
        response = FineTuningJobListResponse(data=[job])
        result = response.to_dict()
        assert result["object"] == "list"
        assert len(result["data"]) == 1
    
    def test_event_list_response(self):
        """Test event list response."""
        event = FineTuningEvent(id="ftevent-123")
        response = FineTuningEventListResponse(data=[event])
        result = response.to_dict()
        assert result["object"] == "list"
    
    def test_checkpoint_list_response(self):
        """Test checkpoint list response."""
        cp = FineTuningCheckpoint(id="ftckpt-123")
        response = FineTuningCheckpointListResponse(
            data=[cp],
            first_id="ftckpt-123",
            last_id="ftckpt-123"
        )
        result = response.to_dict()
        assert result["first_id"] == "ftckpt-123"


# ========================================
# FineTuningErrorResponse Tests
# ========================================

class TestFineTuningErrorResponse:
    """Tests for error response."""
    
    def test_create_error(self):
        """Test creating error response."""
        error = FineTuningErrorResponse(message="Invalid input")
        assert error.message == "Invalid input"
        assert error.type == "invalid_request_error"
    
    def test_to_dict(self):
        """Test converting to dictionary."""
        error = FineTuningErrorResponse(
            message="Job not found",
            code="job_not_found"
        )
        result = error.to_dict()
        assert "error" in result
        assert result["error"]["code"] == "job_not_found"


# ========================================
# FineTuningHandler Tests
# ========================================

class TestFineTuningHandler:
    """Tests for FineTuningHandler class."""
    
    @pytest.fixture
    def handler(self):
        """Create handler fixture."""
        return FineTuningHandler()
    
    def test_handler_default_mock_mode(self, handler):
        """Test handler default mock mode."""
        assert handler.mock_mode is True
    
    def test_create_job(self, handler):
        """Test creating a job."""
        request = FineTuningJobRequest(
            training_file="file-abc123",
            model="gpt-3.5-turbo-0125"
        )
        response = handler.create_job(request)
        
        assert "id" in response
        assert response["id"].startswith("ftjob-")
        assert response["status"] == "validating_files"
    
    def test_create_job_missing_training_file(self, handler):
        """Test error for missing training_file."""
        request = FineTuningJobRequest(training_file="", model="gpt-3.5-turbo-0125")
        response = handler.create_job(request)
        
        assert "error" in response
    
    def test_create_job_invalid_model(self, handler):
        """Test error for invalid model."""
        request = FineTuningJobRequest(
            training_file="file-abc",
            model="invalid-model"
        )
        response = handler.create_job(request)
        
        assert "error" in response
    
    def test_list_jobs_empty(self, handler):
        """Test listing jobs when empty."""
        response = handler.list_jobs()
        
        assert response["object"] == "list"
        assert response["data"] == []
    
    def test_retrieve_job_not_found(self, handler):
        """Test retrieving non-existent job."""
        response = handler.retrieve_job("ftjob-nonexistent")
        
        assert "error" in response
    
    def test_cancel_job_not_found(self, handler):
        """Test cancelling non-existent job."""
        response = handler.cancel_job("ftjob-nonexistent")
        
        assert "error" in response
    
    def test_create_and_retrieve_job(self, handler):
        """Test create then retrieve job."""
        # Create
        request = FineTuningJobRequest(
            training_file="file-abc123",
            model="gpt-3.5-turbo-0125"
        )
        create_response = handler.create_job(request)
        job_id = create_response["id"]
        
        # Retrieve
        retrieve_response = handler.retrieve_job(job_id)
        
        assert retrieve_response["id"] == job_id
    
    def test_create_and_cancel_job(self, handler):
        """Test create then cancel job."""
        # Create
        request = FineTuningJobRequest(
            training_file="file-abc123",
            model="gpt-3.5-turbo-0125"
        )
        create_response = handler.create_job(request)
        job_id = create_response["id"]
        
        # Cancel
        cancel_response = handler.cancel_job(job_id)
        
        assert cancel_response["status"] == "cancelled"
    
    def test_list_events(self, handler):
        """Test listing events for job."""
        # Create job first
        request = FineTuningJobRequest(
            training_file="file-abc123",
            model="gpt-3.5-turbo-0125"
        )
        create_response = handler.create_job(request)
        job_id = create_response["id"]
        
        # List events
        events_response = handler.list_events(job_id)
        
        assert events_response["object"] == "list"
        assert len(events_response["data"]) > 0


# ========================================
# Utility Function Tests
# ========================================

class TestFineTuningUtilities:
    """Tests for utility functions."""
    
    def test_get_fine_tuning_handler(self):
        """Test factory function."""
        handler = get_fine_tuning_handler()
        assert isinstance(handler, FineTuningHandler)
    
    def test_create_fine_tuning_job(self):
        """Test convenience function."""
        response = create_fine_tuning_job(
            training_file="file-abc",
            model="gpt-3.5-turbo-0125"
        )
        assert "id" in response
    
    def test_validate_training_file_id_valid(self):
        """Test valid file ID."""
        assert validate_training_file_id("file-abc123") is True
    
    def test_validate_training_file_id_invalid(self):
        """Test invalid file ID."""
        assert validate_training_file_id("") is False
        assert validate_training_file_id("abc123") is False
    
    def test_is_finetune_model_true(self):
        """Test is_finetune_model with ft model."""
        assert is_finetune_model("ft:gpt-3.5-turbo:org:name:id") is True
    
    def test_is_finetune_model_false(self):
        """Test is_finetune_model with base model."""
        assert is_finetune_model("gpt-3.5-turbo-0125") is False
    
    def test_get_base_model_finetune(self):
        """Test get_base_model with fine-tuned model."""
        base = get_base_model("ft:gpt-3.5-turbo:org:name:id")
        assert base == "gpt-3.5-turbo"
    
    def test_get_base_model_base(self):
        """Test get_base_model with base model."""
        base = get_base_model("gpt-3.5-turbo-0125")
        assert base == "gpt-3.5-turbo-0125"


# ========================================
# Constants Tests
# ========================================

class TestConstants:
    """Tests for module constants."""
    
    def test_finetune_base_models(self):
        """Test base models list."""
        assert "gpt-3.5-turbo-0125" in FINETUNE_BASE_MODELS
        assert "gpt-4o-2024-08-06" in FINETUNE_BASE_MODELS
    
    def test_default_hyperparameters(self):
        """Test default hyperparameter values."""
        assert DEFAULT_N_EPOCHS == "auto"
        assert DEFAULT_BATCH_SIZE == "auto"
        assert DEFAULT_LEARNING_RATE_MULTIPLIER == "auto"
    
    def test_max_suffix_length(self):
        """Test max suffix length."""
        assert MAX_SUFFIX_LENGTH == 40


# ========================================
# OpenAI Compliance Tests
# ========================================

class TestOpenAICompliance:
    """Tests for OpenAI API compliance."""
    
    def test_job_object_structure(self):
        """Test job object matches OpenAI structure."""
        handler = get_fine_tuning_handler()
        request = FineTuningJobRequest(
            training_file="file-abc",
            model="gpt-3.5-turbo-0125"
        )
        response = handler.create_job(request)
        
        # Required fields
        assert "id" in response
        assert "object" in response
        assert response["object"] == "fine_tuning.job"
        assert "created_at" in response
        assert "model" in response
        assert "status" in response
    
    def test_list_response_structure(self):
        """Test list response structure."""
        handler = get_fine_tuning_handler()
        response = handler.list_jobs()
        
        assert response["object"] == "list"
        assert "data" in response
        assert "has_more" in response
    
    def test_id_prefix(self):
        """Test job ID prefix format."""
        handler = get_fine_tuning_handler()
        request = FineTuningJobRequest(
            training_file="file-abc",
            model="gpt-3.5-turbo-0125"
        )
        response = handler.create_job(request)
        
        assert response["id"].startswith("ftjob-")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])