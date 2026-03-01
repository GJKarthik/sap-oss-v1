"""
OpenAI-compatible Fine-tuning Advanced Features

Day 18 Deliverable: Fine-tuning Part 2 - Training simulation and validation

Extends fine_tuning.py with:
- Training data validation
- Job progress simulation
- Metric tracking and reporting
- Fine-tuned model naming conventions
- Integration with Files endpoint
"""

import time
import json
import hashlib
import threading
from enum import Enum
from typing import Dict, Any, Optional, List, Callable
from dataclasses import dataclass, field

from .fine_tuning import (
    FineTuningStatus,
    FineTuningEventLevel,
    FineTuningEventType,
    FineTuningJobObject,
    FineTuningEvent,
    FineTuningCheckpoint,
    FineTuningHandler,
    Hyperparameters,
)


# ========================================
# Training Data Validation
# ========================================

class ValidationErrorCode(str, Enum):
    """Validation error codes."""
    INVALID_FORMAT = "invalid_format"
    MISSING_FIELD = "missing_field"
    INVALID_FIELD = "invalid_field"
    TOO_FEW_EXAMPLES = "too_few_examples"
    TOO_LONG_EXAMPLE = "too_long_example"
    INCONSISTENT_FORMAT = "inconsistent_format"
    FILE_NOT_FOUND = "file_not_found"
    PARSING_ERROR = "parsing_error"


@dataclass
class ValidationError:
    """Training data validation error."""
    code: str
    message: str
    line: Optional[int] = None
    field: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "code": self.code,
            "message": self.message,
        }
        if self.line is not None:
            result["line"] = self.line
        if self.field:
            result["field"] = self.field
        return result


@dataclass
class ValidationResult:
    """Result of training data validation."""
    valid: bool
    errors: List[ValidationError] = field(default_factory=list)
    warnings: List[ValidationError] = field(default_factory=list)
    stats: Dict[str, Any] = field(default_factory=dict)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "valid": self.valid,
            "errors": [e.to_dict() for e in self.errors],
            "warnings": [w.to_dict() for w in self.warnings],
            "stats": self.stats,
        }


