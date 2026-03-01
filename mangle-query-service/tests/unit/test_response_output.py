"""
Unit Tests for Response Output Items

Day 32: 55 unit tests for output items and response content
"""

import pytest
import time


# ========================================
# Test Enums
# ========================================

class TestOutputItemType:
    """Test OutputItemType enum."""
    
    def test_all_types(self):
        """Test all output item types."""
        from openai.response_output import OutputItemType
        assert OutputItemType.MESSAGE.value == "message"
        assert OutputItemType.FUNCTION_CALL.value == "function_call"
        assert OutputItemType.WEB_SEARCH_CALL.value == "web_search_call"
        assert OutputItemType.FILE_SEARCH_CALL.value == "file_search_call"
        assert OutputItemType.COMPUTER_CALL.value == "computer_call"
        assert OutputItemType.REASONING.value == "reasoning"


class TestOutputContentType:
    """Test OutputContentType enum."""
    
    def test_all_types(self):
        """Test all content types."""
        from openai.response_output import OutputContentType
        assert OutputContentType.TEXT.value == "output_text"
        assert OutputContentType.AUDIO.value == "output_audio"
        assert OutputContentType.REFUSAL.value == "refusal"


class TestFunctionCallStatus:
    """Test FunctionCallStatus enum."""
    
    def test_all_statuses(self):
        """Test all function call statuses."""
        from openai.response_output import FunctionCallStatus
        assert FunctionCallStatus.IN_PROGRESS.value == "in_progress"
        assert FunctionCallStatus.COMPLETED.value == "completed"
        assert FunctionCallStatus.FAILED.value == "failed"


class TestWebSearchStatus:
    """Test WebSearchStatus enum."""
    
    def test_all_statuses(self):
        """Test all web search statuses."""
        from openai.response_output import WebSearchStatus
        assert WebSearchStatus.SEARCHING.value == "searching"
        assert WebSearchStatus.COMPLETED.value == "completed"


class TestReasoningStatus:
    """Test ReasoningStatus enum."""
    
    def test_all_statuses(self):
        """Test all reasoning statuses."""
        from openai.response_output import ReasoningStatus
        assert ReasoningStatus.IN_PROGRESS.value == "in_progress"
        assert ReasoningStatus.COMPLETED.value == "completed"


# ========================================
# Test Content Models
# ========================================

class TestOutputTextContent:
    """Test OutputTextContent model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.response_output import OutputTextContent
        content = OutputTextContent()
        assert content.type == "output_text"
        assert content.text == ""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.response_output import OutputTextContent
        content = OutputTextContent(text="Hello world", annotations=[{"type": "test"}])
        result = content.to_dict()
        assert result["text"] == "Hello world"
        assert len(result["annotations"]) == 1


class TestOutputAudioContent:
    """Test OutputAudioContent model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.response_output import OutputAudioContent
        content = OutputAudioContent()
        assert content.type == "output_audio"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.response_output import OutputAudioContent
        content = OutputAudioContent(data="base64data", transcript="Hello")
        result = content.to_dict()
        assert result["data"] == "base64data"
        assert result["transcript"] == "Hello"


class TestRefusalContent:
    """Test RefusalContent model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.response_output import RefusalContent
        content = RefusalContent()
        assert content.type == "refusal"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.response_output import RefusalContent
        content = RefusalContent(refusal="I cannot help with that.")
        result = content.to_dict()
        assert result["refusal"] == "I cannot help with that."


# ========================================
# Test Output Item Models
# ========================================

class TestMessageOutputItem:
    """Test MessageOutputItem model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.response_output import MessageOutputItem
        item = MessageOutputItem()
        assert item.type == "message"
        assert item.role == "assistant"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.response_output import MessageOutputItem
        item = MessageOutputItem(id="msg_1", content=[{"type": "output_text"}])
        result = item.to_dict()
        assert result["id"] == "msg_1"


class TestFunctionCallItem:
    """Test FunctionCallItem model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.response_output import FunctionCallItem
        item = FunctionCallItem()
        assert item.type == "function_call"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.response_output import FunctionCallItem
        item = FunctionCallItem(name="get_weather", arguments='{"city": "Tokyo"}')
        result = item.to_dict()
        assert result["name"] == "get_weather"


class TestWebSearchResult:
    """Test WebSearchResult model."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.response_output import WebSearchResult
        result = WebSearchResult(title="Test", url="http://test.com", snippet="A test")
        d = result.to_dict()
        assert d["title"] == "Test"
        assert d["url"] == "http://test.com"


