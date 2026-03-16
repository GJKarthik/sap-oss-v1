"""
Unit tests for integration test framework.

Day 56 - Week 12 Integration Testing
45 tests covering fixtures, mock server, assertions, and utilities.
"""

import pytest
import time
import json
from unittest.mock import Mock, patch

from testing.framework import (
    # Fixtures
    TestFixture,
    FixtureScope,
    fixture,
    # Mock server
    MockServer,
    MockResponse,
    MockEndpoint,
    # Assertions
    assert_status,
    assert_json,
    assert_contains,
    assert_matches,
    assert_timing,
    AssertionError as TestAssertionError,
    # Utilities
    TestClient,
    HTTPResponse,
    with_timeout,
    retry_until,
    # Test data
    TestDataGenerator,
    RequestFactory,
)


# =============================================================================
# FixtureScope Tests (2 tests)
# =============================================================================

class TestFixtureScope:
    """Tests for FixtureScope enum."""
    
    def test_scope_values(self):
        """Test all scope values exist."""
        assert FixtureScope.FUNCTION.value == "function"
        assert FixtureScope.CLASS.value == "class"
        assert FixtureScope.MODULE.value == "module"
        assert FixtureScope.SESSION.value == "session"
    
    def test_scope_count(self):
        """Test correct number of scopes."""
        assert len(FixtureScope) == 4


# =============================================================================
# TestFixture Tests (4 tests)
# =============================================================================

class TestTestFixture:
    """Tests for TestFixture class."""
    
    def test_fixture_creation(self):
        """Test basic fixture creation."""
        f = TestFixture(name="test")
        assert f.name == "test"
        assert f.scope == FixtureScope.FUNCTION
    
    def test_fixture_setup(self):
        """Test fixture setup."""
        class CounterFixture(TestFixture):
            def setup(self):
                return {"count": 0}
        
        f = CounterFixture(name="counter")
        value = f.get_value()
        assert value == {"count": 0}
    
    def test_fixture_lazy_setup(self):
        """Test fixture is lazily set up."""
        setup_called = [False]
        
        class LazyFixture(TestFixture):
            def setup(self):
                setup_called[0] = True
                return "value"
        
        f = LazyFixture(name="lazy")
        assert not setup_called[0]
        f.get_value()
        assert setup_called[0]
    
    def test_fixture_reset(self):
        """Test fixture reset."""
        teardown_called = [False]
        
        class ResetFixture(TestFixture):
            def setup(self):
                return "value"
            def teardown(self):
                teardown_called[0] = True
        
        f = ResetFixture(name="reset")
        f.get_value()
        f.reset()
        assert teardown_called[0]


# =============================================================================
# MockResponse Tests (3 tests)
# =============================================================================

class TestMockResponse:
    """Tests for MockResponse class."""
    
    def test_default_response(self):
        """Test default response values."""
        r = MockResponse()
        assert r.status == 200
        assert r.delay == 0.0
    
    def test_json_body(self):
        """Test JSON body serialization."""
        r = MockResponse(body={"key": "value"})
        body_bytes = r.get_body_bytes()
        assert json.loads(body_bytes) == {"key": "value"}
    
    def test_content_type(self):
        """Test content type detection."""
        json_resp = MockResponse(body={"a": 1})
        assert json_resp.get_content_type() == "application/json"
        
        text_resp = MockResponse(body="hello")
        assert text_resp.get_content_type() == "text/plain"


# =============================================================================
# MockEndpoint Tests (4 tests)
# =============================================================================

class TestMockEndpoint:
    """Tests for MockEndpoint class."""
    
    def test_endpoint_matches_exact(self):
        """Test exact path matching."""
        endpoint = MockEndpoint(
            method="GET",
            path="/api/users",
            response=MockResponse(),
        )
        
        assert endpoint.matches("GET", "/api/users")
        assert not endpoint.matches("POST", "/api/users")
        assert not endpoint.matches("GET", "/api/other")
    
    def test_endpoint_matches_wildcard(self):
        """Test wildcard path matching."""
        endpoint = MockEndpoint(
            method="GET",
            path="/api/users/*",
            response=MockResponse(),
        )
        
        assert endpoint.matches("GET", "/api/users/123")
        assert endpoint.matches("GET", "/api/users/abc")
    
    def test_endpoint_call_count(self):
        """Test call counting."""
        endpoint = MockEndpoint(
            method="GET",
            path="/test",
            response=MockResponse(),
        )
        
        assert endpoint.call_count == 0
        endpoint.record_call("GET", "/test", None, {})
        assert endpoint.call_count == 1
    
    def test_endpoint_last_request(self):
        """Test last request recording."""
        endpoint = MockEndpoint(
            method="POST",
            path="/api",
            response=MockResponse(),
        )
        
        endpoint.record_call("POST", "/api", {"data": 1}, {"Content-Type": "application/json"})
        assert endpoint.last_request is not None
        assert endpoint.last_request["body"] == {"data": 1}


