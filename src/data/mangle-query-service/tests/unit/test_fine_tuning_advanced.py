"""
Unit Tests for Advanced Fine-tuning Features

Day 18 Deliverable: 50 tests for training simulation and validation

Test Categories:
1. ValidationErrorCode enum tests
2. ValidationError tests
3. ValidationResult tests
4. TrainingDataValidator tests
5. TrainingMetrics tests
6. MetricsTracker tests
7. TrainingSimulator tests
8. FineTunedModelNamer tests
9. AdvancedFineTuningHandler tests
10. Utility function tests
"""

import pytest
import json
from typing import Dict, Any, List

from openai.fine_tuning_advanced import (
    ValidationErrorCode,
    ValidationError,
    ValidationResult,
    TrainingDataValidator,
    TrainingMetrics,
    MetricsTracker,
    TrainingSimulator,
    FineTunedModelNamer,
    AdvancedFineTuningHandler,
    get_advanced_fine_tuning_handler,
    validate_training_data,
    estimate_training_cost,
    generate_sample_training_data,
)

from openai.fine_tuning import (
    FineTuningStatus,
    FineTuningJobRequest,
)


# ========================================
# ValidationErrorCode Enum Tests
# ========================================

class TestValidationErrorCode:
    """Tests for ValidationErrorCode enum."""
    
    def test_invalid_format(self):
        """Test invalid_format value."""
        assert ValidationErrorCode.INVALID_FORMAT.value == "invalid_format"
    
    def test_missing_field(self):
        """Test missing_field value."""
        assert ValidationErrorCode.MISSING_FIELD.value == "missing_field"
    
    def test_too_few_examples(self):
        """Test too_few_examples value."""
        assert ValidationErrorCode.TOO_FEW_EXAMPLES.value == "too_few_examples"
    
    def test_file_not_found(self):
        """Test file_not_found value."""
        assert ValidationErrorCode.FILE_NOT_FOUND.value == "file_not_found"
    
    def test_parsing_error(self):
        """Test parsing_error value."""
        assert ValidationErrorCode.PARSING_ERROR.value == "parsing_error"


# ========================================
# ValidationError Tests
# ========================================

class TestValidationError:
    """Tests for ValidationError dataclass."""
    
    def test_create_error(self):
        """Test creating validation error."""
        error = ValidationError(
            code="missing_field",
            message="Missing required field"
        )
        assert error.code == "missing_field"
        assert error.message == "Missing required field"
    
    def test_error_with_line(self):
        """Test error with line number."""
        error = ValidationError(
            code="invalid_format",
            message="Invalid JSON",
            line=5
        )
        assert error.line == 5
    
    def test_error_with_field(self):
        """Test error with field name."""
        error = ValidationError(
            code="missing_field",
            message="Missing 'messages'",
            field="messages"
        )
        assert error.field == "messages"
    
    def test_to_dict(self):
        """Test converting to dictionary."""
        error = ValidationError(
            code="test_error",
            message="Test message",
            line=10,
            field="test_field"
        )
        result = error.to_dict()
        assert result["code"] == "test_error"
        assert result["message"] == "Test message"
        assert result["line"] == 10
        assert result["field"] == "test_field"


# ========================================
# ValidationResult Tests
# ========================================

class TestValidationResult:
    """Tests for ValidationResult dataclass."""
    
    def test_valid_result(self):
        """Test valid result."""
        result = ValidationResult(valid=True)
        assert result.valid is True
        assert len(result.errors) == 0
    
    def test_invalid_result(self):
        """Test invalid result with errors."""
        error = ValidationError(code="test", message="error")
        result = ValidationResult(valid=False, errors=[error])
        assert result.valid is False
        assert len(result.errors) == 1
    
    def test_result_with_warnings(self):
        """Test result with warnings."""
        warning = ValidationError(code="warning", message="warning msg")
        result = ValidationResult(valid=True, warnings=[warning])
        assert len(result.warnings) == 1
    
    def test_result_with_stats(self):
        """Test result with stats."""
        result = ValidationResult(
            valid=True,
            stats={"num_examples": 50, "total_tokens": 10000}
        )
        assert result.stats["num_examples"] == 50
    
    def test_to_dict(self):
        """Test converting to dictionary."""
        result = ValidationResult(
            valid=True,
            stats={"count": 10}
        )
        d = result.to_dict()
        assert "valid" in d
        assert "errors" in d
        assert "stats" in d


