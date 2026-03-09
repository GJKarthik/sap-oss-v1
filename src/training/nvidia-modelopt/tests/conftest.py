#!/usr/bin/env python3
"""
Shared fixtures for ModelOpt API tests.
"""

import os
import sys
import pytest

# Ensure the nvidia-modelopt package root is on sys.path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


@pytest.fixture
def client():
    """FastAPI TestClient for the ModelOpt API."""
    from fastapi.testclient import TestClient
    from api.main import app
    return TestClient(app)


@pytest.fixture
def auth_headers():
    """Authorization headers using a generated API key."""
    from api.auth import generate_api_key
    key = generate_api_key("test-fixture")
    return {"Authorization": f"Bearer {key}"}


@pytest.fixture
def sample_job_config():
    """A valid job creation payload."""
    return {
        "config": {
            "model_name": "Qwen/Qwen3.5-1.8B",
            "quant_format": "int8",
            "calib_samples": 512,
            "export_format": "hf",
        }
    }


@pytest.fixture
def sample_chat_request():
    """A valid chat completion request payload."""
    return {
        "model": "qwen3.5-1.8b-int8",
        "messages": [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "Hello!"},
        ],
        "temperature": 0.7,
        "max_tokens": 128,
    }