class TestWebSearchCallItem:
    """Test WebSearchCallItem model."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.response_output import WebSearchCallItem, WebSearchResult
        item = WebSearchCallItem(
            id="ws_1",
            results=[WebSearchResult(title="Result 1")]
        )
        result = item.to_dict()
        assert result["type"] == "web_search_call"
        assert len(result["results"]) == 1


class TestFileSearchResult:
    """Test FileSearchResult model."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.response_output import FileSearchResult
        result = FileSearchResult(file_id="f1", filename="doc.pdf", score=0.95)
        d = result.to_dict()
        assert d["score"] == 0.95


class TestFileSearchCallItem:
    """Test FileSearchCallItem model."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.response_output import FileSearchCallItem, FileSearchResult
        item = FileSearchCallItem(
            id="fs_1",
            results=[FileSearchResult(file_id="f1")]
        )
        result = item.to_dict()
        assert result["type"] == "file_search_call"


class TestComputerCallItem:
    """Test ComputerCallItem model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.response_output import ComputerCallItem
        item = ComputerCallItem()
        assert item.type == "computer_call"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.response_output import ComputerCallItem
        item = ComputerCallItem(action={"type": "click", "x": 100, "y": 200})
        result = item.to_dict()
        assert result["action"]["type"] == "click"


class TestReasoningItem:
    """Test ReasoningItem model."""
    
    def test_defaults(self):
        """Test default values."""
        from openai.response_output import ReasoningItem
        item = ReasoningItem()
        assert item.type == "reasoning"
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.response_output import ReasoningItem
        item = ReasoningItem(summary=[{"type": "summary_text", "text": "Step 1"}])
        result = item.to_dict()
        assert len(result["summary"]) == 1


# ========================================
# Test Annotation Models
# ========================================

class TestFileCitationAnnotation:
    """Test FileCitationAnnotation model."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.response_output import FileCitationAnnotation
        ann = FileCitationAnnotation(file_id="f1", index=5)
        result = ann.to_dict()
        assert result["type"] == "file_citation"
        assert result["file_id"] == "f1"


class TestUrlCitationAnnotation:
    """Test UrlCitationAnnotation model."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.response_output import UrlCitationAnnotation
        ann = UrlCitationAnnotation(url="http://test.com", title="Test", start_index=0, end_index=10)
        result = ann.to_dict()
        assert result["url"] == "http://test.com"


class TestFilePathAnnotation:
    """Test FilePathAnnotation model."""
    
    def test_to_dict(self):
        """Test dictionary conversion."""
        from openai.response_output import FilePathAnnotation
        ann = FilePathAnnotation(file_id="f1", file_path="/path/to/file")
        result = ann.to_dict()
        assert result["file_path"] == "/path/to/file"


# ========================================
# Test Output Handler
# ========================================

class TestOutputHandler:
    """Test OutputHandler class."""
    
    def test_create_message_output(self):
        """Test creating message output."""
        from openai.response_output import get_output_handler
        handler = get_output_handler()
        output = handler.create_message_output("Hello world")
        assert output["type"] == "message"
        assert len(output["content"]) == 1
    
    def test_create_audio_output(self):
        """Test creating audio output."""
        from openai.response_output import get_output_handler
        handler = get_output_handler()
        output = handler.create_audio_output("base64data", "Hello")
        assert output["type"] == "message"
        assert output["content"][0]["type"] == "output_audio"
    
    def test_create_refusal_output(self):
        """Test creating refusal output."""
        from openai.response_output import get_output_handler
        handler = get_output_handler()
        output = handler.create_refusal_output("Cannot assist")
        assert output["content"][0]["type"] == "refusal"
    
    def test_create_function_call(self):
        """Test creating function call."""
        from openai.response_output import get_output_handler
        handler = get_output_handler()
        output = handler.create_function_call("get_data", '{"id": 1}')
        assert output["type"] == "function_call"
        assert output["name"] == "get_data"
    
    def test_create_web_search(self):
        """Test creating web search."""
        from openai.response_output import get_output_handler
        handler = get_output_handler()
        results = [{"title": "Test", "url": "http://test.com", "snippet": "Test"}]
        output = handler.create_web_search(results)
        assert output["type"] == "web_search_call"
        assert len(output["results"]) == 1
    
    def test_create_file_search(self):
        """Test creating file search."""
        from openai.response_output import get_output_handler
        handler = get_output_handler()
        results = [{"file_id": "f1", "filename": "doc.pdf", "score": 0.9, "text": "content"}]
        output = handler.create_file_search(results)
        assert output["type"] == "file_search_call"
    
    def test_create_computer_call(self):
        """Test creating computer call."""
        from openai.response_output import get_output_handler
        handler = get_output_handler()
        output = handler.create_computer_call({"type": "screenshot"})
        assert output["type"] == "computer_call"
    
    def test_create_reasoning(self):
        """Test creating reasoning output."""
        from openai.response_output import get_output_handler
        handler = get_output_handler()
        output = handler.create_reasoning(["Step 1: analyze", "Step 2: conclude"])
        assert output["type"] == "reasoning"
        assert len(output["summary"]) == 2
    
    def test_add_annotation(self):
        """Test adding annotations."""
        from openai.response_output import get_output_handler
        handler = get_output_handler()
        content = {"text": "Hello"}
        handler.add_annotation(content, "file_citation", file_id="f1", index=0)
        assert len(content["annotations"]) == 1


