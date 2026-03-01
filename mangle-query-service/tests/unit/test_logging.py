"""
Unit tests for structured logging module.

Day 52 - Week 11 Observability & Monitoring
45 tests covering LogLevel, LogRecord, Formatters, Handlers, and Logger.
No external service dependencies.
"""

import pytest
import json
import time
import io
import tempfile
import os
from unittest.mock import Mock, patch

from observability.logging import (
    LogLevel,
    LogRecord,
    LogContext,
    LogFormatter,
    JSONFormatter,
    TextFormatter,
    ColoredFormatter,
    LogHandler,
    StreamHandler,
    FileHandler,
    MemoryHandler,
    StructuredLogger,
    BoundLogger,
    LoggerFactory,
    get_logger,
    configure_logging,
    log_function_call,
)


# =============================================================================
# LogLevel Tests (3 tests)
# =============================================================================

class TestLogLevel:
    """Tests for LogLevel enum."""
    
    def test_level_values(self):
        """Test log level numeric values."""
        assert LogLevel.DEBUG < LogLevel.INFO
        assert LogLevel.INFO < LogLevel.WARNING
        assert LogLevel.WARNING < LogLevel.ERROR
        assert LogLevel.ERROR < LogLevel.CRITICAL
    
    def test_from_string(self):
        """Test parsing level from string."""
        assert LogLevel.from_string("debug") == LogLevel.DEBUG
        assert LogLevel.from_string("INFO") == LogLevel.INFO
        assert LogLevel.from_string("Warning") == LogLevel.WARNING
        assert LogLevel.from_string("error") == LogLevel.ERROR
    
    def test_from_string_aliases(self):
        """Test level string aliases."""
        assert LogLevel.from_string("warn") == LogLevel.WARNING
        assert LogLevel.from_string("fatal") == LogLevel.CRITICAL


# =============================================================================
# LogRecord Tests (4 tests)
# =============================================================================

class TestLogRecord:
    """Tests for LogRecord dataclass."""
    
    def test_creation(self):
        """Test record creation."""
        record = LogRecord(
            timestamp=time.time(),
            level=LogLevel.INFO,
            message="Test message",
            logger_name="test_logger",
        )
        assert record.message == "Test message"
        assert record.level == LogLevel.INFO
    
    def test_to_dict(self):
        """Test conversion to dictionary."""
        record = LogRecord(
            timestamp=1234567890.0,
            level=LogLevel.INFO,
            message="Test",
            logger_name="test",
        )
        d = record.to_dict()
        assert "timestamp" in d
        assert "level" in d
        assert "message" in d
        assert d["level"] == "INFO"
    
    def test_with_context(self):
        """Test record with context."""
        record = LogRecord(
            timestamp=time.time(),
            level=LogLevel.INFO,
            message="Test",
            logger_name="test",
            context={"key": "value", "count": 42},
        )
        d = record.to_dict()
        assert "context" in d
        assert d["context"]["key"] == "value"
    
    def test_with_exception(self):
        """Test record with exception info."""
        record = LogRecord(
            timestamp=time.time(),
            level=LogLevel.ERROR,
            message="Error occurred",
            logger_name="test",
            exception="ValueError: invalid",
            stack_trace="Traceback...",
        )
        d = record.to_dict()
        assert "exception" in d
        assert "stack_trace" in d


# =============================================================================
# LogContext Tests (5 tests)
# =============================================================================

class TestLogContext:
    """Tests for LogContext thread-local storage."""
    
    def setup_method(self):
        """Clear context before each test."""
        LogContext.clear()
    
    def test_set_and_get(self):
        """Test setting and getting context values."""
        LogContext.set("request_id", "abc123")
        ctx = LogContext.get()
        assert ctx["request_id"] == "abc123"
    
    def test_remove(self):
        """Test removing context values."""
        LogContext.set("key", "value")
        LogContext.remove("key")
        ctx = LogContext.get()
        assert "key" not in ctx
    
    def test_clear(self):
        """Test clearing all context."""
        LogContext.set("a", 1)
        LogContext.set("b", 2)
        LogContext.clear()
        ctx = LogContext.get()
        assert len(ctx) == 0
    
    def test_scope(self):
        """Test context scope manager."""
        LogContext.set("existing", "value")
        
        with LogContext.scope(temp="scoped"):
            ctx = LogContext.get()
            assert ctx["temp"] == "scoped"
            assert ctx["existing"] == "value"
        
        ctx = LogContext.get()
        assert "temp" not in ctx
        assert ctx["existing"] == "value"
    
    def test_scope_restore(self):
        """Test scope restores previous values."""
        LogContext.set("key", "original")
        
        with LogContext.scope(key="modified"):
            assert LogContext.get()["key"] == "modified"
        
        assert LogContext.get()["key"] == "original"


