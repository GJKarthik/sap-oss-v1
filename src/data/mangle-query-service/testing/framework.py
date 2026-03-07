"""
Integration Test Framework - Core Components.

Day 56 Implementation - Week 12 Integration Testing
Provides fixtures, mock servers, assertions, and test utilities.
No external dependencies beyond Python standard library.
"""

import time
import json
import threading
import socket
import re
import functools
import asyncio
from typing import (
    Optional, Dict, Any, List, Callable, Union, TypeVar, Generic
)
from dataclasses import dataclass, field
from enum import Enum
from abc import ABC, abstractmethod
from http.server import HTTPServer, BaseHTTPRequestHandler
from contextlib import contextmanager
from urllib.parse import parse_qs, urlparse
import uuid


# =============================================================================
# Fixture System
# =============================================================================

class FixtureScope(Enum):
    """Scope for test fixtures."""
    FUNCTION = "function"  # New instance per test function
    CLASS = "class"        # Shared within test class
    MODULE = "module"      # Shared within module
    SESSION = "session"    # Shared for entire test session


@dataclass
class TestFixture:
    """
    Base class for test fixtures.
    
    Fixtures provide setup and teardown functionality for tests.
    """
    name: str
    scope: FixtureScope = FixtureScope.FUNCTION
    _value: Any = None
    _setup_done: bool = False
    
    def setup(self) -> Any:
        """Setup fixture and return value. Override in subclasses."""
        return None
    
    def teardown(self) -> None:
        """Teardown fixture. Override in subclasses."""
        pass
    
    def get_value(self) -> Any:
        """Get fixture value, setting up if needed."""
        if not self._setup_done:
            self._value = self.setup()
            self._setup_done = True
        return self._value
    
    def reset(self) -> None:
        """Reset fixture state."""
        if self._setup_done:
            self.teardown()
            self._setup_done = False
            self._value = None


def fixture(
    scope: FixtureScope = FixtureScope.FUNCTION,
    name: Optional[str] = None,
):
    """Decorator to create a fixture from a function."""
    def decorator(func: Callable) -> TestFixture:
        fixture_name = name or func.__name__
        
        class FunctionFixture(TestFixture):
            def setup(self) -> Any:
                return func()
        
        return FunctionFixture(name=fixture_name, scope=scope)
    
    return decorator


# =============================================================================
# Mock Server
# =============================================================================

@dataclass
class MockResponse:
    """Definition of a mock HTTP response."""
    status: int = 200
    body: Union[str, bytes, Dict[str, Any]] = ""
    headers: Dict[str, str] = field(default_factory=dict)
    delay: float = 0.0  # Simulated latency
    
    def get_body_bytes(self) -> bytes:
        """Get response body as bytes."""
        if isinstance(self.body, bytes):
            return self.body
        elif isinstance(self.body, dict):
            return json.dumps(self.body).encode("utf-8")
        else:
            return str(self.body).encode("utf-8")
    
    def get_content_type(self) -> str:
        """Get content type header."""
        if "Content-Type" in self.headers:
            return self.headers["Content-Type"]
        elif isinstance(self.body, dict):
            return "application/json"
        else:
            return "text/plain"


@dataclass
class MockEndpoint:
    """Definition of a mock endpoint."""
    method: str
    path: str
    response: MockResponse
    match_body: Optional[Dict[str, Any]] = None
    match_headers: Optional[Dict[str, str]] = None
    call_count: int = 0
    last_request: Optional[Dict[str, Any]] = None
    
    def matches(
        self,
        method: str,
        path: str,
        body: Optional[Dict[str, Any]] = None,
        headers: Optional[Dict[str, str]] = None,
    ) -> bool:
        """Check if request matches this endpoint."""
        if method.upper() != self.method.upper():
            return False
        
        # Path matching (supports wildcards)
        if not self._match_path(path):
            return False
        
        # Body matching
        if self.match_body is not None and body != self.match_body:
            return False
        
        # Header matching
        if self.match_headers is not None:
            if headers is None:
                return False
            for key, value in self.match_headers.items():
                if headers.get(key) != value:
                    return False
        
        return True
    
    def _match_path(self, path: str) -> bool:
        """Match path with wildcard support."""
        pattern = self.path.replace("*", ".*")
        return bool(re.match(f"^{pattern}$", path))
    
    def record_call(
        self,
        method: str,
        path: str,
        body: Any,
        headers: Dict[str, str],
    ) -> None:
        """Record a call to this endpoint."""
        self.call_count += 1
        self.last_request = {
            "method": method,
            "path": path,
            "body": body,
            "headers": headers,
            "timestamp": time.time(),
        }


