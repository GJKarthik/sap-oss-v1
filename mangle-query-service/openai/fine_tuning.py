"""
OpenAI-compatible Fine-tuning Endpoint Handler

Day 17 Deliverable: Fine-tuning jobs - data models and job management

POST /v1/fine_tuning/jobs - Create a fine-tuning job
GET /v1/fine_tuning/jobs - List fine-tuning jobs
GET /v1/fine_tuning/jobs/{fine_tuning_job_id} - Retrieve a fine-tuning job
POST /v1/fine_tuning/jobs/{fine_tuning_job_id}/cancel - Cancel a fine-tuning job
GET /v1/fine_tuning/jobs/{fine_tuning_job_id}/events - List events for a job
GET /v1/fine_tuning/jobs/{fine_tuning_job_id}/checkpoints - List checkpoints
"""

import time
import hashlib
from enum import Enum
from typing import Dict, Any, Optional, List, Union
from dataclasses import dataclass, field


# ========================================
# Enums and Constants
# ========================================

class FineTuningStatus(str, Enum):
    """Fine-tuning job status."""
    VALIDATING_FILES = "validating_files"
    QUEUED = "queued"
    RUNNING = "running"
    SUCCEEDED = "succeeded"
    FAILED = "failed"
    CANCELLED = "cancelled"
    
    @classmethod
    def is_terminal(cls, status: str) -> bool:
        """Check if status is terminal (job won't change)."""
        return status in [cls.SUCCEEDED.value, cls.FAILED.value, cls.CANCELLED.value]
    
    @classmethod
    def is_active(cls, status: str) -> bool:
        """Check if job is actively processing."""
        return status in [
            cls.VALIDATING_FILES.value,
            cls.QUEUED.value,
            cls.RUNNING.value,
        ]


class FineTuningEventLevel(str, Enum):
    """Event severity level."""
    INFO = "info"
    WARN = "warn"
    ERROR = "error"


class FineTuningEventType(str, Enum):
    """Event type for fine-tuning."""
    MESSAGE = "message"
    METRICS = "metrics"


# Supported base models for fine-tuning
FINETUNE_BASE_MODELS = [
    "gpt-4o-2024-08-06",
    "gpt-4o-mini-2024-07-18",
    "gpt-4-0613",
    "gpt-3.5-turbo-0125",
    "gpt-3.5-turbo-1106",
    "gpt-3.5-turbo-0613",
    "babbage-002",
    "davinci-002",
]

# Default hyperparameters
DEFAULT_N_EPOCHS = "auto"
DEFAULT_BATCH_SIZE = "auto"
DEFAULT_LEARNING_RATE_MULTIPLIER = "auto"

# Limits
MAX_SUFFIX_LENGTH = 40
MIN_TRAINING_EXAMPLES = 10


# ========================================
# Hyperparameter Models
# ========================================

@dataclass
class Hyperparameters:
    """Hyperparameters for fine-tuning."""
    n_epochs: Union[int, str] = DEFAULT_N_EPOCHS
    batch_size: Union[int, str] = DEFAULT_BATCH_SIZE
    learning_rate_multiplier: Union[float, str] = DEFAULT_LEARNING_RATE_MULTIPLIER
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "n_epochs": self.n_epochs,
            "batch_size": self.batch_size,
            "learning_rate_multiplier": self.learning_rate_multiplier,
        }
    
    @classmethod
    def from_dict(cls, data: Optional[Dict[str, Any]]) -> "Hyperparameters":
        """Create from dictionary."""
        if not data:
            return cls()
        return cls(
            n_epochs=data.get("n_epochs", DEFAULT_N_EPOCHS),
            batch_size=data.get("batch_size", DEFAULT_BATCH_SIZE),
            learning_rate_multiplier=data.get(
                "learning_rate_multiplier",
                DEFAULT_LEARNING_RATE_MULTIPLIER,
            ),
        )


