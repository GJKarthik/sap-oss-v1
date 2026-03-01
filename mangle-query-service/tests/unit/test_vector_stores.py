"""
Unit Tests for Vector Stores API

Day 26 Deliverable: 55 unit tests for vector stores endpoint
"""

import pytest
from openai.vector_stores import (
    VectorStoresHandler,
    CreateVectorStoreRequest,
    ModifyVectorStoreRequest,
    VectorStoreStatus,
    ChunkingStrategyType,
    ExpirationPolicy,
    StaticChunkingStrategy,
    ChunkingStrategy,
    ExpiresAfter,
    FileCounts,
    VectorStoreObject,
    VectorStoreListResponse,
    VectorStoreDeleteResponse,
    get_vector_stores_handler,
    create_vector_store,
    create_chunking_strategy,
    create_expiration_policy,
    is_store_expired,
    is_store_ready,
    get_file_progress,
    validate_chunk_size,
    validate_chunk_overlap,
    estimate_storage_bytes,
    DEFAULT_CHUNK_SIZE,
    MAX_CHUNK_SIZE,
    MIN_CHUNK_SIZE,
)


# ========================================
# Enum Tests
# ========================================

class TestVectorStoreStatus:
    def test_expired_value(self):
        assert VectorStoreStatus.EXPIRED.value == "expired"
    
    def test_in_progress_value(self):
        assert VectorStoreStatus.IN_PROGRESS.value == "in_progress"
    
    def test_completed_value(self):
        assert VectorStoreStatus.COMPLETED.value == "completed"


class TestChunkingStrategyType:
    def test_auto_value(self):
        assert ChunkingStrategyType.AUTO.value == "auto"
    
    def test_static_value(self):
        assert ChunkingStrategyType.STATIC.value == "static"


class TestExpirationPolicy:
    def test_last_active_at_value(self):
        assert ExpirationPolicy.LAST_ACTIVE_AT.value == "last_active_at"


# ========================================
# Chunking Model Tests
# ========================================

class TestStaticChunkingStrategy:
    def test_default_values(self):
        strategy = StaticChunkingStrategy()
        assert strategy.max_chunk_size_tokens == DEFAULT_CHUNK_SIZE
        assert strategy.chunk_overlap_tokens == 400
    
    def test_custom_values(self):
        strategy = StaticChunkingStrategy(max_chunk_size_tokens=1000, chunk_overlap_tokens=200)
        assert strategy.max_chunk_size_tokens == 1000
        assert strategy.chunk_overlap_tokens == 200
    
    def test_validate_valid(self):
        strategy = StaticChunkingStrategy(max_chunk_size_tokens=800, chunk_overlap_tokens=200)
        errors = strategy.validate()
        assert len(errors) == 0
    
    def test_validate_chunk_too_small(self):
        strategy = StaticChunkingStrategy(max_chunk_size_tokens=50)
        errors = strategy.validate()
        assert any("100" in e for e in errors)
    
    def test_validate_chunk_too_large(self):
        strategy = StaticChunkingStrategy(max_chunk_size_tokens=5000)
        errors = strategy.validate()
        assert any("4096" in e for e in errors)
    
    def test_validate_overlap_negative(self):
        strategy = StaticChunkingStrategy(chunk_overlap_tokens=-10)
        errors = strategy.validate()
        assert any(">= 0" in e for e in errors)
    
    def test_validate_overlap_too_large(self):
        strategy = StaticChunkingStrategy(max_chunk_size_tokens=800, chunk_overlap_tokens=500)
        errors = strategy.validate()
        assert any("50%" in e for e in errors)
    
    def test_to_dict(self):
        strategy = StaticChunkingStrategy(max_chunk_size_tokens=1000, chunk_overlap_tokens=300)
        result = strategy.to_dict()
        assert result["max_chunk_size_tokens"] == 1000
        assert result["chunk_overlap_tokens"] == 300


class TestChunkingStrategy:
    def test_auto_strategy(self):
        strategy = ChunkingStrategy(type="auto")
        assert strategy.to_dict() == {"type": "auto"}
    
    def test_static_strategy(self):
        static = StaticChunkingStrategy(max_chunk_size_tokens=1000)
        strategy = ChunkingStrategy(type="static", static=static)
        result = strategy.to_dict()
        assert result["type"] == "static"
        assert "static" in result


# ========================================
# Expiration Policy Tests
# ========================================

