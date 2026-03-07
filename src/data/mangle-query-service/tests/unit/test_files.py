"""
Unit Tests for Files Endpoints

Day 13 Tests: Comprehensive tests for /v1/files endpoint
Target: 50+ tests for full coverage

Test Categories:
1. FilePurpose and FileStatus enums
2. FileObject creation and serialization
3. FileListResponse and FileDeleteResponse
4. File validation (extension, size, content)
5. JSONL content validation
6. FilesHandler CRUD operations
7. Error handling
8. OpenAI API compliance
"""

import pytest
import json
from unittest.mock import Mock

from openai.files import (
    FilePurpose,
    FileStatus,
    FileObject,
    FileListResponse,
    FileDeleteResponse,
    FileContentResponse,
    FileErrorResponse,
    FilesHandler,
    get_files_handler,
    upload_file,
    list_files,
    get_file,
    delete_file,
    validate_file,
    validate_jsonl_content,
    get_content_type,
    get_file_extension,
    SUPPORTED_PURPOSES,
    ALLOWED_EXTENSIONS,
    MAX_FILE_SIZES,
)


# ========================================
# Fixtures
# ========================================

@pytest.fixture
def sample_jsonl_data():
    """Create sample JSONL file data."""
    lines = [
        {"messages": [{"role": "user", "content": "Hello"}]},
        {"messages": [{"role": "assistant", "content": "Hi there!"}]},
    ]
    return "\n".join(json.dumps(line) for line in lines).encode("utf-8")


@pytest.fixture
def sample_text_data():
    """Create sample text file data."""
    return b"This is a sample text file content."


@pytest.fixture
def handler():
    """Create a files handler in mock mode."""
    return FilesHandler()


# ========================================
# Test FilePurpose Enum
# ========================================

class TestFilePurpose:
    """Tests for FilePurpose enum."""
    
    def test_fine_tune(self):
        """Test fine-tune purpose value."""
        assert FilePurpose.FINE_TUNE.value == "fine-tune"
    
    def test_assistants(self):
        """Test assistants purpose value."""
        assert FilePurpose.ASSISTANTS.value == "assistants"
    
    def test_batch(self):
        """Test batch purpose value."""
        assert FilePurpose.BATCH.value == "batch"
    
    def test_vision(self):
        """Test vision purpose value."""
        assert FilePurpose.VISION.value == "vision"
    
    def test_all_purposes(self):
        """Test all purposes are defined."""
        purposes = [p.value for p in FilePurpose]
        assert "fine-tune" in purposes
        assert "assistants" in purposes
        assert "batch" in purposes


# ========================================
# Test FileStatus Enum
# ========================================

class TestFileStatus:
    """Tests for FileStatus enum."""
    
    def test_uploaded(self):
        """Test uploaded status value."""
        assert FileStatus.UPLOADED.value == "uploaded"
    
    def test_processed(self):
        """Test processed status value."""
        assert FileStatus.PROCESSED.value == "processed"
    
    def test_error(self):
        """Test error status value."""
        assert FileStatus.ERROR.value == "error"


# ========================================
# Test FileObject
# ========================================

class TestFileObject:
    """Tests for FileObject dataclass."""
    
    def test_create_basic(self):
        """Test basic file object creation."""
        file_obj = FileObject.create(
            filename="training.jsonl",
            purpose="fine-tune",
            file_size=1024,
        )
        
        assert file_obj.filename == "training.jsonl"
        assert file_obj.purpose == "fine-tune"
        assert file_obj.bytes == 1024
        assert file_obj.object == "file"
        assert file_obj.status == "uploaded"
    
    def test_create_with_id(self):
        """Test creation with custom ID."""
        file_obj = FileObject.create(
            filename="test.jsonl",
            purpose="fine-tune",
            file_size=100,
            file_id="file-custom123",
        )
        
        assert file_obj.id == "file-custom123"
    
    def test_id_format(self):
        """Test generated ID format."""
        file_obj = FileObject.create(
            filename="test.jsonl",
            purpose="fine-tune",
            file_size=100,
        )
        
        assert file_obj.id.startswith("file-")
        assert len(file_obj.id) == 29  # file- + 24 hex chars
    
    def test_to_dict(self):
        """Test dict conversion."""
        file_obj = FileObject.create(
            filename="test.jsonl",
            purpose="fine-tune",
            file_size=1024,
        )
        result = file_obj.to_dict()
        
        assert result["object"] == "file"
        assert result["filename"] == "test.jsonl"
        assert result["purpose"] == "fine-tune"
        assert result["bytes"] == 1024
        assert "created_at" in result
    
    def test_to_dict_with_status_details(self):
        """Test dict with status details."""
        file_obj = FileObject(
            id="file-123",
            filename="test.jsonl",
            purpose="fine-tune",
            status="error",
            status_details="Invalid format",
        )
        result = file_obj.to_dict()
        
        assert result["status_details"] == "Invalid format"


