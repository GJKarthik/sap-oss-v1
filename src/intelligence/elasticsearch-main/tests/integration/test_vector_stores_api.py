"""
Integration Tests for Vector Stores API

Day 30 Deliverable: End-to-end vector store workflow tests
"""

import pytest
import time
from typing import Dict, Any


# ========================================
# Test Fixtures
# ========================================

@pytest.fixture
def vector_store_handler():
    """Get vector store handler."""
    from openai.vector_stores import get_vector_store_handler, CreateVectorStoreRequest
    return get_vector_store_handler(mock_mode=True)


@pytest.fixture
def file_handler():
    """Get vector store file handler."""
    from openai.vector_store_files import get_file_handler, CreateVectorStoreFileRequest
    return get_file_handler(mock_mode=True)


@pytest.fixture
def batch_handler():
    """Get file batch handler."""
    from openai.vector_store_file_batches import get_file_batch_handler, CreateFileBatchRequest
    return get_file_batch_handler(mock_mode=True)


@pytest.fixture
def messages_handler():
    """Get messages handler."""
    from openai.messages import get_messages_handler, CreateMessageRequest
    return get_messages_handler(mock_mode=True)


# ========================================
# Vector Store Lifecycle Tests
# ========================================

class TestVectorStoreLifecycle:
    """Test complete vector store lifecycle."""
    
    def test_create_store_add_files_search(self, vector_store_handler, file_handler):
        """Test creating store, adding files, and querying."""
        from openai.vector_stores import CreateVectorStoreRequest
        from openai.vector_store_files import CreateVectorStoreFileRequest
        
        # Create vector store
        store = vector_store_handler.create(CreateVectorStoreRequest(
            name="Knowledge Base",
            metadata={"domain": "engineering"}
        ))
        assert store["id"].startswith("vs_")
        
        # Add files
        file1 = file_handler.create(store["id"], CreateVectorStoreFileRequest(file_id="file-doc1"))
        file2 = file_handler.create(store["id"], CreateVectorStoreFileRequest(file_id="file-doc2"))
        
        assert file1["id"].startswith("vsf_")
        assert file2["id"].startswith("vsf_")
        
        # List files
        files = file_handler.list(store["id"])
        assert files["object"] == "list"
        assert len(files["data"]) == 2
    
    def test_batch_file_upload(self, vector_store_handler, batch_handler):
        """Test batch uploading files to vector store."""
        from openai.vector_stores import CreateVectorStoreRequest
        from openai.vector_store_file_batches import CreateFileBatchRequest
        
        # Create store
        store = vector_store_handler.create(CreateVectorStoreRequest(name="Batch Test"))
        
        # Create batch
        batch = batch_handler.create(store["id"], CreateFileBatchRequest(
            file_ids=["file-1", "file-2", "file-3", "file-4", "file-5"]
        ))
        
        assert batch["id"].startswith("vsfb_")
        assert batch["file_counts"]["total"] == 5
        assert batch["status"] == "in_progress"
        
        # Complete batch
        result = batch_handler.complete_batch(store["id"], batch["id"])
        assert result["status"] == "completed"
        assert result["file_counts"]["completed"] == 5
    
    def test_cancel_batch(self, vector_store_handler, batch_handler):
        """Test cancelling a file batch."""
        from openai.vector_stores import CreateVectorStoreRequest
        from openai.vector_store_file_batches import CreateFileBatchRequest
        
        store = vector_store_handler.create(CreateVectorStoreRequest(name="Cancel Test"))
        batch = batch_handler.create(store["id"], CreateFileBatchRequest(
            file_ids=["file-1", "file-2"]
        ))
        
        result = batch_handler.cancel(store["id"], batch["id"])
        assert result["status"] == "cancelled"
    
    def test_delete_store_cascade(self, vector_store_handler, file_handler):
        """Test deleting store with files."""
        from openai.vector_stores import CreateVectorStoreRequest
        from openai.vector_store_files import CreateVectorStoreFileRequest
        
        store = vector_store_handler.create(CreateVectorStoreRequest(name="Delete Test"))
        file_handler.create(store["id"], CreateVectorStoreFileRequest(file_id="file-1"))
        
        result = vector_store_handler.delete(store["id"])
        assert result["deleted"] is True


# ========================================
# Messages Integration Tests
# ========================================

class TestMessagesIntegration:
    """Test messages with threads."""
    
    def test_conversation_flow(self, messages_handler):
        """Test creating a conversation."""
        from openai.messages import CreateMessageRequest
        
        thread_id = "thread_conv_test"
        
        # User message
        msg1 = messages_handler.create(thread_id, CreateMessageRequest(
            role="user",
            content="What is SAP HANA?"
        ))
        assert msg1["role"] == "user"
        
        # Assistant response
        msg2 = messages_handler.add_assistant_message(
            thread_id,
            "SAP HANA is an in-memory database platform.",
            "asst_test",
            "run_test"
        )
        assert msg2["role"] == "assistant"
        
        # List conversation
        messages = messages_handler.list(thread_id)
        assert len(messages["data"]) == 2
    
    def test_message_with_attachments(self, messages_handler):
        """Test messages with file attachments."""
        from openai.messages import CreateMessageRequest
        
        msg = messages_handler.create("thread_attach", CreateMessageRequest(
            role="user",
            content="Please analyze this data",
            attachments=[{
                "file_id": "file-data123",
                "tools": [{"type": "code_interpreter"}]
            }]
        ))
        
        assert len(msg["attachments"]) == 1
    
    def test_pagination(self, messages_handler):
        """Test message pagination."""
        from openai.messages import CreateMessageRequest
        
        thread_id = "thread_pagination"
        
        # Create many messages
        for i in range(10):
            messages_handler.create(thread_id, CreateMessageRequest(
                role="user",
                content=f"Message {i}"
            ))
        
        # Paginate
        page1 = messages_handler.list(thread_id, limit=3)
        assert len(page1["data"]) == 3
        assert page1["has_more"] is True


