"""
Unit Tests for Threads and Messages API

Day 22 Deliverable: 55 unit tests for OpenAI Threads API
"""

import pytest
from typing import Dict, Any

from openai.threads import (
    # Constants
    MAX_THREAD_METADATA_PAIRS,
    MAX_MESSAGE_CONTENT_LENGTH,
    MAX_MESSAGES_PER_THREAD,
    # Enums
    MessageRole,
    MessageContentType,
    MessageStatus,
    # Content types
    TextContent,
    ImageFileContent,
    ImageUrlContent,
    Attachment,
    # Thread models
    CreateThreadRequest,
    ModifyThreadRequest,
    ThreadObject,
    ThreadDeleteResponse,
    # Message models
    CreateMessageRequest,
    ModifyMessageRequest,
    MessageObject,
    MessageListResponse,
    MessageDeleteResponse,
    ThreadsErrorResponse,
    # Handler
    ThreadsHandler,
    # Utilities
    get_threads_handler,
    create_thread,
    create_message,
    create_text_content,
    create_image_file_content,
    create_image_url_content,
    create_attachment,
    extract_text_from_message,
    is_user_message,
    is_assistant_message,
)


# ========================================
# Enum Tests
# ========================================

class TestMessageRole:
    """Tests for MessageRole enum."""
    
    def test_user_value(self):
        """Test user role value."""
        assert MessageRole.USER.value == "user"
    
    def test_assistant_value(self):
        """Test assistant role value."""
        assert MessageRole.ASSISTANT.value == "assistant"


class TestMessageContentType:
    """Tests for MessageContentType enum."""
    
    def test_text_value(self):
        """Test text content type."""
        assert MessageContentType.TEXT.value == "text"
    
    def test_image_file_value(self):
        """Test image_file content type."""
        assert MessageContentType.IMAGE_FILE.value == "image_file"
    
    def test_image_url_value(self):
        """Test image_url content type."""
        assert MessageContentType.IMAGE_URL.value == "image_url"


class TestMessageStatus:
    """Tests for MessageStatus enum."""
    
    def test_in_progress(self):
        """Test in_progress status."""
        assert MessageStatus.IN_PROGRESS.value == "in_progress"
    
    def test_completed(self):
        """Test completed status."""
        assert MessageStatus.COMPLETED.value == "completed"


# ========================================
# Content Type Tests
# ========================================

class TestTextContent:
    """Tests for TextContent."""
    
    def test_default_type(self):
        """Test default type is text."""
        content = TextContent()
        assert content.type == "text"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        content = TextContent(text="Hello, world!")
        result = content.to_dict()
        assert result["type"] == "text"
        assert result["text"]["value"] == "Hello, world!"
    
    def test_with_annotations(self):
        """Test with annotations."""
        content = TextContent(text="See file", annotations=[{"type": "file_citation"}])
        result = content.to_dict()
        assert len(result["text"]["annotations"]) == 1


class TestImageFileContent:
    """Tests for ImageFileContent."""
    
    def test_default_type(self):
        """Test default type."""
        content = ImageFileContent()
        assert content.type == "image_file"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        content = ImageFileContent(file_id="file-abc123", detail="high")
        result = content.to_dict()
        assert result["image_file"]["file_id"] == "file-abc123"
        assert result["image_file"]["detail"] == "high"


class TestImageUrlContent:
    """Tests for ImageUrlContent."""
    
    def test_default_type(self):
        """Test default type."""
        content = ImageUrlContent()
        assert content.type == "image_url"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        content = ImageUrlContent(url="https://example.com/image.png")
        result = content.to_dict()
        assert result["image_url"]["url"] == "https://example.com/image.png"


