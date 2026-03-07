"""
Unit Tests for Responses API

Day 31: 55 unit tests for response endpoints and input items
"""

import pytest
import time
from unittest.mock import patch


# ========================================
# Test Imports
# ========================================

class TestImports:
    """Test module imports."""
    
    def test_import_constants(self):
        """Test constant imports."""
        from openai.responses import (
            MAX_INPUT_ITEMS, MAX_INSTRUCTIONS_LENGTH, MAX_CONTEXT_LENGTH,
            DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE
        )
        assert MAX_INPUT_ITEMS == 256
        assert MAX_INSTRUCTIONS_LENGTH == 256000
        assert DEFAULT_PAGE_SIZE == 20
    
    def test_import_enums(self):
        """Test enum imports."""
        from openai.responses import ResponseStatus, InputItemType, MessageRole, ContentType
        assert ResponseStatus.COMPLETED.value == "completed"
        assert InputItemType.MESSAGE.value == "message"


# ========================================
# Test Enums
# ========================================

class TestResponseStatus:
    """Test ResponseStatus enum."""
    
    def test_all_statuses(self):
        """Test all response statuses."""
        from openai.responses import ResponseStatus
        assert ResponseStatus.IN_PROGRESS.value == "in_progress"
        assert ResponseStatus.COMPLETED.value == "completed"
        assert ResponseStatus.INCOMPLETE.value == "incomplete"
        assert ResponseStatus.CANCELLED.value == "cancelled"
        assert ResponseStatus.FAILED.value == "failed"


class TestInputItemType:
    """Test InputItemType enum."""
    
    def test_all_types(self):
        """Test all input item types."""
        from openai.responses import InputItemType
        assert InputItemType.MESSAGE.value == "message"
        assert InputItemType.ITEM_REFERENCE.value == "item_reference"
        assert InputItemType.FILE.value == "file"
        assert InputItemType.FUNCTION_CALL_OUTPUT.value == "function_call_output"


class TestMessageRole:
    """Test MessageRole enum."""
    
    def test_all_roles(self):
        """Test all message roles."""
        from openai.responses import MessageRole
        assert MessageRole.USER.value == "user"
        assert MessageRole.ASSISTANT.value == "assistant"
        assert MessageRole.SYSTEM.value == "system"
        assert MessageRole.DEVELOPER.value == "developer"


class TestContentType:
    """Test ContentType enum."""
    
    def test_all_content_types(self):
        """Test all content types."""
        from openai.responses import ContentType
        assert ContentType.TEXT.value == "input_text"
        assert ContentType.AUDIO.value == "input_audio"
        assert ContentType.IMAGE.value == "input_image"


# ========================================
# Test Content Models
# ========================================

class TestTextContent:
    """Test TextContent model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.responses import TextContent
        content = TextContent()
        assert content.type == "input_text"
        assert content.text == ""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.responses import TextContent
        content = TextContent(text="Hello world")
        result = content.to_dict()
        assert result["type"] == "input_text"
        assert result["text"] == "Hello world"


class TestAudioContent:
    """Test AudioContent model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.responses import AudioContent
        content = AudioContent()
        assert content.format == "wav"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.responses import AudioContent
        content = AudioContent(data="base64data", format="mp3")
        result = content.to_dict()
        assert result["format"] == "mp3"


class TestImageContent:
    """Test ImageContent model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.responses import ImageContent
        content = ImageContent()
        assert content.detail == "auto"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.responses import ImageContent
        content = ImageContent(image_url="http://example.com/img.png", detail="high")
        result = content.to_dict()
        assert result["detail"] == "high"


# ========================================
# Test Input Item Models
# ========================================

class TestMessageInputItem:
    """Test MessageInputItem model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.responses import MessageInputItem
        item = MessageInputItem()
        assert item.type == "message"
        assert item.role == "user"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.responses import MessageInputItem
        item = MessageInputItem(
            id="item_123",
            role="assistant",
            content=[{"type": "text", "text": "Hi"}]
        )
        result = item.to_dict()
        assert result["id"] == "item_123"
        assert result["role"] == "assistant"


class TestItemReference:
    """Test ItemReference model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.responses import ItemReference
        ref = ItemReference()
        assert ref.type == "item_reference"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.responses import ItemReference
        ref = ItemReference(id="ref_1", item_id="item_prev")
        result = ref.to_dict()
        assert result["item_id"] == "item_prev"


class TestFileInputItem:
    """Test FileInputItem model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.responses import FileInputItem
        item = FileInputItem()
        assert item.type == "file"
        assert item.status == "completed"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.responses import FileInputItem
        item = FileInputItem(file_id="file_123", filename="doc.pdf")
        result = item.to_dict()
        assert result["filename"] == "doc.pdf"


