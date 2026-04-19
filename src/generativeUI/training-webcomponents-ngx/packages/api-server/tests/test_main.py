"""
Tests for the Training Console API Server.
"""

import base64
import json
import uuid

import pytest
from httpx import AsyncClient, ASGITransport

# Import the app with lifespan management
import src.main as main_module
import src.personal_knowledge as personal_knowledge_module
from src.main import app
from src.store import WorkspaceSettingsRecord

EDGE_HEADERS = {"X-Auth-Request-Email": "sap.operator@example.com", "X-Auth-Request-Name": "SAP Operator"}


@pytest.fixture
async def client():
    """Async test client using the ASGI transport (no real HTTP)."""
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


@pytest.mark.anyio
async def test_health_returns_200(client: AsyncClient):
    """GET /health returns 200 with the expected shape."""
    response = await client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] in {"healthy", "degraded", "unavailable"}
    assert data["service"] == "training-webcomponents-ngx-api"
    assert "dependencies" in data


@pytest.mark.anyio
async def test_health_includes_mode(client: AsyncClient):
    """GET /health includes dependency details for the runtime services."""
    response = await client.get("/health")
    data = response.json()
    assert set(data["dependencies"]).issuperset({"database", "hana_vector", "vllm_turboquant"})


@pytest.mark.anyio
async def test_unknown_endpoint_returns_404(client: AsyncClient):
    """Unknown routes return 404."""
    response = await client.get("/not-a-real-endpoint-xyz")
    assert response.status_code == 404


@pytest.mark.anyio
async def test_large_body_rejected(client: AsyncClient):
    """POST with body exceeding MAX_BODY_BYTES returns 413."""
    big_body = b"x" * (11 * 1024 * 1024)  # 11 MB > 10 MB limit
    response = await client.post("/jobs", content=big_body)
    assert response.status_code in (413, 422)


