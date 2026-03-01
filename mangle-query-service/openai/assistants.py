"""
OpenAI-compatible Assistants API Endpoint

Day 21 Deliverable: Core Assistants API for stateful conversation agents

Implements:
- POST /v1/assistants - Create assistant
- GET /v1/assistants - List assistants
- GET /v1/assistants/{assistant_id} - Retrieve assistant
- POST /v1/assistants/{assistant_id} - Modify assistant
- DELETE /v1/assistants/{assistant_id} - Delete assistant
"""

import time
import hashlib
import json
from enum import Enum
from typing import Dict, Any, Optional, List, Union
from dataclasses import dataclass, field


# ========================================
# Constants
# ========================================

ASSISTANT_MODELS = [
    "gpt-4o",
    "gpt-4o-mini",
    "gpt-4-turbo",
    "gpt-4-turbo-preview",
    "gpt-4",
    "gpt-3.5-turbo",
    "gpt-3.5-turbo-16k",
]

DEFAULT_MODEL = "gpt-4o"

MAX_ASSISTANT_NAME_LENGTH = 256
MAX_DESCRIPTION_LENGTH = 512
MAX_INSTRUCTIONS_LENGTH = 256000  # 256K characters
MAX_TOOLS_PER_ASSISTANT = 128
MAX_FILE_IDS_PER_ASSISTANT = 20


# ========================================
# Enums
# ========================================

class ToolType(str, Enum):
    """Tool types available for assistants."""
    CODE_INTERPRETER = "code_interpreter"
    FILE_SEARCH = "file_search"
    FUNCTION = "function"


class ResponseFormat(str, Enum):
    """Response format options."""
    AUTO = "auto"
    TEXT = "text"
    JSON_OBJECT = "json_object"


class TruncationStrategy(str, Enum):
    """Truncation strategy options."""
    AUTO = "auto"
    LAST_MESSAGES = "last_messages"


# ========================================
# Tool Definitions
# ========================================

@dataclass
class CodeInterpreterTool:
    """Code interpreter tool configuration."""
    type: str = "code_interpreter"
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"type": self.type}


@dataclass
class FileSearchTool:
    """File search tool configuration."""
    type: str = "file_search"
    file_search: Optional[Dict[str, Any]] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {"type": self.type}
        if self.file_search:
            result["file_search"] = self.file_search
        return result


@dataclass
class FunctionDefinition:
    """Function definition for function tools."""
    name: str
    description: Optional[str] = None
    parameters: Optional[Dict[str, Any]] = None
    strict: bool = False
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {"name": self.name}
        if self.description:
            result["description"] = self.description
        if self.parameters:
            result["parameters"] = self.parameters
        if self.strict:
            result["strict"] = self.strict
        return result


@dataclass
class FunctionTool:
    """Function tool configuration."""
    type: str = "function"
    function: Optional[FunctionDefinition] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {"type": self.type}
        if self.function:
            result["function"] = self.function.to_dict()
        return result


@dataclass 
class ToolResources:
    """Tool resources for assistants."""
    code_interpreter: Optional[Dict[str, Any]] = None
    file_search: Optional[Dict[str, Any]] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {}
        if self.code_interpreter:
            result["code_interpreter"] = self.code_interpreter
        if self.file_search:
            result["file_search"] = self.file_search
        return result
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "ToolResources":
        """Create from dictionary."""
        return cls(
            code_interpreter=data.get("code_interpreter"),
            file_search=data.get("file_search"),
        )


# ========================================
# Request/Response Models
# ========================================

