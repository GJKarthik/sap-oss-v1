"""
OpenAI Audio Endpoints Handler

Day 12 Deliverable: /v1/audio/transcriptions and /v1/audio/translations endpoints
Reference: https://platform.openai.com/docs/api-reference/audio

Provides OpenAI-compatible audio processing:
- Transcription: Convert audio to text in the source language
- Translation: Convert audio to English text

Usage:
    from openai.audio import AudioHandler
    
    handler = AudioHandler()
    result = handler.transcribe(audio_file, model="whisper-1")
"""

import time
import uuid
import logging
import hashlib
import base64
from typing import Optional, Dict, Any, List, Union, BinaryIO
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

logger = logging.getLogger(__name__)


# ========================================
# Enums
# ========================================

class AudioResponseFormat(str, Enum):
    """Supported response formats for audio endpoints."""
    JSON = "json"
    TEXT = "text"
    SRT = "srt"
    VERBOSE_JSON = "verbose_json"
    VTT = "vtt"


class TimestampGranularity(str, Enum):
    """Timestamp granularity levels."""
    WORD = "word"
    SEGMENT = "segment"


# ========================================
# Request Models
# ========================================

@dataclass
class TranscriptionRequest:
    """
    Request for audio transcription.
    
    Reference: https://platform.openai.com/docs/api-reference/audio/createTranscription
    """
    file: Union[bytes, BinaryIO, str]  # Audio file or path
    model: str = "whisper-1"
    
    # Optional parameters
    language: Optional[str] = None  # ISO-639-1 code
    prompt: Optional[str] = None
    response_format: AudioResponseFormat = AudioResponseFormat.JSON
    temperature: float = 0.0
    timestamp_granularities: Optional[List[TimestampGranularity]] = None
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any], file_data: bytes = None) -> "TranscriptionRequest":
        """Create request from form data."""
        response_format = data.get("response_format", "json")
        if isinstance(response_format, str):
            response_format = AudioResponseFormat(response_format)
        
        timestamp_granularities = data.get("timestamp_granularities")
        if timestamp_granularities:
            timestamp_granularities = [
                TimestampGranularity(g) if isinstance(g, str) else g 
                for g in timestamp_granularities
            ]
        
        return cls(
            file=file_data or data.get("file", b""),
            model=data.get("model", "whisper-1"),
            language=data.get("language"),
            prompt=data.get("prompt"),
            response_format=response_format,
            temperature=float(data.get("temperature", 0.0)),
            timestamp_granularities=timestamp_granularities,
        )
    
    def validate(self) -> Optional[str]:
        """Validate request parameters."""
        if not self.file:
            return "file is required"
        
        if not self.model:
            return "model is required"
        
        if self.temperature < 0 or self.temperature > 1:
            return "temperature must be between 0 and 1"
        
        if self.language and len(self.language) != 2:
            return "language must be a 2-letter ISO-639-1 code"
        
        return None


@dataclass
class TranslationRequest:
    """
    Request for audio translation to English.
    
    Reference: https://platform.openai.com/docs/api-reference/audio/createTranslation
    """
    file: Union[bytes, BinaryIO, str]
    model: str = "whisper-1"
    
    # Optional parameters
    prompt: Optional[str] = None
    response_format: AudioResponseFormat = AudioResponseFormat.JSON
    temperature: float = 0.0
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any], file_data: bytes = None) -> "TranslationRequest":
        """Create request from form data."""
        response_format = data.get("response_format", "json")
        if isinstance(response_format, str):
            response_format = AudioResponseFormat(response_format)
        
        return cls(
            file=file_data or data.get("file", b""),
            model=data.get("model", "whisper-1"),
            prompt=data.get("prompt"),
            response_format=response_format,
            temperature=float(data.get("temperature", 0.0)),
        )
    
    def validate(self) -> Optional[str]:
        """Validate request parameters."""
        if not self.file:
            return "file is required"
        
        if not self.model:
            return "model is required"
        
        if self.temperature < 0 or self.temperature > 1:
            return "temperature must be between 0 and 1"
        
        return None


# ========================================
# Response Models
# ========================================

