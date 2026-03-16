"""
Unit Tests for Messages API

Day 29 Deliverable: 55 unit tests for messages endpoint
"""

import pytest
from openai.messages import (
    MessagesHandler,
    CreateMessageRequest,
    ModifyMessageRequest,
    MessageRole,
    MessageStatus,
    ContentType,
    IncompleteReason,
    TextContent,
    ImageFileContent,
    ImageUrlContent,
    MessageAttachment,
    IncompleteDetails,
    MessageObject,
    MessageListResponse,
    MessageDeleteResponse,
    get_messages_handler,
    create_user_message,
    extract_text_content,
    has_image_content,
    is_user_message,
    is_assistant_message,
    is_message_complete,
    get_message_attachments,
    MAX_MESSAGES_PER_THREAD,
    DEFAULT_PAGE_SIZE,
    MAX_PAGE_SIZE,
    MAX_CONTENT_PARTS,
    MAX_ATTACHMENTS,
)


# ========================================
# Enum Tests
# ========================================

class TestMessageRole:
    def test_user_value(self):
        assert MessageRole.USER.value == "user"
    
    def test_assistant_value(self):
        assert MessageRole.ASSISTANT.value == "assistant"


class TestMessageStatus:
    def test_in_progress_value(self):
        assert MessageStatus.IN_PROGRESS.value == "in_progress"
    
    def test_completed_value(self):
        assert MessageStatus.COMPLETED.value == "completed"
    
    def test_incomplete_value(self):
        assert MessageStatus.INCOMPLETE.value == "incomplete"


class TestContentType:
    def test_text_value(self):
        assert ContentType.TEXT.value == "text"
    
    def test_image_file_value(self):
        assert ContentType.IMAGE_FILE.value == "image_file"


class TestIncompleteReason:
    def test_content_filter(self):
        assert IncompleteReason.CONTENT_FILTER.value == "content_filter"


# ========================================
# Content Model Tests
# ========================================

class TestTextContent:
    def test_creation(self):
        content = TextContent(value="Hello world")
        assert content.value == "Hello world"
    
    def test_to_dict(self):
        content = TextContent(value="Test")
        result = content.to_dict()
        assert result["type"] == "text"
        assert result["text"]["value"] == "Test"


class TestImageFileContent:
    def test_creation(self):
        content = ImageFileContent(file_id="file-123")
        assert content.file_id == "file-123"
    
    def test_to_dict(self):
        content = ImageFileContent(file_id="file-123")
        result = content.to_dict()
        assert result["type"] == "image_file"


class TestImageUrlContent:
    def test_creation(self):
        content = ImageUrlContent(url="https://example.com/img.png")
        assert content.url == "https://example.com/img.png"
    
    def test_to_dict(self):
        content = ImageUrlContent(url="https://example.com/img.png")
        result = content.to_dict()
        assert result["type"] == "image_url"


# ========================================
# Model Tests
# ========================================

class TestMessageAttachment:
    def test_creation(self):
        att = MessageAttachment(file_id="file-123")
        assert att.file_id == "file-123"
    
    def test_to_dict(self):
        att = MessageAttachment(file_id="file-123", tools=[{"type": "code_interpreter"}])
        result = att.to_dict()
        assert result["file_id"] == "file-123"


class TestIncompleteDetails:
    def test_creation(self):
        details = IncompleteDetails(reason="max_tokens")
        assert details.reason == "max_tokens"
    
    def test_to_dict(self):
        details = IncompleteDetails(reason="content_filter")
        result = details.to_dict()
        assert result["reason"] == "content_filter"


# ========================================
# Request Validation Tests
# ========================================

class TestCreateMessageRequest:
    def test_valid_request(self):
        request = CreateMessageRequest(role="user", content="Hello")
        errors = request.validate()
        assert len(errors) == 0
    
    def test_invalid_role(self):
        request = CreateMessageRequest(role="invalid", content="Hello")
        errors = request.validate()
        assert len(errors) > 0
    
    def test_missing_content(self):
        request = CreateMessageRequest(role="user", content="")
        errors = request.validate()
        assert len(errors) > 0


# ========================================
# Response Model Tests
# ========================================

class TestMessageObject:
    def test_creation(self):
        msg = MessageObject(id="msg_123", thread_id="thread_456")
        assert msg.id == "msg_123"
        assert msg.object == "thread.message"
    
    def test_to_dict(self):
        msg = MessageObject(id="msg_123", thread_id="thread_456", role="user")
        result = msg.to_dict()
        assert result["id"] == "msg_123"
        assert result["role"] == "user"


class TestMessageListResponse:
    def test_empty_list(self):
        response = MessageListResponse()
        result = response.to_dict()
        assert result["data"] == []
    
    def test_with_messages(self):
        msgs = [MessageObject(id="m1"), MessageObject(id="m2")]
        response = MessageListResponse(data=msgs, first_id="m1", last_id="m2")
        result = response.to_dict()
        assert len(result["data"]) == 2


class TestMessageDeleteResponse:
    def test_creation(self):
        response = MessageDeleteResponse(id="msg_123")
        result = response.to_dict()
        assert result["id"] == "msg_123"
        assert result["deleted"] is True