# =============================================================================
# Formatter Tests (6 tests)
# =============================================================================

class TestFormatters:
    """Tests for log formatters."""
    
    def test_json_formatter(self):
        """Test JSON formatter."""
        formatter = JSONFormatter()
        record = LogRecord(
            timestamp=1234567890.0,
            level=LogLevel.INFO,
            message="Test",
            logger_name="test",
        )
        output = formatter.format(record)
        data = json.loads(output)
        assert data["message"] == "Test"
        assert data["level"] == "INFO"
    
    def test_json_formatter_pretty(self):
        """Test pretty JSON formatter."""
        formatter = JSONFormatter(pretty=True)
        record = LogRecord(
            timestamp=time.time(),
            level=LogLevel.INFO,
            message="Test",
            logger_name="test",
        )
        output = formatter.format(record)
        assert "\n" in output  # Pretty print has newlines
    
    def test_text_formatter(self):
        """Test text formatter."""
        formatter = TextFormatter()
        record = LogRecord(
            timestamp=time.time(),
            level=LogLevel.INFO,
            message="Test message",
            logger_name="test",
        )
        output = formatter.format(record)
        assert "INFO" in output
        assert "Test message" in output
    
    def test_text_formatter_with_context(self):
        """Test text formatter with context."""
        formatter = TextFormatter()
        record = LogRecord(
            timestamp=time.time(),
            level=LogLevel.INFO,
            message="Test",
            logger_name="test",
            context={"key": "value"},
        )
        output = formatter.format(record)
        assert "key=value" in output
    
    def test_text_formatter_options(self):
        """Test text formatter options."""
        formatter = TextFormatter(
            include_timestamp=False,
            include_level=True,
            include_logger=False,
            include_context=False,
        )
        record = LogRecord(
            timestamp=time.time(),
            level=LogLevel.INFO,
            message="Test",
            logger_name="test",
            context={"key": "value"},
        )
        output = formatter.format(record)
        assert "[INFO" in output
        assert "key=value" not in output
    
    def test_colored_formatter(self):
        """Test colored formatter."""
        formatter = ColoredFormatter()
        record = LogRecord(
            timestamp=time.time(),
            level=LogLevel.ERROR,
            message="Error",
            logger_name="test",
        )
        output = formatter.format(record)
        assert "\033[31m" in output  # Red color code


# =============================================================================
# Handler Tests (8 tests)
# =============================================================================

class TestHandlers:
    """Tests for log handlers."""
    
    def test_stream_handler(self):
        """Test stream handler."""
        output = io.StringIO()
        handler = StreamHandler(
            stream=output,
            formatter=JSONFormatter(),
        )
        record = LogRecord(
            timestamp=time.time(),
            level=LogLevel.INFO,
            message="Test",
            logger_name="test",
        )
        handler.handle(record)
        output.seek(0)
        line = output.read()
        assert "Test" in line
    
    def test_stream_handler_level_filter(self):
        """Test stream handler level filtering."""
        output = io.StringIO()
        handler = StreamHandler(
            stream=output,
            level=LogLevel.ERROR,
        )
        
        # Info should be filtered out
        info_record = LogRecord(
            timestamp=time.time(),
            level=LogLevel.INFO,
            message="Info",
            logger_name="test",
        )
        handler.handle(info_record)
        
        # Error should pass through
        error_record = LogRecord(
            timestamp=time.time(),
            level=LogLevel.ERROR,
            message="Error",
            logger_name="test",
        )
        handler.handle(error_record)
        
        output.seek(0)
        content = output.read()
        assert "Info" not in content
        assert "Error" in content
    
    def test_file_handler(self):
        """Test file handler."""
        with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.log') as f:
            filename = f.name
        
        try:
            handler = FileHandler(filename, formatter=JSONFormatter())
            record = LogRecord(
                timestamp=time.time(),
                level=LogLevel.INFO,
                message="File test",
                logger_name="test",
            )
            handler.handle(record)
            
            with open(filename) as f:
                content = f.read()
            assert "File test" in content
        finally:
            os.unlink(filename)
    
    def test_memory_handler(self):
        """Test memory handler."""
        handler = MemoryHandler(max_records=10)
        
        for i in range(5):
            record = LogRecord(
                timestamp=time.time(),
                level=LogLevel.INFO,
                message=f"Message {i}",
                logger_name="test",
            )
            handler.handle(record)
        
        records = handler.get_records()
        assert len(records) == 5
    
    def test_memory_handler_max_records(self):
        """Test memory handler max records limit."""
        handler = MemoryHandler(max_records=3)
        
        for i in range(5):
            record = LogRecord(
                timestamp=time.time(),
                level=LogLevel.INFO,
                message=f"Message {i}",
                logger_name="test",
            )
            handler.handle(record)
        
        records = handler.get_records()
        assert len(records) == 3
        assert "Message 4" in records[-1].message
    
    def test_memory_handler_filter_by_level(self):
        """Test memory handler filtering by level."""
        handler = MemoryHandler()
        
        handler.handle(LogRecord(time.time(), LogLevel.DEBUG, "Debug", "test"))
        handler.handle(LogRecord(time.time(), LogLevel.INFO, "Info", "test"))
        handler.handle(LogRecord(time.time(), LogLevel.ERROR, "Error", "test"))
        
        error_records = handler.get_records(level=LogLevel.ERROR)
        assert len(error_records) == 1
    
    def test_memory_handler_clear(self):
        """Test memory handler clear."""
        handler = MemoryHandler()
        handler.handle(LogRecord(time.time(), LogLevel.INFO, "Test", "test"))
        
        handler.clear()
        assert len(handler.get_records()) == 0
    
    def test_memory_handler_filter_by_logger(self):
        """Test memory handler filtering by logger."""
        handler = MemoryHandler()
        
        handler.handle(LogRecord(time.time(), LogLevel.INFO, "App", "app"))
        handler.handle(LogRecord(time.time(), LogLevel.INFO, "DB", "db"))
        
        app_records = handler.get_records(logger="app")
        assert len(app_records) == 1
        assert app_records[0].message == "App"


