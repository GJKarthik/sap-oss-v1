#!/usr/bin/env python3
"""
Tests for OpenAI-compatible API endpoints (/v1/*).
"""

import json
import pytest


class TestModelsEndpoint:
    """GET /v1/models & /v1/models/{id}"""

    def test_list_models_schema(self, client):
        data = client.get("/v1/models").json()
        assert data["object"] == "list"
        for m in data["data"]:
            assert set(m.keys()) >= {"id", "object", "created", "owned_by"}
            assert m["object"] == "model"

    def test_get_known_model(self, client):
        data = client.get("/v1/models/qwen3.5-0.6b-int8").json()
        assert data["id"] == "qwen3.5-0.6b-int8"

    def test_get_unknown_model_404(self, client):
        resp = client.get("/v1/models/does-not-exist")
        assert resp.status_code == 404
        err = resp.json()["detail"]["error"]
        assert err["type"] == "invalid_request_error"

    def test_delete_model_not_allowed(self, client):
        resp = client.delete("/v1/models/qwen3.5-0.6b-int8")
        assert resp.status_code == 400


class TestChatCompletions:
    """POST /v1/chat/completions"""

    def test_basic_completion(self, client, sample_chat_request):
        resp = client.post("/v1/chat/completions", json=sample_chat_request)
        assert resp.status_code == 200
        data = resp.json()
        assert data["object"] == "chat.completion"
        assert data["model"] == sample_chat_request["model"]
        assert len(data["choices"]) == 1
        choice = data["choices"][0]
        assert choice["finish_reason"] == "stop"
        assert choice["message"]["role"] == "assistant"
        assert len(choice["message"]["content"]) > 0

    def test_completion_has_usage(self, client, sample_chat_request):
        data = client.post("/v1/chat/completions", json=sample_chat_request).json()
        usage = data["usage"]
        assert usage["prompt_tokens"] > 0
        assert usage["completion_tokens"] > 0
        assert usage["total_tokens"] == usage["prompt_tokens"] + usage["completion_tokens"]

    def test_completion_id_format(self, client, sample_chat_request):
        data = client.post("/v1/chat/completions", json=sample_chat_request).json()
        assert data["id"].startswith("chatcmpl-")

    def test_system_fingerprint(self, client, sample_chat_request):
        data = client.post("/v1/chat/completions", json=sample_chat_request).json()
        assert data["system_fingerprint"] is not None

    def test_invalid_model_404(self, client, sample_chat_request):
        sample_chat_request["model"] = "nonexistent"
        resp = client.post("/v1/chat/completions", json=sample_chat_request)
        assert resp.status_code == 404

    def test_missing_messages_422(self, client):
        resp = client.post("/v1/chat/completions", json={"model": "qwen3.5-0.6b-int8"})
        assert resp.status_code == 422

    def test_temperature_bounds(self, client, sample_chat_request):
        """temperature must be 0..2"""
        sample_chat_request["temperature"] = 2.5
        resp = client.post("/v1/chat/completions", json=sample_chat_request)
        assert resp.status_code == 422

    def test_temperature_zero_ok(self, client, sample_chat_request):
        sample_chat_request["temperature"] = 0.0
        resp = client.post("/v1/chat/completions", json=sample_chat_request)
        assert resp.status_code == 200

    def test_streaming_sse_format(self, client, sample_chat_request):
        """Streaming response must follow SSE 'data: ...' format."""
        sample_chat_request["stream"] = True
        resp = client.post("/v1/chat/completions", json=sample_chat_request)
        assert resp.status_code == 200
        assert resp.headers["content-type"].startswith("text/event-stream")

        chunks = [
            line for line in resp.text.split("\n")
            if line.startswith("data: ")
        ]
        assert len(chunks) >= 2  # at least role + [DONE]

        # Last data line must be [DONE]
        assert chunks[-1] == "data: [DONE]"

        # First real chunk has role
        first = json.loads(chunks[0].removeprefix("data: "))
        assert first["object"] == "chat.completion.chunk"
        assert first["choices"][0]["delta"]["role"] == "assistant"

    def test_streaming_finish_reason(self, client, sample_chat_request):
        """The last non-[DONE] chunk must have finish_reason='stop'."""
        sample_chat_request["stream"] = True
        resp = client.post("/v1/chat/completions", json=sample_chat_request)

        data_lines = [
            line.removeprefix("data: ")
            for line in resp.text.split("\n")
            if line.startswith("data: ") and line != "data: [DONE]"
        ]
        last_chunk = json.loads(data_lines[-1])
        assert last_chunk["choices"][0]["finish_reason"] == "stop"


class TestEmbeddings:
    """POST /v1/embeddings"""

    def test_basic_embedding(self, client):
        resp = client.post("/v1/embeddings", json={
            "model": "qwen3.5-0.6b-int8",
            "input": "hello world",
        })
        assert resp.status_code == 200
        data = resp.json()
        assert data["object"] == "list"
        assert len(data["data"]) == 1
        assert data["data"][0]["object"] == "embedding"
        assert len(data["data"][0]["embedding"]) == 1536  # default dim

    def test_custom_dimensions(self, client):
        resp = client.post("/v1/embeddings", json={
            "model": "qwen3.5-0.6b-int8",
            "input": "hello",
            "dimensions": 256,
        })
        data = resp.json()
        assert len(data["data"][0]["embedding"]) == 256

    def test_batch_embedding(self, client):
        resp = client.post("/v1/embeddings", json={
            "model": "qwen3.5-0.6b-int8",
            "input": ["one", "two", "three"],
        })
        data = resp.json()
        assert len(data["data"]) == 3
        for i, emb in enumerate(data["data"]):
            assert emb["index"] == i

    def test_embedding_usage(self, client):
        data = client.post("/v1/embeddings", json={
            "model": "qwen3.5-0.6b-int8",
            "input": "hello",
        }).json()
        assert data["usage"]["prompt_tokens"] > 0
        assert data["usage"]["total_tokens"] > 0