@dataclass
class CreateAssistantRequest:
    """Request to create an assistant."""
    model: str = DEFAULT_MODEL
    name: Optional[str] = None
    description: Optional[str] = None
    instructions: Optional[str] = None
    tools: List[Dict[str, Any]] = field(default_factory=list)
    tool_resources: Optional[Dict[str, Any]] = None
    metadata: Optional[Dict[str, str]] = None
    temperature: Optional[float] = None
    top_p: Optional[float] = None
    response_format: Optional[Union[str, Dict[str, Any]]] = None
    
    def validate(self) -> List[str]:
        """Validate the request."""
        errors = []
        
        if not self.model:
            errors.append("model is required")
        
        if self.name and len(self.name) > MAX_ASSISTANT_NAME_LENGTH:
            errors.append(f"name must be {MAX_ASSISTANT_NAME_LENGTH} characters or less")
        
        if self.description and len(self.description) > MAX_DESCRIPTION_LENGTH:
            errors.append(f"description must be {MAX_DESCRIPTION_LENGTH} characters or less")
        
        if self.instructions and len(self.instructions) > MAX_INSTRUCTIONS_LENGTH:
            errors.append(f"instructions must be {MAX_INSTRUCTIONS_LENGTH} characters or less")
        
        if len(self.tools) > MAX_TOOLS_PER_ASSISTANT:
            errors.append(f"tools must have {MAX_TOOLS_PER_ASSISTANT} items or less")
        
        # Validate tools
        for i, tool in enumerate(self.tools):
            tool_type = tool.get("type")
            if tool_type not in [t.value for t in ToolType]:
                errors.append(f"tools[{i}].type must be one of: {[t.value for t in ToolType]}")
            
            if tool_type == "function":
                if "function" not in tool:
                    errors.append(f"tools[{i}].function is required for function tools")
                elif "name" not in tool.get("function", {}):
                    errors.append(f"tools[{i}].function.name is required")
        
        if self.temperature is not None:
            if not 0 <= self.temperature <= 2:
                errors.append("temperature must be between 0 and 2")
        
        if self.top_p is not None:
            if not 0 <= self.top_p <= 1:
                errors.append("top_p must be between 0 and 1")
        
        return errors


@dataclass
class ModifyAssistantRequest:
    """Request to modify an assistant."""
    model: Optional[str] = None
    name: Optional[str] = None
    description: Optional[str] = None
    instructions: Optional[str] = None
    tools: Optional[List[Dict[str, Any]]] = None
    tool_resources: Optional[Dict[str, Any]] = None
    metadata: Optional[Dict[str, str]] = None
    temperature: Optional[float] = None
    top_p: Optional[float] = None
    response_format: Optional[Union[str, Dict[str, Any]]] = None
    
    def validate(self) -> List[str]:
        """Validate the request."""
        errors = []
        
        if self.name is not None and len(self.name) > MAX_ASSISTANT_NAME_LENGTH:
            errors.append(f"name must be {MAX_ASSISTANT_NAME_LENGTH} characters or less")
        
        if self.description is not None and len(self.description) > MAX_DESCRIPTION_LENGTH:
            errors.append(f"description must be {MAX_DESCRIPTION_LENGTH} characters or less")
        
        if self.instructions is not None and len(self.instructions) > MAX_INSTRUCTIONS_LENGTH:
            errors.append(f"instructions must be {MAX_INSTRUCTIONS_LENGTH} characters or less")
        
        if self.tools is not None and len(self.tools) > MAX_TOOLS_PER_ASSISTANT:
            errors.append(f"tools must have {MAX_TOOLS_PER_ASSISTANT} items or less")
        
        return errors


@dataclass
class AssistantObject:
    """Assistant object response."""
    id: str
    object: str = "assistant"
    created_at: int = 0
    name: Optional[str] = None
    description: Optional[str] = None
    model: str = DEFAULT_MODEL
    instructions: Optional[str] = None
    tools: List[Dict[str, Any]] = field(default_factory=list)
    tool_resources: Optional[Dict[str, Any]] = None
    metadata: Optional[Dict[str, str]] = None
    temperature: Optional[float] = None
    top_p: Optional[float] = None
    response_format: Optional[Union[str, Dict[str, Any]]] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "id": self.id,
            "object": self.object,
            "created_at": self.created_at,
            "model": self.model,
            "tools": self.tools,
        }
        
        # Optional fields
        if self.name is not None:
            result["name"] = self.name
        if self.description is not None:
            result["description"] = self.description
        if self.instructions is not None:
            result["instructions"] = self.instructions
        if self.tool_resources is not None:
            result["tool_resources"] = self.tool_resources
        if self.metadata is not None:
            result["metadata"] = self.metadata
        if self.temperature is not None:
            result["temperature"] = self.temperature
        if self.top_p is not None:
            result["top_p"] = self.top_p
        if self.response_format is not None:
            result["response_format"] = self.response_format
        
        return result


