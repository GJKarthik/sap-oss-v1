"""
OpenAI-compatible Response Output Items

Day 32 Deliverable: Output items and response content handling

Implements output item types:
- Message output (text, audio)
- Function call output
- Web search results
- File search results
- Computer use results
- Reasoning output
"""

import time
import hashlib
from enum import Enum
from typing import Dict, Any, Optional, List, Union
from dataclasses import dataclass, field


# ========================================
# Constants
# ========================================

MAX_OUTPUT_ITEMS = 128
DEFAULT_MAX_TOKENS = 4096
MAX_AUDIO_SECONDS = 600


# ========================================
# Enums
# ========================================

class OutputItemType(str, Enum):
    """Output item types."""
    MESSAGE = "message"
    FUNCTION_CALL = "function_call"
    WEB_SEARCH_CALL = "web_search_call"
    FILE_SEARCH_CALL = "file_search_call"
    COMPUTER_CALL = "computer_call"
    REASONING = "reasoning"


class OutputContentType(str, Enum):
    """Output content types."""
    TEXT = "output_text"
    AUDIO = "output_audio"
    REFUSAL = "refusal"


class FunctionCallStatus(str, Enum):
    """Function call statuses."""
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"
    FAILED = "failed"


class WebSearchStatus(str, Enum):
    """Web search statuses."""
    SEARCHING = "searching"
    COMPLETED = "completed"
    FAILED = "failed"


class ReasoningStatus(str, Enum):
    """Reasoning statuses."""
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"


# ========================================
# Output Content Models
# ========================================

@dataclass
class OutputTextContent:
    """Text output content."""
    type: str = "output_text"
    text: str = ""
    annotations: List[Dict[str, Any]] = field(default_factory=list)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "text": self.text,
            "annotations": self.annotations,
        }


@dataclass
class OutputAudioContent:
    """Audio output content."""
    type: str = "output_audio"
    id: str = ""
    data: str = ""  # base64
    transcript: str = ""
    expires_at: int = 0
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "id": self.id,
            "data": self.data,
            "transcript": self.transcript,
            "expires_at": self.expires_at,
        }


@dataclass
class RefusalContent:
    """Refusal content when model declines."""
    type: str = "refusal"
    refusal: str = ""
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"type": self.type, "refusal": self.refusal}


# ========================================
# Output Item Models
# ========================================

@dataclass
class MessageOutputItem:
    """Message output item."""
    type: str = "message"
    id: str = ""
    role: str = "assistant"
    content: List[Dict[str, Any]] = field(default_factory=list)
    status: str = "completed"
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "id": self.id,
            "role": self.role,
            "content": self.content,
            "status": self.status,
        }


@dataclass
class FunctionCallItem:
    """Function call output item."""
    type: str = "function_call"
    id: str = ""
    call_id: str = ""
    name: str = ""
    arguments: str = ""
    status: str = FunctionCallStatus.COMPLETED.value
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "id": self.id,
            "call_id": self.call_id,
            "name": self.name,
            "arguments": self.arguments,
            "status": self.status,
        }


@dataclass
class WebSearchResult:
    """Individual web search result."""
    title: str = ""
    url: str = ""
    snippet: str = ""
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"title": self.title, "url": self.url, "snippet": self.snippet}


@dataclass
class WebSearchCallItem:
    """Web search call output item."""
    type: str = "web_search_call"
    id: str = ""
    status: str = WebSearchStatus.COMPLETED.value
    results: List[WebSearchResult] = field(default_factory=list)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "id": self.id,
            "status": self.status,
            "results": [r.to_dict() for r in self.results],
        }


@dataclass
class FileSearchResult:
    """File search result item."""
    file_id: str = ""
    filename: str = ""
    score: float = 0.0
    text: str = ""
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "file_id": self.file_id,
            "filename": self.filename,
            "score": self.score,
            "text": self.text,
        }


@dataclass
class FileSearchCallItem:
    """File search call output item."""
    type: str = "file_search_call"
    id: str = ""
    status: str = "completed"
    results: List[FileSearchResult] = field(default_factory=list)
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "id": self.id,
            "status": self.status,
            "results": [r.to_dict() for r in self.results],
        }


