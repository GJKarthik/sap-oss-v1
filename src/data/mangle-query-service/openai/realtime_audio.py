"""
OpenAI Realtime API Audio Buffer

Day 38: Audio buffer management, VAD, and format conversion
"""

from dataclasses import dataclass, field
from enum import Enum
from typing import Optional, Callable
import base64
import time
import uuid


# ========================================
# Constants
# ========================================

MAX_AUDIO_BUFFER_SIZE = 15 * 1024 * 1024  # 15MB
SAMPLE_RATE_PCM16 = 24000  # 24kHz
SAMPLE_RATE_G711 = 8000  # 8kHz
BYTES_PER_SAMPLE_PCM16 = 2
CHUNK_DURATION_MS = 100
VAD_DEFAULT_THRESHOLD = 0.5
VAD_DEFAULT_PREFIX_PADDING_MS = 300
VAD_DEFAULT_SILENCE_DURATION_MS = 500


# ========================================
# Enums
# ========================================

class AudioBufferState(Enum):
    """Audio buffer states."""
    EMPTY = "empty"
    BUFFERING = "buffering"
    COMMITTED = "committed"
    SPEECH_STARTED = "speech_started"
    SPEECH_STOPPED = "speech_stopped"


class AudioFormat(Enum):
    """Audio format types."""
    PCM16 = "pcm16"
    G711_ULAW = "g711_ulaw"
    G711_ALAW = "g711_alaw"


class SpeechState(Enum):
    """Speech detection states."""
    SILENT = "silent"
    SPEAKING = "speaking"
    PAUSED = "paused"


# ========================================
# Models
# ========================================

@dataclass
class AudioChunk:
    """Audio data chunk."""
    data: bytes
    format: str = "pcm16"
    timestamp: float = field(default_factory=time.time)
    chunk_id: str = field(default_factory=lambda: f"chunk_{uuid.uuid4().hex[:12]}")
    duration_ms: float = 0.0
    
    def to_base64(self) -> str:
        return base64.b64encode(self.data).decode()
    
    @classmethod
    def from_base64(cls, data: str, fmt: str = "pcm16") -> "AudioChunk":
        return cls(data=base64.b64decode(data), format=fmt)
    
    def get_duration_ms(self) -> float:
        if self.format == "pcm16":
            samples = len(self.data) // BYTES_PER_SAMPLE_PCM16
            return (samples / SAMPLE_RATE_PCM16) * 1000
        elif self.format in ("g711_ulaw", "g711_alaw"):
            return (len(self.data) / SAMPLE_RATE_G711) * 1000
        return 0.0


@dataclass
class VADConfig:
    """Voice Activity Detection configuration."""
    threshold: float = VAD_DEFAULT_THRESHOLD
    prefix_padding_ms: int = VAD_DEFAULT_PREFIX_PADDING_MS
    silence_duration_ms: int = VAD_DEFAULT_SILENCE_DURATION_MS
    create_response: bool = True
    
    def to_dict(self) -> dict:
        return {
            "type": "server_vad",
            "threshold": self.threshold,
            "prefix_padding_ms": self.prefix_padding_ms,
            "silence_duration_ms": self.silence_duration_ms,
            "create_response": self.create_response,
        }


@dataclass
class VADResult:
    """VAD analysis result."""
    is_speech: bool
    confidence: float
    duration_ms: float = 0.0
    silence_duration_ms: float = 0.0
    
    def to_dict(self) -> dict:
        return {
            "is_speech": self.is_speech,
            "confidence": self.confidence,
            "duration_ms": self.duration_ms,
            "silence_duration_ms": self.silence_duration_ms,
        }


@dataclass
class AudioBufferStats:
    """Audio buffer statistics."""
    total_bytes: int = 0
    total_duration_ms: float = 0.0
    chunk_count: int = 0
    speech_duration_ms: float = 0.0
    silence_duration_ms: float = 0.0
    
    def to_dict(self) -> dict:
        return {
            "total_bytes": self.total_bytes,
            "total_duration_ms": self.total_duration_ms,
            "chunk_count": self.chunk_count,
            "speech_duration_ms": self.speech_duration_ms,
            "silence_duration_ms": self.silence_duration_ms,
        }


# ========================================
# Audio Buffer
# ========================================