# ========================================
# TrainingDataValidator Tests
# ========================================

class TestTrainingDataValidator:
    """Tests for TrainingDataValidator class."""
    
    @pytest.fixture
    def validator(self):
        """Create validator fixture."""
        return TrainingDataValidator(model_type="chat")
    
    def test_default_model_type(self, validator):
        """Test default model type."""
        assert validator.model_type == "chat"
    
    def test_validate_valid_chat_data(self, validator):
        """Test validating valid chat data."""
        data = generate_sample_training_data(15)
        result = validator.validate_jsonl(data)
        assert result.valid is True
    
    def test_validate_too_few_examples(self, validator):
        """Test validation fails with too few examples."""
        data = generate_sample_training_data(5)
        result = validator.validate_jsonl(data)
        assert result.valid is False
        assert any(e.code == "too_few_examples" for e in result.errors)
    
    def test_validate_invalid_json(self, validator):
        """Test validation fails with invalid JSON."""
        data = "not valid json\n{also bad"
        result = validator.validate_jsonl(data)
        assert result.valid is False
        assert any(e.code == "parsing_error" for e in result.errors)
    
    def test_validate_missing_messages(self, validator):
        """Test validation fails when messages missing."""
        data = '{"text": "hello"}\n' * 15
        result = validator.validate_jsonl(data)
        assert result.valid is False
    
    def test_validate_calculates_stats(self, validator):
        """Test validation calculates stats."""
        data = generate_sample_training_data(20)
        result = validator.validate_jsonl(data)
        assert "num_examples" in result.stats
        assert result.stats["num_examples"] == 20
    
    def test_completion_validator(self):
        """Test completion model validator."""
        validator = TrainingDataValidator(model_type="completion")
        # Create completion-style data
        lines = []
        for i in range(15):
            lines.append(json.dumps({"prompt": "Q?", "completion": "A."}))
        data = "\n".join(lines)
        result = validator.validate_jsonl(data)
        assert result.valid is True


# ========================================
# TrainingMetrics Tests
# ========================================

class TestTrainingMetrics:
    """Tests for TrainingMetrics dataclass."""
    
    def test_create_metrics(self):
        """Test creating metrics."""
        metrics = TrainingMetrics(
            step=100,
            train_loss=0.5,
            train_accuracy=0.85
        )
        assert metrics.step == 100
        assert metrics.train_loss == 0.5
    
    def test_metrics_with_validation(self):
        """Test metrics with validation data."""
        metrics = TrainingMetrics(
            step=100,
            train_loss=0.5,
            train_accuracy=0.85,
            valid_loss=0.6,
            valid_accuracy=0.80
        )
        assert metrics.valid_loss == 0.6
    
    def test_to_dict(self):
        """Test converting to dictionary."""
        metrics = TrainingMetrics(
            step=50,
            train_loss=0.8,
            train_accuracy=0.7
        )
        d = metrics.to_dict()
        assert d["step"] == 50
        assert d["train_loss"] == 0.8
        assert "epoch" in d


# ========================================
# MetricsTracker Tests
# ========================================

class TestMetricsTracker:
    """Tests for MetricsTracker class."""
    
    @pytest.fixture
    def tracker(self):
        """Create tracker fixture."""
        return MetricsTracker()
    
    def test_empty_tracker(self, tracker):
        """Test empty tracker."""
        assert tracker.get_latest() is None
        assert tracker.get_history() == []
    
    def test_add_metrics(self, tracker):
        """Test adding metrics."""
        metrics = TrainingMetrics(step=1, train_loss=1.0, train_accuracy=0.5)
        tracker.add_metrics(metrics)
        assert tracker.get_latest().step == 1
    
    def test_get_history(self, tracker):
        """Test getting history."""
        for i in range(10):
            tracker.add_metrics(
                TrainingMetrics(step=i, train_loss=1.0-i*0.1, train_accuracy=0.5+i*0.05)
            )
        history = tracker.get_history(5)
        assert len(history) == 5
    
    def test_get_summary(self, tracker):
        """Test getting summary."""
        for i in range(5):
            tracker.add_metrics(
                TrainingMetrics(step=i, train_loss=1.0-i*0.2, train_accuracy=0.5+i*0.1)
            )
        summary = tracker.get_summary()
        assert "total_steps" in summary
        assert summary["total_steps"] == 5
        assert "final_loss" in summary
        assert "min_loss" in summary


# ========================================
# TrainingSimulator Tests
# ========================================