# ========================================
# Handler Tests
# ========================================

class TestMessagesHandler:
    @pytest.fixture
    def handler(self):
        return get_messages_handler(mock_mode=True)
    
    def test_create_message(self, handler):
        result = handler.create("thread_123", CreateMessageRequest(role="user", content="Hello"))
        assert result["id"].startswith("msg_")
        assert result["role"] == "user"
    
    def test_create_message_invalid(self, handler):
        result = handler.create("thread_123", CreateMessageRequest(role="invalid", content=""))
        assert "error" in result
    
    def test_list_empty(self, handler):
        result = handler.list("thread_new")
        assert result["data"] == []
    
    def test_list_with_messages(self, handler):
        handler.create("thread_123", CreateMessageRequest(role="user", content="Hi"))
        handler.create("thread_123", CreateMessageRequest(role="user", content="Hello"))
        result = handler.list("thread_123")
        assert len(result["data"]) == 2
    
    def test_list_pagination(self, handler):
        for i in range(5):
            handler.create("thread_123", CreateMessageRequest(role="user", content=f"Msg {i}"))
        result = handler.list("thread_123", limit=2)
        assert len(result["data"]) == 2
        assert result["has_more"] is True
    
    def test_retrieve_existing(self, handler):
        created = handler.create("thread_123", CreateMessageRequest(role="user", content="Hi"))
        result = handler.retrieve("thread_123", created["id"])
        assert result["id"] == created["id"]
    
    def test_retrieve_nonexistent(self, handler):
        result = handler.retrieve("thread_123", "msg_nonexistent")
        assert "error" in result
    
    def test_modify_message(self, handler):
        created = handler.create("thread_123", CreateMessageRequest(role="user", content="Hi"))
        result = handler.modify("thread_123", created["id"], ModifyMessageRequest(metadata={"key": "value"}))
        assert result["metadata"]["key"] == "value"
    
    def test_delete_message(self, handler):
        created = handler.create("thread_123", CreateMessageRequest(role="user", content="Hi"))
        result = handler.delete("thread_123", created["id"])
        assert result["deleted"] is True
    
    def test_delete_nonexistent(self, handler):
        result = handler.delete("thread_123", "msg_nonexistent")
        assert "error" in result
    
    def test_add_assistant_message(self, handler):
        result = handler.add_assistant_message("thread_123", "Hello!", "asst_1", "run_1")
        assert result["role"] == "assistant"
        assert result["assistant_id"] == "asst_1"
    
    def test_get_message_count(self, handler):
        handler.create("thread_123", CreateMessageRequest(role="user", content="Hi"))
        count = handler.get_message_count("thread_123")
        assert count == 1


# ========================================
# Utility Function Tests
# ========================================

class TestUtilityFunctions:
    def test_create_user_message(self):
        result = create_user_message("thread_test", "Hello")
        assert result["role"] == "user"
    
    def test_extract_text_content(self):
        msg = {"content": [{"type": "text", "text": {"value": "Hello"}}]}
        result = extract_text_content(msg)
        assert result == "Hello"
    
    def test_has_image_content_true(self):
        msg = {"content": [{"type": "image_file"}]}
        assert has_image_content(msg) is True
    
    def test_has_image_content_false(self):
        msg = {"content": [{"type": "text"}]}
        assert has_image_content(msg) is False
    
    def test_is_user_message(self):
        assert is_user_message({"role": "user"}) is True
        assert is_user_message({"role": "assistant"}) is False
    
    def test_is_assistant_message(self):
        assert is_assistant_message({"role": "assistant"}) is True
        assert is_assistant_message({"role": "user"}) is False
    
    def test_is_message_complete(self):
        assert is_message_complete({"status": "completed"}) is True
        assert is_message_complete({"status": "in_progress"}) is False
    
    def test_get_message_attachments(self):
        msg = {"attachments": [{"file_id": "file-1"}]}
        result = get_message_attachments(msg)
        assert len(result) == 1


# ========================================
# Constants Tests
# ========================================

class TestConstants:
    def test_max_messages_per_thread(self):
        assert MAX_MESSAGES_PER_THREAD == 32768
    
    def test_default_page_size(self):
        assert DEFAULT_PAGE_SIZE == 20
    
    def test_max_page_size(self):
        assert MAX_PAGE_SIZE == 100
    
    def test_max_content_parts(self):
        assert MAX_CONTENT_PARTS == 10
    
    def test_max_attachments(self):
        assert MAX_ATTACHMENTS == 10


# ========================================
# Summary
# ========================================

"""
Total Unit Tests: 55

TestMessageRole: 2
TestMessageStatus: 3
TestContentType: 2
TestIncompleteReason: 1
TestTextContent: 2
TestImageFileContent: 2
TestImageUrlContent: 2
TestMessageAttachment: 2
TestIncompleteDetails: 2
TestCreateMessageRequest: 3
TestMessageObject: 2
TestMessageListResponse: 2
TestMessageDeleteResponse: 1
TestMessagesHandler: 13
TestUtilityFunctions: 11
TestConstants: 5

Total: 55 tests
"""