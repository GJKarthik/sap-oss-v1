"""
Unit Tests for Assistants API

Day 21 Deliverable: 55 unit tests for OpenAI Assistants API
"""

import pytest
import time
from typing import Dict, Any

from openai.assistants import (
    # Constants
    ASSISTANT_MODELS,
    DEFAULT_MODEL,
    MAX_TOOLS_PER_ASSISTANT,
    MAX_ASSISTANT_NAME_LENGTH,
    MAX_DESCRIPTION_LENGTH,
    MAX_INSTRUCTIONS_LENGTH,
    # Enums
    ToolType,
    ResponseFormat,
    TruncationStrategy,
    # Tool definitions
    CodeInterpreterTool,
    FileSearchTool,
    FunctionDefinition,
    FunctionTool,
    ToolResources,
    # Request/Response
    CreateAssistantRequest,
    ModifyAssistantRequest,
    AssistantObject,
    AssistantListResponse,
    AssistantDeleteResponse,
    AssistantErrorResponse,
    # Handler
    AssistantsHandler,
    # Utilities
    get_assistants_handler,
    create_assistant,
    create_code_interpreter_tool,
    create_file_search_tool,
    create_function_tool,
    validate_assistant_request,
    is_valid_tool_type,
    get_supported_models,
)


# ========================================
# ToolType Enum Tests
# ========================================

class TestToolType:
    """Tests for ToolType enum."""
    
    def test_code_interpreter_value(self):
        """Test code interpreter value."""
        assert ToolType.CODE_INTERPRETER.value == "code_interpreter"
    
    def test_file_search_value(self):
        """Test file search value."""
        assert ToolType.FILE_SEARCH.value == "file_search"
    
    def test_function_value(self):
        """Test function value."""
        assert ToolType.FUNCTION.value == "function"
    
    def test_all_tool_types(self):
        """Test all tool types are defined."""
        assert len(ToolType) == 3


class TestResponseFormat:
    """Tests for ResponseFormat enum."""
    
    def test_auto_value(self):
        """Test auto format value."""
        assert ResponseFormat.AUTO.value == "auto"
    
    def test_text_value(self):
        """Test text format value."""
        assert ResponseFormat.TEXT.value == "text"
    
    def test_json_object_value(self):
        """Test json_object format value."""
        assert ResponseFormat.JSON_OBJECT.value == "json_object"


# ========================================
# Tool Definition Tests
# ========================================

class TestCodeInterpreterTool:
    """Tests for CodeInterpreterTool."""
    
    def test_default_type(self):
        """Test default type is code_interpreter."""
        tool = CodeInterpreterTool()
        assert tool.type == "code_interpreter"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        tool = CodeInterpreterTool()
        result = tool.to_dict()
        assert result == {"type": "code_interpreter"}


class TestFileSearchTool:
    """Tests for FileSearchTool."""
    
    def test_default_type(self):
        """Test default type is file_search."""
        tool = FileSearchTool()
        assert tool.type == "file_search"
    
    def test_to_dict_without_config(self):
        """Test dictionary conversion without config."""
        tool = FileSearchTool()
        result = tool.to_dict()
        assert result == {"type": "file_search"}
    
    def test_to_dict_with_config(self):
        """Test dictionary conversion with config."""
        tool = FileSearchTool(file_search={"max_num_results": 10})
        result = tool.to_dict()
        assert result == {
            "type": "file_search",
            "file_search": {"max_num_results": 10}
        }


class TestFunctionDefinition:
    """Tests for FunctionDefinition."""
    
    def test_name_required(self):
        """Test name is set."""
        func = FunctionDefinition(name="my_function")
        assert func.name == "my_function"
    
    def test_optional_fields(self):
        """Test optional fields."""
        func = FunctionDefinition(
            name="my_function",
            description="A test function",
            parameters={"type": "object", "properties": {}},
            strict=True
        )
        assert func.description == "A test function"
        assert func.parameters == {"type": "object", "properties": {}}
        assert func.strict is True
    
    def test_to_dict_minimal(self):
        """Test minimal dictionary conversion."""
        func = FunctionDefinition(name="test")
        result = func.to_dict()
        assert result == {"name": "test"}
    
    def test_to_dict_full(self):
        """Test full dictionary conversion."""
        func = FunctionDefinition(
            name="test",
            description="Test function",
            parameters={"type": "object"},
            strict=True
        )
        result = func.to_dict()
        assert result["name"] == "test"
        assert result["description"] == "Test function"
        assert result["parameters"] == {"type": "object"}
        assert result["strict"] is True


class TestFunctionTool:
    """Tests for FunctionTool."""
    
    def test_default_type(self):
        """Test default type is function."""
        tool = FunctionTool()
        assert tool.type == "function"
    
    def test_to_dict_with_function(self):
        """Test dictionary conversion with function."""
        func = FunctionDefinition(name="my_func")
        tool = FunctionTool(function=func)
        result = tool.to_dict()
        assert result["type"] == "function"
        assert result["function"]["name"] == "my_func"