class TestTrainingSimulator:
    """Tests for TrainingSimulator class."""
    
    @pytest.fixture
    def simulator(self):
        """Create simulator fixture."""
        return TrainingSimulator(
            total_steps=30,
            steps_per_epoch=10,
            checkpoint_interval=10
        )
    
    def test_initial_state(self, simulator):
        """Test initial state."""
        assert simulator.current_step == 0
        assert simulator.is_complete() is False
    
    def test_simulate_step(self, simulator):
        """Test simulating a step."""
        metrics = simulator.simulate_step()
        assert metrics.step == 1
        assert simulator.current_step == 1
    
    def test_progress(self, simulator):
        """Test progress tracking."""
        for _ in range(15):
            simulator.simulate_step()
        assert simulator.get_progress() == 0.5
    
    def test_checkpoint_trigger(self, simulator):
        """Test checkpoint triggering."""
        for _ in range(10):
            simulator.simulate_step()
        assert simulator.should_checkpoint() is True
    
    def test_completion(self, simulator):
        """Test training completion."""
        for _ in range(30):
            simulator.simulate_step()
        assert simulator.is_complete() is True
    
    def test_loss_decreases(self, simulator):
        """Test that loss generally decreases."""
        metrics_start = simulator.simulate_step()
        for _ in range(28):
            simulator.simulate_step()
        metrics_end = simulator.simulate_step()
        assert metrics_end.train_loss < metrics_start.train_loss


# ========================================
# FineTunedModelNamer Tests
# ========================================

class TestFineTunedModelNamer:
    """Tests for FineTunedModelNamer class."""
    
    def test_generate_name(self):
        """Test generating model name."""
        name = FineTunedModelNamer.generate_name(
            base_model="gpt-3.5-turbo-0125",
            organization_id="org-test",
            suffix="my-model",
            job_id="ftjob-abc123def"
        )
        assert name.startswith("ft:")
        assert "org-test" in name
        assert "my-model" in name
    
    def test_generate_name_no_suffix(self):
        """Test generating name without suffix."""
        name = FineTunedModelNamer.generate_name(
            base_model="gpt-4",
            organization_id="org-abc",
            suffix=None,
            job_id="ftjob-xyz"
        )
        assert "model" in name  # Default suffix
    
    def test_parse_name_valid(self):
        """Test parsing valid name."""
        result = FineTunedModelNamer.parse_name(
            "ft:gpt:org-test:my-suffix:abc123"
        )
        assert result is not None
        assert result["base_model"] == "gpt"
        assert result["organization"] == "org-test"
    
    def test_parse_name_invalid(self):
        """Test parsing invalid name."""
        result = FineTunedModelNamer.parse_name("gpt-3.5-turbo")
        assert result is None
    
    def test_parse_name_too_short(self):
        """Test parsing name with too few parts."""
        result = FineTunedModelNamer.parse_name("ft:gpt:org")
        assert result is None


# ========================================
# AdvancedFineTuningHandler Tests
# ========================================

class TestAdvancedFineTuningHandler:
    """Tests for AdvancedFineTuningHandler class."""
    
    @pytest.fixture
    def handler(self):
        """Create handler fixture."""
        file_store = {
            "file-training": generate_sample_training_data(20),
            "file-small": generate_sample_training_data(5),
        }
        return AdvancedFineTuningHandler(file_store=file_store)
    
    def test_validate_existing_file(self, handler):
        """Test validating existing file."""
        result = handler.validate_training_file("file-training")
        assert result.valid is True
    
    def test_validate_nonexistent_file(self, handler):
        """Test validating nonexistent file."""
        result = handler.validate_training_file("file-nonexistent")
        assert result.valid is False
        assert result.errors[0].code == "file_not_found"
    
    def test_validate_small_file(self, handler):
        """Test validating file with too few examples."""
        result = handler.validate_training_file("file-small")
        assert result.valid is False
    
    def test_start_training_simulation(self, handler):
        """Test starting training simulation."""
        # First create a job
        request = FineTuningJobRequest(
            training_file="file-training",
            model="gpt-3.5-turbo-0125"
        )
        job = handler.create_job(request)
        job_id = job["id"]
        
        handler.start_training_simulation(job_id)
        assert job_id in handler.simulators
    
    def test_advance_training(self, handler):
        """Test advancing training."""
        request = FineTuningJobRequest(
            training_file="file-training",
            model="gpt-3.5-turbo-0125"
        )
        job = handler.create_job(request)
        job_id = job["id"]
        
        handler.start_training_simulation(job_id)
        metrics = handler.advance_training(job_id)
        
        assert metrics is not None
        assert "step" in metrics
    
    def test_get_job_metrics(self, handler):
        """Test getting job metrics."""
        request = FineTuningJobRequest(
            training_file="file-training",
            model="gpt-3.5-turbo-0125"
        )
        job = handler.create_job(request)
        job_id = job["id"]
        
        handler.start_training_simulation(job_id)
        handler.advance_training(job_id)
        
        metrics = handler.get_job_metrics(job_id)
        assert metrics is not None


