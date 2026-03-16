"""
Structured Logging Module - Observability Without External Dependencies.

Day 52 Implementation - Week 11 Observability & Monitoring
Provides structured JSON logging with context propagation.
No external service dependencies - pure Python implementation.
"""

import logging
import json
import sys
import time
import threading
import traceback
from typing import Optional, Dict, Any, List, Union, TextIO
from dataclasses import dataclass, field
from enum import Enum, IntEnum
from contextlib import contextmanager
from functools import wraps
import uuid


# =============================================================================
# Log Levels
# =============================================================================

class LogLevel(IntEnum):
    """Log levels matching Python's logging module."""
    DEBUG = logging.DEBUG      # 10
    INFO = logging.INFO        # 20
    WARNING = logging.WARNING  # 30
    ERROR = logging.ERROR      # 40
    CRITICAL = logging.CRITICAL  # 50
    
    @classmethod
    def from_string(cls, level: str) -> "LogLevel":
        """Parse level from string."""
        mapping = {
            "debug": cls.DEBUG,
            "info": cls.INFO,
            "warning": cls.WARNING,
            "warn": cls.WARNING,
            "error": cls.ERROR,
            "critical": cls.CRITICAL,
            "fatal": cls.CRITICAL,
        }
        return mapping.get(level.lower(), cls.INFO)


# =============================================================================
# Log Record
# =============================================================================

@dataclass
class LogRecord:
    """Represents a structured log record."""
    timestamp: float
    level: LogLevel
    message: str
    logger_name: str
    context: Dict[str, Any] = field(default_factory=dict)
    exception: Optional[str] = None
    stack_trace: Optional[str] = None
    
    # Standard fields
    request_id: Optional[str] = None
    trace_id: Optional[str] = None
    span_id: Optional[str] = None
    user_id: Optional[str] = None
    service: Optional[str] = None
    environment: Optional[str] = None
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        result = {
            "timestamp": self.timestamp,
            "time": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(self.timestamp)),
            "level": self.level.name,
            "message": self.message,
            "logger": self.logger_name,
        }
        
        # Add context fields
        if self.context:
            result["context"] = self.context
        
        # Add exception info
        if self.exception:
            result["exception"] = self.exception
        if self.stack_trace:
            result["stack_trace"] = self.stack_trace
        
        # Add standard fields if present
        if self.request_id:
            result["request_id"] = self.request_id
        if self.trace_id:
            result["trace_id"] = self.trace_id
        if self.span_id:
            result["span_id"] = self.span_id
        if self.user_id:
            result["user_id"] = self.user_id
        if self.service:
            result["service"] = self.service
        if self.environment:
            result["environment"] = self.environment
        
        return result


# =============================================================================
# Log Context
# =============================================================================

class LogContext:
    """Thread-local log context for propagating fields across log calls."""
    
    _local = threading.local()
    
    @classmethod
    def get(cls) -> Dict[str, Any]:
        """Get current context."""
        if not hasattr(cls._local, "context"):
            cls._local.context = {}
        return cls._local.context
    
    @classmethod
    def set(cls, key: str, value: Any) -> None:
        """Set a context value."""
        ctx = cls.get()
        ctx[key] = value
    
    @classmethod
    def remove(cls, key: str) -> None:
        """Remove a context value."""
        ctx = cls.get()
        ctx.pop(key, None)
    
    @classmethod
    def clear(cls) -> None:
        """Clear all context."""
        cls._local.context = {}
    
    @classmethod
    @contextmanager
    def scope(cls, **kwargs):
        """Context manager for temporary context scope."""
        ctx = cls.get()
        old_values = {}
        
        # Save old values and set new ones
        for key, value in kwargs.items():
            if key in ctx:
                old_values[key] = ctx[key]
            ctx[key] = value
        
        try:
            yield
        finally:
            # Restore old values
            for key in kwargs:
                if key in old_values:
                    ctx[key] = old_values[key]
                else:
                    ctx.pop(key, None)


# =============================================================================
# Formatters
# =============================================================================

class LogFormatter:
    """Base class for log formatters."""
    
    def format(self, record: LogRecord) -> str:
        """Format a log record."""
        raise NotImplementedError


class JSONFormatter(LogFormatter):
    """JSON log formatter."""
    
    def __init__(self, pretty: bool = False):
        self.pretty = pretty
    
    def format(self, record: LogRecord) -> str:
        """Format as JSON."""
        data = record.to_dict()
        if self.pretty:
            return json.dumps(data, indent=2, default=str)
        return json.dumps(data, default=str)


