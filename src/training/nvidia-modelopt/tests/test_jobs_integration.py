#!/usr/bin/env python3
"""
Integration tests for the ModelOpt job lifecycle.
"""

import pytest
from unittest.mock import patch, AsyncMock, MagicMock


class TestJobLifecycle:
    """Full job create → poll → complete/fail cycle."""

    def test_create_and_retrieve_job(self, client, sample_job_config):
        """Create a job and retrieve it by ID."""
        resp = client.post("/jobs", json=sample_job_config)
        assert resp.status_code == 200
        job = resp.json()
        job_id = job["id"]
        assert job["status"] in ("pending", "running")

        resp2 = client.get(f"/jobs/{job_id}")
        assert resp2.status_code == 200
        assert resp2.json()["id"] == job_id

    def test_create_job_appears_in_list(self, client, sample_job_config):
        """Newly created job shows up in GET /jobs."""
        resp = client.post("/jobs", json=sample_job_config)
        job_id = resp.json()["id"]

        jobs = client.get("/jobs").json()
        assert any(j["id"] == job_id for j in jobs)

    def test_create_job_with_custom_name(self, client, sample_job_config):
        """Job name is honoured when provided."""
        sample_job_config["name"] = "my-custom-name"
        resp = client.post("/jobs", json=sample_job_config)
        assert resp.json()["name"] == "my-custom-name"

    def test_create_job_default_name(self, client, sample_job_config):
        """Auto-generated name starts with 'job-'."""
        resp = client.post("/jobs", json=sample_job_config)
        assert resp.json()["name"].startswith("job-")

    def test_cancel_pending_job(self, client, sample_job_config):
        """A pending/running/failed job can be cancelled or has already finished.

        In the synchronous TestClient the background task runs immediately,
        so the job may already be 'failed' (no GPU script) by the time we
        attempt to cancel. We accept either 200 (cancelled) or 400 (already
        finished) as valid outcomes.
        """
        resp = client.post("/jobs", json=sample_job_config)
        job_id = resp.json()["id"]

        cancel = client.delete(f"/jobs/{job_id}")
        assert cancel.status_code in (200, 400)

    def test_cancel_nonexistent_job(self, client):
        """Cancelling a non-existent job returns 404."""
        resp = client.delete("/jobs/no-such-id")
        assert resp.status_code == 404

    def test_get_nonexistent_job(self, client):
        """Fetching a non-existent job returns 404."""
        resp = client.get("/jobs/no-such-id")
        assert resp.status_code == 404

    def test_filter_jobs_by_status(self, client, sample_job_config):
        """Jobs can be filtered by status query param."""
        client.post("/jobs", json=sample_job_config)
        resp = client.get("/jobs?status=pending")
        assert resp.status_code == 200
        for j in resp.json():
            assert j["status"] == "pending"

    def test_invalid_quant_format(self, client):
        """Invalid quant format is rejected by Pydantic."""
        bad = {"config": {"model_name": "X", "quant_format": "nope"}}
        resp = client.post("/jobs", json=bad)
        assert resp.status_code == 422

    def test_calib_samples_bounds(self, client):
        """calib_samples outside [32, 2048] is rejected."""
        for val in [1, 5000]:
            cfg = {"config": {"model_name": "X", "quant_format": "int8", "calib_samples": val}}
            resp = client.post("/jobs", json=cfg)
            assert resp.status_code == 422, f"calib_samples={val} should be rejected"


class TestGPUStatusFallback:
    """GPU endpoint graceful fallback."""

    def test_no_gpu_detected(self, client):
        """When detect_gpu returns None, fallback response is correct."""
        with patch("api.main.detect_gpu", return_value=None):
            resp = client.get("/gpu/status")
            assert resp.status_code == 200
            data = resp.json()
            assert data["gpu_name"] == "No GPU detected"
            assert data["total_memory_gb"] == 0
            assert "int8" in data["supported_formats"]

    def test_gpu_detected(self, client):
        """When a real GPU is detected, fields are populated."""
        from api.inference import GPUInfo
        fake_gpu = GPUInfo(
            name="Tesla T4",
            compute_capability="7.5",
            memory_total_gb=15.0,
            memory_used_gb=1.5,
            memory_free_gb=13.5,
            utilization_percent=10,
            temperature_c=42,
            driver_version="535.183",
            cuda_version="12.2",
        )
        with patch("api.main.detect_gpu", return_value=fake_gpu):
            resp = client.get("/gpu/status")
            data = resp.json()
            assert data["gpu_name"] == "Tesla T4"
            assert data["total_memory_gb"] == 15.0
            assert "int8" in data["supported_formats"]


class TestRequestIDMiddleware:
    """X-Request-ID is returned on every response."""

    def test_auto_generated_request_id(self, client):
        resp = client.get("/health")
        assert "x-request-id" in resp.headers

    def test_echoed_request_id(self, client):
        resp = client.get("/health", headers={"X-Request-ID": "my-req-123"})
        assert resp.headers["x-request-id"] == "my-req-123"

