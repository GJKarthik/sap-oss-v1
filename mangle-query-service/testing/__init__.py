"""
Testing Framework - Integration Test Infrastructure.

Day 56 Implementation - Week 12 Integration Testing
Provides fixtures, mocks, and utilities for comprehensive testing.
No external test framework dependencies beyond pytest.
"""

from testing.framework import (
    # Test fixtures
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
    # Utilities
    TestClient,
    with_timeout,
    retry_until,
    # Test data
    TestDataGenerator,
    RequestFactory,
)

__all__ = [
    # Fixtures
    "TestFixture",
    "FixtureScope",
    "fixture",
    # Mock server
    "MockServer",
    "MockResponse",
    "MockEndpoint",
    # Assertions
    "assert_status",
    "assert_json",
    "assert_contains",
    "assert_matches",
    "assert_timing",
    # Utilities
    "TestClient",
    "with_timeout",
    "retry_until",
    # Test data
    "TestDataGenerator",
    "RequestFactory",
]