@dataclass
class TranscriptionWord:
    """Word-level transcription with timing."""
    word: str
    start: float
    end: float
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "word": self.word,
            "start": self.start,
            "end": self.end,
        }


@dataclass 
class TranscriptionSegment:
    """Segment-level transcription with timing."""
    id: int
    seek: int
    start: float
    end: float
    text: str
    tokens: List[int] = field(default_factory=list)
    temperature: float = 0.0
    avg_logprob: float = 0.0
    compression_ratio: float = 0.0
    no_speech_prob: float = 0.0
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "id": self.id,
            "seek": self.seek,
            "start": self.start,
            "end": self.end,
            "text": self.text,
            "tokens": self.tokens,
            "temperature": self.temperature,
            "avg_logprob": self.avg_logprob,
            "compression_ratio": self.compression_ratio,
            "no_speech_prob": self.no_speech_prob,
        }


@dataclass
class TranscriptionResponse:
    """
    Response from audio transcription.
    
    Reference: https://platform.openai.com/docs/api-reference/audio/json-object
    """
    text: str
    
    # Verbose JSON fields
    task: Optional[str] = None
    language: Optional[str] = None
    duration: Optional[float] = None
    words: Optional[List[TranscriptionWord]] = None
    segments: Optional[List[TranscriptionSegment]] = None
    
    @classmethod
    def create(
        cls,
        text: str,
        language: str = "en",
        duration: float = None,
        include_verbose: bool = False,
    ) -> "TranscriptionResponse":
        """Create transcription response."""
        response = cls(text=text)
        
        if include_verbose:
            response.task = "transcribe"
            response.language = language
            response.duration = duration
        
        return response
    
    def to_dict(self, verbose: bool = False) -> Dict[str, Any]:
        """Convert to dictionary."""
        if not verbose:
            return {"text": self.text}
        
        result = {
            "task": self.task or "transcribe",
            "language": self.language or "en",
            "duration": self.duration or 0.0,
            "text": self.text,
        }
        
        if self.words:
            result["words"] = [w.to_dict() for w in self.words]
        if self.segments:
            result["segments"] = [s.to_dict() for s in self.segments]
        
        return result
    
    def to_text(self) -> str:
        """Return plain text."""
        return self.text
    
    def to_srt(self) -> str:
        """Convert to SRT subtitle format."""
        if not self.segments:
            return f"1\n00:00:00,000 --> 00:00:30,000\n{self.text}\n"
        
        lines = []
        for i, seg in enumerate(self.segments):
            start = self._format_srt_time(seg.start)
            end = self._format_srt_time(seg.end)
            lines.append(f"{i + 1}")
            lines.append(f"{start} --> {end}")
            lines.append(seg.text.strip())
            lines.append("")
        
        return "\n".join(lines)
    
    def to_vtt(self) -> str:
        """Convert to WebVTT format."""
        lines = ["WEBVTT", ""]
        
        if not self.segments:
            lines.append("00:00:00.000 --> 00:00:30.000")
            lines.append(self.text)
        else:
            for seg in self.segments:
                start = self._format_vtt_time(seg.start)
                end = self._format_vtt_time(seg.end)
                lines.append(f"{start} --> {end}")
                lines.append(seg.text.strip())
                lines.append("")
        
        return "\n".join(lines)
    
    def _format_srt_time(self, seconds: float) -> str:
        """Format seconds as SRT timestamp (HH:MM:SS,mmm)."""
        hours = int(seconds // 3600)
        minutes = int((seconds % 3600) // 60)
        secs = int(seconds % 60)
        millis = int((seconds % 1) * 1000)
        return f"{hours:02d}:{minutes:02d}:{secs:02d},{millis:03d}"
    
    def _format_vtt_time(self, seconds: float) -> str:
        """Format seconds as VTT timestamp (HH:MM:SS.mmm)."""
        hours = int(seconds // 3600)
        minutes = int((seconds % 3600) // 60)
        secs = int(seconds % 60)
        millis = int((seconds % 1) * 1000)
        return f"{hours:02d}:{minutes:02d}:{secs:02d}.{millis:03d}"


@dataclass
class TranslationResponse:
    """Response from audio translation."""
    text: str
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"text": self.text}
    
    def to_text(self) -> str:
        """Return plain text."""
        return self.text


@dataclass
class AudioErrorResponse:
    """Error response for audio endpoints."""
    message: str
    type: str = "invalid_request_error"
    param: Optional[str] = None
    code: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        result = {
            "error": {
                "message": self.message,
                "type": self.type,
            }
        }
        if self.param:
            result["error"]["param"] = self.param
        if self.code:
            result["error"]["code"] = self.code
        return result


# ========================================
# Audio File Utilities
# ========================================

SUPPORTED_AUDIO_FORMATS = {
    "flac", "m4a", "mp3", "mp4", "mpeg", "mpga", "oga", "ogg", "wav", "webm"
}


def get_audio_content_type(filename: str) -> str:
    """Get content type for audio file."""
    ext = Path(filename).suffix.lower().lstrip(".")
    content_types = {
        "flac": "audio/flac",
        "m4a": "audio/mp4",
        "mp3": "audio/mpeg",
        "mp4": "audio/mp4",
        "mpeg": "audio/mpeg",
        "mpga": "audio/mpeg",
        "oga": "audio/ogg",
        "ogg": "audio/ogg",
        "wav": "audio/wav",
        "webm": "audio/webm",
    }
    return content_types.get(ext, "application/octet-stream")


def validate_audio_file(filename: str, file_size: int) -> Optional[str]:
    """
    Validate audio file.
    
    Returns error message if invalid, None if valid.
    """
    ext = Path(filename).suffix.lower().lstrip(".")
    
    if ext not in SUPPORTED_AUDIO_FORMATS:
        return f"Unsupported audio format: {ext}. Supported: {', '.join(SUPPORTED_AUDIO_FORMATS)}"
    
    # Max file size is 25 MB
    max_size = 25 * 1024 * 1024
    if file_size > max_size:
        return f"File too large: {file_size} bytes. Maximum: {max_size} bytes (25 MB)"
    
    return None


def estimate_audio_duration(file_size: int, format: str = "mp3") -> float:
    """
    Estimate audio duration from file size.
    
    Uses approximate bitrates for estimation.
    """
    # Approximate bitrates (bytes per second)
    bitrates = {
        "mp3": 16000,  # 128 kbps
        "wav": 176400,  # 44.1kHz 16-bit stereo
        "flac": 88200,  # ~50% of WAV
        "ogg": 12500,  # 100 kbps
        "m4a": 16000,  # 128 kbps
    }
    
    bps = bitrates.get(format, 16000)
    return file_size / bps


# ========================================
# Audio Handler
# ========================================

class AudioHandler:
    """
    Handler for audio transcription and translation.
    
    Provides OpenAI-compatible audio processing endpoints.
    Routes requests through SAP AI Core or compatible backend.
    """
    
    def __init__(self, http_client: Optional[Any] = None):
        """
        Initialize handler.
        
        Args:
            http_client: HTTP client for backend calls
        """
        self._http_client = http_client
        self._mock_mode = http_client is None
    
    @property
    def is_mock_mode(self) -> bool:
        """Check if running in mock mode."""
        return self._mock_mode
    
    def transcribe(
        self,
        request: TranscriptionRequest,
    ) -> Union[Dict[str, Any], str]:
        """
        Transcribe audio to text.
        
        Args:
            request: Transcription request
        
        Returns:
            Transcription response (format depends on response_format)
        """
        # Validate request
        error = request.validate()
        if error:
            return AudioErrorResponse(message=error, param="request").to_dict()
        
        if self._mock_mode:
            return self._mock_transcription(request)
        
        # TODO: Forward to backend (SAP AI Core)
        return self._mock_transcription(request)
    
    def translate(
        self,
        request: TranslationRequest,
    ) -> Union[Dict[str, Any], str]:
        """
        Translate audio to English text.
        
        Args:
            request: Translation request
        
        Returns:
            Translation response (format depends on response_format)
        """
        # Validate request
        error = request.validate()
        if error:
            return AudioErrorResponse(message=error, param="request").to_dict()
        
        if self._mock_mode:
            return self._mock_translation(request)
        
        # TODO: Forward to backend
        return self._mock_translation(request)
    
    def _mock_transcription(
        self,
        request: TranscriptionRequest,
    ) -> Union[Dict[str, Any], str]:
        """Generate mock transcription for testing."""
        # Generate deterministic text based on file hash
        file_data = self._get_file_bytes(request.file)
        file_hash = hashlib.md5(file_data).hexdigest()[:8]
        
        # Mock transcription based on language
        language = request.language or "en"
        mock_texts = {
            "en": "Hello, this is a test transcription. The audio file has been successfully processed.",
            "es": "Hola, esta es una transcripción de prueba. El archivo de audio ha sido procesado exitosamente.",
            "fr": "Bonjour, ceci est une transcription de test. Le fichier audio a été traité avec succès.",
            "de": "Hallo, dies ist eine Testtranskription. Die Audiodatei wurde erfolgreich verarbeitet.",
            "zh": "你好，这是测试转录。音频文件已成功处理。",
            "ja": "こんにちは、これはテストの文字起こしです。音声ファイルは正常に処理されました。",
        }
        
        text = mock_texts.get(language, mock_texts["en"])
        
        # Estimate duration
        duration = estimate_audio_duration(len(file_data))
        
        # Create response based on format
        response = TranscriptionResponse.create(
            text=text,
            language=language,
            duration=duration,
            include_verbose=(request.response_format == AudioResponseFormat.VERBOSE_JSON),
        )
        
        # Add segments and words for verbose format
        if request.response_format == AudioResponseFormat.VERBOSE_JSON:
            response.segments = self._generate_mock_segments(text, duration)
            
            if request.timestamp_granularities and TimestampGranularity.WORD in request.timestamp_granularities:
                response.words = self._generate_mock_words(text, duration)
        
        # Return in requested format
        return self._format_response(response, request.response_format)
    
    def _mock_translation(
        self,
        request: TranslationRequest,
    ) -> Union[Dict[str, Any], str]:
        """Generate mock translation for testing."""
        file_data = self._get_file_bytes(request.file)
        
        # Mock translation (always English)
        text = "Hello, this is a translation to English. The original audio has been translated successfully."
        
        response = TranslationResponse(text=text)
        
        # Return in requested format
        if request.response_format == AudioResponseFormat.TEXT:
            return response.to_text()
        else:
            return response.to_dict()
    
    def _get_file_bytes(self, file: Union[bytes, BinaryIO, str]) -> bytes:
        """Get bytes from file input."""
        if isinstance(file, bytes):
            return file
        elif isinstance(file, str):
            # Path or base64
            if Path(file).exists():
                return Path(file).read_bytes()
            else:
                try:
                    return base64.b64decode(file)
                except Exception:
                    return file.encode()
        elif hasattr(file, "read"):
            return file.read()
        return b""
    
    def _generate_mock_segments(
        self,
        text: str,
        duration: float,
    ) -> List[TranscriptionSegment]:
        """Generate mock segments for verbose response."""
        # Split into sentences
        sentences = [s.strip() for s in text.split(".") if s.strip()]
        if not sentences:
            sentences = [text]
        
        segments = []
        time_per_sentence = duration / len(sentences) if sentences else duration
        
        for i, sentence in enumerate(sentences):
            start = i * time_per_sentence
            end = start + time_per_sentence
            
            segment = TranscriptionSegment(
                id=i,
                seek=int(start * 100),
                start=round(start, 3),
                end=round(end, 3),
                text=sentence + ".",
                tokens=list(range(i * 10, (i + 1) * 10)),
                temperature=0.0,
                avg_logprob=-0.25,
                compression_ratio=1.5,
                no_speech_prob=0.02,
            )
            segments.append(segment)
        
        return segments
    
    def _generate_mock_words(
        self,
        text: str,
        duration: float,
    ) -> List[TranscriptionWord]:
        """Generate mock word-level timestamps."""
        words = text.split()
        if not words:
            return []
        
        time_per_word = duration / len(words)
        
        result = []
        for i, word in enumerate(words):
            start = i * time_per_word
            end = start + time_per_word
            
            result.append(TranscriptionWord(
                word=word,
                start=round(start, 3),
                end=round(end, 3),
            ))
        
        return result
    
    def _format_response(
        self,
        response: TranscriptionResponse,
        format: AudioResponseFormat,
    ) -> Union[Dict[str, Any], str]:
        """Format response according to requested format."""
        if format == AudioResponseFormat.TEXT:
            return response.to_text()
        elif format == AudioResponseFormat.SRT:
            return response.to_srt()
        elif format == AudioResponseFormat.VTT:
            return response.to_vtt()
        elif format == AudioResponseFormat.VERBOSE_JSON:
            return response.to_dict(verbose=True)
        else:
            return response.to_dict()
    
    def handle_transcription(
        self,
        form_data: Dict[str, Any],
        file_data: bytes,
        filename: str = "audio.mp3",
    ) -> Union[Dict[str, Any], str]:
        """
        Handle transcription from HTTP form data.
        
        Args:
            form_data: Form field values
            file_data: Raw audio file bytes
            filename: Original filename
        
        Returns:
            Transcription response
        """
        # Validate file
        error = validate_audio_file(filename, len(file_data))
        if error:
            return AudioErrorResponse(message=error, param="file").to_dict()
        
        try:
            request = TranscriptionRequest.from_dict(form_data, file_data)
            return self.transcribe(request)
        except Exception as e:
            logger.error(f"Transcription error: {e}")
            return AudioErrorResponse(
                message=str(e),
                type="server_error",
            ).to_dict()
    
    def handle_translation(
        self,
        form_data: Dict[str, Any],
        file_data: bytes,
        filename: str = "audio.mp3",
    ) -> Union[Dict[str, Any], str]:
        """
        Handle translation from HTTP form data.
        
        Args:
            form_data: Form field values
            file_data: Raw audio file bytes
            filename: Original filename
        
        Returns:
            Translation response
        """
        # Validate file
        error = validate_audio_file(filename, len(file_data))
        if error:
            return AudioErrorResponse(message=error, param="file").to_dict()
        
        try:
            request = TranslationRequest.from_dict(form_data, file_data)
            return self.translate(request)
        except Exception as e:
            logger.error(f"Translation error: {e}")
            return AudioErrorResponse(
                message=str(e),
                type="server_error",
            ).to_dict()


# ========================================
# Utility Functions
# ========================================

def get_audio_handler(http_client: Optional[Any] = None) -> AudioHandler:
    """Get an AudioHandler instance."""
    return AudioHandler(http_client=http_client)


def transcribe_audio(
    file: Union[bytes, str, BinaryIO],
    model: str = "whisper-1",
    language: str = None,
    **kwargs,
) -> Dict[str, Any]:
    """
    Convenience function for transcribing audio.
    
    Args:
        file: Audio file (bytes, path, or file object)
        model: Model ID
        language: Source language code
        **kwargs: Additional parameters
    
    Returns:
        Transcription response
    """
    handler = get_audio_handler()
    request = TranscriptionRequest(
        file=file,
        model=model,
        language=language,
        **kwargs,
    )
    result = handler.transcribe(request)
    if isinstance(result, str):
        return {"text": result}
    return result


def translate_audio(
    file: Union[bytes, str, BinaryIO],
    model: str = "whisper-1",
    **kwargs,
) -> Dict[str, Any]:
    """
    Convenience function for translating audio to English.
    
    Args:
        file: Audio file (bytes, path, or file object)
        model: Model ID
        **kwargs: Additional parameters
    
    Returns:
        Translation response
    """
    handler = get_audio_handler()
    request = TranslationRequest(
        file=file,
        model=model,
        **kwargs,
    )
    result = handler.translate(request)
    if isinstance(result, str):
        return {"text": result}
    return result


# ========================================
# Exports
# ========================================

__all__ = [
    # Enums
    "AudioResponseFormat",
    "TimestampGranularity",
    # Request/Response
    "TranscriptionRequest",
    "TranscriptionResponse",
    "TranscriptionWord",
    "TranscriptionSegment",
    "TranslationRequest",
    "TranslationResponse",
    "AudioErrorResponse",
    # Handler
    "AudioHandler",
    # Utilities
    "get_audio_handler",
    "transcribe_audio",
    "translate_audio",
    "validate_audio_file",
    "get_audio_content_type",
    "estimate_audio_duration",
    "SUPPORTED_AUDIO_FORMATS",
]