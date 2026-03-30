"""Shared pytest configuration for the api-server tests."""
import pytest


def pytest_configure(config):
    config.addinivalue_line("markers", "anyio: mark test as async (anyio backend)")
