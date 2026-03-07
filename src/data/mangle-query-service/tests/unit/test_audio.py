"""
Unit Tests for Audio Endpoints

Day 12 Tests: Comprehensive tests for /v1/audio/transcriptions and /v1/audio/translations
Target: 48+ tests for full coverage

Test Categories:
1. AudioResponseFormat enum
2. TranscriptionRequest creation and validation
3. TranslationRequest creation and validation
4. TranscriptionResponse formatting (JSON, text, SRT, VTT)
5. TranscriptionSegment and TranscriptionWord
6. AudioHandler operations
7. Audio file utilities
8. Error handling
9. OpenAI API compliance
"""

import pytest
from io import BytesIO
from pathlib import Path

from openai.audio import (
    AudioResponseFormat,
    TimestampGranularity,
    TranscriptionRequest,
    TranscriptionResponse,
    TranscriptionWord,
    TranscriptionSegment,
    TranslationRequest,
    TranslationResponse,
    AudioErrorResponse,
    AudioHandler,
    get_audio_handler,
    transcribe_audio,
    translate_audio,
    validate_audio_file,
    get_audio_content_type,
    estimate_audio_duration,
    SUPPORTED_AUDIO_FORMATS,
)


# ========================================
# Fixtures
# ========================================

@pytest.fixture
def sample_audio_data():
    """Create sample audio file data (mock MP3 header)."""
    # Simple mock audio data
    return b"\xff\xfb\x90\x00" + b"\x00" * 1000


@pytest.fixture
def basic_transcription_request(sample_audio_data):
    """Create a basic transcription request."""
    return TranscriptionRequest(
        file=sample_audio_data,
        model="whisper-1",
    )


@pytest.fixture
def full_transcription_request(sample_audio_data):
    """Create a request with all parameters."""
    return TranscriptionRequest(
        file=sample_audio_data,
        model="whisper-1",
        language="en",
        prompt="Meeting transcription",
        response_format=AudioResponseFormat.VERBOSE_JSON,
        temperature=0.2,
        timestamp_granularities=[TimestampGranularity.WORD, TimestampGranularity.SEGMENT],
    )


@pytest.fixture
def handler():
    """Create an audio handler in mock mode."""
    return AudioHandler()


# ========================================
# Test AudioResponseFormat Enum
# ========================================

class TestAudioResponseFormat:
    """Tests for AudioResponseFormat enum."""
    
    def test_json_format(self):
        """Test JSON format value."""
        assert AudioResponseFormat.JSON.value == "json"
    
    def test_text_format(self):
        """Test text format value."""
        assert AudioResponseFormat.TEXT.value == "text"
    
    def test_srt_format(self):
        """Test SRT format value."""
        assert AudioResponseFormat.SRT.value == "srt"
    
    def test_verbose_json_format(self):
        """Test verbose JSON format value."""
        assert AudioResponseFormat.VERBOSE_JSON.value == "verbose_json"
    
    def test_vtt_format(self):
        """Test VTT format value."""
        assert AudioResponseFormat.VTT.value == "vtt"
    
    def test_all_formats(self):
        """Test all formats are defined."""
        formats = [f.value for f in AudioResponseFormat]
        assert "json" in formats
        assert "text" in formats
        assert "srt" in formats
        assert "verbose_json" in formats
        assert "vtt" in formats


# ========================================
# Test TimestampGranularity Enum
# ========================================

class TestTimestampGranularity:
    """Tests for TimestampGranularity enum."""
    
    def test_word_granularity(self):
        """Test word granularity value."""
        assert TimestampGranularity.WORD.value == "word"
    
    def test_segment_granularity(self):
        """Test segment granularity value."""
        assert TimestampGranularity.SEGMENT.value == "segment"


# ========================================
# Test TranscriptionRequest
# ========================================