# ========================================
# Test FileListResponse
# ========================================

class TestFileListResponse:
    """Tests for FileListResponse dataclass."""
    
    def test_empty_list(self):
        """Test empty file list."""
        response = FileListResponse()
        result = response.to_dict()
        
        assert result["object"] == "list"
        assert result["data"] == []
        assert result["has_more"] is False
    
    def test_with_files(self):
        """Test list with files."""
        files = [
            FileObject.create("a.jsonl", "fine-tune", 100),
            FileObject.create("b.jsonl", "fine-tune", 200),
        ]
        response = FileListResponse(data=files, has_more=True)
        result = response.to_dict()
        
        assert len(result["data"]) == 2
        assert result["has_more"] is True


# ========================================
# Test FileDeleteResponse
# ========================================

class TestFileDeleteResponse:
    """Tests for FileDeleteResponse dataclass."""
    
    def test_delete_response(self):
        """Test delete response."""
        response = FileDeleteResponse(id="file-123")
        result = response.to_dict()
        
        assert result["id"] == "file-123"
        assert result["object"] == "file"
        assert result["deleted"] is True


# ========================================
# Test FileContentResponse
# ========================================

class TestFileContentResponse:
    """Tests for FileContentResponse dataclass."""
    
    def test_content_response(self):
        """Test content response."""
        response = FileContentResponse(
            content=b"test content",
            filename="test.txt",
            content_type="text/plain",
        )
        
        assert response.content == b"test content"
        assert response.filename == "test.txt"
    
    def test_to_dict(self):
        """Test metadata dict."""
        response = FileContentResponse(
            content=b"test",
            filename="test.txt",
        )
        result = response.to_dict()
        
        assert result["filename"] == "test.txt"
        assert result["size"] == 4


# ========================================
# Test FileErrorResponse
# ========================================

class TestFileErrorResponse:
    """Tests for FileErrorResponse dataclass."""
    
    def test_basic_error(self):
        """Test basic error."""
        error = FileErrorResponse(message="Test error")
        result = error.to_dict()
        
        assert result["error"]["message"] == "Test error"
        assert result["error"]["type"] == "invalid_request_error"
    
    def test_full_error(self):
        """Test error with all fields."""
        error = FileErrorResponse(
            message="File not found",
            type="invalid_request_error",
            param="file_id",
            code="resource_not_found",
        )
        result = error.to_dict()
        
        assert result["error"]["param"] == "file_id"
        assert result["error"]["code"] == "resource_not_found"


# ========================================
# Test File Validation
# ========================================

class TestFileValidation:
    """Tests for file validation functions."""
    
    def test_validate_valid_jsonl(self):
        """Test valid JSONL file."""
        error = validate_file("training.jsonl", 1024, "fine-tune")
        assert error is None
    
    def test_validate_missing_filename(self):
        """Test missing filename."""
        error = validate_file("", 1024, "fine-tune")
        assert "filename is required" in error
    
    def test_validate_empty_file(self):
        """Test empty file."""
        error = validate_file("test.jsonl", 0, "fine-tune")
        assert "cannot be empty" in error
    
    def test_validate_invalid_purpose(self):
        """Test invalid purpose."""
        error = validate_file("test.jsonl", 1024, "invalid")
        assert "Invalid purpose" in error
    
    def test_validate_wrong_extension(self):
        """Test wrong extension for purpose."""
        error = validate_file("test.pdf", 1024, "fine-tune")
        assert "not allowed" in error
    
    def test_validate_file_too_large(self):
        """Test file too large."""
        # 600 MB > 512 MB limit for fine-tune
        error = validate_file("test.jsonl", 600 * 1024 * 1024, "fine-tune")
        assert "too large" in error
    
    def test_validate_assistants_extension(self):
        """Test valid assistant file extension."""
        error = validate_file("doc.pdf", 1024, "assistants")
        assert error is None
    
    def test_validate_vision_extension(self):
        """Test valid vision file extension."""
        error = validate_file("image.png", 1024, "vision")
        assert error is None


# ========================================
# Test JSONL Validation
# ========================================

class TestJSONLValidation:
    """Tests for JSONL content validation."""
    
    def test_valid_jsonl(self, sample_jsonl_data):
        """Test valid JSONL content."""
        error = validate_jsonl_content(sample_jsonl_data)
        assert error is None
    
    def test_invalid_json(self):
        """Test invalid JSON in JSONL."""
        content = b'{"valid": true}\n{invalid json}'
        error = validate_jsonl_content(content)
        assert "Invalid JSON" in error
    
    def test_empty_lines(self):
        """Test JSONL with empty lines."""
        content = b'{"a": 1}\n\n{"b": 2}'
        error = validate_jsonl_content(content)
        assert error is None
    
    def test_non_utf8(self):
        """Test non-UTF8 content."""
        content = b'\xff\xfe'  # Invalid UTF-8
        error = validate_jsonl_content(content)
        assert "UTF-8" in error