# =============================================================================
# StructuredLogger Tests (10 tests)
# =============================================================================

class TestStructuredLogger:
    """Tests for StructuredLogger."""
    
    def test_basic_logging(self):
        """Test basic logging."""
        handler = MemoryHandler()
        logger = StructuredLogger("test", handlers=[handler])
        
        logger.info("Test message")
        
        records = handler.get_records()
        assert len(records) == 1
        assert records[0].message == "Test message"
    
    def test_log_levels(self):
        """Test all log levels."""
        handler = MemoryHandler()
        logger = StructuredLogger("test", level=LogLevel.DEBUG, handlers=[handler])
        
        logger.debug("Debug")
        logger.info("Info")
        logger.warning("Warning")
        logger.error("Error")
        logger.critical("Critical")
        
        records = handler.get_records()
        assert len(records) == 5
    
    def test_level_filtering(self):
        """Test level filtering."""
        handler = MemoryHandler()
        logger = StructuredLogger("test", level=LogLevel.WARNING, handlers=[handler])
        
        logger.debug("Debug")
        logger.info("Info")
        logger.warning("Warning")
        logger.error("Error")
        
        records = handler.get_records()
        assert len(records) == 2
    
    def test_with_context_fields(self):
        """Test logging with context fields."""
        handler = MemoryHandler()
        logger = StructuredLogger("test", handlers=[handler])
        
        logger.info("Test", user_id="123", action="login")
        
        records = handler.get_records()
        assert records[0].context["user_id"] == "123"
        assert records[0].context["action"] == "login"
    
    def test_exception_logging(self):
        """Test exception logging."""
        handler = MemoryHandler()
        logger = StructuredLogger("test", handlers=[handler])
        
        try:
            raise ValueError("Test error")
        except ValueError as e:
            logger.exception("Error occurred", e)
        
        records = handler.get_records()
        assert "Test error" in records[0].exception
    
    def test_context_manager(self):
        """Test context manager."""
        handler = MemoryHandler()
        logger = StructuredLogger("test", handlers=[handler])
        
        with logger.context(request_id="abc123"):
            logger.info("Inside context")
        
        logger.info("Outside context")
        
        records = handler.get_records()
        assert records[0].request_id == "abc123"
        assert records[1].request_id is None
    
    def test_bound_logger(self):
        """Test bound logger."""
        handler = MemoryHandler()
        logger = StructuredLogger("test", handlers=[handler])
        
        bound = logger.bind(service="api", version="1.0")
        bound.info("Test")
        
        records = handler.get_records()
        assert records[0].context["service"] == "api"
        assert records[0].context["version"] == "1.0"
    
    def test_add_remove_handler(self):
        """Test adding and removing handlers."""
        logger = StructuredLogger("test")
        handler = MemoryHandler()
        
        logger.add_handler(handler)
        logger.info("Test")
        assert len(handler.get_records()) == 1
        
        logger.remove_handler(handler)
        logger.info("After removal")
        assert len(handler.get_records()) == 1  # No new records
    
    def test_set_level(self):
        """Test changing log level."""
        handler = MemoryHandler()
        logger = StructuredLogger("test", level=LogLevel.ERROR, handlers=[handler])
        
        logger.info("Should not appear")
        assert len(handler.get_records()) == 0
        
        logger.set_level(LogLevel.INFO)
        logger.info("Should appear")
        assert len(handler.get_records()) == 1
    
    def test_service_and_environment(self):
        """Test service and environment fields."""
        handler = MemoryHandler()
        logger = StructuredLogger(
            "test",
            handlers=[handler],
            service="my-service",
            environment="production",
        )
        
        logger.info("Test")
        
        records = handler.get_records()
        assert records[0].service == "my-service"
        assert records[0].environment == "production"