@pytest.mark.anyio
async def test_data_cleaning_health_native(client: AsyncClient):
    response = await client.get("/data-cleaning/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    assert response.json()["mode"] == "native"


@pytest.mark.anyio
async def test_data_cleaning_chat_native(client: AsyncClient):
    response = await client.post("/data-cleaning/chat", json={"message": "Find nulls"})
    assert response.status_code == 200
    assert "Generated" in response.json()["response"]


@pytest.mark.anyio
async def test_data_cleaning_workflow_native(client: AsyncClient):
    chat_response = await client.post("/data-cleaning/chat", json={"message": "Check duplicates and nulls"})
    assert chat_response.status_code == 200

    run_response = await client.post("/data-cleaning/workflow/run", json={"message": "Prepare training data"})
    assert run_response.status_code == 200
    run_id = run_response.json()["run_id"]

    for _ in range(20):
        status_response = await client.get(f"/data-cleaning/workflow/{run_id}")
        assert status_response.status_code == 200
        if status_response.json()["status"] in {"completed", "failed"}:
            break
    else:
        pytest.fail("Workflow did not reach terminal state in time")

    events_response = await client.get(f"/data-cleaning/workflow/{run_id}/events")
    assert events_response.status_code == 200
    assert len(events_response.json()["events"]) > 0


@pytest.mark.anyio
async def test_training_job_validate_alias_creates_governance_run_when_blocked(client: AsyncClient):
    main_module.ensure_training_governance_seed_defaults()
    response = await client.post(
        "/jobs/training",
        json={"team": "finance", "examples_per_domain": 25, "validate": False},
    )
    assert response.status_code == 409
    detail = response.json()["detail"]
    assert detail["governance_run_id"]
    assert any(check["gate_key"] == "validation_enabled" for check in detail["blocking_checks"])

    run_response = await client.get(f"/governance/training-runs/{detail['governance_run_id']}")
    assert run_response.status_code == 200
    run = run_response.json()
    assert run["workflow_type"] == "pipeline"
    assert run["config_json"]["validate"] is False
    assert run["gate_status"] == "blocked"


@pytest.mark.anyio
async def test_training_generation_auto_creates_governance_summary_on_success(
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
):
    main_module.ensure_training_governance_seed_defaults()

    async def fake_run_training_generation(
        job_id: str,
        team: str,
        examples_per_domain: int,
        validate: bool,
        governance_run_id: str | None = None,
    ):
        return None

    monkeypatch.setattr(main_module, "_run_training_generation", fake_run_training_generation)

    response = await client.post(
        "/jobs/training",
        json={"team": "finance", "examples_per_domain": 25, "validate": True},
    )
    assert response.status_code == 201
    payload = response.json()
    assert payload["governance"]["workflow_type"] == "pipeline"
    assert payload["governance"]["run_id"]

    job_response = await client.get(f"/jobs/{payload['job_id']}")
    assert job_response.status_code == 200
    assert job_response.json()["governance"]["run_id"] == payload["governance"]["run_id"]


@pytest.mark.anyio
async def test_governance_policies_seeded(client: AsyncClient):
    main_module.ensure_training_governance_seed_defaults()
    response = await client.get("/governance/policies")
    assert response.status_code == 200
    data = response.json()
    assert len(data["policies"]) >= 4
    assert any(policy["id"] == "training-policy-deployment-approval" for policy in data["policies"])


@pytest.mark.anyio
async def test_governance_approval_persists_for_high_cost_optimization_run(client: AsyncClient):
    main_module.ensure_training_governance_seed_defaults()
    create_response = await client.post(
        "/governance/training-runs",
        json={
            "workflow_type": "optimization",
            "run_name": "Large optimization",
            "requested_by": "reviewer@example.com",
            "team": "platform",
            "model_name": "meta-llama/Llama-3-8B-Instruct",
            "config_json": {"estimated_size_gb": 16.1, "quant_format": "int8"},
        },
    )
    assert create_response.status_code == 201
    created_run = create_response.json()
    assert created_run["approval_status"] == "pending"
    assert created_run["approvals"]

    approval_id = created_run["approvals"][0]["id"]
    decide_response = await client.post(
        f"/governance/approvals/{approval_id}/decide",
        json={"approver": "risk-owner", "action": "approve", "comment": "Risk accepted"},
    )
    assert decide_response.status_code == 200
    assert decide_response.json()["status"] == "pending"

    second_decision = await client.post(
        f"/governance/approvals/{approval_id}/decide",
        json={"approver": "team-lead", "action": "approve", "comment": "Operationally approved"},
    )
    assert second_decision.status_code == 200
    assert second_decision.json()["status"] == "approved"

    approvals_response = await client.get("/governance/approvals", params={"status": "approved"})
    assert approvals_response.status_code == 200
    approvals = approvals_response.json()["approvals"]
    assert any(approval["id"] == approval_id for approval in approvals)


@pytest.mark.anyio
async def test_governed_launch_links_job_and_governance_summary(
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
):
    main_module.ensure_training_governance_seed_defaults()

    async def fake_real_worker_task(job_id: str, governance_run_id: str | None = None):
        return None

    monkeypatch.setattr(main_module, "real_worker_task", fake_real_worker_task)

    create_response = await client.post(
        "/governance/training-runs",
        json={
            "workflow_type": "optimization",
            "run_name": "Small optimization",
            "requested_by": "operator@example.com",
            "team": "platform",
            "model_name": "gpt2",
            "config_json": {"quant_format": "int8"},
        },
    )
    assert create_response.status_code == 201
    run_id = create_response.json()["id"]

    submit_response = await client.post(f"/governance/training-runs/{run_id}/submit")
    assert submit_response.status_code == 200

    launch_response = await client.post(f"/governance/training-runs/{run_id}/launch")
    assert launch_response.status_code == 200
    launched_run = launch_response.json()
    assert launched_run["job_id"]
    assert launched_run["status"] == "running"

    job_response = await client.get(f"/jobs/{launched_run['job_id']}")
    assert job_response.status_code == 200
    assert job_response.json()["governance"]["run_id"] == run_id
    assert job_response.json()["governance"]["workflow_type"] == "optimization"


@pytest.mark.anyio
async def test_raw_jobs_endpoint_auto_creates_governance_run(
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
):
    main_module.ensure_training_governance_seed_defaults()

    async def fake_real_worker_task(job_id: str, governance_run_id: str | None = None):
        return None

    monkeypatch.setattr(main_module, "real_worker_task", fake_real_worker_task)

    response = await client.post(
        "/jobs",
        json={"config": {"model_name": "gpt2", "quant_format": "int8"}},
    )
    assert response.status_code == 201
    payload = response.json()
    assert payload["governance"]["workflow_type"] == "optimization"

    run_response = await client.get(f"/governance/training-runs/{payload['governance']['run_id']}")
    assert run_response.status_code == 200
    run = run_response.json()
    assert run["job_id"] == payload["id"]
    assert run["status"] == "running"


@pytest.mark.anyio
async def test_pipeline_start_auto_creates_governance_run(
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
):
    main_module.ensure_training_governance_seed_defaults()

    async def fake_run_pipeline_worker(
        governance_run_id: str | None = None,
        job_id: str | None = None,
    ):
        return None

    monkeypatch.setattr(main_module, "run_pipeline_worker", fake_run_pipeline_worker)

    response = await client.post("/pipeline/start", json={})
    assert response.status_code == 200
    payload = response.json()
    assert payload["governance_run_id"]
    assert payload["job_id"]

    run_response = await client.get(f"/governance/training-runs/{payload['governance_run_id']}")
    assert run_response.status_code == 200
    run = run_response.json()
    assert run["workflow_type"] == "pipeline"
    assert run["job_id"] == payload["job_id"]

    job_response = await client.get(f"/jobs/{payload['job_id']}")
    assert job_response.status_code == 200
    assert job_response.json()["governance"]["run_id"] == payload["governance_run_id"]


@pytest.mark.anyio
async def test_deploy_endpoint_auto_creates_deployment_run_when_missing(client: AsyncClient):
    main_module.ensure_training_governance_seed_defaults()
    job_id = f"job-{uuid.uuid4().hex[:8]}"
    main_module.save_job(
        {
            "id": job_id,
            "status": "completed",
            "progress": 100.0,
            "config": {"model_name": "gpt2", "quant_format": "int8"},
            "history": [],
            "deployed": False,
            "evaluation": {"eval_loss": 1.2, "perplexity": 3.4, "runtime_sec": 8.5},
            "error": None,
        }
    )

    response = await client.post(f"/jobs/{job_id}/deploy")
    assert response.status_code == 409
    detail = response.json()["detail"]
    assert detail["governance_run_id"]
    assert any(check["gate_key"] == "required_approvals" for check in detail["blocking_checks"])

    run_response = await client.get(f"/governance/training-runs/{detail['governance_run_id']}")
    assert run_response.status_code == 200
    run = run_response.json()
    assert run["workflow_type"] == "deployment"
    assert run["job_id"] == job_id
    assert run["approval_status"] == "pending"


@pytest.mark.anyio
async def test_hana_stats_falls_back_to_preview_when_unconfigured(client: AsyncClient, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(main_module, "HANA_HOST", "")
    monkeypatch.setattr(main_module, "HANA_USER", "")
    monkeypatch.setattr(main_module, "HANA_PASSWORD", "")

    response = await client.get("/hana/stats")
    assert response.status_code == 200
    data = response.json()
    assert data["mode"] == "preview"
    assert data["reason"] == "credentials_missing"


@pytest.mark.anyio
async def test_hana_query_returns_preview_rows_when_unconfigured(client: AsyncClient, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(main_module, "HANA_HOST", "")
    monkeypatch.setattr(main_module, "HANA_USER", "")
    monkeypatch.setattr(main_module, "HANA_PASSWORD", "")

    response = await client.post("/hana/query", json={"sql": "SELECT COUNT(*) AS total FROM TRAINING_PAIRS"})
    assert response.status_code == 200
    data = response.json()
    assert data["mode"] == "preview"
    assert data["reason"] == "credentials_missing"
    assert data["rows"][0]["total"] == 13952


@pytest.mark.anyio
async def test_hana_query_rejects_non_read_only_sql(client: AsyncClient):
    response = await client.post("/hana/query", json={"sql": "DELETE FROM TRAINING_PAIRS"})
    assert response.status_code == 400
    assert "read-only" in response.json()["detail"]


@pytest.mark.anyio
async def test_personal_knowledge_preview_flow(client: AsyncClient, monkeypatch: pytest.MonkeyPatch):
    personal_knowledge_module._backend = None
    monkeypatch.setattr(personal_knowledge_module, "HANA_HOST", "")
    monkeypatch.setattr(personal_knowledge_module, "HANA_USER", "")
    monkeypatch.setattr(personal_knowledge_module, "HANA_PASSWORD", "")

    async def fake_embed_texts(texts: list[str], model: str) -> list[list[float]]:
        return [personal_knowledge_module._local_embedding(text) for text in texts]

    monkeypatch.setattr(personal_knowledge_module, "_embed_texts", fake_embed_texts)

    create_response = await client.post(
        "/knowledge/bases",
        json={
            "name": "Field Notes",
            "description": "Daily observations",
            "embedding_model": "default",
        },
        headers=EDGE_HEADERS,
    )
    assert create_response.status_code == 201
    created = create_response.json()
    assert created["storage_backend"] == "preview"
    assert created["wiki_pages"] == 1
    assert created["owner_id"] == EDGE_HEADERS["X-Auth-Request-Email"].lower()

    add_response = await client.post(
        f"/knowledge/bases/{created['id']}/documents",
        json={
            "documents": [
                "Alice met the HANA team and documented the rollout plan.",
                "The product launch depends on a personal wiki and durable memory.",
            ],
        },
        headers=EDGE_HEADERS,
    )
    assert add_response.status_code == 200
    assert add_response.json()["documents_added"] == 2

    query_response = await client.post(
        f"/knowledge/bases/{created['id']}/query",
        json={
            "query": "What matters for the launch?",
            "k": 3,
        },
        headers=EDGE_HEADERS,
    )
    assert query_response.status_code == 200
    query_data = query_response.json()
    assert query_data["source"] == "preview"
    assert len(query_data["context_docs"]) >= 1
    assert query_data["suggested_wiki_page"] == "overview"

    list_response = await client.get("/knowledge/bases", headers=EDGE_HEADERS)
    assert list_response.status_code == 200
    listed = list_response.json()
    assert listed[0]["documents_added"] == 2
    assert listed[0]["wiki_pages"] == 1

    wiki_response = await client.get(
        f"/knowledge/bases/{created['id']}/wiki",
        headers=EDGE_HEADERS,
    )
    assert wiki_response.status_code == 200
    wiki_pages = wiki_response.json()
    assert wiki_pages[0]["slug"] == "overview"
    assert "What this knowledge base currently knows" in wiki_pages[0]["content"]


@pytest.mark.anyio
async def test_personal_knowledge_wiki_update(client: AsyncClient, monkeypatch: pytest.MonkeyPatch):
    personal_knowledge_module._backend = None
    monkeypatch.setattr(personal_knowledge_module, "HANA_HOST", "")
    monkeypatch.setattr(personal_knowledge_module, "HANA_USER", "")
    monkeypatch.setattr(personal_knowledge_module, "HANA_PASSWORD", "")

    async def fake_embed_texts(texts: list[str], model: str) -> list[list[float]]:
        return [personal_knowledge_module._local_embedding(text) for text in texts]

    monkeypatch.setattr(personal_knowledge_module, "_embed_texts", fake_embed_texts)

    create_response = await client.post(
        "/knowledge/bases",
        json={"name": "Mission Control"},
        headers=EDGE_HEADERS,
    )
    base_id = create_response.json()["id"]

    update_response = await client.put(
        f"/knowledge/bases/{base_id}/wiki/launch-brief",
        json={
            "title": "Launch Brief",
            "content": "Ship a personal memory system that learns from documents, notes, and activity.",
        },
        headers=EDGE_HEADERS,
    )
    assert update_response.status_code == 200
    updated = update_response.json()
    assert updated["slug"] == "launch-brief"
    assert updated["generated"] is False

    wiki_response = await client.get(
        f"/knowledge/bases/{base_id}/wiki",
        headers=EDGE_HEADERS,
    )
    assert wiki_response.status_code == 200
    slugs = {page["slug"] for page in wiki_response.json()}
    assert {"overview", "launch-brief"}.issubset(slugs)


@pytest.mark.anyio
async def test_personal_knowledge_graph_summary_and_query(client: AsyncClient, monkeypatch: pytest.MonkeyPatch):
    personal_knowledge_module._backend = None
    monkeypatch.setattr(personal_knowledge_module, "HANA_HOST", "")
    monkeypatch.setattr(personal_knowledge_module, "HANA_USER", "")
    monkeypatch.setattr(personal_knowledge_module, "HANA_PASSWORD", "")

    async def fake_embed_texts(texts: list[str], model: str) -> list[list[float]]:
        return [personal_knowledge_module._local_embedding(text) for text in texts]

    monkeypatch.setattr(personal_knowledge_module, "_embed_texts", fake_embed_texts)

    create_response = await client.post(
        "/knowledge/bases",
        json={"name": "Operating Memory"},
        headers=EDGE_HEADERS,
    )
    base_id = create_response.json()["id"]

    await client.post(
        f"/knowledge/bases/{base_id}/documents",
        json={
            "documents": [
                "Alice owns the launch plan and coordinates the HANA rollout.",
                "Bob maintains the personal wiki and reviews customer findings.",
            ],
            "metadatas": [
                {"file_name": "launch-plan.md", "source": "chat"},
                {"file_name": "customer-findings.md", "source": "ocr"},
            ],
        },
        headers=EDGE_HEADERS,
    )

    summary_response = await client.get(
        "/knowledge/graph/summary",
        params={"base_id": base_id},
        headers=EDGE_HEADERS,
    )
    assert summary_response.status_code == 200
    summary_data = summary_response.json()
    assert summary_data["node_count"] >= 4
    assert summary_data["edge_count"] >= 3
    assert summary_data["status"] == "preview_ready"

    graph_response = await client.post(
        "/knowledge/graph/query",
        json={
          "base_id": base_id,
          "query": "show graph relationships",
          "limit": 20,
        },
        headers=EDGE_HEADERS,
    )
    assert graph_response.status_code == 200
    graph_rows = graph_response.json()["rows"]
    assert graph_rows
    assert any(row["relationship"] == "contains" for row in graph_rows)
    assert any(row["target_type"] in {"Document", "Concept", "WikiPage"} for row in graph_rows)


@pytest.mark.anyio
async def test_workspace_bootstrap_and_save_follow_authenticated_identity(client: AsyncClient):
    db = main_module.SessionLocal()
    try:
        db.query(WorkspaceSettingsRecord).filter(
            WorkspaceSettingsRecord.owner_id == "sap.operator@example.com"
        ).delete()
        db.commit()
    finally:
        db.close()

    bootstrap = await client.get("/workspace", headers=EDGE_HEADERS)
    assert bootstrap.status_code == 200
    bootstrap_data = bootstrap.json()
    assert bootstrap_data["identity"]["userId"] == "sap.operator@example.com"
    assert bootstrap_data["authenticated"] is True
    assert bootstrap_data["auth_source"] == "edge_header"
    assert bootstrap_data["settings"]["backend"]["apiBaseUrl"] == "/api"
    assert bootstrap_data["settings"]["backend"]["openAiBaseUrl"] == "/api/v1/ui5/openai"
    assert bootstrap_data["settings"]["backend"]["mcpBaseUrl"] == "/api/v1/ui5/mcp/mcp"
    assert bootstrap_data["settings"]["backend"]["agUiEndpoint"] == "/ag-ui/run"
    assert bootstrap_data["settings"]["nav"]["defaultLandingPath"] == "/"
    assert bootstrap_data["settings"]["nav"]["items"][0]["route"] == "/dashboard"
    assert bootstrap_data["settings"]["nav"]["items"][0]["path"] == "/dashboard"

    save_response = await client.put(
        "/workspace",
        headers=EDGE_HEADERS,
        json={
            "version": 1,
            "identity": {
                "userId": "spoofed@example.com",
                "displayName": "Spoofed User",
                "teamName": "Launch",
            },
            "backend": {"apiBaseUrl": "/api", "collabWsUrl": "/collab"},
            "nav": {"items": []},
            "model": {"defaultModel": "", "temperature": 0.7, "systemPrompt": ""},
            "theme": "sap_horizon",
            "language": "en",
            "updatedAt": "2026-04-09T00:00:00Z",
        },
    )
    assert save_response.status_code == 403

    allowed_save = await client.put(
        "/workspace",
        headers=EDGE_HEADERS,
        json={
            "version": 1,
            "identity": {
                "userId": "sap.operator@example.com",
                "displayName": "Ignored By Server",
                "teamName": "Launch",
            },
            "backend": {"apiBaseUrl": "/api", "collabWsUrl": "/collab"},
            "nav": {"items": [{"route": "/dashboard", "visible": True, "order": 0}]},
            "model": {"defaultModel": "claude", "temperature": 0.6, "systemPrompt": "Use memory"},
            "theme": "sap_horizon_dark",
            "language": "en",
            "updatedAt": "2026-04-09T00:00:00Z",
        },
    )
    assert allowed_save.status_code == 200
    saved = allowed_save.json()
    assert saved["identity"]["userId"] == "sap.operator@example.com"
    assert saved["identity"]["displayName"] == "SAP Operator"
    assert saved["identity"]["teamName"] == "Launch"

    reloaded = await client.get("/workspace", headers=EDGE_HEADERS)
    assert reloaded.status_code == 200
    reloaded_data = reloaded.json()
    assert reloaded_data["settings"]["identity"]["userId"] == "sap.operator@example.com"
    assert reloaded_data["settings"]["identity"]["displayName"] == "SAP Operator"
    assert reloaded_data["settings"]["identity"]["teamName"] == "Launch"
    assert reloaded_data["settings"]["nav"]["items"][0]["route"] == "/dashboard"
    assert reloaded_data["settings"]["nav"]["items"][0]["path"] == "/dashboard"
    assert reloaded_data["settings"]["backend"]["openAiBaseUrl"] == "/api/v1/ui5/openai"


@pytest.mark.anyio
async def test_workspace_hint_headers_are_ignored_without_opt_in(client: AsyncClient, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.delenv("ALLOW_UNAUTHENTICATED_WORKSPACE_HINTS", raising=False)

    response = await client.get(
        "/workspace",
        headers={
            "X-Workspace-User": "shared-ws",
            "X-Workspace-Display-Name": "Shared Workspace",
        },
    )
    assert response.status_code == 200
    data = response.json()
    assert data["identity"]["userId"] == "personal-user"
    assert data["auth_source"] == "preview_fallback"
    assert data["authenticated"] is False


@pytest.mark.anyio
async def test_workspace_rejects_unauthenticated_owner_override(client: AsyncClient):
    response = await client.put(
        "/workspace",
        json={
            "version": 1,
            "identity": {
                "userId": "spoofed-user",
                "displayName": "Spoofed User",
                "teamName": "Launch",
            },
            "backend": {"apiBaseUrl": "/api", "collabWsUrl": "/collab"},
            "nav": {"items": []},
            "model": {"defaultModel": "", "temperature": 0.7, "systemPrompt": ""},
            "theme": "sap_horizon",
            "language": "en",
            "updatedAt": "2026-04-09T00:00:00Z",
        },
    )
    assert response.status_code == 403


@pytest.mark.anyio
async def test_personal_knowledge_rejects_unauthenticated_owner_override(
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
):
    personal_knowledge_module._backend = None
    monkeypatch.setattr(personal_knowledge_module, "HANA_HOST", "")
    monkeypatch.setattr(personal_knowledge_module, "HANA_USER", "")
    monkeypatch.setattr(personal_knowledge_module, "HANA_PASSWORD", "")

    response = await client.post(
        "/knowledge/bases",
        json={
            "owner_id": "someone-else",
            "name": "Blocked Override",
        },
    )
    assert response.status_code == 403


@pytest.mark.anyio
async def test_invalid_bearer_token_is_not_treated_as_authenticated(client: AsyncClient):
    payload = base64.urlsafe_b64encode(
        json.dumps({"sub": "fake-user", "email": "fake@example.com"}).encode("utf-8")
    ).rstrip(b"=").decode("ascii")
    fake_token = f"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.{payload}.invalid-signature"

    response = await client.get("/workspace", headers={"Authorization": f"Bearer {fake_token}"})
    assert response.status_code == 200
    data = response.json()
    assert data["authenticated"] is False
    assert data["auth_source"] == "preview_fallback"
    assert data["identity"]["userId"] == "personal-user"


@pytest.mark.anyio
async def test_local_auth_register_requires_secure_secret(client: AsyncClient, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.delenv("AUTH_JWT_SECRET", raising=False)

    response = await client.post(
        "/auth/register",
        json={
            "email": "new.user@example.com",
            "password": "supersecret123",
            "display_name": "New User",
        },
    )
    assert response.status_code == 503


@pytest.mark.anyio
async def test_local_auth_register_and_me_with_configured_secret(
    client: AsyncClient,
    monkeypatch: pytest.MonkeyPatch,
):
    monkeypatch.setenv("AUTH_JWT_SECRET", "unit-test-secret-1234567890")
    email = f"codex-{uuid.uuid4().hex[:8]}@example.com"

    register_response = await client.post(
        "/auth/register",
        json={
            "email": email,
            "password": "supersecret123",
            "display_name": "Codex Operator",
        },
    )
    assert register_response.status_code == 201
    token = register_response.json()["token"]

    me_response = await client.get("/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert me_response.status_code == 200
    profile = me_response.json()
    assert profile["email"] == email
    assert profile["role"] == "user"