class TrainingDataValidator:
    """Validates training data for fine-tuning."""
    
    MIN_EXAMPLES = 10
    MAX_EXAMPLE_TOKENS = 16384
    REQUIRED_CHAT_FIELDS = ["messages"]
    REQUIRED_MESSAGE_FIELDS = ["role", "content"]
    VALID_ROLES = ["system", "user", "assistant"]
    
    def __init__(self, model_type: str = "chat"):
        """
        Initialize validator.
        
        Args:
            model_type: Type of model ('chat' or 'completion')
        """
        self.model_type = model_type
    
    def validate_jsonl(self, content: str) -> ValidationResult:
        """
        Validate JSONL training data.
        
        Args:
            content: JSONL file content as string
            
        Returns:
            ValidationResult with errors, warnings, and stats
        """
        errors = []
        warnings = []
        examples = []
        
        lines = content.strip().split('\n')
        
        for i, line in enumerate(lines, 1):
            if not line.strip():
                continue
            
            try:
                example = json.loads(line)
                examples.append(example)
                
                # Validate example based on model type
                if self.model_type == "chat":
                    line_errors = self._validate_chat_example(example, i)
                else:
                    line_errors = self._validate_completion_example(example, i)
                
                errors.extend(line_errors)
                
            except json.JSONDecodeError as e:
                errors.append(ValidationError(
                    code=ValidationErrorCode.PARSING_ERROR.value,
                    message=f"Invalid JSON: {str(e)}",
                    line=i,
                ))
        
        # Check minimum examples
        if len(examples) < self.MIN_EXAMPLES:
            errors.append(ValidationError(
                code=ValidationErrorCode.TOO_FEW_EXAMPLES.value,
                message=f"Training file must have at least {self.MIN_EXAMPLES} examples, got {len(examples)}",
            ))
        
        # Calculate stats
        stats = self._calculate_stats(examples)
        
        # Add warnings
        if stats.get("avg_tokens", 0) > 4096:
            warnings.append(ValidationError(
                code="high_avg_tokens",
                message=f"Average token count ({stats['avg_tokens']}) is high, consider shorter examples",
            ))
        
        return ValidationResult(
            valid=len(errors) == 0,
            errors=errors,
            warnings=warnings,
            stats=stats,
        )
    
    def _validate_chat_example(self, example: Dict, line: int) -> List[ValidationError]:
        """Validate a chat completion training example."""
        errors = []
        
        # Check required fields
        if "messages" not in example:
            errors.append(ValidationError(
                code=ValidationErrorCode.MISSING_FIELD.value,
                message="Missing required field 'messages'",
                line=line,
                field="messages",
            ))
            return errors
        
        messages = example["messages"]
        if not isinstance(messages, list):
            errors.append(ValidationError(
                code=ValidationErrorCode.INVALID_FIELD.value,
                message="'messages' must be an array",
                line=line,
                field="messages",
            ))
            return errors
        
        if len(messages) < 2:
            errors.append(ValidationError(
                code=ValidationErrorCode.INVALID_FIELD.value,
                message="'messages' must have at least 2 messages",
                line=line,
                field="messages",
            ))
        
        # Validate each message
        for j, msg in enumerate(messages):
            if not isinstance(msg, dict):
                errors.append(ValidationError(
                    code=ValidationErrorCode.INVALID_FORMAT.value,
                    message=f"Message {j} must be an object",
                    line=line,
                ))
                continue
            
            # Check role
            if "role" not in msg:
                errors.append(ValidationError(
                    code=ValidationErrorCode.MISSING_FIELD.value,
                    message=f"Message {j} missing 'role'",
                    line=line,
                    field="role",
                ))
            elif msg["role"] not in self.VALID_ROLES:
                errors.append(ValidationError(
                    code=ValidationErrorCode.INVALID_FIELD.value,
                    message=f"Message {j} has invalid role '{msg['role']}'",
                    line=line,
                    field="role",
                ))
            
            # Check content
            if "content" not in msg:
                errors.append(ValidationError(
                    code=ValidationErrorCode.MISSING_FIELD.value,
                    message=f"Message {j} missing 'content'",
                    line=line,
                    field="content",
                ))
        
        # Check for assistant message
        has_assistant = any(m.get("role") == "assistant" for m in messages)
        if not has_assistant:
            errors.append(ValidationError(
                code=ValidationErrorCode.INVALID_FORMAT.value,
                message="Messages must include at least one 'assistant' role",
                line=line,
            ))
        
        return errors
    
    def _validate_completion_example(self, example: Dict, line: int) -> List[ValidationError]:
        """Validate a completion training example."""
        errors = []
        
        if "prompt" not in example:
            errors.append(ValidationError(
                code=ValidationErrorCode.MISSING_FIELD.value,
                message="Missing required field 'prompt'",
                line=line,
                field="prompt",
            ))
        
        if "completion" not in example:
            errors.append(ValidationError(
                code=ValidationErrorCode.MISSING_FIELD.value,
                message="Missing required field 'completion'",
                line=line,
                field="completion",
            ))
        
        return errors
    
    def _calculate_stats(self, examples: List[Dict]) -> Dict[str, Any]:
        """Calculate statistics about training data."""
        if not examples:
            return {}
        
        # Estimate tokens (rough approximation)
        total_tokens = 0
        for example in examples:
            content = json.dumps(example)
            # Rough token estimate: 4 chars per token
            total_tokens += len(content) // 4
        
        return {
            "num_examples": len(examples),
            "total_tokens": total_tokens,
            "avg_tokens": total_tokens // len(examples) if examples else 0,
        }


# ========================================
# Training Metrics
# ========================================

@dataclass
class TrainingMetrics:
    """Metrics from a training step."""
    step: int
    train_loss: float
    train_accuracy: float
    valid_loss: Optional[float] = None
    valid_accuracy: Optional[float] = None
    learning_rate: float = 0.0001
    epoch: float = 0.0
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "step": self.step,
            "train_loss": self.train_loss,
            "train_accuracy": self.train_accuracy,
            "learning_rate": self.learning_rate,
            "epoch": self.epoch,
        }
        if self.valid_loss is not None:
            result["valid_loss"] = self.valid_loss
        if self.valid_accuracy is not None:
            result["valid_accuracy"] = self.valid_accuracy
        return result


class MetricsTracker:
    """Tracks training metrics over time."""
    
    def __init__(self):
        """Initialize tracker."""
        self.metrics: List[TrainingMetrics] = []
    
    def add_metrics(self, metrics: TrainingMetrics):
        """Add metrics for a step."""
        self.metrics.append(metrics)
    
    def get_latest(self) -> Optional[TrainingMetrics]:
        """Get latest metrics."""
        return self.metrics[-1] if self.metrics else None
    
    def get_history(self, last_n: int = 100) -> List[TrainingMetrics]:
        """Get metrics history."""
        return self.metrics[-last_n:]
    
    def get_summary(self) -> Dict[str, Any]:
        """Get summary statistics."""
        if not self.metrics:
            return {}
        
        losses = [m.train_loss for m in self.metrics]
        accuracies = [m.train_accuracy for m in self.metrics]
        
        return {
            "total_steps": len(self.metrics),
            "final_loss": losses[-1],
            "final_accuracy": accuracies[-1],
            "min_loss": min(losses),
            "max_accuracy": max(accuracies),
        }


