"""
Tests for the Data Products API — validation, authz, and path resolution.
"""

from __future__ import annotations

import json
import shutil
import uuid
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient

import src.data_products as data_products_module
from src.data_products import TeamAccessUpdate, _PRODUCT_ID_RE, _validate_product_id
from src.main import app
from src.store import UserRecord

EDGE_HEADERS = {
    "X-Auth-Request-Email": "sap.operator@example.com",
    "X-Auth-Request-Name": "SAP Operator",
}
TEAM_CONTEXT_HEADER = json.dumps({"country": "AE", "domain": "treasury"})
REPO_DATA_PRODUCTS_DIR = Path("/Users/user/Documents/sap-oss/src/training/data_products")


@pytest.fixture
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


@pytest.fixture
def isolated_data_products_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    target = tmp_path / "data_products"
    shutil.copytree(REPO_DATA_PRODUCTS_DIR, target)
    monkeypatch.setattr(data_products_module, "DATA_PRODUCTS_DIR", target)
    return target


def _set_user_role(email: str, role: str | None) -> None:
    db = data_products_module.get_store().SessionLocal()
    try:
        db.query(UserRecord).filter(UserRecord.email == email).delete()
        if role is not None:
            db.add(
                UserRecord(
                    id=f"user-{uuid.uuid4().hex[:12]}",
                    email=email,
                    display_name="SAP Operator",
                    initials="SO",
                    team_name="Launch",
                    role=role,
                    password_hash="external-auth",
                    auth_source="edge_header",
                )
            )
        db.commit()
    finally:
        db.close()


class TestProductIdValidation:
    def test_valid_ids(self):
        assert _validate_product_id("treasury-capital-markets-v1") == "treasury-capital-markets-v1"
        assert _validate_product_id("esg_sustainability") == "esg_sustainability"
        assert _validate_product_id("product.v2") == "product.v2"
        assert _validate_product_id("A123") == "A123"

    def test_rejects_path_traversal(self):
        from fastapi import HTTPException

        with pytest.raises(HTTPException) as exc:
            _validate_product_id("../../etc/passwd")
        assert exc.value.status_code == 400

    def test_rejects_slash(self):
        from fastapi import HTTPException

        with pytest.raises(HTTPException):
            _validate_product_id("foo/bar")

    def test_rejects_backslash(self):
        from fastapi import HTTPException

        with pytest.raises(HTTPException):
            _validate_product_id("foo\\bar")

    def test_rejects_empty(self):
        from fastapi import HTTPException

        with pytest.raises(HTTPException):
            _validate_product_id("")

    def test_rejects_leading_dot(self):
        from fastapi import HTTPException

        with pytest.raises(HTTPException):
            _validate_product_id(".hidden")

    def test_rejects_too_long(self):
        from fastapi import HTTPException

        with pytest.raises(HTTPException):
            _validate_product_id("a" * 200)

    def test_regex_pattern(self):
        assert _PRODUCT_ID_RE.match("valid-id-123")
        assert _PRODUCT_ID_RE.match("A")
        assert not _PRODUCT_ID_RE.match("")
        assert not _PRODUCT_ID_RE.match("-starts-with-dash")
        assert not _PRODUCT_ID_RE.match(".starts-with-dot")


class TestTeamAccessValidation:
    def test_valid_access(self):
        access = TeamAccessUpdate(
            defaultAccess="write",
            domainRestrictions=["treasury", "esg"],
            countryRestrictions=["AE", "GB"],
        )
        assert access.defaultAccess == "write"
        assert access.domainRestrictions == ["treasury", "esg"]

    def test_normalizes_access_to_lowercase(self):
        access = TeamAccessUpdate(defaultAccess="ADMIN")
        assert access.defaultAccess == "admin"

    def test_rejects_invalid_access_level(self):
        with pytest.raises(Exception):
            TeamAccessUpdate(defaultAccess="superuser")

    def test_rejects_invalid_restriction_chars(self):
        with pytest.raises(Exception):
            TeamAccessUpdate(domainRestrictions=["valid", "../../bad"])

    def test_strips_empty_restrictions(self):
        access = TeamAccessUpdate(domainRestrictions=["treasury", "", "  ", "esg"])
        assert access.domainRestrictions == ["treasury", "esg"]

    def test_max_length_restriction_items(self):
        access = TeamAccessUpdate(domainRestrictions=["a" * 64])
        assert len(access.domainRestrictions) == 1

    def test_rejects_overlong_restriction_item(self):
        with pytest.raises(Exception):
            TeamAccessUpdate(domainRestrictions=["a" * 65])