class TestToolResources:
    """Tests for ToolResources."""
    
    def test_empty_resources(self):
        """Test empty resources."""
        resources = ToolResources()
        assert resources.to_dict() == {}
    
    def test_with_code_interpreter(self):
        """Test with code interpreter files."""
        resources = ToolResources(
            code_interpreter={"file_ids": ["file-abc"]}
        )
        result = resources.to_dict()
        assert result["code_interpreter"]["file_ids"] == ["file-abc"]
    
    def test_from_dict(self):
        """Test creation from dictionary."""
        data = {
            "code_interpreter": {"file_ids": ["file-1"]},
            "file_search": {"vector_store_ids": ["vs-1"]}
        }
        resources = ToolResources.from_dict(data)
        assert resources.code_interpreter == {"file_ids": ["file-1"]}
        assert resources.file_search == {"vector_store_ids": ["vs-1"]}


# ========================================
# CreateAssistantRequest Tests
# ========================================

class TestCreateAssistantRequest:
    """Tests for CreateAssistantRequest."""
    
    def test_default_model(self):
        """Test default model is set."""
        request = CreateAssistantRequest()
        assert request.model == DEFAULT_MODEL
    
    def test_validate_empty_model(self):
        """Test validation fails for empty model."""
        request = CreateAssistantRequest(model="")
        errors = request.validate()
        assert any("model is required" in e for e in errors)
    
    def test_validate_name_too_long(self):
        """Test validation fails for long name."""
        request = CreateAssistantRequest(name="x" * (MAX_ASSISTANT_NAME_LENGTH + 1))
        errors = request.validate()
        assert any("name must be" in e for e in errors)
    
    def test_validate_description_too_long(self):
        """Test validation fails for long description."""
        request = CreateAssistantRequest(description="x" * (MAX_DESCRIPTION_LENGTH + 1))
        errors = request.validate()
        assert any("description must be" in e for e in errors)
    
    def test_validate_instructions_too_long(self):
        """Test validation fails for long instructions."""
        request = CreateAssistantRequest(instructions="x" * (MAX_INSTRUCTIONS_LENGTH + 1))
        errors = request.validate()
        assert any("instructions must be" in e for e in errors)
    
    def test_validate_too_many_tools(self):
        """Test validation fails for too many tools."""
        tools = [{"type": "code_interpreter"}] * (MAX_TOOLS_PER_ASSISTANT + 1)
        request = CreateAssistantRequest(tools=tools)
        errors = request.validate()
        assert any("tools must have" in e for e in errors)
    
    def test_validate_invalid_tool_type(self):
        """Test validation fails for invalid tool type."""
        request = CreateAssistantRequest(tools=[{"type": "invalid"}])
        errors = request.validate()
        assert any("tools[0].type must be" in e for e in errors)
    
    def test_validate_function_tool_requires_function(self):
        """Test function tool requires function field."""
        request = CreateAssistantRequest(tools=[{"type": "function"}])
        errors = request.validate()
        assert any("function is required" in e for e in errors)
    
    def test_validate_function_requires_name(self):
        """Test function requires name."""
        request = CreateAssistantRequest(
            tools=[{"type": "function", "function": {}}]
        )
        errors = request.validate()
        assert any("function.name is required" in e for e in errors)
    
    def test_validate_temperature_range(self):
        """Test temperature validation."""
        request = CreateAssistantRequest(temperature=2.5)
        errors = request.validate()
        assert any("temperature must be" in e for e in errors)
    
    def test_validate_top_p_range(self):
        """Test top_p validation."""
        request = CreateAssistantRequest(top_p=1.5)
        errors = request.validate()
        assert any("top_p must be" in e for e in errors)
    
    def test_valid_request(self):
        """Test valid request passes validation."""
        request = CreateAssistantRequest(
            model="gpt-4o",
            name="Test Assistant",
            tools=[{"type": "code_interpreter"}],
            temperature=0.7
        )
        errors = request.validate()
        assert len(errors) == 0


class TestModifyAssistantRequest:
    """Tests for ModifyAssistantRequest."""
    
    def test_all_optional(self):
        """Test all fields are optional."""
        request = ModifyAssistantRequest()
        errors = request.validate()
        assert len(errors) == 0
    
    def test_validate_name_too_long(self):
        """Test validation for long name."""
        request = ModifyAssistantRequest(name="x" * (MAX_ASSISTANT_NAME_LENGTH + 1))
        errors = request.validate()
        assert len(errors) > 0


# ========================================
# AssistantObject Tests
# ========================================