# =============================================================================
# LoggerFactory Tests (5 tests)
# =============================================================================

class TestLoggerFactory:
    """Tests for LoggerFactory."""
    
    def setup_method(self):
        """Reset factory before each test."""
        LoggerFactory.reset()
    
    def test_get_logger(self):
        """Test getting a logger."""
        logger = LoggerFactory.get_logger("test")
        assert logger.name == "test"
    
    def test_singleton_logger(self):
        """Test same logger is returned."""
        logger1 = LoggerFactory.get_logger("test")
        logger2 = LoggerFactory.get_logger("test")
        assert logger1 is logger2
    
    def test_configure(self):
        """Test factory configuration."""
        handler = MemoryHandler()
        LoggerFactory.configure(
            level=LogLevel.DEBUG,
            handlers=[handler],
            service="test-service",
        )
        
        logger = LoggerFactory.get_logger("mylogger")
        assert logger.level == LogLevel.DEBUG
        assert logger.service == "test-service"
    
    def test_reset(self):
        """Test factory reset."""
        LoggerFactory.get_logger("test1")
        LoggerFactory.reset()
        
        # After reset, factory state should be cleared
        logger = LoggerFactory.get_logger("test2")
        assert logger.name == "test2"
    
    def test_convenience_get_logger(self):
        """Test convenience get_logger function."""
        logger = get_logger("convenience_test")
        assert logger.name == "convenience_test"


# =============================================================================
# Integration Tests (4 tests)
# =============================================================================

class TestLoggingIntegration:
    """Integration tests for logging system."""
    
    def setup_method(self):
        """Reset state before each test."""
        LoggerFactory.reset()
        LogContext.clear()
    
    def test_configure_logging(self):
        """Test configure_logging function."""
        output = io.StringIO()
        configure_logging(
            level="DEBUG",
            format="json",
            service="test",
            output=output,
        )
        
        logger = get_logger("integration")
        logger.info("Test message")
        
        output.seek(0)
        content = output.read()
        assert "Test message" in content
    
    def test_context_propagation(self):
        """Test context propagation across log calls."""
        handler = MemoryHandler()
        LoggerFactory.configure(handlers=[handler])
        
        logger = get_logger("propagation")
        
        LogContext.set("request_id", "req-123")
        logger.info("First")
        logger.info("Second")
        
        records = handler.get_records()
        assert records[0].request_id == "req-123"
        assert records[1].request_id == "req-123"
    
    def test_multiple_loggers(self):
        """Test multiple loggers sharing handlers."""
        handler = MemoryHandler()
        LoggerFactory.configure(handlers=[handler])
        
        app_logger = get_logger("app")
        db_logger = get_logger("db")
        
        app_logger.info("App message")
        db_logger.info("DB message")
        
        records = handler.get_records()
        assert len(records) == 2
        assert records[0].logger_name == "app"
        assert records[1].logger_name == "db"
    
    def test_log_function_decorator(self):
        """Test log function decorator."""
        handler = MemoryHandler()
        logger = StructuredLogger("test", level=LogLevel.DEBUG, handlers=[handler])
        
        @log_function_call(logger=logger)
        def my_function(x, y):
            return x + y
        
        result = my_function(1, 2)
        assert result == 3
        
        records = handler.get_records()
        assert len(records) == 2  # Call and complete messages


# =============================================================================
# Summary
# =============================================================================
# Total: 45 tests
# - LogLevel: 3 tests
# - LogRecord: 4 tests
# - LogContext: 5 tests
# - Formatters: 6 tests
# - Handlers: 8 tests
# - StructuredLogger: 10 tests
# - LoggerFactory: 5 tests
# - Integration: 4 tests