# ========================================
# Utility Function Tests
# ========================================

class TestUtilityFunctions:
    """Tests for utility functions."""
    
    def test_get_advanced_handler(self):
        """Test factory function."""
        handler = get_advanced_fine_tuning_handler()
        assert isinstance(handler, AdvancedFineTuningHandler)
    
    def test_validate_training_data(self):
        """Test validate_training_data function."""
        data = generate_sample_training_data(15)
        result = validate_training_data(data)
        assert result.valid is True
    
    def test_validate_training_data_completion(self):
        """Test validate_training_data for completion model."""
        lines = []
        for i in range(15):
            lines.append(json.dumps({"prompt": "Q?", "completion": "A."}))
        data = "\n".join(lines)
        result = validate_training_data(data, model_type="completion")
        assert result.valid is True
    
    def test_estimate_training_cost(self):
        """Test cost estimation."""
        estimate = estimate_training_cost(
            num_examples=100,
            avg_tokens_per_example=500,
            n_epochs=3
        )
        assert "total_tokens" in estimate
        assert estimate["total_tokens"] == 150000
        assert "estimated_cost_usd" in estimate
        assert "epochs" in estimate
    
    def test_estimate_training_cost_small(self):
        """Test cost estimation for small dataset."""
        estimate = estimate_training_cost(
            num_examples=10,
            avg_tokens_per_example=100,
            n_epochs=1
        )
        assert estimate["total_tokens"] == 1000
    
    def test_generate_sample_data_default(self):
        """Test generating sample data with default count."""
        data = generate_sample_training_data()
        lines = data.strip().split('\n')
        assert len(lines) == 20
    
    def test_generate_sample_data_custom_count(self):
        """Test generating sample data with custom count."""
        data = generate_sample_training_data(50)
        lines = data.strip().split('\n')
        assert len(lines) == 50
    
    def test_generate_sample_data_valid_format(self):
        """Test that generated data is valid JSONL."""
        data = generate_sample_training_data(10)
        for line in data.strip().split('\n'):
            parsed = json.loads(line)
            assert "messages" in parsed
            assert len(parsed["messages"]) >= 2


# ========================================
# Integration Tests
# ========================================

class TestIntegration:
    """Integration tests for advanced fine-tuning."""
    
    def test_full_training_workflow(self):
        """Test complete training workflow."""
        # Setup
        file_store = {
            "file-training": generate_sample_training_data(20)
        }
        handler = AdvancedFineTuningHandler(file_store=file_store)
        
        # Create job
        request = FineTuningJobRequest(
            training_file="file-training",
            model="gpt-3.5-turbo-0125",
            suffix="test-model"
        )
        job = handler.create_job(request)
        job_id = job["id"]
        
        # Start training
        handler.start_training_simulation(job_id)
        
        # Run training to completion
        while True:
            metrics = handler.advance_training(job_id)
            if metrics is None:
                break
        
        # Check final state
        final_job = handler.retrieve_job(job_id)
        assert final_job["status"] == "succeeded"
        assert "fine_tuned_model" in final_job
    
    def test_training_creates_checkpoints(self):
        """Test that training creates checkpoints."""
        file_store = {
            "file-training": generate_sample_training_data(20)
        }
        handler = AdvancedFineTuningHandler(file_store=file_store)
        
        request = FineTuningJobRequest(
            training_file="file-training",
            model="gpt-3.5-turbo-0125"
        )
        job = handler.create_job(request)
        job_id = job["id"]
        
        handler.start_training_simulation(job_id)
        
        # Run training
        while True:
            metrics = handler.advance_training(job_id)
            if metrics is None:
                break
        
        # Check checkpoints
        checkpoints = handler.list_checkpoints(job_id)
        assert len(checkpoints["data"]) > 0


if __name__ == "__main__":
    pytest.main([__file__, "-v"])