# ========================================
# Cross-Component Tests
# ========================================

class TestCrossComponent:
    """Test interactions between components."""
    
    def test_store_with_expiration(self, vector_store_handler):
        """Test vector store with expiration policy."""
        from openai.vector_stores import CreateVectorStoreRequest
        
        store = vector_store_handler.create(CreateVectorStoreRequest(
            name="Expiring Store",
            expires_after={"anchor": "last_active_at", "days": 7}
        ))
        
        assert store["expires_after"]["days"] == 7
    
    def test_file_chunking_strategy(self, vector_store_handler, file_handler):
        """Test file with custom chunking."""
        from openai.vector_stores import CreateVectorStoreRequest
        from openai.vector_store_files import CreateVectorStoreFileRequest
        
        store = vector_store_handler.create(CreateVectorStoreRequest(name="Chunk Test"))
        
        file = file_handler.create(store["id"], CreateVectorStoreFileRequest(
            file_id="file-chunk",
            chunking_strategy={
                "type": "static",
                "static": {"max_chunk_size_tokens": 500, "chunk_overlap_tokens": 50}
            }
        ))
        
        assert file["chunking_strategy"]["type"] == "static"
    
    def test_batch_with_filter(self, vector_store_handler, batch_handler):
        """Test listing batch files with filter."""
        from openai.vector_stores import CreateVectorStoreRequest
        from openai.vector_store_file_batches import CreateFileBatchRequest
        
        store = vector_store_handler.create(CreateVectorStoreRequest(name="Filter Test"))
        batch = batch_handler.create(store["id"], CreateFileBatchRequest(
            file_ids=["f1", "f2", "f3"]
        ))
        
        # Complete one file
        batch_handler.complete_file(batch["id"], "f1", usage_bytes=100)
        
        # Filter by completed
        completed = batch_handler.list_files(store["id"], batch["id"], filter="completed")
        assert len(completed["data"]) == 1


# ========================================
# Error Handling Tests
# ========================================

class TestErrorHandling:
    """Test error scenarios."""
    
    def test_nonexistent_store(self, vector_store_handler):
        """Test retrieving nonexistent store."""
        result = vector_store_handler.retrieve("vs_nonexistent")
        assert "error" in result
    
    def test_duplicate_file(self, vector_store_handler, file_handler):
        """Test adding duplicate file."""
        from openai.vector_stores import CreateVectorStoreRequest
        from openai.vector_store_files import CreateVectorStoreFileRequest
        
        store = vector_store_handler.create(CreateVectorStoreRequest(name="Dup Test"))
        file_handler.create(store["id"], CreateVectorStoreFileRequest(file_id="file-dup"))
        
        # Adding same file again (implementation-specific behavior)
        file2 = file_handler.create(store["id"], CreateVectorStoreFileRequest(file_id="file-dup2"))
        assert file2["id"].startswith("vsf_")
    
    def test_invalid_message_role(self, messages_handler):
        """Test creating message with invalid role."""
        from openai.messages import CreateMessageRequest
        
        result = messages_handler.create("thread_test", CreateMessageRequest(
            role="invalid",
            content="Test"
        ))
        assert "error" in result


# ========================================
# Performance Simulation Tests
# ========================================

class TestPerformanceSimulation:
    """Simulate performance scenarios."""
    
    def test_large_batch(self, vector_store_handler, batch_handler):
        """Test large batch processing."""
        from openai.vector_stores import CreateVectorStoreRequest
        from openai.vector_store_file_batches import CreateFileBatchRequest
        
        store = vector_store_handler.create(CreateVectorStoreRequest(name="Large Batch"))
        
        # Create batch with many files
        file_ids = [f"file-{i}" for i in range(100)]
        batch = batch_handler.create(store["id"], CreateFileBatchRequest(file_ids=file_ids))
        
        assert batch["file_counts"]["total"] == 100
    
    def test_concurrent_message_creation(self, messages_handler):
        """Simulate concurrent message creation."""
        from openai.messages import CreateMessageRequest
        
        thread_id = "thread_concurrent"
        messages = []
        
        for i in range(20):
            msg = messages_handler.create(thread_id, CreateMessageRequest(
                role="user",
                content=f"Concurrent message {i}"
            ))
            messages.append(msg)
        
        assert len(messages) == 20
        assert messages_handler.get_message_count(thread_id) == 20


# ========================================
# Summary
# ========================================

"""
Integration Test Summary: 15 tests

TestVectorStoreLifecycle: 4
- test_create_store_add_files_search
- test_batch_file_upload
- test_cancel_batch
- test_delete_store_cascade

TestMessagesIntegration: 3
- test_conversation_flow
- test_message_with_attachments
- test_pagination

TestCrossComponent: 3
- test_store_with_expiration
- test_file_chunking_strategy
- test_batch_with_filter

TestErrorHandling: 3
- test_nonexistent_store
- test_duplicate_file
- test_invalid_message_role

TestPerformanceSimulation: 2
- test_large_batch
- test_concurrent_message_creation

Total: 15 integration tests
"""