@dataclass
class AssistantListResponse:
    """Response for list assistants."""
    object: str = "list"
    data: List[AssistantObject] = field(default_factory=list)
    first_id: Optional[str] = None
    last_id: Optional[str] = None
    has_more: bool = False
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "object": self.object,
            "data": [a.to_dict() for a in self.data],
            "first_id": self.first_id,
            "last_id": self.last_id,
            "has_more": self.has_more,
        }


@dataclass
class AssistantDeleteResponse:
    """Response for delete assistant."""
    id: str
    object: str = "assistant.deleted"
    deleted: bool = True
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "id": self.id,
            "object": self.object,
            "deleted": self.deleted,
        }


@dataclass
class AssistantErrorResponse:
    """Error response for assistant operations."""
    error: Dict[str, Any] = field(default_factory=dict)
    
    def __init__(self, message: str, type: str = "invalid_request_error", code: Optional[str] = None):
        self.error = {
            "message": message,
            "type": type,
        }
        if code:
            self.error["code"] = code
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"error": self.error}


# ========================================
# Assistants Handler
# ========================================

class AssistantsHandler:
    """Handler for assistant operations."""
    
    def __init__(
        self,
        backend: Optional[Any] = None,
        mock_mode: bool = True,
    ):
        """
        Initialize handler.
        
        Args:
            backend: Optional backend service
            mock_mode: If True, use mock responses
        """
        self.backend = backend
        self.mock_mode = mock_mode
        self._assistants: Dict[str, AssistantObject] = {}
    
    def create_assistant(self, request: CreateAssistantRequest) -> Dict[str, Any]:
        """
        Create a new assistant.
        
        Args:
            request: Assistant creation request
            
        Returns:
            Assistant object dictionary
        """
        # Validate request
        errors = request.validate()
        if errors:
            return AssistantErrorResponse("; ".join(errors)).to_dict()
        
        # Generate assistant ID
        assistant_id = f"asst_{hashlib.md5(f'{time.time()}'.encode()).hexdigest()[:24]}"
        
        now = int(time.time())
        
        # Create assistant object
        assistant = AssistantObject(
            id=assistant_id,
            created_at=now,
            name=request.name,
            description=request.description,
            model=request.model,
            instructions=request.instructions,
            tools=request.tools,
            tool_resources=request.tool_resources,
            metadata=request.metadata,
            temperature=request.temperature,
            top_p=request.top_p,
            response_format=request.response_format,
        )
        
        self._assistants[assistant_id] = assistant
        
        return assistant.to_dict()
    
    def list_assistants(
        self,
        limit: int = 20,
        order: str = "desc",
        after: Optional[str] = None,
        before: Optional[str] = None,
    ) -> Dict[str, Any]:
        """
        List assistants.
        
        Args:
            limit: Number of results
            order: Sort order (asc or desc)
            after: Cursor for pagination
            before: Cursor for pagination
            
        Returns:
            List response dictionary
        """
        # Get all assistants sorted by creation time
        assistants = sorted(
            self._assistants.values(),
            key=lambda a: a.created_at,
            reverse=(order == "desc")
        )
        
        # Apply cursor pagination
        if after:
            found_idx = -1
            for i, assistant in enumerate(assistants):
                if assistant.id == after:
                    found_idx = i
                    break
            if found_idx >= 0:
                assistants = assistants[found_idx + 1:]
        
        if before:
            found_idx = -1
            for i, assistant in enumerate(assistants):
                if assistant.id == before:
                    found_idx = i
                    break
            if found_idx >= 0:
                assistants = assistants[:found_idx]
        
        # Limit results
        has_more = len(assistants) > limit
        assistants = assistants[:limit]
        
        response = AssistantListResponse(
            data=assistants,
            first_id=assistants[0].id if assistants else None,
            last_id=assistants[-1].id if assistants else None,
            has_more=has_more,
        )
        
        return response.to_dict()
    
    def retrieve_assistant(self, assistant_id: str) -> Dict[str, Any]:
        """
        Retrieve an assistant.
        
        Args:
            assistant_id: Assistant ID
            
        Returns:
            Assistant object dictionary
        """
        if assistant_id not in self._assistants:
            return AssistantErrorResponse(
                f"No assistant found with id '{assistant_id}'",
                code="assistant_not_found"
            ).to_dict()
        
        return self._assistants[assistant_id].to_dict()
    
    def modify_assistant(
        self,
        assistant_id: str,
        request: ModifyAssistantRequest,
    ) -> Dict[str, Any]:
        """
        Modify an assistant.
        
        Args:
            assistant_id: Assistant ID
            request: Modification request
            
        Returns:
            Updated assistant object dictionary
        """
        if assistant_id not in self._assistants:
            return AssistantErrorResponse(
                f"No assistant found with id '{assistant_id}'",
                code="assistant_not_found"
            ).to_dict()
        
        # Validate request
        errors = request.validate()
        if errors:
            return AssistantErrorResponse("; ".join(errors)).to_dict()
        
        assistant = self._assistants[assistant_id]
        
        # Update fields that are provided
        if request.model is not None:
            assistant.model = request.model
        if request.name is not None:
            assistant.name = request.name
        if request.description is not None:
            assistant.description = request.description
        if request.instructions is not None:
            assistant.instructions = request.instructions
        if request.tools is not None:
            assistant.tools = request.tools
        if request.tool_resources is not None:
            assistant.tool_resources = request.tool_resources
        if request.metadata is not None:
            assistant.metadata = request.metadata
        if request.temperature is not None:
            assistant.temperature = request.temperature
        if request.top_p is not None:
            assistant.top_p = request.top_p
        if request.response_format is not None:
            assistant.response_format = request.response_format
        
        return assistant.to_dict()
    
    def delete_assistant(self, assistant_id: str) -> Dict[str, Any]:
        """
        Delete an assistant.
        
        Args:
            assistant_id: Assistant ID
            
        Returns:
            Delete response dictionary
        """
        if assistant_id not in self._assistants:
            return AssistantErrorResponse(
                f"No assistant found with id '{assistant_id}'",
                code="assistant_not_found"
            ).to_dict()
        
        del self._assistants[assistant_id]
        
        return AssistantDeleteResponse(id=assistant_id).to_dict()
    
    def handle_request(
        self,
        method: str,
        path: str,
        data: Optional[Dict[str, Any]] = None,
        params: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """
        Handle assistant API request.
        
        Args:
            method: HTTP method
            path: Request path
            data: Request body
            params: Query parameters
            
        Returns:
            Response dictionary
        """
        path = path.rstrip("/")
        params = params or {}
        data = data or {}
        
        # POST /v1/assistants - Create
        if path == "/v1/assistants" and method == "POST":
            request = CreateAssistantRequest(
                model=data.get("model", DEFAULT_MODEL),
                name=data.get("name"),
                description=data.get("description"),
                instructions=data.get("instructions"),
                tools=data.get("tools", []),
                tool_resources=data.get("tool_resources"),
                metadata=data.get("metadata"),
                temperature=data.get("temperature"),
                top_p=data.get("top_p"),
                response_format=data.get("response_format"),
            )
            return self.create_assistant(request)
        
        # GET /v1/assistants - List
        elif path == "/v1/assistants" and method == "GET":
            return self.list_assistants(
                limit=int(params.get("limit", 20)),
                order=params.get("order", "desc"),
                after=params.get("after"),
                before=params.get("before"),
            )
        
        # GET /v1/assistants/{id} - Retrieve
        elif path.startswith("/v1/assistants/") and method == "GET":
            assistant_id = path.split("/")[-1]
            return self.retrieve_assistant(assistant_id)
        
        # POST /v1/assistants/{id} - Modify
        elif path.startswith("/v1/assistants/") and method == "POST":
            assistant_id = path.split("/")[-1]
            request = ModifyAssistantRequest(
                model=data.get("model"),
                name=data.get("name"),
                description=data.get("description"),
                instructions=data.get("instructions"),
                tools=data.get("tools"),
                tool_resources=data.get("tool_resources"),
                metadata=data.get("metadata"),
                temperature=data.get("temperature"),
                top_p=data.get("top_p"),
                response_format=data.get("response_format"),
            )
            return self.modify_assistant(assistant_id, request)
        
        # DELETE /v1/assistants/{id} - Delete
        elif path.startswith("/v1/assistants/") and method == "DELETE":
            assistant_id = path.split("/")[-1]
            return self.delete_assistant(assistant_id)
        
        return AssistantErrorResponse("Unknown endpoint", code="unknown_endpoint").to_dict()


# ========================================
# Factory and Utilities
# ========================================

def get_assistants_handler(
    backend: Optional[Any] = None,
    mock_mode: bool = True,
) -> AssistantsHandler:
    """
    Factory function to create assistants handler.
    
    Args:
        backend: Optional backend service
        mock_mode: If True, use mock responses
        
    Returns:
        Configured AssistantsHandler instance
    """
    return AssistantsHandler(
        backend=backend,
        mock_mode=mock_mode,
    )


def create_assistant(
    model: str = DEFAULT_MODEL,
    name: Optional[str] = None,
    description: Optional[str] = None,
    instructions: Optional[str] = None,
    tools: Optional[List[Dict[str, Any]]] = None,
    metadata: Optional[Dict[str, str]] = None,
) -> Dict[str, Any]:
    """
    Convenience function to create an assistant.
    
    Args:
        model: Model to use
        name: Assistant name
        description: Description
        instructions: System instructions
        tools: List of tools
        metadata: Metadata
        
    Returns:
        Assistant object dictionary
    """
    handler = get_assistants_handler()
    request = CreateAssistantRequest(
        model=model,
        name=name,
        description=description,
        instructions=instructions,
        tools=tools or [],
        metadata=metadata,
    )
    return handler.create_assistant(request)


def create_code_interpreter_tool() -> Dict[str, Any]:
    """Create a code interpreter tool."""
    return CodeInterpreterTool().to_dict()


def create_file_search_tool(
    max_num_results: Optional[int] = None,
) -> Dict[str, Any]:
    """
    Create a file search tool.
    
    Args:
        max_num_results: Maximum number of results to return
        
    Returns:
        Tool dictionary
    """
    file_search = None
    if max_num_results:
        file_search = {"max_num_results": max_num_results}
    return FileSearchTool(file_search=file_search).to_dict()


def create_function_tool(
    name: str,
    description: Optional[str] = None,
    parameters: Optional[Dict[str, Any]] = None,
    strict: bool = False,
) -> Dict[str, Any]:
    """
    Create a function tool.
    
    Args:
        name: Function name
        description: Function description
        parameters: JSON Schema for parameters
        strict: Whether to use strict mode
        
    Returns:
        Tool dictionary
    """
    function = FunctionDefinition(
        name=name,
        description=description,
        parameters=parameters,
        strict=strict,
    )
    return FunctionTool(function=function).to_dict()


def validate_assistant_request(request: CreateAssistantRequest) -> List[str]:
    """
    Validate an assistant creation request.
    
    Args:
        request: Assistant request
        
    Returns:
        List of error messages
    """
    return request.validate()


def is_valid_tool_type(tool_type: str) -> bool:
    """
    Check if tool type is valid.
    
    Args:
        tool_type: Tool type string
        
    Returns:
        True if valid
    """
    return tool_type in [t.value for t in ToolType]


def get_supported_models() -> List[str]:
    """Get list of supported assistant models."""
    return ASSISTANT_MODELS.copy()


# ========================================
# Exports
# ========================================

__all__ = [
    # Constants
    "ASSISTANT_MODELS",
    "DEFAULT_MODEL",
    "MAX_TOOLS_PER_ASSISTANT",
    # Enums
    "ToolType",
    "ResponseFormat",
    "TruncationStrategy",
    # Tool definitions
    "CodeInterpreterTool",
    "FileSearchTool",
    "FunctionDefinition",
    "FunctionTool",
    "ToolResources",
    # Request/Response
    "CreateAssistantRequest",
    "ModifyAssistantRequest",
    "AssistantObject",
    "AssistantListResponse",
    "AssistantDeleteResponse",
    "AssistantErrorResponse",
    # Handler
    "AssistantsHandler",
    # Utilities
    "get_assistants_handler",
    "create_assistant",
    "create_code_interpreter_tool",
    "create_file_search_tool",
    "create_function_tool",
    "validate_assistant_request",
    "is_valid_tool_type",
    "get_supported_models",
]