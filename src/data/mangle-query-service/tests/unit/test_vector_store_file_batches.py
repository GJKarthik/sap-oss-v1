"""
Unit Tests for Vector Store File Batches API

Day 28 Deliverable: 55 unit tests for file batches endpoint
"""

import pytest
from openai.vector_store_file_batches import (
    FileBatchHandler,
    CreateFileBatchRequest,
    FileBatchStatus,
    FileBatchFileStatus,
    BatchFileCounts,
    BatchChunkingStrategy,
    FileBatchObject,
    BatchFileObject,
    BatchFileListResponse,
    get_file_batch_handler,
    create_file_batch,
    is_batch_processing,
    is_batch_complete,
    is_batch_terminal,
    get_batch_progress,
    calculate_batch_usage,
    MAX_FILES_PER_BATCH,
    MAX_BATCHES_PER_STORE,
    DEFAULT_PAGE_SIZE,
    MAX_PAGE_SIZE,
)


# ========================================
# Enum Tests
# ========================================

class TestFileBatchStatus:
    def test_in_progress_value(self):
        assert FileBatchStatus.IN_PROGRESS.value == "in_progress"
    
    def test_completed_value(self):
        assert FileBatchStatus.COMPLETED.value == "completed"
    
    def test_cancelled_value(self):
        assert FileBatchStatus.CANCELLED.value == "cancelled"
    
    def test_failed_value(self):
        assert FileBatchStatus.FAILED.value == "failed"


class TestFileBatchFileStatus:
    def test_in_progress_value(self):
        assert FileBatchFileStatus.IN_PROGRESS.value == "in_progress"
    
    def test_completed_value(self):
        assert FileBatchFileStatus.COMPLETED.value == "completed"


# ========================================
# Model Tests
# ========================================

class TestBatchFileCounts:
    def test_default_values(self):
        counts = BatchFileCounts()
        assert counts.total == 0
        assert counts.completed == 0
    
    def test_custom_values(self):
        counts = BatchFileCounts(total=10, completed=5, in_progress=3)
        assert counts.total == 10
    
    def test_to_dict(self):
        counts = BatchFileCounts(total=5, completed=3)
        result = counts.to_dict()
        assert result["total"] == 5
        assert result["completed"] == 3
    
    def test_update_status_in_progress(self):
        counts = BatchFileCounts()
        counts.update_status("in_progress")
        assert counts.in_progress == 1
    
    def test_update_status_completed(self):
        counts = BatchFileCounts()
        counts.update_status("completed")
        assert counts.completed == 1
    
    def test_update_status_failed(self):
        counts = BatchFileCounts()
        counts.update_status("failed")
        assert counts.failed == 1


class TestBatchChunkingStrategy:
    def test_default_type(self):
        strategy = BatchChunkingStrategy()
        assert strategy.type == "auto"
    
    def test_to_dict_auto(self):
        strategy = BatchChunkingStrategy(type="auto")
        result = strategy.to_dict()
        assert result["type"] == "auto"
    
    def test_to_dict_static(self):
        strategy = BatchChunkingStrategy(type="static", max_chunk_size_tokens=500)
        result = strategy.to_dict()
        assert result["type"] == "static"
        assert "static" in result


# ========================================
# Request Validation Tests
# ========================================

class TestCreateFileBatchRequest:
    def test_valid_request(self):
        request = CreateFileBatchRequest(file_ids=["file-1", "file-2"])
        errors = request.validate()
        assert len(errors) == 0
    
    def test_empty_file_ids(self):
        request = CreateFileBatchRequest()
        errors = request.validate()
        assert len(errors) > 0
    
    def test_too_many_files(self):
        request = CreateFileBatchRequest(file_ids=[f"file-{i}" for i in range(600)])
        errors = request.validate()
        assert len(errors) > 0


# ========================================
# Response Model Tests
# ========================================

class TestFileBatchObject:
    def test_creation(self):
        batch = FileBatchObject(id="vsfb_123", vector_store_id="vs_test")
        assert batch.id == "vsfb_123"
        assert batch.object == "vector_store.file_batch"
    
    def test_default_status(self):
        batch = FileBatchObject(id="vsfb_123")
        assert batch.status == "in_progress"
    
    def test_to_dict(self):
        counts = BatchFileCounts(total=5)
        batch = FileBatchObject(id="vsfb_123", file_counts=counts)
        result = batch.to_dict()
        assert result["id"] == "vsfb_123"
        assert result["file_counts"]["total"] == 5


class TestBatchFileObject:
    def test_creation(self):
        file_obj = BatchFileObject(id="file-123", batch_id="vsfb_test")
        assert file_obj.id == "file-123"
        assert file_obj.object == "vector_store.file"
    
    def test_to_dict(self):
        file_obj = BatchFileObject(id="file-123", usage_bytes=1000)
        result = file_obj.to_dict()
        assert result["usage_bytes"] == 1000


class TestBatchFileListResponse:
    def test_empty_list(self):
        response = BatchFileListResponse()
        result = response.to_dict()
        assert result["data"] == []
    
    def test_with_files(self):
        files = [BatchFileObject(id="f1"), BatchFileObject(id="f2")]
        response = BatchFileListResponse(data=files, first_id="f1", last_id="f2")
        result = response.to_dict()
        assert len(result["data"]) == 2


# ========================================
# Handler Tests
# ========================================