class TestAttachment:
    """Tests for Attachment."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        attachment = Attachment(file_id="file-123", tools=[{"type": "code_interpreter"}])
        result = attachment.to_dict()
        assert result["file_id"] == "file-123"
        assert len(result["tools"]) == 1


# ========================================
# Thread Model Tests
# ========================================

class TestCreateThreadRequest:
    """Tests for CreateThreadRequest."""
    
    def test_empty_request_valid(self):
        """Test empty request is valid."""
        request = CreateThreadRequest()
        errors = request.validate()
        assert len(errors) == 0
    
    def test_with_messages(self):
        """Test with initial messages."""
        request = CreateThreadRequest(
            messages=[{"role": "user", "content": "Hello"}]
        )
        errors = request.validate()
        assert len(errors) == 0
    
    def test_metadata_limit(self):
        """Test metadata pair limit."""
        metadata = {f"key{i}": f"value{i}" for i in range(MAX_THREAD_METADATA_PAIRS + 1)}
        request = CreateThreadRequest(metadata=metadata)
        errors = request.validate()
        assert any("metadata" in e for e in errors)
    
    def test_invalid_message_role(self):
        """Test invalid message role."""
        request = CreateThreadRequest(
            messages=[{"role": "system", "content": "Hello"}]
        )
        errors = request.validate()
        assert len(errors) > 0
    
    def test_missing_message_content(self):
        """Test missing message content."""
        request = CreateThreadRequest(
            messages=[{"role": "user"}]
        )
        errors = request.validate()
        assert any("content" in e for e in errors)


class TestModifyThreadRequest:
    """Tests for ModifyThreadRequest."""
    
    def test_empty_valid(self):
        """Test empty request is valid."""
        request = ModifyThreadRequest()
        errors = request.validate()
        assert len(errors) == 0
    
    def test_with_metadata(self):
        """Test with metadata."""
        request = ModifyThreadRequest(metadata={"key": "value"})
        errors = request.validate()
        assert len(errors) == 0


class TestThreadObject:
    """Tests for ThreadObject."""
    
    def test_required_fields(self):
        """Test required fields."""
        thread = ThreadObject(id="thread_123")
        assert thread.id == "thread_123"
        assert thread.object == "thread"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        thread = ThreadObject(id="thread_123", created_at=1234567890)
        result = thread.to_dict()
        assert result["id"] == "thread_123"
        assert result["object"] == "thread"


class TestThreadDeleteResponse:
    """Tests for ThreadDeleteResponse."""
    
    def test_delete_response(self):
        """Test delete response."""
        response = ThreadDeleteResponse(id="thread_123")
        result = response.to_dict()
        assert result["id"] == "thread_123"
        assert result["object"] == "thread.deleted"
        assert result["deleted"] is True


# ========================================
# Message Model Tests
# ========================================

class TestCreateMessageRequest:
    """Tests for CreateMessageRequest."""
    
    def test_default_role(self):
        """Test default role is user."""
        request = CreateMessageRequest(content="Hello")
        assert request.role == "user"
    
    def test_valid_request(self):
        """Test valid request."""
        request = CreateMessageRequest(role="user", content="Hello")
        errors = request.validate()
        assert len(errors) == 0
    
    def test_invalid_role(self):
        """Test invalid role."""
        request = CreateMessageRequest(role="system", content="Hello")
        errors = request.validate()
        assert any("role" in e for e in errors)
    
    def test_empty_content(self):
        """Test empty content fails."""
        request = CreateMessageRequest(role="user", content="")
        errors = request.validate()
        assert any("content" in e for e in errors)


class TestMessageObject:
    """Tests for MessageObject."""
    
    def test_required_fields(self):
        """Test required fields."""
        msg = MessageObject(id="msg_123", thread_id="thread_456")
        assert msg.id == "msg_123"
        assert msg.thread_id == "thread_456"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        msg = MessageObject(
            id="msg_123",
            thread_id="thread_456",
            role="user",
            content=[{"type": "text", "text": {"value": "Hello"}}]
        )
        result = msg.to_dict()
        assert result["id"] == "msg_123"
        assert result["role"] == "user"


class TestMessageListResponse:
    """Tests for MessageListResponse."""
    
    def test_empty_list(self):
        """Test empty list."""
        response = MessageListResponse()
        result = response.to_dict()
        assert result["object"] == "list"
        assert result["data"] == []


class TestMessageDeleteResponse:
    """Tests for MessageDeleteResponse."""
    
    def test_delete_response(self):
        """Test delete response."""
        response = MessageDeleteResponse(id="msg_123")
        result = response.to_dict()
        assert result["object"] == "thread.message.deleted"


# ========================================
# Handler Tests
# ========================================

class TestThreadsHandler:
    """Tests for ThreadsHandler."""
    
    def test_create_thread(self):
        """Test creating a thread."""
        handler = ThreadsHandler()
        request = CreateThreadRequest()
        result = handler.create_thread(request)
        assert "id" in result
        assert result["id"].startswith("thread_")
    
    def test_create_thread_with_messages(self):
        """Test creating thread with messages."""
        handler = ThreadsHandler()
        request = CreateThreadRequest(
            messages=[{"role": "user", "content": "Hello!"}]
        )
        result = handler.create_thread(request)
        assert "id" in result
        
        # Check messages were created
        messages = handler.list_messages(result["id"])
        assert len(messages["data"]) == 1
    
    def test_retrieve_thread(self):
        """Test retrieving a thread."""
        handler = ThreadsHandler()
        created = handler.create_thread(CreateThreadRequest())
        
        result = handler.retrieve_thread(created["id"])
        assert result["id"] == created["id"]
    
    def test_retrieve_nonexistent(self):
        """Test retrieving nonexistent thread."""
        handler = ThreadsHandler()
        result = handler.retrieve_thread("thread_nonexistent")
        assert "error" in result
    
    def test_modify_thread(self):
        """Test modifying a thread."""
        handler = ThreadsHandler()
        created = handler.create_thread(CreateThreadRequest())
        
        modify_request = ModifyThreadRequest(metadata={"key": "value"})
        result = handler.modify_thread(created["id"], modify_request)
        assert result["metadata"]["key"] == "value"
    
    def test_delete_thread(self):
        """Test deleting a thread."""
        handler = ThreadsHandler()
        created = handler.create_thread(CreateThreadRequest())
        
        result = handler.delete_thread(created["id"])
        assert result["deleted"] is True
        
        # Verify deleted
        retrieve = handler.retrieve_thread(created["id"])
        assert "error" in retrieve
    
    def test_create_message(self):
        """Test creating a message."""
        handler = ThreadsHandler()
        thread = handler.create_thread(CreateThreadRequest())
        
        msg_request = CreateMessageRequest(role="user", content="Hello!")
        result = handler.create_message(thread["id"], msg_request)
        assert result["id"].startswith("msg_")
        assert result["role"] == "user"
    
    def test_list_messages(self):
        """Test listing messages."""
        handler = ThreadsHandler()
        thread = handler.create_thread(CreateThreadRequest())
        
        # Create messages
        for i in range(3):
            handler.create_message(
                thread["id"],
                CreateMessageRequest(content=f"Message {i}")
            )
        
        result = handler.list_messages(thread["id"])
        assert len(result["data"]) == 3
    
    def test_retrieve_message(self):
        """Test retrieving a message."""
        handler = ThreadsHandler()
        thread = handler.create_thread(CreateThreadRequest())
        msg = handler.create_message(
            thread["id"],
            CreateMessageRequest(content="Test")
        )
        
        result = handler.retrieve_message(thread["id"], msg["id"])
        assert result["id"] == msg["id"]
    
    def test_modify_message(self):
        """Test modifying a message."""
        handler = ThreadsHandler()
        thread = handler.create_thread(CreateThreadRequest())
        msg = handler.create_message(
            thread["id"],
            CreateMessageRequest(content="Test")
        )
        
        modify = ModifyMessageRequest(metadata={"edited": "true"})
        result = handler.modify_message(thread["id"], msg["id"], modify)
        assert result["metadata"]["edited"] == "true"
    
    def test_delete_message(self):
        """Test deleting a message."""
        handler = ThreadsHandler()
        thread = handler.create_thread(CreateThreadRequest())
        msg = handler.create_message(
            thread["id"],
            CreateMessageRequest(content="Test")
        )
        
        result = handler.delete_message(thread["id"], msg["id"])
        assert result["deleted"] is True


# ========================================
# Utility Function Tests
# ========================================

class TestUtilityFunctions:
    """Tests for utility functions."""
    
    def test_get_threads_handler(self):
        """Test factory function."""
        handler = get_threads_handler()
        assert isinstance(handler, ThreadsHandler)
    
    def test_create_text_content(self):
        """Test text content creation."""
        content = create_text_content("Hello")
        assert content["type"] == "text"
        assert content["text"]["value"] == "Hello"
    
    def test_create_image_file_content(self):
        """Test image file content creation."""
        content = create_image_file_content("file-123", "high")
        assert content["type"] == "image_file"
        assert content["image_file"]["file_id"] == "file-123"
    
    def test_create_image_url_content(self):
        """Test image URL content creation."""
        content = create_image_url_content("https://example.com/img.png")
        assert content["type"] == "image_url"
    
    def test_create_attachment(self):
        """Test attachment creation."""
        attachment = create_attachment("file-123", ["code_interpreter"])
        assert attachment["file_id"] == "file-123"
        assert attachment["tools"][0]["type"] == "code_interpreter"
    
    def test_extract_text_from_message(self):
        """Test text extraction."""
        message = {
            "content": [
                {"type": "text", "text": {"value": "Hello"}},
                {"type": "text", "text": {"value": "World"}}
            ]
        }
        result = extract_text_from_message(message)
        assert "Hello" in result
        assert "World" in result
    
    def test_is_user_message(self):
        """Test user message check."""
        assert is_user_message({"role": "user"}) is True
        assert is_user_message({"role": "assistant"}) is False
    
    def test_is_assistant_message(self):
        """Test assistant message check."""
        assert is_assistant_message({"role": "assistant"}) is True
        assert is_assistant_message({"role": "user"}) is False


# ========================================
# Integration Tests
# ========================================

class TestThreadsIntegration:
    """Integration tests for threads and messages."""
    
    def test_full_conversation(self):
        """Test full conversation flow."""
        handler = ThreadsHandler()
        
        # Create thread
        thread = handler.create_thread(CreateThreadRequest())
        thread_id = thread["id"]
        
        # User sends message
        user_msg = handler.create_message(
            thread_id,
            CreateMessageRequest(role="user", content="What is 2+2?")
        )
        
        # Assistant responds
        asst_msg = handler.create_message(
            thread_id,
            CreateMessageRequest(role="assistant", content="2+2 equals 4.")
        )
        
        # List messages
        messages = handler.list_messages(thread_id)
        assert len(messages["data"]) == 2
    
    def test_thread_with_attachments(self):
        """Test messages with attachments."""
        handler = ThreadsHandler()
        thread = handler.create_thread(CreateThreadRequest())
        
        msg = handler.create_message(
            thread["id"],
            CreateMessageRequest(
                content="Here is a file",
                attachments=[{"file_id": "file-abc", "tools": [{"type": "file_search"}]}]
            )
        )
        
        assert len(msg["attachments"]) == 1


class TestConstants:
    """Tests for constants."""
    
    def test_metadata_limit(self):
        """Test metadata limit constant."""
        assert MAX_THREAD_METADATA_PAIRS == 16
    
    def test_content_length(self):
        """Test content length constant."""
        assert MAX_MESSAGE_CONTENT_LENGTH == 256000
    
    def test_messages_limit(self):
        """Test messages per thread limit."""
        assert MAX_MESSAGES_PER_THREAD == 10000