class MockRequestHandler(BaseHTTPRequestHandler):
    """HTTP request handler for mock server."""
    
    server: "MockHTTPServer"
    
    def log_message(self, format: str, *args) -> None:
        """Suppress logging by default."""
        pass
    
    def do_GET(self):
        self._handle_request("GET")
    
    def do_POST(self):
        self._handle_request("POST")
    
    def do_PUT(self):
        self._handle_request("PUT")
    
    def do_DELETE(self):
        self._handle_request("DELETE")
    
    def do_PATCH(self):
        self._handle_request("PATCH")
    
    def _handle_request(self, method: str):
        """Handle any HTTP request."""
        # Parse path and query
        parsed = urlparse(self.path)
        path = parsed.path
        
        # Read body if present
        content_length = int(self.headers.get("Content-Length", 0))
        body = None
        if content_length > 0:
            body_bytes = self.rfile.read(content_length)
            try:
                body = json.loads(body_bytes.decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                body = body_bytes.decode("utf-8", errors="replace")
        
        # Get headers as dict
        headers = dict(self.headers)
        
        # Find matching endpoint
        endpoint = self.server.mock_server.find_endpoint(
            method, path, body, headers
        )
        
        if endpoint:
            endpoint.record_call(method, path, body, headers)
            response = endpoint.response
            
            # Simulate delay
            if response.delay > 0:
                time.sleep(response.delay)
            
            # Send response
            self.send_response(response.status)
            self.send_header("Content-Type", response.get_content_type())
            for key, value in response.headers.items():
                if key.lower() != "content-type":
                    self.send_header(key, value)
            self.end_headers()
            self.wfile.write(response.get_body_bytes())
        else:
            # No matching endpoint
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "error": "No matching mock endpoint",
                "method": method,
                "path": path,
            }).encode("utf-8"))


class MockHTTPServer(HTTPServer):
    """HTTP server that references MockServer."""
    mock_server: "MockServer"


class MockServer:
    """
    Mock HTTP server for integration testing.
    
    Allows defining endpoints and responses for testing HTTP clients.
    """
    
    def __init__(self, host: str = "127.0.0.1", port: int = 0):
        self.host = host
        self.port = port
        self._endpoints: List[MockEndpoint] = []
        self._server: Optional[MockHTTPServer] = None
        self._thread: Optional[threading.Thread] = None
        self._lock = threading.Lock()
    
    @property
    def url(self) -> str:
        """Get server base URL."""
        if self._server:
            return f"http://{self.host}:{self._server.server_address[1]}"
        return f"http://{self.host}:{self.port}"
    
    def add_endpoint(
        self,
        method: str,
        path: str,
        response: Optional[MockResponse] = None,
        status: int = 200,
        body: Union[str, Dict[str, Any]] = "",
        headers: Optional[Dict[str, str]] = None,
        delay: float = 0.0,
    ) -> MockEndpoint:
        """Add a mock endpoint."""
        if response is None:
            response = MockResponse(
                status=status,
                body=body,
                headers=headers or {},
                delay=delay,
            )
        
        endpoint = MockEndpoint(
            method=method.upper(),
            path=path,
            response=response,
        )
        
        with self._lock:
            self._endpoints.append(endpoint)
        
        return endpoint
    
    def find_endpoint(
        self,
        method: str,
        path: str,
        body: Any = None,
        headers: Optional[Dict[str, str]] = None,
    ) -> Optional[MockEndpoint]:
        """Find matching endpoint for request."""
        with self._lock:
            for endpoint in self._endpoints:
                if endpoint.matches(method, path, body, headers):
                    return endpoint
        return None
    
    def start(self) -> None:
        """Start the mock server."""
        if self._server is not None:
            return
        
        self._server = MockHTTPServer(
            (self.host, self.port),
            MockRequestHandler,
        )
        self._server.mock_server = self
        
        # Update port if auto-assigned
        self.port = self._server.server_address[1]
        
        self._thread = threading.Thread(
            target=self._server.serve_forever,
            daemon=True,
        )
        self._thread.start()
    
    def stop(self) -> None:
        """Stop the mock server."""
        if self._server is not None:
            self._server.shutdown()
            self._server = None
        
        if self._thread is not None:
            self._thread.join(timeout=1.0)
            self._thread = None
    
    def reset(self) -> None:
        """Reset all endpoints and call counts."""
        with self._lock:
            for endpoint in self._endpoints:
                endpoint.call_count = 0
                endpoint.last_request = None
    
    def clear_endpoints(self) -> None:
        """Remove all endpoints."""
        with self._lock:
            self._endpoints.clear()
    
    def __enter__(self) -> "MockServer":
        self.start()
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        self.stop()