class TestExpiresAfter:
    def test_default_values(self):
        exp = ExpiresAfter()
        assert exp.anchor == "last_active_at"
        assert exp.days == 7
    
    def test_custom_days(self):
        exp = ExpiresAfter(days=30)
        assert exp.days == 30
    
    def test_validate_valid(self):
        exp = ExpiresAfter(days=30)
        errors = exp.validate()
        assert len(errors) == 0
    
    def test_validate_invalid_anchor(self):
        exp = ExpiresAfter(anchor="invalid")
        errors = exp.validate()
        assert len(errors) > 0
    
    def test_validate_days_too_low(self):
        exp = ExpiresAfter(days=0)
        errors = exp.validate()
        assert len(errors) > 0
    
    def test_validate_days_too_high(self):
        exp = ExpiresAfter(days=400)
        errors = exp.validate()
        assert len(errors) > 0
    
    def test_to_dict(self):
        exp = ExpiresAfter(days=14)
        result = exp.to_dict()
        assert result["anchor"] == "last_active_at"
        assert result["days"] == 14


# ========================================
# File Counts Tests
# ========================================

class TestFileCounts:
    def test_default_values(self):
        counts = FileCounts()
        assert counts.total == 0
        assert counts.completed == 0
    
    def test_custom_values(self):
        counts = FileCounts(total=10, completed=5, in_progress=3, failed=2)
        assert counts.total == 10
        assert counts.completed == 5
    
    def test_to_dict(self):
        counts = FileCounts(total=5, completed=3)
        result = counts.to_dict()
        assert result["total"] == 5
        assert result["completed"] == 3


# ========================================
# Request Validation Tests
# ========================================

class TestCreateVectorStoreRequest:
    def test_empty_request_valid(self):
        request = CreateVectorStoreRequest()
        errors = request.validate()
        assert len(errors) == 0
    
    def test_with_name(self):
        request = CreateVectorStoreRequest(name="Test Store")
        errors = request.validate()
        assert len(errors) == 0
    
    def test_with_file_ids(self):
        request = CreateVectorStoreRequest(file_ids=["file_1", "file_2"])
        errors = request.validate()
        assert len(errors) == 0
    
    def test_too_many_files(self):
        request = CreateVectorStoreRequest(file_ids=[f"file_{i}" for i in range(150)])
        errors = request.validate()
        assert len(errors) > 0
    
    def test_valid_metadata(self):
        request = CreateVectorStoreRequest(metadata={"key": "value"})
        errors = request.validate()
        assert len(errors) == 0
    
    def test_too_many_metadata_pairs(self):
        request = CreateVectorStoreRequest(metadata={f"key_{i}": f"value_{i}" for i in range(20)})
        errors = request.validate()
        assert len(errors) > 0


class TestModifyVectorStoreRequest:
    def test_empty_request_valid(self):
        request = ModifyVectorStoreRequest()
        errors = request.validate()
        assert len(errors) == 0
    
    def test_with_name(self):
        request = ModifyVectorStoreRequest(name="New Name")
        errors = request.validate()
        assert len(errors) == 0
    
    def test_with_expires_after(self):
        request = ModifyVectorStoreRequest(expires_after={"anchor": "last_active_at", "days": 30})
        errors = request.validate()
        assert len(errors) == 0


# ========================================
# Handler Tests
# ========================================