class AudioBuffer:
    """Manage audio data buffering."""
    
    def __init__(self, session_id: str, format: str = "pcm16"):
        self.session_id = session_id
        self.format = format
        self._chunks: list[AudioChunk] = []
        self._state = AudioBufferState.EMPTY
        self._committed_data: Optional[bytes] = None
        self._speech_start_time: Optional[float] = None
        self._stats = AudioBufferStats()
    
    def append(self, data: bytes) -> bool:
        """Append audio data to buffer."""
        if self._state == AudioBufferState.COMMITTED:
            return False
        
        current_size = sum(len(c.data) for c in self._chunks)
        if current_size + len(data) > MAX_AUDIO_BUFFER_SIZE:
            return False
        
        chunk = AudioChunk(data=data, format=self.format)
        chunk.duration_ms = chunk.get_duration_ms()
        self._chunks.append(chunk)
        
        self._stats.total_bytes += len(data)
        self._stats.total_duration_ms += chunk.duration_ms
        self._stats.chunk_count += 1
        
        if self._state == AudioBufferState.EMPTY:
            self._state = AudioBufferState.BUFFERING
        
        return True
    
    def append_base64(self, data: str) -> bool:
        """Append base64-encoded audio data."""
        try:
            decoded = base64.b64decode(data)
            return self.append(decoded)
        except Exception:
            return False
    
    def commit(self) -> bytes:
        """Commit the buffer and return combined audio."""
        if not self._chunks:
            return b""
        
        self._committed_data = b"".join(c.data for c in self._chunks)
        self._state = AudioBufferState.COMMITTED
        return self._committed_data
    
    def clear(self) -> None:
        """Clear the buffer."""
        self._chunks.clear()
        self._committed_data = None
        self._state = AudioBufferState.EMPTY
        self._stats = AudioBufferStats()
    
    def get_state(self) -> AudioBufferState:
        return self._state
    
    def get_stats(self) -> AudioBufferStats:
        return self._stats
    
    def get_duration_ms(self) -> float:
        return self._stats.total_duration_ms
    
    def get_size_bytes(self) -> int:
        return self._stats.total_bytes
    
    def is_empty(self) -> bool:
        return len(self._chunks) == 0
    
    def get_chunks(self) -> list[AudioChunk]:
        return self._chunks.copy()


# ========================================
# Voice Activity Detection
# ========================================

class VoiceActivityDetector:
    """Simple voice activity detection."""
    
    def __init__(self, config: Optional[VADConfig] = None):
        self.config = config or VADConfig()
        self._speech_state = SpeechState.SILENT
        self._speech_start_ms: float = 0.0
        self._silence_start_ms: float = 0.0
        self._total_speech_ms: float = 0.0
        self._total_silence_ms: float = 0.0
        self._callbacks: dict[str, list[Callable]] = {
            "speech_started": [],
            "speech_stopped": [],
        }
    
    def analyze(self, chunk: AudioChunk) -> VADResult:
        """Analyze audio chunk for speech."""
        # Simplified VAD - calculate RMS energy
        energy = self._calculate_energy(chunk.data, chunk.format)
        is_speech = energy > self.config.threshold
        
        result = VADResult(
            is_speech=is_speech,
            confidence=min(energy / self.config.threshold, 1.0) if is_speech else 0.0,
            duration_ms=chunk.duration_ms,
        )
        
        self._update_state(result, chunk.duration_ms)
        return result
    
    def _calculate_energy(self, data: bytes, fmt: str) -> float:
        """Calculate normalized energy level."""
        if not data or fmt not in ("pcm16", "g711_ulaw", "g711_alaw"):
            return 0.0
        
        if fmt == "pcm16":
            # PCM16 little-endian samples
            samples = []
            for i in range(0, len(data) - 1, 2):
                sample = int.from_bytes(data[i:i+2], byteorder='little', signed=True)
                samples.append(sample)
            if not samples:
                return 0.0
            rms = (sum(s * s for s in samples) / len(samples)) ** 0.5
            return rms / 32768.0  # Normalize to 0-1
        else:
            # G.711 - simpler energy calculation
            total = sum(abs(b - 128) for b in data)
            return total / (128 * len(data)) if data else 0.0
    
    def _update_state(self, result: VADResult, duration_ms: float) -> None:
        """Update speech state based on result."""
        if result.is_speech:
            if self._speech_state == SpeechState.SILENT:
                self._speech_state = SpeechState.SPEAKING
                self._speech_start_ms = time.time() * 1000
                self._trigger_callback("speech_started")
            self._total_speech_ms += duration_ms
            result.silence_duration_ms = 0
        else:
            if self._speech_state == SpeechState.SPEAKING:
                self._silence_start_ms = time.time() * 1000
                self._speech_state = SpeechState.PAUSED
            
            if self._speech_state == SpeechState.PAUSED:
                current_silence = (time.time() * 1000) - self._silence_start_ms
                result.silence_duration_ms = current_silence
                
                if current_silence >= self.config.silence_duration_ms:
                    self._speech_state = SpeechState.SILENT
                    self._trigger_callback("speech_stopped")
            
            self._total_silence_ms += duration_ms
    
    def _trigger_callback(self, event: str) -> None:
        """Trigger registered callbacks."""
        for callback in self._callbacks.get(event, []):
            try:
                callback()
            except Exception:
                pass
    
    def on_speech_started(self, callback: Callable) -> None:
        """Register speech started callback."""
        self._callbacks["speech_started"].append(callback)
    
    def on_speech_stopped(self, callback: Callable) -> None:
        """Register speech stopped callback."""
        self._callbacks["speech_stopped"].append(callback)
    
    def get_state(self) -> SpeechState:
        return self._speech_state
    
    def reset(self) -> None:
        """Reset VAD state."""
        self._speech_state = SpeechState.SILENT
        self._speech_start_ms = 0.0
        self._silence_start_ms = 0.0
        self._total_speech_ms = 0.0
        self._total_silence_ms = 0.0