class TextFormatter(LogFormatter):
    """Human-readable text formatter."""
    
    def __init__(
        self,
        include_timestamp: bool = True,
        include_level: bool = True,
        include_logger: bool = True,
        include_context: bool = True,
    ):
        self.include_timestamp = include_timestamp
        self.include_level = include_level
        self.include_logger = include_logger
        self.include_context = include_context
    
    def format(self, record: LogRecord) -> str:
        """Format as human-readable text."""
        parts = []
        
        if self.include_timestamp:
            ts = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(record.timestamp))
            parts.append(ts)
        
        if self.include_level:
            parts.append(f"[{record.level.name:8}]")
        
        if self.include_logger:
            parts.append(f"[{record.logger_name}]")
        
        parts.append(record.message)
        
        if self.include_context and record.context:
            ctx_str = " ".join(f"{k}={v}" for k, v in record.context.items())
            parts.append(f"| {ctx_str}")
        
        result = " ".join(parts)
        
        if record.exception:
            result += f"\nException: {record.exception}"
        if record.stack_trace:
            result += f"\n{record.stack_trace}"
        
        return result


class ColoredFormatter(TextFormatter):
    """Colored text formatter for terminal output."""
    
    COLORS = {
        LogLevel.DEBUG: "\033[36m",     # Cyan
        LogLevel.INFO: "\033[32m",      # Green
        LogLevel.WARNING: "\033[33m",   # Yellow
        LogLevel.ERROR: "\033[31m",     # Red
        LogLevel.CRITICAL: "\033[35m",  # Magenta
    }
    RESET = "\033[0m"
    
    def format(self, record: LogRecord) -> str:
        """Format with colors."""
        text = super().format(record)
        color = self.COLORS.get(record.level, "")
        return f"{color}{text}{self.RESET}"


# =============================================================================
# Handlers
# =============================================================================

class LogHandler:
    """Base class for log handlers."""
    
    def __init__(
        self,
        formatter: Optional[LogFormatter] = None,
        level: LogLevel = LogLevel.DEBUG,
    ):
        self.formatter = formatter or TextFormatter()
        self.level = level
    
    def handle(self, record: LogRecord) -> None:
        """Handle a log record."""
        if record.level >= self.level:
            self.emit(record)
    
    def emit(self, record: LogRecord) -> None:
        """Emit the log record."""
        raise NotImplementedError


class StreamHandler(LogHandler):
    """Handler that writes to a stream."""
    
    def __init__(
        self,
        stream: TextIO = sys.stdout,
        formatter: Optional[LogFormatter] = None,
        level: LogLevel = LogLevel.DEBUG,
    ):
        super().__init__(formatter, level)
        self.stream = stream
        self._lock = threading.Lock()
    
    def emit(self, record: LogRecord) -> None:
        """Write to stream."""
        try:
            msg = self.formatter.format(record)
            with self._lock:
                self.stream.write(msg + "\n")
                self.stream.flush()
        except Exception:
            pass  # Silently ignore errors in logging


class FileHandler(LogHandler):
    """Handler that writes to a file."""
    
    def __init__(
        self,
        filename: str,
        formatter: Optional[LogFormatter] = None,
        level: LogLevel = LogLevel.DEBUG,
        mode: str = "a",
    ):
        super().__init__(formatter, level)
        self.filename = filename
        self.mode = mode
        self._lock = threading.Lock()
    
    def emit(self, record: LogRecord) -> None:
        """Write to file."""
        try:
            msg = self.formatter.format(record)
            with self._lock:
                with open(self.filename, self.mode) as f:
                    f.write(msg + "\n")
        except Exception:
            pass


class MemoryHandler(LogHandler):
    """Handler that stores logs in memory (useful for testing)."""
    
    def __init__(
        self,
        max_records: int = 1000,
        formatter: Optional[LogFormatter] = None,
        level: LogLevel = LogLevel.DEBUG,
    ):
        super().__init__(formatter, level)
        self.max_records = max_records
        self.records: List[LogRecord] = []
        self._lock = threading.Lock()
    
    def emit(self, record: LogRecord) -> None:
        """Store in memory."""
        with self._lock:
            self.records.append(record)
            if len(self.records) > self.max_records:
                self.records = self.records[-self.max_records:]
    
    def get_records(
        self,
        level: Optional[LogLevel] = None,
        logger: Optional[str] = None,
    ) -> List[LogRecord]:
        """Get stored records with optional filtering."""
        with self._lock:
            records = list(self.records)
        
        if level is not None:
            records = [r for r in records if r.level >= level]
        if logger is not None:
            records = [r for r in records if r.logger_name == logger]
        
        return records
    
    def clear(self) -> None:
        """Clear stored records."""
        with self._lock:
            self.records.clear()