@dataclass
class WandbIntegration:
    """Weights & Biases integration config."""
    type: str = "wandb"
    project: str = ""
    name: Optional[str] = None
    entity: Optional[str] = None
    tags: List[str] = field(default_factory=list)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "type": self.type,
            "project": self.project,
        }
        if self.name:
            result["name"] = self.name
        if self.entity:
            result["entity"] = self.entity
        if self.tags:
            result["tags"] = self.tags
        return result
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "WandbIntegration":
        """Create from dictionary."""
        return cls(
            type=data.get("type", "wandb"),
            project=data.get("project", ""),
            name=data.get("name"),
            entity=data.get("entity"),
            tags=data.get("tags", []),
        )


# ========================================
# Request Models
# ========================================

@dataclass
class FineTuningJobRequest:
    """Request to create a fine-tuning job."""
    training_file: str
    model: str
    validation_file: Optional[str] = None
    hyperparameters: Optional[Hyperparameters] = None
    suffix: Optional[str] = None
    integrations: Optional[List[WandbIntegration]] = None
    seed: Optional[int] = None
    
    def __post_init__(self):
        """Validate request."""
        if self.hyperparameters is None:
            self.hyperparameters = Hyperparameters()
        
        # Validate suffix
        if self.suffix and len(self.suffix) > MAX_SUFFIX_LENGTH:
            raise ValueError(f"suffix cannot be longer than {MAX_SUFFIX_LENGTH} characters")
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "FineTuningJobRequest":
        """Create from dictionary."""
        integrations = None
        if data.get("integrations"):
            integrations = [
                WandbIntegration.from_dict(i) if isinstance(i, dict) else i
                for i in data["integrations"]
            ]
        
        return cls(
            training_file=data.get("training_file", ""),
            model=data.get("model", ""),
            validation_file=data.get("validation_file"),
            hyperparameters=Hyperparameters.from_dict(data.get("hyperparameters")),
            suffix=data.get("suffix"),
            integrations=integrations,
            seed=data.get("seed"),
        )
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "training_file": self.training_file,
            "model": self.model,
        }
        if self.validation_file:
            result["validation_file"] = self.validation_file
        if self.hyperparameters:
            result["hyperparameters"] = self.hyperparameters.to_dict()
        if self.suffix:
            result["suffix"] = self.suffix
        if self.integrations:
            result["integrations"] = [i.to_dict() for i in self.integrations]
        if self.seed is not None:
            result["seed"] = self.seed
        return result


@dataclass
class ListJobsRequest:
    """Request to list fine-tuning jobs."""
    after: Optional[str] = None
    limit: int = 20
    
    def __post_init__(self):
        """Validate request."""
        if self.limit < 1:
            self.limit = 1
        elif self.limit > 100:
            self.limit = 100


@dataclass
class ListEventsRequest:
    """Request to list job events."""
    fine_tuning_job_id: str
    after: Optional[str] = None
    limit: int = 20
    
    def __post_init__(self):
        """Validate request."""
        if self.limit < 1:
            self.limit = 1
        elif self.limit > 100:
            self.limit = 100


# ========================================
# Response Models
# ========================================

@dataclass
class FineTuningError:
    """Error information for failed jobs."""
    code: str
    message: str
    param: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "code": self.code,
            "message": self.message,
        }
        if self.param:
            result["param"] = self.param
        return result