class TestTranscriptionRequest:
    """Tests for TranscriptionRequest dataclass."""
    
    def test_create_basic(self, basic_transcription_request):
        """Test basic request creation."""
        assert basic_transcription_request.model == "whisper-1"
        assert basic_transcription_request.temperature == 0.0
        assert basic_transcription_request.response_format == AudioResponseFormat.JSON
    
    def test_create_with_all_params(self, full_transcription_request):
        """Test creation with all parameters."""
        assert full_transcription_request.language == "en"
        assert full_transcription_request.prompt == "Meeting transcription"
        assert full_transcription_request.temperature == 0.2
        assert full_transcription_request.response_format == AudioResponseFormat.VERBOSE_JSON
    
    def test_from_dict_minimal(self, sample_audio_data):
        """Test creation from minimal dict."""
        data = {"model": "whisper-1"}
        request = TranscriptionRequest.from_dict(data, sample_audio_data)
        
        assert request.model == "whisper-1"
        assert request.file == sample_audio_data
    
    def test_from_dict_full(self, sample_audio_data):
        """Test creation from full dict."""
        data = {
            "model": "whisper-1",
            "language": "fr",
            "response_format": "verbose_json",
            "temperature": 0.5,
        }
        request = TranscriptionRequest.from_dict(data, sample_audio_data)
        
        assert request.language == "fr"
        assert request.response_format == AudioResponseFormat.VERBOSE_JSON
        assert request.temperature == 0.5
    
    def test_validate_valid_request(self, basic_transcription_request):
        """Test valid request passes validation."""
        assert basic_transcription_request.validate() is None
    
    def test_validate_missing_file(self):
        """Test validation fails without file."""
        request = TranscriptionRequest(file=b"", model="whisper-1")
        assert "file is required" in request.validate()
    
    def test_validate_missing_model(self, sample_audio_data):
        """Test validation fails without model."""
        request = TranscriptionRequest(file=sample_audio_data, model="")
        assert "model is required" in request.validate()
    
    def test_validate_invalid_temperature(self, sample_audio_data):
        """Test temperature > 1 is invalid."""
        request = TranscriptionRequest(
            file=sample_audio_data,
            model="whisper-1",
            temperature=1.5,
        )
        assert "temperature" in request.validate()
    
    def test_validate_invalid_language(self, sample_audio_data):
        """Test invalid language code."""
        request = TranscriptionRequest(
            file=sample_audio_data,
            model="whisper-1",
            language="english",  # Should be "en"
        )
        assert "language" in request.validate()


# ========================================
# Test TranslationRequest
# ========================================

class TestTranslationRequest:
    """Tests for TranslationRequest dataclass."""
    
    def test_create_basic(self, sample_audio_data):
        """Test basic request creation."""
        request = TranslationRequest(file=sample_audio_data, model="whisper-1")
        assert request.model == "whisper-1"
        assert request.temperature == 0.0
    
    def test_from_dict(self, sample_audio_data):
        """Test creation from dict."""
        data = {
            "model": "whisper-1",
            "response_format": "text",
        }
        request = TranslationRequest.from_dict(data, sample_audio_data)
        
        assert request.response_format == AudioResponseFormat.TEXT
    
    def test_validate_valid(self, sample_audio_data):
        """Test valid request passes validation."""
        request = TranslationRequest(file=sample_audio_data, model="whisper-1")
        assert request.validate() is None
    
    def test_validate_missing_file(self):
        """Test validation fails without file."""
        request = TranslationRequest(file=b"", model="whisper-1")
        assert "file is required" in request.validate()


# ========================================
# Test TranscriptionResponse
# ========================================