# =============================================================================
# Logger
# =============================================================================

class StructuredLogger:
    """
    Structured logger with context propagation.
    
    Features:
    - JSON and text output formats
    - Context propagation across log calls
    - Exception handling with stack traces
    - Multiple handlers support
    """
    
    def __init__(
        self,
        name: str,
        level: LogLevel = LogLevel.INFO,
        handlers: Optional[List[LogHandler]] = None,
        service: Optional[str] = None,
        environment: Optional[str] = None,
    ):
        self.name = name
        self.level = level
        self.handlers = handlers or []
        self.service = service
        self.environment = environment
        self._lock = threading.Lock()
    
    def add_handler(self, handler: LogHandler) -> None:
        """Add a log handler."""
        with self._lock:
            self.handlers.append(handler)
    
    def remove_handler(self, handler: LogHandler) -> None:
        """Remove a log handler."""
        with self._lock:
            if handler in self.handlers:
                self.handlers.remove(handler)
    
    def set_level(self, level: LogLevel) -> None:
        """Set the log level."""
        self.level = level
    
    def _log(
        self,
        level: LogLevel,
        message: str,
        exc_info: Optional[BaseException] = None,
        **kwargs,
    ) -> None:
        """Internal logging method."""
        if level < self.level:
            return
        
        # Build context from thread-local and kwargs
        context = dict(LogContext.get())
        context.update(kwargs)
        
        # Extract standard fields
        request_id = context.pop("request_id", None)
        trace_id = context.pop("trace_id", None)
        span_id = context.pop("span_id", None)
        user_id = context.pop("user_id", None)
        
        # Build log record
        record = LogRecord(
            timestamp=time.time(),
            level=level,
            message=message,
            logger_name=self.name,
            context=context if context else {},
            request_id=request_id,
            trace_id=trace_id,
            span_id=span_id,
            user_id=user_id,
            service=self.service,
            environment=self.environment,
        )
        
        # Add exception info
        if exc_info:
            record.exception = str(exc_info)
            record.stack_trace = traceback.format_exc()
        
        # Dispatch to handlers
        with self._lock:
            handlers = list(self.handlers)
        
        for handler in handlers:
            try:
                handler.handle(record)
            except Exception:
                pass  # Silently ignore handler errors
    
    def debug(self, message: str, **kwargs) -> None:
        """Log at DEBUG level."""
        self._log(LogLevel.DEBUG, message, **kwargs)
    
    def info(self, message: str, **kwargs) -> None:
        """Log at INFO level."""
        self._log(LogLevel.INFO, message, **kwargs)
    
    def warning(self, message: str, **kwargs) -> None:
        """Log at WARNING level."""
        self._log(LogLevel.WARNING, message, **kwargs)
    
    def error(self, message: str, exc_info: Optional[BaseException] = None, **kwargs) -> None:
        """Log at ERROR level."""
        self._log(LogLevel.ERROR, message, exc_info=exc_info, **kwargs)
    
    def critical(self, message: str, exc_info: Optional[BaseException] = None, **kwargs) -> None:
        """Log at CRITICAL level."""
        self._log(LogLevel.CRITICAL, message, exc_info=exc_info, **kwargs)
    
    def exception(self, message: str, exc: BaseException, **kwargs) -> None:
        """Log an exception at ERROR level."""
        self._log(LogLevel.ERROR, message, exc_info=exc, **kwargs)
    
    @contextmanager
    def context(self, **kwargs):
        """Context manager for adding fields to all logs in scope."""
        with LogContext.scope(**kwargs):
            yield
    
    def bind(self, **kwargs) -> "BoundLogger":
        """Create a bound logger with preset context."""
        return BoundLogger(self, kwargs)


class BoundLogger:
    """Logger with preset context fields."""
    
    def __init__(self, logger: StructuredLogger, context: Dict[str, Any]):
        self._logger = logger
        self._context = context
    
    def _merge_context(self, kwargs: Dict[str, Any]) -> Dict[str, Any]:
        """Merge bound context with call context."""
        result = dict(self._context)
        result.update(kwargs)
        return result
    
    def debug(self, message: str, **kwargs) -> None:
        self._logger.debug(message, **self._merge_context(kwargs))
    
    def info(self, message: str, **kwargs) -> None:
        self._logger.info(message, **self._merge_context(kwargs))
    
    def warning(self, message: str, **kwargs) -> None:
        self._logger.warning(message, **self._merge_context(kwargs))
    
    def error(self, message: str, **kwargs) -> None:
        self._logger.error(message, **self._merge_context(kwargs))
    
    def critical(self, message: str, **kwargs) -> None:
        self._logger.critical(message, **self._merge_context(kwargs))