# ========================================
# Test Content Type
# ========================================

class TestContentType:
    """Tests for content type detection."""
    
    def test_json(self):
        """Test JSON content type."""
        assert get_content_type("file.json") == "application/json"
    
    def test_jsonl(self):
        """Test JSONL content type."""
        assert get_content_type("file.jsonl") == "application/jsonl"
    
    def test_pdf(self):
        """Test PDF content type."""
        assert get_content_type("file.pdf") == "application/pdf"
    
    def test_png(self):
        """Test PNG content type."""
        assert get_content_type("file.png") == "image/png"
    
    def test_unknown(self):
        """Test unknown extension."""
        assert get_content_type("file.xyz") == "application/octet-stream"


# ========================================
# Test File Extension
# ========================================

class TestFileExtension:
    """Tests for file extension extraction."""
    
    def test_simple(self):
        """Test simple extension."""
        assert get_file_extension("file.txt") == "txt"
    
    def test_uppercase(self):
        """Test uppercase extension."""
        assert get_file_extension("FILE.TXT") == "txt"
    
    def test_no_extension(self):
        """Test no extension."""
        assert get_file_extension("filename") == ""
    
    def test_multiple_dots(self):
        """Test multiple dots."""
        assert get_file_extension("file.tar.gz") == "gz"


# ========================================
# Test FilesHandler Upload
# ========================================

class TestFilesHandlerUpload:
    """Tests for FilesHandler upload operations."""
    
    def test_mock_mode(self, handler):
        """Test handler is in mock mode."""
        assert handler.is_mock_mode is True
    
    def test_upload_valid_file(self, handler, sample_jsonl_data):
        """Test uploading a valid file."""
        result = handler.upload_file(
            sample_jsonl_data,
            "training.jsonl",
            "fine-tune",
        )
        
        assert "id" in result
        assert result["filename"] == "training.jsonl"
        assert result["purpose"] == "fine-tune"
        assert result["object"] == "file"
    
    def test_upload_invalid_purpose(self, handler, sample_jsonl_data):
        """Test uploading with invalid purpose."""
        result = handler.upload_file(
            sample_jsonl_data,
            "test.jsonl",
            "invalid-purpose",
        )
        
        assert "error" in result
    
    def test_upload_invalid_jsonl(self, handler):
        """Test uploading invalid JSONL."""
        result = handler.upload_file(
            b"not valid json",
            "test.jsonl",
            "fine-tune",
        )
        
        assert "error" in result


# ========================================
# Test FilesHandler List
# ========================================

class TestFilesHandlerList:
    """Tests for FilesHandler list operations."""
    
    def test_list_empty(self, handler):
        """Test listing with no files."""
        result = handler.list_files()
        
        assert result["object"] == "list"
        assert result["data"] == []
    
    def test_list_after_upload(self, handler, sample_jsonl_data):
        """Test listing after upload."""
        handler.upload_file(sample_jsonl_data, "a.jsonl", "fine-tune")
        handler.upload_file(sample_jsonl_data, "b.jsonl", "fine-tune")
        
        result = handler.list_files()
        
        assert len(result["data"]) == 2
    
    def test_list_filter_by_purpose(self, handler, sample_jsonl_data, sample_text_data):
        """Test filtering by purpose."""
        handler.upload_file(sample_jsonl_data, "train.jsonl", "fine-tune")
        handler.upload_file(sample_text_data, "doc.txt", "assistants")
        
        result = handler.list_files(purpose="fine-tune")
        
        assert len(result["data"]) == 1
        assert result["data"][0]["purpose"] == "fine-tune"
    
    def test_list_with_limit(self, handler, sample_jsonl_data):
        """Test listing with limit."""
        for i in range(5):
            handler.upload_file(sample_jsonl_data, f"file{i}.jsonl", "fine-tune")
        
        result = handler.list_files(limit=3)
        
        assert len(result["data"]) == 3
        assert result["has_more"] is True


# ========================================
# Test FilesHandler Retrieve
# ========================================

class TestFilesHandlerRetrieve:
    """Tests for FilesHandler retrieve operations."""
    
    def test_retrieve_existing(self, handler, sample_jsonl_data):
        """Test retrieving existing file."""
        upload_result = handler.upload_file(
            sample_jsonl_data,
            "test.jsonl",
            "fine-tune",
        )
        file_id = upload_result["id"]
        
        result = handler.retrieve_file(file_id)
        
        assert result["id"] == file_id
        assert result["filename"] == "test.jsonl"
    
    def test_retrieve_nonexistent(self, handler):
        """Test retrieving nonexistent file."""
        result = handler.retrieve_file("file-nonexistent")
        
        assert "error" in result
        assert "No such File" in result["error"]["message"]