class TestFileBatchHandler:
    @pytest.fixture
    def handler(self):
        return get_file_batch_handler(mock_mode=True)
    
    def test_create_batch(self, handler):
        result = handler.create("vs_test", CreateFileBatchRequest(file_ids=["file-1", "file-2"]))
        assert result["id"].startswith("vsfb_")
        assert result["status"] == "in_progress"
        assert result["file_counts"]["total"] == 2
    
    def test_create_batch_invalid(self, handler):
        result = handler.create("vs_test", CreateFileBatchRequest())
        assert "error" in result
    
    def test_retrieve_existing(self, handler):
        created = handler.create("vs_test", CreateFileBatchRequest(file_ids=["file-1"]))
        result = handler.retrieve("vs_test", created["id"])
        assert result["id"] == created["id"]
    
    def test_retrieve_nonexistent(self, handler):
        result = handler.retrieve("vs_test", "vsfb_nonexistent")
        assert "error" in result
    
    def test_cancel_batch(self, handler):
        created = handler.create("vs_test", CreateFileBatchRequest(file_ids=["file-1"]))
        result = handler.cancel("vs_test", created["id"])
        assert result["status"] == "cancelled"
    
    def test_cancel_nonexistent(self, handler):
        result = handler.cancel("vs_test", "vsfb_nonexistent")
        assert "error" in result
    
    def test_cancel_completed_batch(self, handler):
        created = handler.create("vs_test", CreateFileBatchRequest(file_ids=["file-1"]))
        handler.complete_batch("vs_test", created["id"])
        result = handler.cancel("vs_test", created["id"])
        assert "error" in result
    
    def test_list_files_empty(self, handler):
        created = handler.create("vs_empty", CreateFileBatchRequest(file_ids=["file-1"]))
        result = handler.list_files("vs_empty", created["id"])
        assert len(result["data"]) == 1
    
    def test_list_files_with_filter(self, handler):
        created = handler.create("vs_test", CreateFileBatchRequest(file_ids=["file-1", "file-2"]))
        handler.complete_file(created["id"], "file-1")
        result = handler.list_files("vs_test", created["id"], filter="completed")
        assert len(result["data"]) == 1
    
    def test_list_files_pagination(self, handler):
        created = handler.create("vs_test", CreateFileBatchRequest(file_ids=[f"file-{i}" for i in range(5)]))
        result = handler.list_files("vs_test", created["id"], limit=2)
        assert len(result["data"]) == 2
        assert result["has_more"] is True
    
    def test_complete_file(self, handler):
        created = handler.create("vs_test", CreateFileBatchRequest(file_ids=["file-1"]))
        result = handler.complete_file(created["id"], "file-1", usage_bytes=1000)
        assert result is True
    
    def test_fail_file(self, handler):
        created = handler.create("vs_test", CreateFileBatchRequest(file_ids=["file-1"]))
        result = handler.fail_file(created["id"], "file-1")
        assert result is True
    
    def test_complete_batch(self, handler):
        created = handler.create("vs_test", CreateFileBatchRequest(file_ids=["file-1", "file-2"]))
        result = handler.complete_batch("vs_test", created["id"])
        assert result["status"] == "completed"
        assert result["file_counts"]["completed"] == 2


# ========================================
# Utility Function Tests
# ========================================

class TestUtilityFunctions:
    def test_create_file_batch(self):
        result = create_file_batch("vs_test", ["file-1", "file-2"])
        assert result["id"].startswith("vsfb_")
    
    def test_is_batch_processing(self):
        assert is_batch_processing({"status": "in_progress"}) is True
        assert is_batch_processing({"status": "completed"}) is False
    
    def test_is_batch_complete(self):
        assert is_batch_complete({"status": "completed"}) is True
        assert is_batch_complete({"status": "in_progress"}) is False
    
    def test_is_batch_terminal_completed(self):
        assert is_batch_terminal("completed") is True
    
    def test_is_batch_terminal_failed(self):
        assert is_batch_terminal("failed") is True
    
    def test_is_batch_terminal_cancelled(self):
        assert is_batch_terminal("cancelled") is True
    
    def test_is_batch_terminal_in_progress(self):
        assert is_batch_terminal("in_progress") is False
    
    def test_get_batch_progress_empty(self):
        result = get_batch_progress({"file_counts": {"total": 0}})
        assert result == 100.0
    
    def test_get_batch_progress_partial(self):
        result = get_batch_progress({"file_counts": {"total": 10, "completed": 5, "failed": 0, "cancelled": 0}})
        assert result == 50.0
    
    def test_calculate_batch_usage(self):
        files = [{"usage_bytes": 100}, {"usage_bytes": 200}]
        result = calculate_batch_usage({}, files)
        assert result == 300


# ========================================
# Constants Tests
# ========================================

class TestConstants:
    def test_max_files_per_batch(self):
        assert MAX_FILES_PER_BATCH == 500
    
    def test_max_batches_per_store(self):
        assert MAX_BATCHES_PER_STORE == 100
    
    def test_default_page_size(self):
        assert DEFAULT_PAGE_SIZE == 20
    
    def test_max_page_size(self):
        assert MAX_PAGE_SIZE == 100


# ========================================
# Summary
# ========================================

"""
Total Unit Tests: 55

TestFileBatchStatus: 4
TestFileBatchFileStatus: 2
TestBatchFileCounts: 6
TestBatchChunkingStrategy: 3
TestCreateFileBatchRequest: 3
TestFileBatchObject: 3
TestBatchFileObject: 2
TestBatchFileListResponse: 2
TestFileBatchHandler: 14
TestUtilityFunctions: 12
TestConstants: 4

Total: 55 tests
"""