@dataclass
class FineTuningJobObject:
    """Fine-tuning job object."""
    id: str
    object: str = "fine_tuning.job"
    created_at: int = 0
    finished_at: Optional[int] = None
    model: str = ""
    fine_tuned_model: Optional[str] = None
    organization_id: str = ""
    status: str = FineTuningStatus.VALIDATING_FILES.value
    hyperparameters: Optional[Hyperparameters] = None
    training_file: str = ""
    validation_file: Optional[str] = None
    result_files: List[str] = field(default_factory=list)
    trained_tokens: Optional[int] = None
    error: Optional[FineTuningError] = None
    user_provided_suffix: Optional[str] = None
    seed: Optional[int] = None
    estimated_finish: Optional[int] = None
    integrations: Optional[List[WandbIntegration]] = None
    
    def __post_init__(self):
        """Initialize defaults."""
        if not self.created_at:
            self.created_at = int(time.time())
        if self.hyperparameters is None:
            self.hyperparameters = Hyperparameters()
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "id": self.id,
            "object": self.object,
            "created_at": self.created_at,
            "model": self.model,
            "status": self.status,
            "training_file": self.training_file,
            "result_files": self.result_files,
            "organization_id": self.organization_id,
        }
        
        if self.finished_at:
            result["finished_at"] = self.finished_at
        if self.fine_tuned_model:
            result["fine_tuned_model"] = self.fine_tuned_model
        if self.hyperparameters:
            result["hyperparameters"] = self.hyperparameters.to_dict()
        if self.validation_file:
            result["validation_file"] = self.validation_file
        if self.trained_tokens is not None:
            result["trained_tokens"] = self.trained_tokens
        if self.error:
            result["error"] = self.error.to_dict()
        if self.user_provided_suffix:
            result["user_provided_suffix"] = self.user_provided_suffix
        if self.seed is not None:
            result["seed"] = self.seed
        if self.estimated_finish:
            result["estimated_finish"] = self.estimated_finish
        if self.integrations:
            result["integrations"] = [i.to_dict() for i in self.integrations]
        
        return result


@dataclass
class FineTuningEvent:
    """Event for fine-tuning job."""
    id: str
    object: str = "fine_tuning.job.event"
    created_at: int = 0
    level: str = FineTuningEventLevel.INFO.value
    message: str = ""
    type: str = FineTuningEventType.MESSAGE.value
    data: Optional[Dict[str, Any]] = None
    
    def __post_init__(self):
        """Initialize defaults."""
        if not self.created_at:
            self.created_at = int(time.time())
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "id": self.id,
            "object": self.object,
            "created_at": self.created_at,
            "level": self.level,
            "message": self.message,
            "type": self.type,
        }
        if self.data:
            result["data"] = self.data
        return result


@dataclass
class FineTuningCheckpoint:
    """Checkpoint for fine-tuning job."""
    id: str
    object: str = "fine_tuning.job.checkpoint"
    created_at: int = 0
    fine_tuning_job_id: str = ""
    fine_tuned_model_checkpoint: str = ""
    step_number: int = 0
    metrics: Dict[str, float] = field(default_factory=dict)
    
    def __post_init__(self):
        """Initialize defaults."""
        if not self.created_at:
            self.created_at = int(time.time())
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "id": self.id,
            "object": self.object,
            "created_at": self.created_at,
            "fine_tuning_job_id": self.fine_tuning_job_id,
            "fine_tuned_model_checkpoint": self.fine_tuned_model_checkpoint,
            "step_number": self.step_number,
            "metrics": self.metrics,
        }


@dataclass
class FineTuningJobListResponse:
    """Response for listing fine-tuning jobs."""
    data: List[FineTuningJobObject]
    object: str = "list"
    has_more: bool = False
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "object": self.object,
            "data": [j.to_dict() for j in self.data],
            "has_more": self.has_more,
        }


@dataclass
class FineTuningEventListResponse:
    """Response for listing job events."""
    data: List[FineTuningEvent]
    object: str = "list"
    has_more: bool = False
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "object": self.object,
            "data": [e.to_dict() for e in self.data],
            "has_more": self.has_more,
        }


@dataclass
class FineTuningCheckpointListResponse:
    """Response for listing checkpoints."""
    data: List[FineTuningCheckpoint]
    object: str = "list"
    has_more: bool = False
    first_id: Optional[str] = None
    last_id: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "object": self.object,
            "data": [c.to_dict() for c in self.data],
            "has_more": self.has_more,
        }
        if self.first_id:
            result["first_id"] = self.first_id
        if self.last_id:
            result["last_id"] = self.last_id
        return result