class TestTranscriptionResponse:
    """Tests for TranscriptionResponse dataclass."""
    
    def test_create_simple(self):
        """Test simple response creation."""
        response = TranscriptionResponse(text="Hello world")
        assert response.text == "Hello world"
    
    def test_create_factory(self):
        """Test factory method."""
        response = TranscriptionResponse.create(
            text="Test transcription",
            language="en",
            duration=30.0,
            include_verbose=True,
        )
        
        assert response.text == "Test transcription"
        assert response.language == "en"
        assert response.duration == 30.0
        assert response.task == "transcribe"
    
    def test_to_dict_simple(self):
        """Test simple dict conversion."""
        response = TranscriptionResponse(text="Hello")
        result = response.to_dict()
        
        assert result == {"text": "Hello"}
    
    def test_to_dict_verbose(self):
        """Test verbose dict conversion."""
        response = TranscriptionResponse.create(
            text="Test",
            language="en",
            duration=10.0,
            include_verbose=True,
        )
        result = response.to_dict(verbose=True)
        
        assert "task" in result
        assert "language" in result
        assert "duration" in result
        assert result["text"] == "Test"
    
    def test_to_text(self):
        """Test text conversion."""
        response = TranscriptionResponse(text="Plain text output")
        assert response.to_text() == "Plain text output"
    
    def test_to_srt_simple(self):
        """Test SRT conversion without segments."""
        response = TranscriptionResponse(text="Hello world")
        srt = response.to_srt()
        
        assert "1\n" in srt
        assert "-->" in srt
        assert "Hello world" in srt
    
    def test_to_srt_with_segments(self):
        """Test SRT conversion with segments."""
        response = TranscriptionResponse(text="Hello. World.")
        response.segments = [
            TranscriptionSegment(id=0, seek=0, start=0.0, end=1.0, text="Hello."),
            TranscriptionSegment(id=1, seek=100, start=1.0, end=2.0, text="World."),
        ]
        srt = response.to_srt()
        
        assert "1\n" in srt
        assert "2\n" in srt
        assert "Hello." in srt
        assert "World." in srt
    
    def test_to_vtt(self):
        """Test WebVTT conversion."""
        response = TranscriptionResponse(text="Test caption")
        vtt = response.to_vtt()
        
        assert vtt.startswith("WEBVTT")
        assert "-->" in vtt
        assert "Test caption" in vtt


# ========================================
# Test TranscriptionWord
# ========================================

class TestTranscriptionWord:
    """Tests for TranscriptionWord dataclass."""
    
    def test_create(self):
        """Test word creation."""
        word = TranscriptionWord(word="hello", start=0.0, end=0.5)
        assert word.word == "hello"
        assert word.start == 0.0
        assert word.end == 0.5
    
    def test_to_dict(self):
        """Test dict conversion."""
        word = TranscriptionWord(word="test", start=1.0, end=1.5)
        result = word.to_dict()
        
        assert result["word"] == "test"
        assert result["start"] == 1.0
        assert result["end"] == 1.5


# ========================================
# Test TranscriptionSegment
# ========================================

class TestTranscriptionSegment:
    """Tests for TranscriptionSegment dataclass."""
    
    def test_create_basic(self):
        """Test segment creation."""
        segment = TranscriptionSegment(
            id=0,
            seek=0,
            start=0.0,
            end=5.0,
            text="Hello world",
        )
        assert segment.id == 0
        assert segment.text == "Hello world"
    
    def test_to_dict(self):
        """Test dict conversion."""
        segment = TranscriptionSegment(
            id=1,
            seek=500,
            start=5.0,
            end=10.0,
            text="Test segment",
            tokens=[1, 2, 3],
            temperature=0.0,
            avg_logprob=-0.3,
        )
        result = segment.to_dict()
        
        assert result["id"] == 1
        assert result["text"] == "Test segment"
        assert result["tokens"] == [1, 2, 3]
        assert result["avg_logprob"] == -0.3


# ========================================
# Test TranslationResponse
# ========================================

class TestTranslationResponse:
    """Tests for TranslationResponse dataclass."""
    
    def test_create(self):
        """Test response creation."""
        response = TranslationResponse(text="Translated text")
        assert response.text == "Translated text"
    
    def test_to_dict(self):
        """Test dict conversion."""
        response = TranslationResponse(text="Hello")
        result = response.to_dict()
        assert result == {"text": "Hello"}
    
    def test_to_text(self):
        """Test text conversion."""
        response = TranslationResponse(text="Plain text")
        assert response.to_text() == "Plain text"


# ========================================
# Test AudioErrorResponse
# ========================================

class TestAudioErrorResponse:
    """Tests for AudioErrorResponse dataclass."""
    
    def test_basic_error(self):
        """Test basic error creation."""
        error = AudioErrorResponse(message="Test error")
        result = error.to_dict()
        
        assert result["error"]["message"] == "Test error"
        assert result["error"]["type"] == "invalid_request_error"
    
    def test_full_error(self):
        """Test error with all fields."""
        error = AudioErrorResponse(
            message="File too large",
            type="validation_error",
            param="file",
            code="file_too_large",
        )
        result = error.to_dict()
        
        assert result["error"]["param"] == "file"
        assert result["error"]["code"] == "file_too_large"