# =============================================================================
# Logger Factory
# =============================================================================

class LoggerFactory:
    """Factory for creating and managing loggers."""
    
    _loggers: Dict[str, StructuredLogger] = {}
    _default_handlers: List[LogHandler] = []
    _default_level: LogLevel = LogLevel.INFO
    _service: Optional[str] = None
    _environment: Optional[str] = None
    _lock = threading.Lock()
    
    @classmethod
    def configure(
        cls,
        level: LogLevel = LogLevel.INFO,
        handlers: Optional[List[LogHandler]] = None,
        service: Optional[str] = None,
        environment: Optional[str] = None,
    ) -> None:
        """Configure default settings for all loggers."""
        with cls._lock:
            cls._default_level = level
            if handlers:
                cls._default_handlers = handlers
            cls._service = service
            cls._environment = environment
    
    @classmethod
    def get_logger(cls, name: str) -> StructuredLogger:
        """Get or create a logger."""
        with cls._lock:
            if name not in cls._loggers:
                handlers = list(cls._default_handlers)
                if not handlers:
                    # Default to console JSON output
                    handlers = [StreamHandler(
                        formatter=JSONFormatter(),
                        level=cls._default_level,
                    )]
                
                cls._loggers[name] = StructuredLogger(
                    name=name,
                    level=cls._default_level,
                    handlers=handlers,
                    service=cls._service,
                    environment=cls._environment,
                )
            return cls._loggers[name]
    
    @classmethod
    def reset(cls) -> None:
        """Reset all loggers."""
        with cls._lock:
            cls._loggers.clear()
            cls._default_handlers.clear()
            cls._default_level = LogLevel.INFO
            cls._service = None
            cls._environment = None


# =============================================================================
# Convenience Functions
# =============================================================================

def get_logger(name: str) -> StructuredLogger:
    """Get or create a logger."""
    return LoggerFactory.get_logger(name)


def configure_logging(
    level: Union[str, LogLevel] = LogLevel.INFO,
    format: str = "json",
    service: Optional[str] = None,
    environment: Optional[str] = None,
    output: TextIO = sys.stdout,
) -> None:
    """Configure logging with sensible defaults."""
    if isinstance(level, str):
        level = LogLevel.from_string(level)
    
    if format == "json":
        formatter = JSONFormatter()
    elif format == "text":
        formatter = TextFormatter()
    elif format == "colored":
        formatter = ColoredFormatter()
    else:
        formatter = JSONFormatter()
    
    handlers = [StreamHandler(stream=output, formatter=formatter, level=level)]
    
    LoggerFactory.configure(
        level=level,
        handlers=handlers,
        service=service,
        environment=environment,
    )


def log_function_call(logger: Optional[StructuredLogger] = None, level: LogLevel = LogLevel.DEBUG):
    """Decorator to log function calls."""
    def decorator(func):
        nonlocal logger
        if logger is None:
            logger = get_logger(func.__module__)
        
        @wraps(func)
        def wrapper(*args, **kwargs):
            func_name = func.__name__
            logger._log(level, f"Calling {func_name}", args_count=len(args), kwargs_keys=list(kwargs.keys()))
            
            start = time.perf_counter()
            try:
                result = func(*args, **kwargs)
                duration = time.perf_counter() - start
                logger._log(level, f"Completed {func_name}", duration_ms=round(duration * 1000, 2))
                return result
            except Exception as e:
                duration = time.perf_counter() - start
                logger.error(f"Failed {func_name}", exc_info=e, duration_ms=round(duration * 1000, 2))
                raise
        
        return wrapper
    return decorator


def request_context_middleware(request_id_header: str = "X-Request-ID"):
    """Create middleware for adding request context to logs."""
    def middleware(handler):
        @wraps(handler)
        async def wrapper(request, *args, **kwargs):
            # Extract or generate request ID
            request_id = (
                request.headers.get(request_id_header) or
                str(uuid.uuid4())
            )
            
            # Add to log context
            with LogContext.scope(request_id=request_id):
                return await handler(request, *args, **kwargs)
        
        return wrapper
    return middleware