class TestAssistantObject:
    """Tests for AssistantObject."""
    
    def test_required_fields(self):
        """Test required fields."""
        assistant = AssistantObject(id="asst_123")
        assert assistant.id == "asst_123"
        assert assistant.object == "assistant"
    
    def test_to_dict_required(self):
        """Test dictionary with required fields."""
        assistant = AssistantObject(id="asst_123", created_at=1234567890)
        result = assistant.to_dict()
        assert result["id"] == "asst_123"
        assert result["object"] == "assistant"
        assert result["created_at"] == 1234567890
    
    def test_to_dict_with_optional(self):
        """Test dictionary with optional fields."""
        assistant = AssistantObject(
            id="asst_123",
            name="My Assistant",
            description="A helpful assistant",
            instructions="You are helpful",
            temperature=0.7
        )
        result = assistant.to_dict()
        assert result["name"] == "My Assistant"
        assert result["description"] == "A helpful assistant"
        assert result["instructions"] == "You are helpful"
        assert result["temperature"] == 0.7


class TestAssistantListResponse:
    """Tests for AssistantListResponse."""
    
    def test_empty_list(self):
        """Test empty list response."""
        response = AssistantListResponse()
        result = response.to_dict()
        assert result["object"] == "list"
        assert result["data"] == []
        assert result["has_more"] is False
    
    def test_with_data(self):
        """Test list with data."""
        assistants = [AssistantObject(id=f"asst_{i}") for i in range(3)]
        response = AssistantListResponse(
            data=assistants,
            first_id="asst_0",
            last_id="asst_2",
            has_more=True
        )
        result = response.to_dict()
        assert len(result["data"]) == 3
        assert result["first_id"] == "asst_0"
        assert result["last_id"] == "asst_2"
        assert result["has_more"] is True


class TestAssistantDeleteResponse:
    """Tests for AssistantDeleteResponse."""
    
    def test_delete_response(self):
        """Test delete response structure."""
        response = AssistantDeleteResponse(id="asst_123")
        result = response.to_dict()
        assert result["id"] == "asst_123"
        assert result["object"] == "assistant.deleted"
        assert result["deleted"] is True


class TestAssistantErrorResponse:
    """Tests for AssistantErrorResponse."""
    
    def test_error_message(self):
        """Test error response with message."""
        error = AssistantErrorResponse("Something went wrong")
        result = error.to_dict()
        assert result["error"]["message"] == "Something went wrong"
        assert result["error"]["type"] == "invalid_request_error"
    
    def test_error_with_code(self):
        """Test error response with code."""
        error = AssistantErrorResponse("Not found", code="not_found")
        result = error.to_dict()
        assert result["error"]["code"] == "not_found"


# ========================================
# AssistantsHandler Tests
# ========================================

class TestAssistantsHandler:
    """Tests for AssistantsHandler."""
    
    def test_create_assistant(self):
        """Test creating an assistant."""
        handler = AssistantsHandler()
        request = CreateAssistantRequest(
            model="gpt-4o",
            name="Test Assistant"
        )
        result = handler.create_assistant(request)
        assert "id" in result
        assert result["id"].startswith("asst_")
        assert result["name"] == "Test Assistant"
    
    def test_list_assistants_empty(self):
        """Test listing with no assistants."""
        handler = AssistantsHandler()
        result = handler.list_assistants()
        assert result["data"] == []
    
    def test_list_assistants_with_data(self):
        """Test listing with assistants."""
        handler = AssistantsHandler()
        # Create some assistants
        for i in range(3):
            request = CreateAssistantRequest(name=f"Assistant {i}")
            handler.create_assistant(request)
        
        result = handler.list_assistants()
        assert len(result["data"]) == 3
    
    def test_retrieve_assistant(self):
        """Test retrieving an assistant."""
        handler = AssistantsHandler()
        request = CreateAssistantRequest(name="Test")
        created = handler.create_assistant(request)
        
        result = handler.retrieve_assistant(created["id"])
        assert result["id"] == created["id"]
        assert result["name"] == "Test"
    
    def test_retrieve_nonexistent(self):
        """Test retrieving nonexistent assistant."""
        handler = AssistantsHandler()
        result = handler.retrieve_assistant("asst_nonexistent")
        assert "error" in result
    
    def test_modify_assistant(self):
        """Test modifying an assistant."""
        handler = AssistantsHandler()
        request = CreateAssistantRequest(name="Original")
        created = handler.create_assistant(request)
        
        modify_request = ModifyAssistantRequest(name="Modified")
        result = handler.modify_assistant(created["id"], modify_request)
        assert result["name"] == "Modified"
    
    def test_modify_nonexistent(self):
        """Test modifying nonexistent assistant."""
        handler = AssistantsHandler()
        request = ModifyAssistantRequest(name="New Name")
        result = handler.modify_assistant("asst_nonexistent", request)
        assert "error" in result
    
    def test_delete_assistant(self):
        """Test deleting an assistant."""
        handler = AssistantsHandler()
        request = CreateAssistantRequest(name="ToDelete")
        created = handler.create_assistant(request)
        
        result = handler.delete_assistant(created["id"])
        assert result["deleted"] is True
        
        # Verify deleted
        retrieve = handler.retrieve_assistant(created["id"])
        assert "error" in retrieve
    
    def test_delete_nonexistent(self):
        """Test deleting nonexistent assistant."""
        handler = AssistantsHandler()
        result = handler.delete_assistant("asst_nonexistent")
        assert "error" in result
    
    def test_handle_request_create(self):
        """Test handle_request for create."""
        handler = AssistantsHandler()
        result = handler.handle_request(
            "POST",
            "/v1/assistants",
            data={"model": "gpt-4o", "name": "Test"}
        )
        assert "id" in result
    
    def test_handle_request_list(self):
        """Test handle_request for list."""
        handler = AssistantsHandler()
        result = handler.handle_request("GET", "/v1/assistants")
        assert "data" in result