# ========================================
# Training Simulation
# ========================================

class TrainingSimulator:
    """Simulates fine-tuning training progress."""
    
    def __init__(
        self,
        total_steps: int = 1000,
        steps_per_epoch: int = 100,
        checkpoint_interval: int = 200,
    ):
        """
        Initialize simulator.
        
        Args:
            total_steps: Total training steps
            steps_per_epoch: Steps per epoch
            checkpoint_interval: Steps between checkpoints
        """
        self.total_steps = total_steps
        self.steps_per_epoch = steps_per_epoch
        self.checkpoint_interval = checkpoint_interval
        self.current_step = 0
        self.metrics_tracker = MetricsTracker()
    
    def simulate_step(self) -> TrainingMetrics:
        """
        Simulate a training step.
        
        Returns:
            TrainingMetrics for this step
        """
        self.current_step += 1
        
        # Simulate decreasing loss and increasing accuracy
        progress = self.current_step / self.total_steps
        base_loss = 2.5 * (1 - progress) + 0.3
        noise = (hash(str(self.current_step)) % 100) / 1000 - 0.05
        
        metrics = TrainingMetrics(
            step=self.current_step,
            train_loss=max(0.1, base_loss + noise),
            train_accuracy=min(0.99, 0.3 + 0.65 * progress + noise),
            learning_rate=0.0001 * (1 - 0.9 * progress),  # Learning rate decay
            epoch=self.current_step / self.steps_per_epoch,
        )
        
        self.metrics_tracker.add_metrics(metrics)
        return metrics
    
    def should_checkpoint(self) -> bool:
        """Check if a checkpoint should be created."""
        return self.current_step % self.checkpoint_interval == 0
    
    def is_complete(self) -> bool:
        """Check if training is complete."""
        return self.current_step >= self.total_steps
    
    def get_progress(self) -> float:
        """Get training progress (0-1)."""
        return self.current_step / self.total_steps


# ========================================
# Model Naming
# ========================================

class FineTunedModelNamer:
    """Generates names for fine-tuned models."""
    
    @staticmethod
    def generate_name(
        base_model: str,
        organization_id: str,
        suffix: Optional[str],
        job_id: str,
    ) -> str:
        """
        Generate fine-tuned model name.
        
        Format: ft:{base_model}:{organization}:{suffix}:{job_id}
        
        Args:
            base_model: Base model name
            organization_id: Organization ID
            suffix: User-provided suffix
            job_id: Fine-tuning job ID
            
        Returns:
            Fine-tuned model name
        """
        # Clean base model name
        base = base_model.split("-")[0]
        
        # Use suffix or generate one
        suffix_part = suffix if suffix else "model"
        
        # Extract job hash
        job_hash = job_id.replace("ftjob-", "")[:8]
        
        return f"ft:{base}:{organization_id}:{suffix_part}:{job_hash}"
    
    @staticmethod
    def parse_name(model_name: str) -> Optional[Dict[str, str]]:
        """
        Parse a fine-tuned model name.
        
        Args:
            model_name: Fine-tuned model name
            
        Returns:
            Dict with base_model, organization, suffix, job_hash or None
        """
        if not model_name.startswith("ft:"):
            return None
        
        parts = model_name.split(":")
        if len(parts) < 5:
            return None
        
        return {
            "base_model": parts[1],
            "organization": parts[2],
            "suffix": parts[3],
            "job_hash": parts[4],
        }


# ========================================
# Advanced Fine-tuning Handler
# ========================================