def test_default_data_products_dir_points_to_real_repo_data():
    assert data_products_module.DATA_PRODUCTS_DIR.exists()
    assert (data_products_module.DATA_PRODUCTS_DIR / "registry.yaml").exists()


def test_resolve_default_data_products_dir_handles_shallow_container_layout(tmp_path: Path):
    container_src = tmp_path / "app" / "src"
    container_src.mkdir(parents=True)

    resolved = data_products_module._resolve_default_data_products_dir(container_src)

    assert resolved == container_src / "data_products"


def test_resolve_default_data_products_dir_prefers_mounted_training_repo_data(tmp_path: Path):
    container_src = tmp_path / "app" / "src"
    mounted_repo_data = container_src / "training" / "data_products"
    mounted_repo_data.mkdir(parents=True)

    resolved = data_products_module._resolve_default_data_products_dir(container_src)

    assert resolved == mounted_repo_data


@pytest.mark.anyio
async def test_list_products(client: AsyncClient, isolated_data_products_dir: Path):
    response = await client.get("/data-products/products")
    assert response.status_code == 200
    data = response.json()
    assert isinstance(data, list)
    assert len(data) > 0


@pytest.mark.anyio
async def test_get_product_invalid_id(client: AsyncClient):
    response = await client.get("/data-products/products/../../etc/passwd")
    assert response.status_code in (400, 404, 422)


@pytest.mark.anyio
async def test_update_product_requires_authenticated_writer(
    client: AsyncClient,
    isolated_data_products_dir: Path,
):
    response = await client.patch(
        "/data-products/products/treasury-capital-markets-v1",
        json={"teamAccess": {"defaultAccess": "read"}},
        headers={"X-Team-Context": TEAM_CONTEXT_HEADER},
    )
    assert response.status_code == 403


@pytest.mark.anyio
async def test_update_product_rejects_spoofed_client_role_header(
    client: AsyncClient,
    isolated_data_products_dir: Path,
):
    _set_user_role(EDGE_HEADERS["X-Auth-Request-Email"].lower(), "viewer")

    response = await client.patch(
        "/data-products/products/treasury-capital-markets-v1",
        json={"teamAccess": {"defaultAccess": "read"}},
        headers={
            **EDGE_HEADERS,
            "X-Team-Context": json.dumps({"country": "AE", "domain": "treasury", "role": "admin"}),
        },
    )
    assert response.status_code == 403


@pytest.mark.anyio
async def test_update_product_allows_authenticated_admin_user(
    client: AsyncClient,
    isolated_data_products_dir: Path,
):
    _set_user_role(EDGE_HEADERS["X-Auth-Request-Email"].lower(), "admin")

    response = await client.patch(
        "/data-products/products/treasury-capital-markets-v1",
        json={"teamAccess": {"defaultAccess": "write"}},
        headers={**EDGE_HEADERS, "X-Team-Context": TEAM_CONTEXT_HEADER},
    )
    assert response.status_code == 200

    filename = data_products_module._find_product_file("treasury-capital-markets-v1")
    assert filename is not None
    updated = data_products_module._load_product_yaml(filename)
    assert updated["dataProduct"]["x-team-access"]["defaultAccess"] == "write"


@pytest.mark.anyio
async def test_registry_endpoint(client: AsyncClient, isolated_data_products_dir: Path):
    response = await client.get("/data-products/registry")
    assert response.status_code == 200
    data = response.json()
    assert isinstance(data, dict)
    assert data.get("products")