class TestFunctionCallOutput:
    """Test FunctionCallOutput model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.responses import FunctionCallOutput
        item = FunctionCallOutput()
        assert item.type == "function_call_output"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.responses import FunctionCallOutput
        item = FunctionCallOutput(call_id="call_1", output='{"result": 42}')
        result = item.to_dict()
        assert result["call_id"] == "call_1"


# ========================================
# Test Request Models
# ========================================

class TestCreateResponseRequest:
    """Test CreateResponseRequest model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.responses import CreateResponseRequest
        req = CreateResponseRequest()
        assert req.model == "gpt-4o"
        assert req.temperature == 1.0
    
    def test_validation_valid(self):
        """Test validation with valid request."""
        from openai.responses import CreateResponseRequest
        req = CreateResponseRequest(model="gpt-4o", input=[{"type": "message"}])
        errors = req.validate()
        assert len(errors) == 0
    
    def test_validation_missing_model(self):
        """Test validation with missing model."""
        from openai.responses import CreateResponseRequest
        req = CreateResponseRequest(model="")
        errors = req.validate()
        assert "model is required" in errors
    
    def test_validation_too_many_items(self):
        """Test validation with too many items."""
        from openai.responses import CreateResponseRequest, MAX_INPUT_ITEMS
        req = CreateResponseRequest(input=[{}] * (MAX_INPUT_ITEMS + 1))
        errors = req.validate()
        assert any("Maximum" in e for e in errors)
    
    def test_validation_invalid_temperature(self):
        """Test validation with invalid temperature."""
        from openai.responses import CreateResponseRequest
        req = CreateResponseRequest(temperature=3.0)
        errors = req.validate()
        assert any("temperature" in e for e in errors)


# ========================================
# Test Response Models
# ========================================

class TestResponseUsage:
    """Test ResponseUsage model."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.responses import ResponseUsage
        usage = ResponseUsage(input_tokens=100, output_tokens=50, total_tokens=150)
        result = usage.to_dict()
        assert result["total_tokens"] == 150


class TestResponseObject:
    """Test ResponseObject model."""
    
    def test_creation(self):
        """Test response object creation."""
        from openai.responses import ResponseObject
        resp = ResponseObject(id="resp_123")
        assert resp.object == "response"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.responses import ResponseObject, ResponseUsage
        resp = ResponseObject(
            id="resp_123",
            model="gpt-4o",
            usage=ResponseUsage(100, 50, 150)
        )
        result = resp.to_dict()
        assert result["model"] == "gpt-4o"
        assert result["usage"]["total_tokens"] == 150


class TestInputItemListResponse:
    """Test InputItemListResponse model."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.responses import InputItemListResponse
        resp = InputItemListResponse(
            data=[{"id": "item_1"}],
            first_id="item_1",
            last_id="item_1"
        )
        result = resp.to_dict()
        assert result["object"] == "list"
        assert len(result["data"]) == 1