class AdvancedFineTuningHandler(FineTuningHandler):
    """Extended fine-tuning handler with advanced features."""
    
    def __init__(
        self,
        backend: Optional[Any] = None,
        mock_mode: bool = True,
        organization_id: str = "org-mock",
        file_store: Optional[Dict[str, str]] = None,
    ):
        """
        Initialize advanced handler.
        
        Args:
            backend: Backend for actual fine-tuning
            mock_mode: If True, return mock results
            organization_id: Organization ID
            file_store: Mock file storage for validation
        """
        super().__init__(backend, mock_mode, organization_id)
        self.file_store = file_store or {}
        self.validators: Dict[str, TrainingDataValidator] = {}
        self.simulators: Dict[str, TrainingSimulator] = {}
        self._training_threads: Dict[str, threading.Thread] = {}
    
    def validate_training_file(self, file_id: str) -> ValidationResult:
        """
        Validate a training file.
        
        Args:
            file_id: File ID to validate
            
        Returns:
            ValidationResult
        """
        if file_id not in self.file_store:
            return ValidationResult(
                valid=False,
                errors=[ValidationError(
                    code=ValidationErrorCode.FILE_NOT_FOUND.value,
                    message=f"File '{file_id}' not found",
                )],
            )
        
        content = self.file_store[file_id]
        validator = TrainingDataValidator(model_type="chat")
        return validator.validate_jsonl(content)
    
    def start_training_simulation(
        self,
        job_id: str,
        callback: Optional[Callable[[str, FineTuningEvent], None]] = None,
    ):
        """
        Start training simulation for a job.
        
        Args:
            job_id: Job ID to simulate
            callback: Optional callback for events
        """
        if job_id not in self._jobs:
            return
        
        job = self._jobs[job_id]
        
        # Calculate total steps based on hyperparameters
        n_epochs = job.hyperparameters.n_epochs
        if n_epochs == "auto":
            n_epochs = 3
        
        # Assume 100 examples, 10 steps per epoch
        total_steps = n_epochs * 10
        
        simulator = TrainingSimulator(
            total_steps=total_steps,
            steps_per_epoch=10,
            checkpoint_interval=5,
        )
        self.simulators[job_id] = simulator
        
        # Update job status
        job.status = FineTuningStatus.RUNNING.value
        
        # Add running event
        self._add_event(job_id, "info", "Training started")
    
    def advance_training(self, job_id: str) -> Optional[Dict[str, Any]]:
        """
        Advance training by one step.
        
        Args:
            job_id: Job ID
            
        Returns:
            Step metrics or None
        """
        if job_id not in self.simulators:
            return None
        
        simulator = self.simulators[job_id]
        job = self._jobs.get(job_id)
        
        if not job or simulator.is_complete():
            return None
        
        # Simulate step
        metrics = simulator.simulate_step()
        
        # Add metrics event
        self._add_event(
            job_id,
            "info",
            f"Step {metrics.step}: loss={metrics.train_loss:.4f}, accuracy={metrics.train_accuracy:.4f}",
            event_type="metrics",
            data=metrics.to_dict(),
        )
        
        # Create checkpoint if needed
        if simulator.should_checkpoint():
            self._create_checkpoint(job_id, metrics)
        
        # Check if complete
        if simulator.is_complete():
            self._complete_training(job_id)
        
        return metrics.to_dict()
    
    def run_full_training(self, job_id: str, delay: float = 0.1):
        """
        Run full training simulation.
        
        Args:
            job_id: Job ID
            delay: Delay between steps (seconds)
        """
        self.start_training_simulation(job_id)
        
        while True:
            result = self.advance_training(job_id)
            if result is None:
                break
            time.sleep(delay)
    
    def get_job_metrics(self, job_id: str) -> Optional[Dict[str, Any]]:
        """
        Get training metrics for a job.
        
        Args:
            job_id: Job ID
            
        Returns:
            Metrics summary or None
        """
        if job_id not in self.simulators:
            return None
        
        simulator = self.simulators[job_id]
        return simulator.metrics_tracker.get_summary()
    
    def _add_event(
        self,
        job_id: str,
        level: str,
        message: str,
        event_type: str = "message",
        data: Optional[Dict] = None,
    ):
        """Add an event to a job."""
        if job_id not in self._events:
            self._events[job_id] = []
        
        event_id = f"ftevent-{hashlib.md5(f'{job_id}{len(self._events[job_id])}'.encode()).hexdigest()[:8]}"
        
        event = FineTuningEvent(
            id=event_id,
            created_at=int(time.time()),
            level=level,
            message=message,
            type=event_type,
            data=data,
        )
        
        self._events[job_id].append(event)
    
    def _create_checkpoint(self, job_id: str, metrics: TrainingMetrics):
        """Create a training checkpoint."""
        if job_id not in self._checkpoints:
            self._checkpoints[job_id] = []
        
        job = self._jobs[job_id]
        checkpoint_id = f"ftckpt-{hashlib.md5(f'{job_id}{metrics.step}'.encode()).hexdigest()[:8]}"
        
        # Generate checkpoint model name
        checkpoint_model = FineTunedModelNamer.generate_name(
            base_model=job.model,
            organization_id=self.organization_id,
            suffix=f"{job.user_provided_suffix or 'model'}-step{metrics.step}",
            job_id=job_id,
        )
        
        checkpoint = FineTuningCheckpoint(
            id=checkpoint_id,
            created_at=int(time.time()),
            fine_tuning_job_id=job_id,
            fine_tuned_model_checkpoint=checkpoint_model,
            step_number=metrics.step,
            metrics={
                "train_loss": metrics.train_loss,
                "train_accuracy": metrics.train_accuracy,
            },
        )
        
        self._checkpoints[job_id].append(checkpoint)
        
        self._add_event(job_id, "info", f"Checkpoint created at step {metrics.step}")
    
    def _complete_training(self, job_id: str):
        """Complete training and update job."""
        job = self._jobs[job_id]
        
        # Generate final model name
        final_model = FineTunedModelNamer.generate_name(
            base_model=job.model,
            organization_id=self.organization_id,
            suffix=job.user_provided_suffix,
            job_id=job_id,
        )
        
        # Update job
        job.status = FineTuningStatus.SUCCEEDED.value
        job.finished_at = int(time.time())
        job.fine_tuned_model = final_model
        
        # Get metrics
        if job_id in self.simulators:
            summary = self.simulators[job_id].metrics_tracker.get_summary()
            job.trained_tokens = summary.get("total_steps", 0) * 1000  # Estimate
        
        self._add_event(job_id, "info", f"Training complete. Fine-tuned model: {final_model}")