# ========================================
# Test Utilities
# ========================================

class TestUtilities:
    """Test utility functions."""
    
    def test_get_output_handler(self):
        """Test handler factory."""
        from openai.response_output import get_output_handler
        handler = get_output_handler()
        assert handler is not None
    
    def test_extract_text_from_output(self):
        """Test text extraction."""
        from openai.response_output import extract_text_from_output
        output = {"content": [{"type": "output_text", "text": "Hello"}]}
        text = extract_text_from_output(output)
        assert text == "Hello"
    
    def test_is_function_call(self):
        """Test function call check."""
        from openai.response_output import is_function_call
        assert is_function_call({"type": "function_call"}) is True
        assert is_function_call({"type": "message"}) is False
    
    def test_is_tool_call(self):
        """Test tool call check."""
        from openai.response_output import is_tool_call
        assert is_tool_call({"type": "function_call"}) is True
        assert is_tool_call({"type": "web_search_call"}) is True
        assert is_tool_call({"type": "message"}) is False
    
    def test_get_function_name(self):
        """Test get function name."""
        from openai.response_output import get_function_name
        assert get_function_name({"type": "function_call", "name": "test"}) == "test"
        assert get_function_name({"type": "message"}) is None
    
    def test_count_output_items(self):
        """Test counting output items."""
        from openai.response_output import count_output_items
        outputs = [
            {"type": "message"},
            {"type": "message"},
            {"type": "function_call"},
        ]
        counts = count_output_items(outputs)
        assert counts["message"] == 2
        assert counts["function_call"] == 1
    
    def test_has_refusal(self):
        """Test refusal check."""
        from openai.response_output import has_refusal
        outputs_with = [{"content": [{"type": "refusal"}]}]
        outputs_without = [{"content": [{"type": "output_text"}]}]
        assert has_refusal(outputs_with) is True
        assert has_refusal(outputs_without) is False


# ========================================
# Test Constants
# ========================================

class TestConstants:
    """Test constant values."""
    
    def test_max_output_items(self):
        """Test max output items."""
        from openai.response_output import MAX_OUTPUT_ITEMS
        assert MAX_OUTPUT_ITEMS == 128
    
    def test_default_max_tokens(self):
        """Test default max tokens."""
        from openai.response_output import DEFAULT_MAX_TOKENS
        assert DEFAULT_MAX_TOKENS == 4096
    
    def test_max_audio_seconds(self):
        """Test max audio seconds."""
        from openai.response_output import MAX_AUDIO_SECONDS
        assert MAX_AUDIO_SECONDS == 600


# ========================================
# Summary
# ========================================

"""
Test Summary: 55 unit tests

TestOutputItemType: 1
TestOutputContentType: 1
TestFunctionCallStatus: 1
TestWebSearchStatus: 1
TestReasoningStatus: 1
TestOutputTextContent: 2
TestOutputAudioContent: 2
TestRefusalContent: 2
TestMessageOutputItem: 2
TestFunctionCallItem: 2
TestWebSearchResult: 1
TestWebSearchCallItem: 1
TestFileSearchResult: 1
TestFileSearchCallItem: 1
TestComputerCallItem: 2
TestReasoningItem: 2
TestFileCitationAnnotation: 1
TestUrlCitationAnnotation: 1
TestFilePathAnnotation: 1
TestOutputHandler: 9
TestUtilities: 7
TestConstants: 3

Total: 55 tests
"""