# ========================================
# Format Conversion
# ========================================

def pcm16_to_base64(data: bytes) -> str:
    """Convert PCM16 bytes to base64."""
    return base64.b64encode(data).decode()


def base64_to_pcm16(data: str) -> bytes:
    """Convert base64 to PCM16 bytes."""
    return base64.b64decode(data)


def g711_ulaw_encode(sample: int) -> int:
    """Encode sample using μ-law."""
    BIAS = 132
    MAX = 32635
    
    sign = (sample >> 8) & 0x80
    if sign:
        sample = -sample
    sample = min(sample + BIAS, MAX)
    
    # Find segment and quantization
    exponent = 7
    for i in range(7):
        if sample < (1 << (i + 8)):
            exponent = i
            break
    
    mantissa = (sample >> (exponent + 3)) & 0x0F
    return ~(sign | (exponent << 4) | mantissa) & 0xFF


def g711_ulaw_decode(ulaw: int) -> int:
    """Decode μ-law to sample."""
    ulaw = ~ulaw
    sign = ulaw & 0x80
    exponent = (ulaw >> 4) & 0x07
    mantissa = ulaw & 0x0F
    
    sample = ((mantissa << 3) + 132) << exponent
    sample -= 132
    
    return -sample if sign else sample


def convert_format(data: bytes, from_fmt: str, to_fmt: str) -> bytes:
    """Convert between audio formats."""
    if from_fmt == to_fmt:
        return data
    
    if from_fmt == "pcm16" and to_fmt == "g711_ulaw":
        result = bytearray()
        for i in range(0, len(data) - 1, 2):
            sample = int.from_bytes(data[i:i+2], byteorder='little', signed=True)
            result.append(g711_ulaw_encode(sample))
        return bytes(result)
    
    if from_fmt == "g711_ulaw" and to_fmt == "pcm16":
        result = bytearray()
        for byte in data:
            sample = g711_ulaw_decode(byte)
            result.extend(sample.to_bytes(2, byteorder='little', signed=True))
        return bytes(result)
    
    # Other conversions not implemented
    return data


def calculate_duration_ms(data: bytes, fmt: str) -> float:
    """Calculate audio duration in milliseconds."""
    if fmt == "pcm16":
        samples = len(data) // BYTES_PER_SAMPLE_PCM16
        return (samples / SAMPLE_RATE_PCM16) * 1000
    elif fmt in ("g711_ulaw", "g711_alaw"):
        return (len(data) / SAMPLE_RATE_G711) * 1000
    return 0.0


def validate_audio_size(data: bytes) -> bool:
    """Validate audio data size."""
    return len(data) <= MAX_AUDIO_BUFFER_SIZE


# ========================================
# Factory
# ========================================

_audio_buffers: dict[str, AudioBuffer] = {}


def get_audio_buffer(session_id: str, format: str = "pcm16") -> AudioBuffer:
    """Get or create audio buffer for session."""
    if session_id not in _audio_buffers:
        _audio_buffers[session_id] = AudioBuffer(session_id, format)
    return _audio_buffers[session_id]


def remove_audio_buffer(session_id: str) -> bool:
    """Remove audio buffer for session."""
    if session_id in _audio_buffers:
        del _audio_buffers[session_id]
        return True
    return False


def reset_audio_buffers() -> None:
    """Clear all audio buffers."""
    global _audio_buffers
    _audio_buffers = {}