# ========================================
# Test Audio File Utilities
# ========================================

class TestAudioFileUtilities:
    """Tests for audio file utility functions."""
    
    def test_supported_formats(self):
        """Test supported formats list."""
        assert "mp3" in SUPPORTED_AUDIO_FORMATS
        assert "wav" in SUPPORTED_AUDIO_FORMATS
        assert "flac" in SUPPORTED_AUDIO_FORMATS
        assert "ogg" in SUPPORTED_AUDIO_FORMATS
    
    def test_get_audio_content_type_mp3(self):
        """Test content type for MP3."""
        assert get_audio_content_type("test.mp3") == "audio/mpeg"
    
    def test_get_audio_content_type_wav(self):
        """Test content type for WAV."""
        assert get_audio_content_type("test.wav") == "audio/wav"
    
    def test_get_audio_content_type_ogg(self):
        """Test content type for OGG."""
        assert get_audio_content_type("test.ogg") == "audio/ogg"
    
    def test_get_audio_content_type_unknown(self):
        """Test content type for unknown format."""
        assert get_audio_content_type("test.xyz") == "application/octet-stream"
    
    def test_validate_audio_file_valid(self):
        """Test validation of valid audio file."""
        error = validate_audio_file("test.mp3", 1000000)
        assert error is None
    
    def test_validate_audio_file_invalid_format(self):
        """Test validation of invalid format."""
        error = validate_audio_file("test.pdf", 1000)
        assert error is not None
        assert "Unsupported audio format" in error
    
    def test_validate_audio_file_too_large(self):
        """Test validation of file too large."""
        # 30 MB exceeds 25 MB limit
        error = validate_audio_file("test.mp3", 30 * 1024 * 1024)
        assert error is not None
        assert "too large" in error
    
    def test_estimate_audio_duration(self):
        """Test audio duration estimation."""
        # 1 MB file at 128 kbps
        duration = estimate_audio_duration(1024 * 1024, "mp3")
        assert duration > 0
        assert duration < 120  # Should be ~64 seconds


# ========================================
# Test AudioHandler
# ========================================

class TestAudioHandler:
    """Tests for AudioHandler."""
    
    def test_mock_mode(self, handler):
        """Test handler is in mock mode."""
        assert handler.is_mock_mode is True
    
    def test_transcribe_basic(self, handler, basic_transcription_request):
        """Test basic transcription."""
        result = handler.transcribe(basic_transcription_request)
        
        assert "text" in result
        assert len(result["text"]) > 0
    
    def test_transcribe_validation_error(self, handler):
        """Test transcription validation error."""
        request = TranscriptionRequest(file=b"", model="whisper-1")
        result = handler.transcribe(request)
        
        assert "error" in result
    
    def test_transcribe_with_language(self, handler, sample_audio_data):
        """Test transcription with specific language."""
        request = TranscriptionRequest(
            file=sample_audio_data,
            model="whisper-1",
            language="es",
        )
        result = handler.transcribe(request)
        
        assert "text" in result
    
    def test_transcribe_text_format(self, handler, sample_audio_data):
        """Test transcription with text format."""
        request = TranscriptionRequest(
            file=sample_audio_data,
            model="whisper-1",
            response_format=AudioResponseFormat.TEXT,
        )
        result = handler.transcribe(request)
        
        assert isinstance(result, str)
    
    def test_transcribe_srt_format(self, handler, sample_audio_data):
        """Test transcription with SRT format."""
        request = TranscriptionRequest(
            file=sample_audio_data,
            model="whisper-1",
            response_format=AudioResponseFormat.SRT,
        )
        result = handler.transcribe(request)
        
        assert isinstance(result, str)
        assert "-->" in result
    
    def test_transcribe_vtt_format(self, handler, sample_audio_data):
        """Test transcription with VTT format."""
        request = TranscriptionRequest(
            file=sample_audio_data,
            model="whisper-1",
            response_format=AudioResponseFormat.VTT,
        )
        result = handler.transcribe(request)
        
        assert isinstance(result, str)
        assert "WEBVTT" in result
    
    def test_transcribe_verbose_json(self, handler, sample_audio_data):
        """Test transcription with verbose JSON."""
        request = TranscriptionRequest(
            file=sample_audio_data,
            model="whisper-1",
            response_format=AudioResponseFormat.VERBOSE_JSON,
        )
        result = handler.transcribe(request)
        
        assert "task" in result
        assert "language" in result
        assert "segments" in result
    
    def test_translate_basic(self, handler, sample_audio_data):
        """Test basic translation."""
        request = TranslationRequest(
            file=sample_audio_data,
            model="whisper-1",
        )
        result = handler.translate(request)
        
        assert "text" in result
    
    def test_translate_text_format(self, handler, sample_audio_data):
        """Test translation with text format."""
        request = TranslationRequest(
            file=sample_audio_data,
            model="whisper-1",
            response_format=AudioResponseFormat.TEXT,
        )
        result = handler.translate(request)
        
        assert isinstance(result, str)