# =============================================================================
# Assertions
# =============================================================================

class AssertionError(Exception):
    """Custom assertion error with detailed messages."""
    pass


def assert_status(response: Any, expected: int, message: str = "") -> None:
    """Assert HTTP response status code."""
    actual = getattr(response, "status_code", None) or getattr(response, "status", None)
    if actual is None:
        raise AssertionError(f"Response has no status code: {response}")
    
    if actual != expected:
        msg = f"Expected status {expected}, got {actual}"
        if message:
            msg = f"{message}: {msg}"
        raise AssertionError(msg)


def assert_json(
    response: Any,
    expected: Dict[str, Any],
    strict: bool = False,
    message: str = "",
) -> None:
    """Assert JSON response matches expected."""
    if hasattr(response, "json"):
        actual = response.json() if callable(response.json) else response.json
    elif isinstance(response, dict):
        actual = response
    elif isinstance(response, (str, bytes)):
        actual = json.loads(response if isinstance(response, str) else response.decode())
    else:
        raise AssertionError(f"Cannot parse JSON from: {type(response)}")
    
    if strict:
        if actual != expected:
            msg = f"JSON mismatch:\nExpected: {expected}\nActual: {actual}"
            if message:
                msg = f"{message}: {msg}"
            raise AssertionError(msg)
    else:
        for key, value in expected.items():
            if key not in actual:
                msg = f"Missing key '{key}' in response"
                if message:
                    msg = f"{message}: {msg}"
                raise AssertionError(msg)
            if actual[key] != value:
                msg = f"Key '{key}': expected {value}, got {actual[key]}"
                if message:
                    msg = f"{message}: {msg}"
                raise AssertionError(msg)


def assert_contains(
    actual: Union[str, bytes, List, Dict],
    expected: Any,
    message: str = "",
) -> None:
    """Assert actual contains expected value."""
    if isinstance(actual, bytes):
        actual = actual.decode("utf-8", errors="replace")
    
    if expected not in actual:
        msg = f"Expected {repr(expected)} to be in {repr(actual)[:200]}"
        if message:
            msg = f"{message}: {msg}"
        raise AssertionError(msg)


def assert_matches(
    actual: str,
    pattern: str,
    message: str = "",
) -> None:
    """Assert string matches regex pattern."""
    if not re.search(pattern, actual):
        msg = f"Expected pattern '{pattern}' to match '{actual[:200]}'"
        if message:
            msg = f"{message}: {msg}"
        raise AssertionError(msg)


def assert_timing(
    duration: float,
    max_ms: Optional[float] = None,
    min_ms: Optional[float] = None,
    message: str = "",
) -> None:
    """Assert timing is within bounds."""
    duration_ms = duration * 1000
    
    if max_ms is not None and duration_ms > max_ms:
        msg = f"Took {duration_ms:.2f}ms, expected <= {max_ms}ms"
        if message:
            msg = f"{message}: {msg}"
        raise AssertionError(msg)
    
    if min_ms is not None and duration_ms < min_ms:
        msg = f"Took {duration_ms:.2f}ms, expected >= {min_ms}ms"
        if message:
            msg = f"{message}: {msg}"
        raise AssertionError(msg)