# ========================================
# Factory and Utilities
# ========================================

def get_advanced_fine_tuning_handler(
    backend: Optional[Any] = None,
    mock_mode: bool = True,
    file_store: Optional[Dict[str, str]] = None,
) -> AdvancedFineTuningHandler:
    """
    Factory function to create advanced fine-tuning handler.
    
    Args:
        backend: Optional backend service
        mock_mode: If True, use mock responses
        file_store: Mock file storage
        
    Returns:
        Configured AdvancedFineTuningHandler instance
    """
    return AdvancedFineTuningHandler(
        backend=backend,
        mock_mode=mock_mode,
        file_store=file_store,
    )


def validate_training_data(content: str, model_type: str = "chat") -> ValidationResult:
    """
    Validate training data content.
    
    Args:
        content: JSONL content
        model_type: 'chat' or 'completion'
        
    Returns:
        ValidationResult
    """
    validator = TrainingDataValidator(model_type=model_type)
    return validator.validate_jsonl(content)


def estimate_training_cost(
    num_examples: int,
    avg_tokens_per_example: int,
    n_epochs: int = 3,
) -> Dict[str, Any]:
    """
    Estimate fine-tuning training cost.
    
    Args:
        num_examples: Number of training examples
        avg_tokens_per_example: Average tokens per example
        n_epochs: Number of training epochs
        
    Returns:
        Cost estimate dictionary
    """
    total_tokens = num_examples * avg_tokens_per_example * n_epochs
    
    # Pricing (approximate, varies by model)
    training_cost_per_1k = 0.008  # $8 per 1M tokens
    
    return {
        "total_tokens": total_tokens,
        "estimated_cost_usd": round(total_tokens * training_cost_per_1k / 1000, 2),
        "estimated_time_minutes": max(5, total_tokens // 10000),
        "epochs": n_epochs,
    }


def generate_sample_training_data(num_examples: int = 20) -> str:
    """
    Generate sample training data for testing.
    
    Args:
        num_examples: Number of examples to generate
        
    Returns:
        JSONL string
    """
    lines = []
    topics = [
        ("What is Python?", "Python is a high-level programming language."),
        ("How do I create a list?", "Use square brackets: my_list = [1, 2, 3]"),
        ("What is a function?", "A function is a reusable block of code."),
        ("How do loops work?", "Loops repeat code using for or while statements."),
        ("What are variables?", "Variables store data values in memory."),
    ]
    
    for i in range(num_examples):
        topic = topics[i % len(topics)]
        example = {
            "messages": [
                {"role": "system", "content": "You are a helpful coding assistant."},
                {"role": "user", "content": topic[0]},
                {"role": "assistant", "content": topic[1]},
            ]
        }
        lines.append(json.dumps(example))
    
    return "\n".join(lines)


# ========================================
# Exports
# ========================================

__all__ = [
    # Validation
    "ValidationErrorCode",
    "ValidationError",
    "ValidationResult",
    "TrainingDataValidator",
    # Metrics
    "TrainingMetrics",
    "MetricsTracker",
    # Simulation
    "TrainingSimulator",
    # Model naming
    "FineTunedModelNamer",
    # Handler
    "AdvancedFineTuningHandler",
    # Utilities
    "get_advanced_fine_tuning_handler",
    "validate_training_data",
    "estimate_training_cost",
    "generate_sample_training_data",
]