# ========================================
# Test FilesHandler Delete
# ========================================

class TestFilesHandlerDelete:
    """Tests for FilesHandler delete operations."""
    
    def test_delete_existing(self, handler, sample_jsonl_data):
        """Test deleting existing file."""
        upload_result = handler.upload_file(
            sample_jsonl_data,
            "test.jsonl",
            "fine-tune",
        )
        file_id = upload_result["id"]
        
        result = handler.delete_file(file_id)
        
        assert result["deleted"] is True
        assert result["id"] == file_id
    
    def test_delete_nonexistent(self, handler):
        """Test deleting nonexistent file."""
        result = handler.delete_file("file-nonexistent")
        
        assert "error" in result
    
    def test_retrieve_after_delete(self, handler, sample_jsonl_data):
        """Test file not found after delete."""
        upload_result = handler.upload_file(
            sample_jsonl_data,
            "test.jsonl",
            "fine-tune",
        )
        file_id = upload_result["id"]
        
        handler.delete_file(file_id)
        result = handler.retrieve_file(file_id)
        
        assert "error" in result


# ========================================
# Test FilesHandler Content
# ========================================

class TestFilesHandlerContent:
    """Tests for FilesHandler content operations."""
    
    def test_retrieve_content(self, handler, sample_jsonl_data):
        """Test retrieving file content."""
        upload_result = handler.upload_file(
            sample_jsonl_data,
            "test.jsonl",
            "fine-tune",
        )
        file_id = upload_result["id"]
        
        result = handler.retrieve_file_content(file_id)
        
        assert isinstance(result, FileContentResponse)
        assert result.content == sample_jsonl_data
    
    def test_retrieve_content_nonexistent(self, handler):
        """Test retrieving content of nonexistent file."""
        result = handler.retrieve_file_content("file-nonexistent")
        
        assert isinstance(result, dict)
        assert "error" in result


# ========================================
# Test FilesHandler Form Data
# ========================================

class TestFilesHandlerFormData:
    """Tests for form data handling."""
    
    def test_handle_upload(self, handler, sample_jsonl_data):
        """Test handling form upload."""
        form_data = {"purpose": "fine-tune"}
        result = handler.handle_upload(
            form_data,
            sample_jsonl_data,
            "training.jsonl",
        )
        
        assert "id" in result


# ========================================
# Test File Stats
# ========================================

class TestFileStats:
    """Tests for file statistics."""
    
    def test_stats_empty(self, handler):
        """Test stats with no files."""
        stats = handler.get_file_stats()
        
        assert stats["total_files"] == 0
        assert stats["total_bytes"] == 0
    
    def test_stats_with_files(self, handler, sample_jsonl_data):
        """Test stats with files."""
        handler.upload_file(sample_jsonl_data, "a.jsonl", "fine-tune")
        handler.upload_file(sample_jsonl_data, "b.jsonl", "fine-tune")
        
        stats = handler.get_file_stats()
        
        assert stats["total_files"] == 2
        assert stats["total_bytes"] > 0
        assert stats["by_purpose"]["fine-tune"] == 2


# ========================================
# Test Utility Functions
# ========================================

class TestUtilityFunctions:
    """Tests for module-level utility functions."""
    
    def test_get_files_handler(self):
        """Test handler factory."""
        handler = get_files_handler()
        assert isinstance(handler, FilesHandler)


# ========================================
# Test OpenAI API Compliance
# ========================================

class TestOpenAICompliance:
    """Tests for OpenAI API compliance."""
    
    def test_file_object_format(self, handler, sample_jsonl_data):
        """Test file object matches OpenAI format."""
        result = handler.upload_file(
            sample_jsonl_data,
            "test.jsonl",
            "fine-tune",
        )
        
        # Required fields per OpenAI spec
        assert "id" in result
        assert "object" in result
        assert result["object"] == "file"
        assert "bytes" in result
        assert "created_at" in result
        assert "filename" in result
        assert "purpose" in result
    
    def test_list_response_format(self, handler):
        """Test list response matches OpenAI format."""
        result = handler.list_files()
        
        assert result["object"] == "list"
        assert isinstance(result["data"], list)
    
    def test_delete_response_format(self, handler, sample_jsonl_data):
        """Test delete response matches OpenAI format."""
        upload_result = handler.upload_file(
            sample_jsonl_data,
            "test.jsonl",
            "fine-tune",
        )
        
        result = handler.delete_file(upload_result["id"])
        
        assert "id" in result
        assert "deleted" in result
        assert result["deleted"] is True


if __name__ == "__main__":
    pytest.main([__file__, "-v"])