# =============================================================================
# Test Client
# =============================================================================

@dataclass
class HTTPResponse:
    """HTTP response wrapper."""
    status_code: int
    headers: Dict[str, str]
    body: bytes
    elapsed: float
    
    @property
    def text(self) -> str:
        """Get body as text."""
        return self.body.decode("utf-8", errors="replace")
    
    def json(self) -> Any:
        """Parse body as JSON."""
        return json.loads(self.body.decode("utf-8"))
    
    @property
    def ok(self) -> bool:
        """Check if status is successful."""
        return 200 <= self.status_code < 300


class TestClient:
    """
    HTTP test client for integration testing.
    
    Provides simple interface for making HTTP requests.
    """
    
    def __init__(
        self,
        base_url: str = "",
        timeout: float = 30.0,
        headers: Optional[Dict[str, str]] = None,
    ):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.default_headers = headers or {}
    
    def request(
        self,
        method: str,
        path: str,
        body: Optional[Union[str, bytes, Dict[str, Any]]] = None,
        headers: Optional[Dict[str, str]] = None,
        timeout: Optional[float] = None,
    ) -> HTTPResponse:
        """Make an HTTP request."""
        import urllib.request
        import urllib.error
        
        url = f"{self.base_url}{path}"
        
        # Prepare headers
        all_headers = {**self.default_headers}
        if headers:
            all_headers.update(headers)
        
        # Prepare body
        data = None
        if body is not None:
            if isinstance(body, dict):
                data = json.dumps(body).encode("utf-8")
                if "Content-Type" not in all_headers:
                    all_headers["Content-Type"] = "application/json"
            elif isinstance(body, str):
                data = body.encode("utf-8")
            else:
                data = body
        
        # Create request
        req = urllib.request.Request(
            url,
            data=data,
            headers=all_headers,
            method=method.upper(),
        )
        
        # Execute request
        start = time.time()
        try:
            with urllib.request.urlopen(
                req,
                timeout=timeout or self.timeout,
            ) as response:
                return HTTPResponse(
                    status_code=response.status,
                    headers=dict(response.headers),
                    body=response.read(),
                    elapsed=time.time() - start,
                )
        except urllib.error.HTTPError as e:
            return HTTPResponse(
                status_code=e.code,
                headers=dict(e.headers),
                body=e.read(),
                elapsed=time.time() - start,
            )
        except urllib.error.URLError as e:
            raise ConnectionError(f"Failed to connect to {url}: {e.reason}")
    
    def get(
        self,
        path: str,
        headers: Optional[Dict[str, str]] = None,
        **kwargs,
    ) -> HTTPResponse:
        """Make GET request."""
        return self.request("GET", path, headers=headers, **kwargs)
    
    def post(
        self,
        path: str,
        body: Optional[Union[str, bytes, Dict[str, Any]]] = None,
        headers: Optional[Dict[str, str]] = None,
        **kwargs,
    ) -> HTTPResponse:
        """Make POST request."""
        return self.request("POST", path, body=body, headers=headers, **kwargs)
    
    def put(
        self,
        path: str,
        body: Optional[Union[str, bytes, Dict[str, Any]]] = None,
        headers: Optional[Dict[str, str]] = None,
        **kwargs,
    ) -> HTTPResponse:
        """Make PUT request."""
        return self.request("PUT", path, body=body, headers=headers, **kwargs)
    
    def delete(
        self,
        path: str,
        headers: Optional[Dict[str, str]] = None,
        **kwargs,
    ) -> HTTPResponse:
        """Make DELETE request."""
        return self.request("DELETE", path, headers=headers, **kwargs)
    
    def patch(
        self,
        path: str,
        body: Optional[Union[str, bytes, Dict[str, Any]]] = None,
        headers: Optional[Dict[str, str]] = None,
        **kwargs,
    ) -> HTTPResponse:
        """Make PATCH request."""
        return self.request("PATCH", path, body=body, headers=headers, **kwargs)