@dataclass
class ComputerCallItem:
    """Computer use call output item."""
    type: str = "computer_call"
    id: str = ""
    call_id: str = ""
    action: Dict[str, Any] = field(default_factory=dict)
    pending_safety_checks: List[Dict[str, Any]] = field(default_factory=list)
    status: str = "completed"
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "id": self.id,
            "call_id": self.call_id,
            "action": self.action,
            "pending_safety_checks": self.pending_safety_checks,
            "status": self.status,
        }


@dataclass
class ReasoningItem:
    """Reasoning output item (chain of thought)."""
    type: str = "reasoning"
    id: str = ""
    summary: List[Dict[str, str]] = field(default_factory=list)
    status: str = ReasoningStatus.COMPLETED.value
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "id": self.id,
            "summary": self.summary,
            "status": self.status,
        }


# ========================================
# Annotation Models
# ========================================

@dataclass
class FileCitationAnnotation:
    """File citation annotation."""
    type: str = "file_citation"
    file_id: str = ""
    index: int = 0
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"type": self.type, "file_id": self.file_id, "index": self.index}


@dataclass
class UrlCitationAnnotation:
    """URL citation annotation."""
    type: str = "url_citation"
    url: str = ""
    title: str = ""
    start_index: int = 0
    end_index: int = 0
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "type": self.type,
            "url": self.url,
            "title": self.title,
            "start_index": self.start_index,
            "end_index": self.end_index,
        }


@dataclass
class FilePathAnnotation:
    """File path annotation."""
    type: str = "file_path"
    file_id: str = ""
    file_path: str = ""
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {"type": self.type, "file_id": self.file_id, "file_path": self.file_path}


# ========================================
# Output Handler
# ========================================

class OutputHandler:
    """Handler for response output items."""
    
    def __init__(self):
        """Initialize handler."""
        self._outputs: Dict[str, List[Dict[str, Any]]] = {}
    
    def _generate_id(self, prefix: str = "out") -> str:
        """Generate output ID."""
        return f"{prefix}_{hashlib.md5(f'{time.time()}'.encode()).hexdigest()[:24]}"
    
    def create_message_output(
        self,
        text: str,
        annotations: Optional[List[Dict[str, Any]]] = None
    ) -> Dict[str, Any]:
        """Create a message output item."""
        content = OutputTextContent(text=text, annotations=annotations or [])
        return MessageOutputItem(
            id=self._generate_id("msg"),
            content=[content.to_dict()],
        ).to_dict()
    
    def create_audio_output(
        self,
        data: str,
        transcript: str
    ) -> Dict[str, Any]:
        """Create an audio output item."""
        audio_content = OutputAudioContent(
            id=self._generate_id("audio"),
            data=data,
            transcript=transcript,
            expires_at=int(time.time()) + 3600,
        )
        return MessageOutputItem(
            id=self._generate_id("msg"),
            content=[audio_content.to_dict()],
        ).to_dict()
    
    def create_refusal_output(self, refusal: str) -> Dict[str, Any]:
        """Create a refusal output item."""
        content = RefusalContent(refusal=refusal)
        return MessageOutputItem(
            id=self._generate_id("msg"),
            content=[content.to_dict()],
        ).to_dict()
    
    def create_function_call(
        self,
        name: str,
        arguments: str
    ) -> Dict[str, Any]:
        """Create a function call output item."""
        return FunctionCallItem(
            id=self._generate_id("fc"),
            call_id=self._generate_id("call"),
            name=name,
            arguments=arguments,
        ).to_dict()
    
    def create_web_search(
        self,
        results: List[Dict[str, str]]
    ) -> Dict[str, Any]:
        """Create a web search output item."""
        search_results = [
            WebSearchResult(
                title=r.get("title", ""),
                url=r.get("url", ""),
                snippet=r.get("snippet", ""),
            )
            for r in results
        ]
        return WebSearchCallItem(
            id=self._generate_id("ws"),
            results=search_results,
        ).to_dict()
    
    def create_file_search(
        self,
        results: List[Dict[str, Any]]
    ) -> Dict[str, Any]:
        """Create a file search output item."""
        file_results = [
            FileSearchResult(
                file_id=r.get("file_id", ""),
                filename=r.get("filename", ""),
                score=r.get("score", 0.0),
                text=r.get("text", ""),
            )
            for r in results
        ]
        return FileSearchCallItem(
            id=self._generate_id("fs"),
            results=file_results,
        ).to_dict()
    
    def create_computer_call(
        self,
        action: Dict[str, Any]
    ) -> Dict[str, Any]:
        """Create a computer call output item."""
        return ComputerCallItem(
            id=self._generate_id("cc"),
            call_id=self._generate_id("call"),
            action=action,
        ).to_dict()
    
    def create_reasoning(
        self,
        summary: List[str]
    ) -> Dict[str, Any]:
        """Create a reasoning output item."""
        summary_items = [{"type": "summary_text", "text": s} for s in summary]
        return ReasoningItem(
            id=self._generate_id("reason"),
            summary=summary_items,
        ).to_dict()
    
    def add_annotation(
        self,
        content: Dict[str, Any],
        annotation_type: str,
        **kwargs
    ) -> Dict[str, Any]:
        """Add annotation to content."""
        if annotation_type == "file_citation":
            annotation = FileCitationAnnotation(**kwargs).to_dict()
        elif annotation_type == "url_citation":
            annotation = UrlCitationAnnotation(**kwargs).to_dict()
        elif annotation_type == "file_path":
            annotation = FilePathAnnotation(**kwargs).to_dict()
        else:
            annotation = {"type": annotation_type, **kwargs}
        
        if "annotations" not in content:
            content["annotations"] = []
        content["annotations"].append(annotation)
        return content