# ========================================
# Utility Function Tests
# ========================================

class TestUtilityFunctions:
    """Tests for utility functions."""
    
    def test_get_assistants_handler(self):
        """Test factory function."""
        handler = get_assistants_handler()
        assert isinstance(handler, AssistantsHandler)
    
    def test_create_assistant_convenience(self):
        """Test convenience function."""
        result = create_assistant(name="Quick Test")
        assert "id" in result
        assert result["name"] == "Quick Test"
    
    def test_create_code_interpreter_tool(self):
        """Test code interpreter tool creation."""
        tool = create_code_interpreter_tool()
        assert tool["type"] == "code_interpreter"
    
    def test_create_file_search_tool(self):
        """Test file search tool creation."""
        tool = create_file_search_tool()
        assert tool["type"] == "file_search"
    
    def test_create_file_search_tool_with_limit(self):
        """Test file search tool with max results."""
        tool = create_file_search_tool(max_num_results=5)
        assert tool["file_search"]["max_num_results"] == 5
    
    def test_create_function_tool(self):
        """Test function tool creation."""
        tool = create_function_tool(
            name="my_function",
            description="Test function",
            parameters={"type": "object"}
        )
        assert tool["type"] == "function"
        assert tool["function"]["name"] == "my_function"
    
    def test_is_valid_tool_type(self):
        """Test tool type validation."""
        assert is_valid_tool_type("code_interpreter") is True
        assert is_valid_tool_type("file_search") is True
        assert is_valid_tool_type("function") is True
        assert is_valid_tool_type("invalid") is False
    
    def test_get_supported_models(self):
        """Test getting supported models."""
        models = get_supported_models()
        assert "gpt-4o" in models
        assert "gpt-4-turbo" in models


class TestConstants:
    """Tests for constants."""
    
    def test_assistant_models(self):
        """Test assistant models list."""
        assert len(ASSISTANT_MODELS) > 0
        assert DEFAULT_MODEL in ASSISTANT_MODELS
    
    def test_max_limits(self):
        """Test max limit constants."""
        assert MAX_TOOLS_PER_ASSISTANT == 128
        assert MAX_ASSISTANT_NAME_LENGTH == 256
        assert MAX_DESCRIPTION_LENGTH == 512


# ========================================
# Integration Tests
# ========================================

class TestAssistantsIntegration:
    """Integration tests for assistants."""
    
    def test_full_lifecycle(self):
        """Test full assistant lifecycle."""
        handler = AssistantsHandler()
        
        # Create
        create_request = CreateAssistantRequest(
            model="gpt-4o",
            name="Integration Test",
            tools=[
                {"type": "code_interpreter"},
                {"type": "file_search"}
            ]
        )
        created = handler.create_assistant(create_request)
        assistant_id = created["id"]
        
        # Retrieve
        retrieved = handler.retrieve_assistant(assistant_id)
        assert retrieved["name"] == "Integration Test"
        
        # Modify
        modify_request = ModifyAssistantRequest(name="Modified Test")
        modified = handler.modify_assistant(assistant_id, modify_request)
        assert modified["name"] == "Modified Test"
        
        # List
        listed = handler.list_assistants()
        assert any(a["id"] == assistant_id for a in listed["data"])
        
        # Delete
        deleted = handler.delete_assistant(assistant_id)
        assert deleted["deleted"] is True
    
    def test_pagination(self):
        """Test list pagination."""
        handler = AssistantsHandler()
        
        # Create 5 assistants
        for i in range(5):
            request = CreateAssistantRequest(name=f"Paginate {i}")
            handler.create_assistant(request)
        
        # List with limit
        result = handler.list_assistants(limit=2)
        assert len(result["data"]) == 2
        assert result["has_more"] is True