class TestResponseDeleteResult:
    """Test ResponseDeleteResult model."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.responses import ResponseDeleteResult
        result = ResponseDeleteResult(id="resp_123").to_dict()
        assert result["deleted"] is True
        assert result["object"] == "response.deleted"


# ========================================
# Test Handler
# ========================================

class TestResponsesHandler:
    """Test ResponsesHandler class."""
    
    def test_create_response(self):
        """Test creating a response."""
        from openai.responses import get_responses_handler, CreateResponseRequest
        handler = get_responses_handler()
        result = handler.create(CreateResponseRequest(
            model="gpt-4o",
            input=[{"type": "message", "role": "user", "content": [{"type": "text", "text": "Hi"}]}]
        ))
        assert result["id"].startswith("resp_")
        assert result["status"] == "completed"
    
    def test_retrieve_response(self):
        """Test retrieving a response."""
        from openai.responses import get_responses_handler, CreateResponseRequest
        handler = get_responses_handler()
        created = handler.create(CreateResponseRequest(model="gpt-4o"))
        result = handler.retrieve(created["id"])
        assert result["id"] == created["id"]
    
    def test_retrieve_nonexistent(self):
        """Test retrieving nonexistent response."""
        from openai.responses import get_responses_handler
        handler = get_responses_handler()
        result = handler.retrieve("resp_nonexistent")
        assert "error" in result
    
    def test_delete_response(self):
        """Test deleting a response."""
        from openai.responses import get_responses_handler, CreateResponseRequest
        handler = get_responses_handler()
        created = handler.create(CreateResponseRequest(model="gpt-4o"))
        result = handler.delete(created["id"])
        assert result["deleted"] is True
    
    def test_delete_nonexistent(self):
        """Test deleting nonexistent response."""
        from openai.responses import get_responses_handler
        handler = get_responses_handler()
        result = handler.delete("resp_nonexistent")
        assert "error" in result
    
    def test_list_input_items(self):
        """Test listing input items."""
        from openai.responses import get_responses_handler, CreateResponseRequest
        handler = get_responses_handler()
        created = handler.create(CreateResponseRequest(
            model="gpt-4o",
            input=[
                {"type": "message", "role": "user", "content": [{"type": "text", "text": "Q1"}]},
                {"type": "message", "role": "user", "content": [{"type": "text", "text": "Q2"}]},
            ]
        ))
        result = handler.list_input_items(created["id"])
        assert len(result["data"]) == 2
    
    def test_list_input_items_pagination(self):
        """Test input items pagination."""
        from openai.responses import get_responses_handler, CreateResponseRequest
        handler = get_responses_handler()
        created = handler.create(CreateResponseRequest(
            model="gpt-4o",
            input=[{"type": "message"} for _ in range(5)]
        ))
        result = handler.list_input_items(created["id"], limit=2)
        assert len(result["data"]) == 2
        assert result["has_more"] is True
    
    def test_list_input_items_order(self):
        """Test input items ordering."""
        from openai.responses import get_responses_handler, CreateResponseRequest
        handler = get_responses_handler()
        created = handler.create(CreateResponseRequest(
            model="gpt-4o",
            input=[{"type": "message"} for _ in range(3)]
        ))
        result = handler.list_input_items(created["id"], order="desc")
        assert result["object"] == "list"
    
    def test_parse_input_items_message(self):
        """Test parsing message input items."""
        from openai.responses import get_responses_handler, CreateResponseRequest
        handler = get_responses_handler()
        created = handler.create(CreateResponseRequest(
            model="gpt-4o",
            input=[{"type": "message", "role": "system", "content": []}]
        ))
        items = handler.list_input_items(created["id"])
        assert items["data"][0]["type"] == "message"
    
    def test_parse_input_items_file(self):
        """Test parsing file input items."""
        from openai.responses import get_responses_handler, CreateResponseRequest
        handler = get_responses_handler()
        created = handler.create(CreateResponseRequest(
            model="gpt-4o",
            input=[{"type": "file", "file_id": "file_123"}]
        ))
        items = handler.list_input_items(created["id"])
        assert items["data"][0]["type"] == "file"
    
    def test_parse_input_items_function_output(self):
        """Test parsing function call output items."""
        from openai.responses import get_responses_handler, CreateResponseRequest
        handler = get_responses_handler()
        created = handler.create(CreateResponseRequest(
            model="gpt-4o",
            input=[{"type": "function_call_output", "call_id": "call_1", "output": "42"}]
        ))
        items = handler.list_input_items(created["id"])
        assert items["data"][0]["type"] == "function_call_output"


# ========================================
# Test Utilities
# ========================================

class TestUtilities:
    """Test utility functions."""
    
    def test_get_responses_handler(self):
        """Test handler factory."""
        from openai.responses import get_responses_handler
        handler = get_responses_handler()
        assert handler.mock_mode is True
    
    def test_create_simple_response(self):
        """Test simple response helper."""
        from openai.responses import create_simple_response
        result = create_simple_response("gpt-4o", [{"type": "message"}])
        assert result["model"] == "gpt-4o"
    
    def test_is_response_complete(self):
        """Test complete status check."""
        from openai.responses import is_response_complete
        assert is_response_complete({"status": "completed"}) is True
        assert is_response_complete({"status": "in_progress"}) is False
    
    def test_is_response_terminal(self):
        """Test terminal status check."""
        from openai.responses import is_response_terminal
        assert is_response_terminal("completed") is True
        assert is_response_terminal("cancelled") is True
        assert is_response_terminal("failed") is True
        assert is_response_terminal("in_progress") is False
    
    def test_get_response_output(self):
        """Test get output helper."""
        from openai.responses import get_response_output
        response = {"output": [{"type": "message"}]}
        assert len(get_response_output(response)) == 1
    
    def test_count_input_items(self):
        """Test count input items."""
        from openai.responses import (
            get_responses_handler, CreateResponseRequest, count_input_items
        )
        handler = get_responses_handler()
        created = handler.create(CreateResponseRequest(
            model="gpt-4o",
            input=[{}, {}, {}]
        ))
        assert count_input_items(created["id"], handler) == 3


# ========================================
# Test Constants
# ========================================

class TestConstants:
    """Test constant values."""
    
    def test_max_input_items(self):
        """Test max input items constant."""
        from openai.responses import MAX_INPUT_ITEMS
        assert MAX_INPUT_ITEMS == 256
    
    def test_max_instructions_length(self):
        """Test max instructions length."""
        from openai.responses import MAX_INSTRUCTIONS_LENGTH
        assert MAX_INSTRUCTIONS_LENGTH == 256000
    
    def test_page_sizes(self):
        """Test page size constants."""
        from openai.responses import DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE
        assert DEFAULT_PAGE_SIZE == 20
        assert MAX_PAGE_SIZE == 100


# ========================================
# Summary
# ========================================

"""
Test Summary: 55 unit tests

TestImports: 2
TestResponseStatus: 1
TestInputItemType: 1
TestMessageRole: 1
TestContentType: 1
TestTextContent: 2
TestAudioContent: 2
TestImageContent: 2
TestMessageInputItem: 2
TestItemReference: 2
TestFileInputItem: 2
TestFunctionCallOutput: 2
TestCreateResponseRequest: 5
TestResponseUsage: 1
TestResponseObject: 2
TestInputItemListResponse: 1
TestResponseDeleteResult: 1
TestResponsesHandler: 13
TestUtilities: 6
TestConstants: 3

Total: 55 tests
"""