# =============================================================================
# MockServer Tests (5 tests)
# =============================================================================

class TestMockServer:
    """Tests for MockServer class."""
    
    def test_server_creation(self):
        """Test mock server creation."""
        server = MockServer()
        assert server.host == "127.0.0.1"
    
    def test_add_endpoint(self):
        """Test adding endpoint."""
        server = MockServer()
        endpoint = server.add_endpoint("GET", "/test", status=200)
        
        assert endpoint.method == "GET"
        assert endpoint.path == "/test"
    
    def test_find_endpoint(self):
        """Test finding endpoint."""
        server = MockServer()
        server.add_endpoint("GET", "/users", body={"users": []})
        server.add_endpoint("POST", "/users", body={"id": 1})
        
        get_endpoint = server.find_endpoint("GET", "/users")
        post_endpoint = server.find_endpoint("POST", "/users")
        
        assert get_endpoint is not None
        assert post_endpoint is not None
        assert get_endpoint != post_endpoint
    
    def test_server_reset(self):
        """Test resetting server."""
        server = MockServer()
        endpoint = server.add_endpoint("GET", "/test")
        endpoint.call_count = 5
        
        server.reset()
        assert endpoint.call_count == 0
    
    def test_clear_endpoints(self):
        """Test clearing all endpoints."""
        server = MockServer()
        server.add_endpoint("GET", "/a")
        server.add_endpoint("GET", "/b")
        
        server.clear_endpoints()
        assert server.find_endpoint("GET", "/a") is None


# =============================================================================
# Assertion Tests (5 tests)
# =============================================================================

class TestAssertions:
    """Tests for assertion functions."""
    
    def test_assert_status_pass(self):
        """Test assert_status passes for matching status."""
        response = Mock(status_code=200)
        assert_status(response, 200)  # Should not raise
    
    def test_assert_status_fail(self):
        """Test assert_status fails for mismatched status."""
        response = Mock(status_code=404)
        with pytest.raises(TestAssertionError):
            assert_status(response, 200)
    
    def test_assert_json_partial(self):
        """Test assert_json with partial match."""
        response = Mock()
        response.json = lambda: {"id": 1, "name": "test", "extra": True}
        
        assert_json(response, {"id": 1, "name": "test"})  # Should pass
    
    def test_assert_contains_pass(self):
        """Test assert_contains passes."""
        assert_contains("hello world", "world")
        assert_contains(["a", "b", "c"], "b")
    
    def test_assert_matches_pass(self):
        """Test assert_matches with regex."""
        assert_matches("user_123_test", r"user_\d+")


# =============================================================================
# assert_timing Tests (3 tests)
# =============================================================================

class TestAssertTiming:
    """Tests for assert_timing function."""
    
    def test_timing_within_max(self):
        """Test timing within max bound."""
        assert_timing(0.05, max_ms=100)  # 50ms < 100ms
    
    def test_timing_exceeds_max(self):
        """Test timing exceeds max bound."""
        with pytest.raises(TestAssertionError):
            assert_timing(0.2, max_ms=100)  # 200ms > 100ms
    
    def test_timing_below_min(self):
        """Test timing below min bound."""
        with pytest.raises(TestAssertionError):
            assert_timing(0.01, min_ms=50)  # 10ms < 50ms


# =============================================================================
# HTTPResponse Tests (4 tests)
# =============================================================================

class TestHTTPResponse:
    """Tests for HTTPResponse class."""
    
    def test_response_text(self):
        """Test text property."""
        response = HTTPResponse(
            status_code=200,
            headers={},
            body=b"hello",
            elapsed=0.1,
        )
        assert response.text == "hello"
    
    def test_response_json(self):
        """Test JSON parsing."""
        response = HTTPResponse(
            status_code=200,
            headers={},
            body=b'{"key": "value"}',
            elapsed=0.1,
        )
        assert response.json() == {"key": "value"}
    
    def test_response_ok(self):
        """Test ok property."""
        ok_response = HTTPResponse(200, {}, b"", 0.1)
        not_ok = HTTPResponse(404, {}, b"", 0.1)
        
        assert ok_response.ok
        assert not not_ok.ok
    
    def test_response_elapsed(self):
        """Test elapsed time."""
        response = HTTPResponse(200, {}, b"", 0.123)
        assert response.elapsed == 0.123