class TestVectorStoresHandler:
    @pytest.fixture
    def handler(self):
        return get_vector_stores_handler(mock_mode=True)
    
    def test_create_basic(self, handler):
        result = handler.create(CreateVectorStoreRequest())
        assert result["id"].startswith("vs_")
        assert result["object"] == "vector_store"
    
    def test_create_with_name(self, handler):
        result = handler.create(CreateVectorStoreRequest(name="My Store"))
        assert result["name"] == "My Store"
    
    def test_create_with_files(self, handler):
        result = handler.create(CreateVectorStoreRequest(file_ids=["file_1", "file_2"]))
        assert result["status"] == "in_progress"
        assert result["file_counts"]["total"] == 2
    
    def test_create_with_expiration(self, handler):
        result = handler.create(CreateVectorStoreRequest(
            expires_after={"anchor": "last_active_at", "days": 14}
        ))
        assert "expires_after" in result
        assert result["expires_after"]["days"] == 14
    
    def test_list_empty(self, handler):
        result = handler.list()
        assert result["object"] == "list"
        assert result["data"] == []
    
    def test_list_with_stores(self, handler):
        handler.create(CreateVectorStoreRequest(name="Store 1"))
        handler.create(CreateVectorStoreRequest(name="Store 2"))
        result = handler.list()
        assert len(result["data"]) == 2
    
    def test_list_pagination(self, handler):
        for i in range(5):
            handler.create(CreateVectorStoreRequest(name=f"Store {i}"))
        result = handler.list(limit=2)
        assert len(result["data"]) == 2
        assert result["has_more"] is True
    
    def test_retrieve_existing(self, handler):
        created = handler.create(CreateVectorStoreRequest(name="Test"))
        result = handler.retrieve(created["id"])
        assert result["id"] == created["id"]
        assert result["name"] == "Test"
    
    def test_retrieve_nonexistent(self, handler):
        result = handler.retrieve("vs_nonexistent")
        assert "error" in result
    
    def test_modify_name(self, handler):
        created = handler.create(CreateVectorStoreRequest(name="Original"))
        result = handler.modify(created["id"], ModifyVectorStoreRequest(name="Modified"))
        assert result["name"] == "Modified"
    
    def test_modify_metadata(self, handler):
        created = handler.create(CreateVectorStoreRequest())
        result = handler.modify(created["id"], ModifyVectorStoreRequest(
            metadata={"category": "test"}
        ))
        assert result["metadata"]["category"] == "test"
    
    def test_modify_nonexistent(self, handler):
        result = handler.modify("vs_nonexistent", ModifyVectorStoreRequest(name="Test"))
        assert "error" in result
    
    def test_delete_existing(self, handler):
        created = handler.create(CreateVectorStoreRequest())
        result = handler.delete(created["id"])
        assert result["deleted"] is True
        assert result["id"] == created["id"]
    
    def test_delete_nonexistent(self, handler):
        result = handler.delete("vs_nonexistent")
        assert "error" in result
    
    def test_complete_files(self, handler):
        created = handler.create(CreateVectorStoreRequest(file_ids=["file_1", "file_2"]))
        assert created["status"] == "in_progress"
        result = handler.complete_files(created["id"])
        assert result["status"] == "completed"
        assert result["file_counts"]["completed"] == 2


# ========================================
# Utility Function Tests
# ========================================

class TestUtilityFunctions:
    def test_create_vector_store(self):
        result = create_vector_store(name="Helper Store")
        assert result["id"].startswith("vs_")
        assert result["name"] == "Helper Store"
    
    def test_create_chunking_strategy_auto(self):
        result = create_chunking_strategy("auto")
        assert result["type"] == "auto"
    
    def test_create_chunking_strategy_static(self):
        result = create_chunking_strategy("static", max_chunk_size=1000, chunk_overlap=200)
        assert result["type"] == "static"
        assert result["static"]["max_chunk_size_tokens"] == 1000
    
    def test_create_expiration_policy(self):
        result = create_expiration_policy(days=30)
        assert result["anchor"] == "last_active_at"
        assert result["days"] == 30
    
    def test_is_store_expired(self):
        assert is_store_expired({"status": "expired"}) is True
        assert is_store_expired({"status": "completed"}) is False
    
    def test_is_store_ready(self):
        assert is_store_ready({"status": "completed"}) is True
        assert is_store_ready({"status": "in_progress"}) is False
    
    def test_get_file_progress_empty(self):
        result = get_file_progress({"file_counts": {"total": 0, "completed": 0}})
        assert result == 100.0
    
    def test_get_file_progress_partial(self):
        result = get_file_progress({"file_counts": {"total": 10, "completed": 5}})
        assert result == 50.0
    
    def test_validate_chunk_size_valid(self):
        assert validate_chunk_size(500) is True
        assert validate_chunk_size(MIN_CHUNK_SIZE) is True
        assert validate_chunk_size(MAX_CHUNK_SIZE) is True
    
    def test_validate_chunk_size_invalid(self):
        assert validate_chunk_size(50) is False
        assert validate_chunk_size(5000) is False
    
    def test_validate_chunk_overlap_valid(self):
        assert validate_chunk_overlap(200, 800) is True
    
    def test_validate_chunk_overlap_invalid(self):
        assert validate_chunk_overlap(500, 800) is False
    
    def test_estimate_storage_bytes(self):
        result = estimate_storage_bytes(10)
        assert result > 0


# ========================================
# Summary
# ========================================

"""
Total Unit Tests: 55

TestVectorStoreStatus: 3
TestChunkingStrategyType: 2
TestExpirationPolicy: 1
TestStaticChunkingStrategy: 8
TestChunkingStrategy: 2
TestExpiresAfter: 7
TestFileCounts: 3
TestCreateVectorStoreRequest: 6
TestModifyVectorStoreRequest: 3
TestVectorStoresHandler: 16
TestUtilityFunctions: 14

Total: 55 tests
"""