# =============================================================================
# Test Utilities
# =============================================================================

def with_timeout(seconds: float):
    """Decorator to add timeout to test function."""
    def decorator(func: Callable) -> Callable:
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            result = [None]
            exception = [None]
            
            def target():
                try:
                    result[0] = func(*args, **kwargs)
                except Exception as e:
                    exception[0] = e
            
            thread = threading.Thread(target=target)
            thread.start()
            thread.join(timeout=seconds)
            
            if thread.is_alive():
                raise TimeoutError(f"Test exceeded {seconds}s timeout")
            
            if exception[0] is not None:
                raise exception[0]
            
            return result[0]
        
        return wrapper
    return decorator


def retry_until(
    condition: Callable[[], bool],
    timeout: float = 10.0,
    interval: float = 0.1,
    message: str = "Condition not met within timeout",
) -> None:
    """Retry until condition is true or timeout."""
    start = time.time()
    
    while time.time() - start < timeout:
        if condition():
            return
        time.sleep(interval)
    
    raise TimeoutError(message)


# =============================================================================
# Test Data Generation
# =============================================================================

class TestDataGenerator:
    """Generator for test data."""
    
    _counter: int = 0
    _lock = threading.Lock()
    
    @classmethod
    def unique_id(cls) -> str:
        """Generate unique ID."""
        return str(uuid.uuid4())
    
    @classmethod
    def sequence(cls) -> int:
        """Get next sequence number."""
        with cls._lock:
            cls._counter += 1
            return cls._counter
    
    @classmethod
    def unique_string(cls, prefix: str = "test") -> str:
        """Generate unique string."""
        return f"{prefix}_{cls.sequence()}"
    
    @classmethod
    def unique_email(cls, domain: str = "test.com") -> str:
        """Generate unique email."""
        return f"user_{cls.sequence()}@{domain}"
    
    @classmethod
    def timestamp(cls) -> float:
        """Get current timestamp."""
        return time.time()
    
    @classmethod
    def random_string(cls, length: int = 10) -> str:
        """Generate random alphanumeric string."""
        import random
        import string
        chars = string.ascii_letters + string.digits
        return "".join(random.choice(chars) for _ in range(length))


class RequestFactory:
    """Factory for creating test requests."""
    
    @staticmethod
    def chat_completion(
        model: str = "gpt-4",
        messages: Optional[List[Dict[str, str]]] = None,
        **kwargs,
    ) -> Dict[str, Any]:
        """Create chat completion request."""
        if messages is None:
            messages = [{"role": "user", "content": "Hello"}]
        
        return {
            "model": model,
            "messages": messages,
            **kwargs,
        }
    
    @staticmethod
    def embedding(
        input: Union[str, List[str]] = "test text",
        model: str = "text-embedding-ada-002",
        **kwargs,
    ) -> Dict[str, Any]:
        """Create embedding request."""
        return {
            "input": input,
            "model": model,
            **kwargs,
        }
    
    @staticmethod
    def completion(
        model: str = "gpt-3.5-turbo-instruct",
        prompt: str = "Hello",
        **kwargs,
    ) -> Dict[str, Any]:
        """Create completion request."""
        return {
            "model": model,
            "prompt": prompt,
            **kwargs,
        }
    
    @staticmethod
    def assistant(
        name: str = "Test Assistant",
        model: str = "gpt-4",
        **kwargs,
    ) -> Dict[str, Any]:
        """Create assistant request."""
        return {
            "name": name,
            "model": model,
            **kwargs,
        }
    
    @staticmethod
    def thread(**kwargs) -> Dict[str, Any]:
        """Create thread request."""
        return kwargs
    
    @staticmethod
    def message(
        role: str = "user",
        content: str = "Hello",
        **kwargs,
    ) -> Dict[str, Any]:
        """Create message request."""
        return {
            "role": role,
            "content": content,
            **kwargs,
        }
    
    @staticmethod
    def run(
        assistant_id: str = "asst_123",
        **kwargs,
    ) -> Dict[str, Any]:
        """Create run request."""
        return {
            "assistant_id": assistant_id,
            **kwargs,
        }