# ========================================
# Factory and Utilities
# ========================================

def get_output_handler() -> OutputHandler:
    """Factory function for output handler."""
    return OutputHandler()


def extract_text_from_output(output: Dict[str, Any]) -> str:
    """Extract text content from output item."""
    content = output.get("content", [])
    texts = []
    for c in content:
        if c.get("type") == "output_text":
            texts.append(c.get("text", ""))
    return " ".join(texts)


def is_function_call(output: Dict[str, Any]) -> bool:
    """Check if output is a function call."""
    return output.get("type") == OutputItemType.FUNCTION_CALL.value


def is_tool_call(output: Dict[str, Any]) -> bool:
    """Check if output is any tool call."""
    return output.get("type") in [
        OutputItemType.FUNCTION_CALL.value,
        OutputItemType.WEB_SEARCH_CALL.value,
        OutputItemType.FILE_SEARCH_CALL.value,
        OutputItemType.COMPUTER_CALL.value,
    ]


def get_function_name(output: Dict[str, Any]) -> Optional[str]:
    """Get function name from function call output."""
    if is_function_call(output):
        return output.get("name")
    return None


def count_output_items(outputs: List[Dict[str, Any]]) -> Dict[str, int]:
    """Count output items by type."""
    counts: Dict[str, int] = {}
    for output in outputs:
        item_type = output.get("type", "unknown")
        counts[item_type] = counts.get(item_type, 0) + 1
    return counts


def has_refusal(outputs: List[Dict[str, Any]]) -> bool:
    """Check if any output contains a refusal."""
    for output in outputs:
        for content in output.get("content", []):
            if content.get("type") == "refusal":
                return True
    return False


# ========================================
# Exports
# ========================================

__all__ = [
    # Constants
    "MAX_OUTPUT_ITEMS",
    "DEFAULT_MAX_TOKENS",
    "MAX_AUDIO_SECONDS",
    # Enums
    "OutputItemType",
    "OutputContentType",
    "FunctionCallStatus",
    "WebSearchStatus",
    "ReasoningStatus",
    # Content Models
    "OutputTextContent",
    "OutputAudioContent",
    "RefusalContent",
    # Output Item Models
    "MessageOutputItem",
    "FunctionCallItem",
    "WebSearchResult",
    "WebSearchCallItem",
    "FileSearchResult",
    "FileSearchCallItem",
    "ComputerCallItem",
    "ReasoningItem",
    # Annotation Models
    "FileCitationAnnotation",
    "UrlCitationAnnotation",
    "FilePathAnnotation",
    # Handler
    "OutputHandler",
    # Utilities
    "get_output_handler",
    "extract_text_from_output",
    "is_function_call",
    "is_tool_call",
    "get_function_name",
    "count_output_items",
    "has_refusal",
]