# ========================================
# Test Handler Form Data Methods
# ========================================

class TestHandlerFormData:
    """Tests for handler form data methods."""
    
    def test_handle_transcription_valid(self, handler, sample_audio_data):
        """Test handling valid transcription request."""
        form_data = {"model": "whisper-1"}
        result = handler.handle_transcription(form_data, sample_audio_data, "audio.mp3")
        
        assert "text" in result
    
    def test_handle_transcription_invalid_format(self, handler, sample_audio_data):
        """Test handling invalid file format."""
        form_data = {"model": "whisper-1"}
        result = handler.handle_transcription(form_data, sample_audio_data, "audio.pdf")
        
        assert "error" in result
    
    def test_handle_translation_valid(self, handler, sample_audio_data):
        """Test handling valid translation request."""
        form_data = {"model": "whisper-1"}
        result = handler.handle_translation(form_data, sample_audio_data, "audio.mp3")
        
        assert "text" in result


# ========================================
# Test Utility Functions
# ========================================

class TestUtilityFunctions:
    """Tests for module-level utility functions."""
    
    def test_get_audio_handler(self):
        """Test handler factory."""
        handler = get_audio_handler()
        assert isinstance(handler, AudioHandler)
    
    def test_transcribe_audio_function(self, sample_audio_data):
        """Test convenience transcription function."""
        result = transcribe_audio(sample_audio_data)
        assert "text" in result
    
    def test_translate_audio_function(self, sample_audio_data):
        """Test convenience translation function."""
        result = translate_audio(sample_audio_data)
        assert "text" in result


# ========================================
# Test OpenAI API Compliance
# ========================================

class TestOpenAICompliance:
    """Tests for OpenAI API compliance."""
    
    def test_transcription_response_format(self, handler, basic_transcription_request):
        """Test transcription response matches OpenAI format."""
        result = handler.transcribe(basic_transcription_request)
        
        assert "text" in result
        assert isinstance(result["text"], str)
    
    def test_verbose_response_fields(self, handler, sample_audio_data):
        """Test verbose response has required fields."""
        request = TranscriptionRequest(
            file=sample_audio_data,
            model="whisper-1",
            response_format=AudioResponseFormat.VERBOSE_JSON,
        )
        result = handler.transcribe(request)
        
        assert "task" in result
        assert result["task"] == "transcribe"
        assert "language" in result
        assert "duration" in result
        assert "text" in result
    
    def test_segment_format(self, handler, sample_audio_data):
        """Test segment format in verbose response."""
        request = TranscriptionRequest(
            file=sample_audio_data,
            model="whisper-1",
            response_format=AudioResponseFormat.VERBOSE_JSON,
        )
        result = handler.transcribe(request)
        
        assert "segments" in result
        if result["segments"]:
            segment = result["segments"][0]
            assert "id" in segment
            assert "start" in segment
            assert "end" in segment
            assert "text" in segment


if __name__ == "__main__":
    pytest.main([__file__, "-v"])