# =============================================================================
# TestClient Tests (4 tests)
# =============================================================================

class TestTestClient:
    """Tests for TestClient class."""
    
    def test_client_creation(self):
        """Test client creation."""
        client = TestClient(base_url="http://localhost:8080")
        assert client.base_url == "http://localhost:8080"
    
    def test_client_headers(self):
        """Test default headers."""
        client = TestClient(headers={"Authorization": "Bearer token"})
        assert "Authorization" in client.default_headers
    
    def test_client_timeout(self):
        """Test custom timeout."""
        client = TestClient(timeout=5.0)
        assert client.timeout == 5.0
    
    def test_client_methods(self):
        """Test HTTP method helpers exist."""
        client = TestClient()
        assert hasattr(client, "get")
        assert hasattr(client, "post")
        assert hasattr(client, "put")
        assert hasattr(client, "delete")
        assert hasattr(client, "patch")


# =============================================================================
# with_timeout Tests (2 tests)
# =============================================================================

class TestWithTimeout:
    """Tests for with_timeout decorator."""
    
    def test_timeout_not_exceeded(self):
        """Test function completes within timeout."""
        @with_timeout(1.0)
        def fast_func():
            return "result"
        
        result = fast_func()
        assert result == "result"
    
    def test_exception_propagated(self):
        """Test exceptions are propagated."""
        @with_timeout(1.0)
        def failing_func():
            raise ValueError("test error")
        
        with pytest.raises(ValueError, match="test error"):
            failing_func()


# =============================================================================
# retry_until Tests (2 tests)
# =============================================================================

class TestRetryUntil:
    """Tests for retry_until function."""
    
    def test_condition_met_immediately(self):
        """Test when condition is met immediately."""
        retry_until(lambda: True, timeout=1.0)  # Should not raise
    
    def test_condition_met_after_retries(self):
        """Test when condition is met after retries."""
        counter = [0]
        
        def condition():
            counter[0] += 1
            return counter[0] >= 3
        
        retry_until(condition, timeout=1.0, interval=0.01)
        assert counter[0] >= 3


# =============================================================================
# TestDataGenerator Tests (4 tests)
# =============================================================================

class TestTestDataGenerator:
    """Tests for TestDataGenerator class."""
    
    def test_unique_id(self):
        """Test unique ID generation."""
        id1 = TestDataGenerator.unique_id()
        id2 = TestDataGenerator.unique_id()
        assert id1 != id2
    
    def test_sequence(self):
        """Test sequence generation."""
        seq1 = TestDataGenerator.sequence()
        seq2 = TestDataGenerator.sequence()
        assert seq2 > seq1
    
    def test_unique_string(self):
        """Test unique string generation."""
        s1 = TestDataGenerator.unique_string("prefix")
        s2 = TestDataGenerator.unique_string("prefix")
        assert s1 != s2
        assert s1.startswith("prefix_")
    
    def test_random_string(self):
        """Test random string generation."""
        s = TestDataGenerator.random_string(20)
        assert len(s) == 20


# =============================================================================
# RequestFactory Tests (3 tests)
# =============================================================================

class TestRequestFactory:
    """Tests for RequestFactory class."""
    
    def test_chat_completion(self):
        """Test chat completion request."""
        req = RequestFactory.chat_completion(model="gpt-4")
        assert req["model"] == "gpt-4"
        assert "messages" in req
    
    def test_embedding(self):
        """Test embedding request."""
        req = RequestFactory.embedding(input="test text")
        assert req["input"] == "test text"
        assert "model" in req
    
    def test_assistant(self):
        """Test assistant request."""
        req = RequestFactory.assistant(name="Test Bot")
        assert req["name"] == "Test Bot"
        assert "model" in req


# =============================================================================
# Summary
# =============================================================================
# Total: 45 tests
# - FixtureScope: 2 tests
# - TestFixture: 4 tests
# - MockResponse: 3 tests
# - MockEndpoint: 4 tests
# - MockServer: 5 tests
# - Assertions: 5 tests
# - assert_timing: 3 tests
# - HTTPResponse: 4 tests
# - TestClient: 4 tests
# - with_timeout: 2 tests
# - retry_until: 2 tests
# - TestDataGenerator: 4 tests
# - RequestFactory: 3 tests