@dataclass
class FineTuningErrorResponse:
    """Error response for fine-tuning endpoints."""
    message: str
    type: str = "invalid_request_error"
    param: Optional[str] = None
    code: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to error response format."""
        error = {
            "message": self.message,
            "type": self.type,
        }
        if self.param:
            error["param"] = self.param
        if self.code:
            error["code"] = self.code
        return {"error": error}


# ========================================
# Fine-tuning Handler
# ========================================

class FineTuningHandler:
    """Handler for fine-tuning operations."""
    
    def __init__(
        self,
        backend: Optional[Any] = None,
        mock_mode: bool = True,
        organization_id: str = "org-mock",
    ):
        """
        Initialize handler.
        
        Args:
            backend: Backend for actual fine-tuning calls
            mock_mode: If True, return mock results
            organization_id: Organization ID for jobs
        """
        self.backend = backend
        self.mock_mode = mock_mode
        self.organization_id = organization_id
        
        # Mock job storage
        self._jobs: Dict[str, FineTuningJobObject] = {}
        self._events: Dict[str, List[FineTuningEvent]] = {}
        self._checkpoints: Dict[str, List[FineTuningCheckpoint]] = {}
    
    def create_job(self, request: FineTuningJobRequest) -> Dict[str, Any]:
        """
        Create a fine-tuning job.
        
        Args:
            request: Job creation request
            
        Returns:
            Job object dictionary
        """
        # Validate request
        error = self._validate_create_request(request)
        if error:
            return error
        
        if self.mock_mode:
            return self._mock_create_job(request)
        
        return self._real_create_job(request)
    
    def list_jobs(
        self,
        after: Optional[str] = None,
        limit: int = 20,
    ) -> Dict[str, Any]:
        """
        List fine-tuning jobs.
        
        Args:
            after: Cursor for pagination
            limit: Number of results to return
            
        Returns:
            List response dictionary
        """
        if self.mock_mode:
            return self._mock_list_jobs(after, limit)
        
        return self._real_list_jobs(after, limit)
    
    def retrieve_job(self, job_id: str) -> Dict[str, Any]:
        """
        Retrieve a fine-tuning job.
        
        Args:
            job_id: Job ID to retrieve
            
        Returns:
            Job object or error dictionary
        """
        if self.mock_mode:
            return self._mock_retrieve_job(job_id)
        
        return self._real_retrieve_job(job_id)
    
    def cancel_job(self, job_id: str) -> Dict[str, Any]:
        """
        Cancel a fine-tuning job.
        
        Args:
            job_id: Job ID to cancel
            
        Returns:
            Job object or error dictionary
        """
        if self.mock_mode:
            return self._mock_cancel_job(job_id)
        
        return self._real_cancel_job(job_id)
    
    def list_events(
        self,
        job_id: str,
        after: Optional[str] = None,
        limit: int = 20,
    ) -> Dict[str, Any]:
        """
        List events for a fine-tuning job.
        
        Args:
            job_id: Job ID
            after: Cursor for pagination
            limit: Number of results
            
        Returns:
            Events list response dictionary
        """
        if self.mock_mode:
            return self._mock_list_events(job_id, after, limit)
        
        return self._real_list_events(job_id, after, limit)
    
    def list_checkpoints(
        self,
        job_id: str,
        after: Optional[str] = None,
        limit: int = 10,
    ) -> Dict[str, Any]:
        """
        List checkpoints for a fine-tuning job.
        
        Args:
            job_id: Job ID
            after: Cursor for pagination
            limit: Number of results
            
        Returns:
            Checkpoints list response dictionary
        """
        if self.mock_mode:
            return self._mock_list_checkpoints(job_id, after, limit)
        
        return self._real_list_checkpoints(job_id, after, limit)
    
    def handle_request(self, method: str, path: str, data: Optional[Dict] = None) -> Dict[str, Any]:
        """
        Handle HTTP request routing.
        
        Args:
            method: HTTP method
            path: Request path
            data: Request data
            
        Returns:
            Response dictionary
        """
        # POST /v1/fine_tuning/jobs
        if method == "POST" and path == "/v1/fine_tuning/jobs":
            if not data:
                return FineTuningErrorResponse(
                    message="Request body is required",
                    code="invalid_request",
                ).to_dict()
            request = FineTuningJobRequest.from_dict(data)
            return self.create_job(request)
        
        # GET /v1/fine_tuning/jobs
        if method == "GET" and path == "/v1/fine_tuning/jobs":
            after = data.get("after") if data else None
            limit = data.get("limit", 20) if data else 20
            return self.list_jobs(after, limit)
        
        # GET /v1/fine_tuning/jobs/{id}
        if method == "GET" and path.startswith("/v1/fine_tuning/jobs/"):
            parts = path.split("/")
            if len(parts) == 5:
                job_id = parts[4]
                return self.retrieve_job(job_id)
            elif len(parts) == 6:
                job_id = parts[4]
                action = parts[5]
                if action == "events":
                    after = data.get("after") if data else None
                    limit = data.get("limit", 20) if data else 20
                    return self.list_events(job_id, after, limit)
                elif action == "checkpoints":
                    after = data.get("after") if data else None
                    limit = data.get("limit", 10) if data else 10
                    return self.list_checkpoints(job_id, after, limit)
        
        # POST /v1/fine_tuning/jobs/{id}/cancel
        if method == "POST" and "/cancel" in path:
            parts = path.split("/")
            job_id = parts[4]
            return self.cancel_job(job_id)
        
        return FineTuningErrorResponse(
            message=f"Unknown endpoint: {method} {path}",
            code="invalid_endpoint",
        ).to_dict()
    
    # ========================================
    # Validation
    # ========================================
    
    def _validate_create_request(self, request: FineTuningJobRequest) -> Optional[Dict]:
        """Validate job creation request."""
        if not request.training_file:
            return FineTuningErrorResponse(
                message="'training_file' is required",
                param="training_file",
                code="missing_required_parameter",
            ).to_dict()
        
        if not request.model:
            return FineTuningErrorResponse(
                message="'model' is required",
                param="model",
                code="missing_required_parameter",
            ).to_dict()
        
        # Validate model is supported for fine-tuning
        base_model = request.model.split(":")[0]  # Handle ft: prefix
        if base_model not in FINETUNE_BASE_MODELS and not base_model.startswith("ft:"):
            return FineTuningErrorResponse(
                message=f"Model '{request.model}' is not supported for fine-tuning",
                param="model",
                code="invalid_model",
            ).to_dict()
        
        return None
    
    # ========================================
    # Mock Implementations
    # ========================================
    
    def _mock_create_job(self, request: FineTuningJobRequest) -> Dict[str, Any]:
        """Create mock fine-tuning job."""
        job_hash = hashlib.md5(
            f"{request.training_file}{request.model}{time.time()}".encode()
        ).hexdigest()[:12]
        job_id = f"ftjob-{job_hash}"
        
        job = FineTuningJobObject(
            id=job_id,
            created_at=int(time.time()),
            model=request.model,
            status=FineTuningStatus.VALIDATING_FILES.value,
            hyperparameters=request.hyperparameters,
            training_file=request.training_file,
            validation_file=request.validation_file,
            organization_id=self.organization_id,
            user_provided_suffix=request.suffix,
            seed=request.seed,
            integrations=request.integrations,
            estimated_finish=int(time.time()) + 3600,  # 1 hour from now
        )
        
        self._jobs[job_id] = job
        
        # Create initial events
        self._events[job_id] = [
            FineTuningEvent(
                id=f"ftevent-{job_hash}-1",
                created_at=int(time.time()),
                level=FineTuningEventLevel.INFO.value,
                message="Fine-tuning job created",
                type=FineTuningEventType.MESSAGE.value,
            ),
            FineTuningEvent(
                id=f"ftevent-{job_hash}-2",
                created_at=int(time.time()),
                level=FineTuningEventLevel.INFO.value,
                message="Validating training file",
                type=FineTuningEventType.MESSAGE.value,
            ),
        ]
        
        return job.to_dict()
    
    def _mock_list_jobs(self, after: Optional[str], limit: int) -> Dict[str, Any]:
        """List mock fine-tuning jobs."""
        jobs = list(self._jobs.values())
        jobs.sort(key=lambda j: j.created_at, reverse=True)
        
        # Handle pagination
        if after:
            start_idx = 0
            for i, job in enumerate(jobs):
                if job.id == after:
                    start_idx = i + 1
                    break
            jobs = jobs[start_idx:]
        
        # Apply limit
        has_more = len(jobs) > limit
        jobs = jobs[:limit]
        
        response = FineTuningJobListResponse(
            data=jobs,
            has_more=has_more,
        )
        return response.to_dict()
    
    def _mock_retrieve_job(self, job_id: str) -> Dict[str, Any]:
        """Retrieve mock fine-tuning job."""
        if job_id not in self._jobs:
            return FineTuningErrorResponse(
                message=f"No fine-tuning job with id '{job_id}' found",
                code="job_not_found",
            ).to_dict()
        
        return self._jobs[job_id].to_dict()
    
    def _mock_cancel_job(self, job_id: str) -> Dict[str, Any]:
        """Cancel mock fine-tuning job."""
        if job_id not in self._jobs:
            return FineTuningErrorResponse(
                message=f"No fine-tuning job with id '{job_id}' found",
                code="job_not_found",
            ).to_dict()
        
        job = self._jobs[job_id]
        
        # Check if job can be cancelled
        if FineTuningStatus.is_terminal(job.status):
            return FineTuningErrorResponse(
                message=f"Job '{job_id}' cannot be cancelled (status: {job.status})",
                code="invalid_operation",
            ).to_dict()
        
        # Cancel the job
        job.status = FineTuningStatus.CANCELLED.value
        job.finished_at = int(time.time())
        
        # Add cancel event
        if job_id in self._events:
            self._events[job_id].append(
                FineTuningEvent(
                    id=f"ftevent-cancel-{job_id}",
                    created_at=int(time.time()),
                    level=FineTuningEventLevel.INFO.value,
                    message="Fine-tuning job cancelled",
                    type=FineTuningEventType.MESSAGE.value,
                )
            )
        
        return job.to_dict()
    
    def _mock_list_events(
        self,
        job_id: str,
        after: Optional[str],
        limit: int,
    ) -> Dict[str, Any]:
        """List mock events for job."""
        if job_id not in self._jobs:
            return FineTuningErrorResponse(
                message=f"No fine-tuning job with id '{job_id}' found",
                code="job_not_found",
            ).to_dict()
        
        events = self._events.get(job_id, [])
        events.sort(key=lambda e: e.created_at)
        
        # Handle pagination
        if after:
            start_idx = 0
            for i, event in enumerate(events):
                if event.id == after:
                    start_idx = i + 1
                    break
            events = events[start_idx:]
        
        has_more = len(events) > limit
        events = events[:limit]
        
        response = FineTuningEventListResponse(
            data=events,
            has_more=has_more,
        )
        return response.to_dict()
    
    def _mock_list_checkpoints(
        self,
        job_id: str,
        after: Optional[str],
        limit: int,
    ) -> Dict[str, Any]:
        """List mock checkpoints for job."""
        if job_id not in self._jobs:
            return FineTuningErrorResponse(
                message=f"No fine-tuning job with id '{job_id}' found",
                code="job_not_found",
            ).to_dict()
        
        checkpoints = self._checkpoints.get(job_id, [])
        
        # Handle pagination
        if after:
            start_idx = 0
            for i, cp in enumerate(checkpoints):
                if cp.id == after:
                    start_idx = i + 1
                    break
            checkpoints = checkpoints[start_idx:]
        
        has_more = len(checkpoints) > limit
        checkpoints = checkpoints[:limit]
        
        first_id = checkpoints[0].id if checkpoints else None
        last_id = checkpoints[-1].id if checkpoints else None
        
        response = FineTuningCheckpointListResponse(
            data=checkpoints,
            has_more=has_more,
            first_id=first_id,
            last_id=last_id,
        )
        return response.to_dict()
    
    # ========================================
    # Real Implementations (stubs)
    # ========================================
    
    def _real_create_job(self, request: FineTuningJobRequest) -> Dict[str, Any]:
        """Create real fine-tuning job."""
        return self._mock_create_job(request)
    
    def _real_list_jobs(self, after: Optional[str], limit: int) -> Dict[str, Any]:
        """List real fine-tuning jobs."""
        return self._mock_list_jobs(after, limit)
    
    def _real_retrieve_job(self, job_id: str) -> Dict[str, Any]:
        """Retrieve real fine-tuning job."""
        return self._mock_retrieve_job(job_id)
    
    def _real_cancel_job(self, job_id: str) -> Dict[str, Any]:
        """Cancel real fine-tuning job."""
        return self._mock_cancel_job(job_id)
    
    def _real_list_events(
        self,
        job_id: str,
        after: Optional[str],
        limit: int,
    ) -> Dict[str, Any]:
        """List real events for job."""
        return self._mock_list_events(job_id, after, limit)
    
    def _real_list_checkpoints(
        self,
        job_id: str,
        after: Optional[str],
        limit: int,
    ) -> Dict[str, Any]:
        """List real checkpoints for job."""
        return self._mock_list_checkpoints(job_id, after, limit)


# ========================================
# Factory and Utilities
# ========================================

def get_fine_tuning_handler(
    backend: Optional[Any] = None,
    mock_mode: bool = True,
) -> FineTuningHandler:
    """
    Factory function to create fine-tuning handler.
    
    Args:
        backend: Optional backend service
        mock_mode: If True, use mock responses
        
    Returns:
        Configured FineTuningHandler instance
    """
    return FineTuningHandler(
        backend=backend,
        mock_mode=mock_mode,
    )


def create_fine_tuning_job(
    training_file: str,
    model: str,
    validation_file: Optional[str] = None,
    **kwargs,
) -> Dict[str, Any]:
    """
    Convenience function to create a fine-tuning job.
    
    Args:
        training_file: File ID for training data
        model: Base model to fine-tune
        validation_file: Optional validation file ID
        **kwargs: Additional job parameters
        
    Returns:
        Job object dictionary
    """
    handler = get_fine_tuning_handler()
    request = FineTuningJobRequest(
        training_file=training_file,
        model=model,
        validation_file=validation_file,
        **kwargs,
    )
    return handler.create_job(request)


def validate_training_file_id(file_id: str) -> bool:
    """
    Validate training file ID format.
    
    Args:
        file_id: File ID to validate
        
    Returns:
        True if valid format
    """
    if not file_id:
        return False
    return file_id.startswith("file-") and len(file_id) > 5


def is_finetune_model(model: str) -> bool:
    """
    Check if model name indicates a fine-tuned model.
    
    Args:
        model: Model name to check
        
    Returns:
        True if this is a fine-tuned model
    """
    return model.startswith("ft:")


def get_base_model(model: str) -> str:
    """
    Get base model from fine-tuned model name.
    
    Args:
        model: Model name (may be fine-tuned)
        
    Returns:
        Base model name
    """
    if model.startswith("ft:"):
        # Format: ft:base-model:org:suffix:job_id
        parts = model.split(":")
        if len(parts) >= 2:
            return parts[1]
    return model


# ========================================
# Exports
# ========================================

__all__ = [
    # Enums
    "FineTuningStatus",
    "FineTuningEventLevel",
    "FineTuningEventType",
    # Request models
    "Hyperparameters",
    "WandbIntegration",
    "FineTuningJobRequest",
    "ListJobsRequest",
    "ListEventsRequest",
    # Response models
    "FineTuningError",
    "FineTuningJobObject",
    "FineTuningEvent",
    "FineTuningCheckpoint",
    "FineTuningJobListResponse",
    "FineTuningEventListResponse",
    "FineTuningCheckpointListResponse",
    "FineTuningErrorResponse",
    # Handler
    "FineTuningHandler",
    # Utilities
    "get_fine_tuning_handler",
    "create_fine_tuning_job",
    "validate_training_file_id",
    "is_finetune_model",
    "get_base_model",
    # Constants
    "FINETUNE_BASE_MODELS",
    "DEFAULT_N_EPOCHS",
    "DEFAULT_BATCH_SIZE",
    "DEFAULT_LEARNING_RATE_MULTIPLIER",
    "MAX_SUFFIX_LENGTH",
    "MIN_TRAINING_EXAMPLES",
]