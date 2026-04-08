"""
Tests for the Data Products API — validation, RBAC, and CRUD.
"""

import json
import pytest
from httpx import AsyncClient, ASGITransport

from src.main import app
from src.data_products import (
    _validate_product_id,
    _require_write_access,
    TeamAccessUpdate,
    _PRODUCT_ID_RE,
)


# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

@pytest.fixture
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


# ---------------------------------------------------------------------------
# Product ID validation
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# TeamAccessUpdate validation
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# RBAC write guard
# ---------------------------------------------------------------------------

class TestRBACGuard:
    @pytest.mark.anyio
    async def test_rejects_missing_header(self):
        from fastapi import HTTPException
        from unittest.mock import MagicMock
        req = MagicMock()
        req.url = "http://test/data-products/products/foo"
        with pytest.raises(HTTPException) as exc:
            await _require_write_access(req, None)
        assert exc.value.status_code == 403

    @pytest.mark.anyio
    async def test_rejects_read_role_json(self):
        from fastapi import HTTPException
        from unittest.mock import MagicMock
        req = MagicMock()
        req.url = "http://test/data-products/products/foo"
        header = json.dumps({"country": "AE", "domain": "treasury", "role": "viewer"})
        with pytest.raises(HTTPException) as exc:
            await _require_write_access(req, header)
        assert exc.value.status_code == 403

    @pytest.mark.anyio
    async def test_allows_write_role_json(self):
        from unittest.mock import MagicMock
        req = MagicMock()
        req.url = "http://test/data-products/products/foo"
        header = json.dumps({"country": "AE", "domain": "treasury", "role": "write"})
        result = await _require_write_access(req, header)
        assert result == header

    @pytest.mark.anyio
    async def test_allows_admin_role_json(self):
        from unittest.mock import MagicMock
        req = MagicMock()
        req.url = "http://test/data-products/products/foo"
        header = json.dumps({"country": "AE", "domain": "treasury", "role": "admin"})
        result = await _require_write_access(req, header)
        assert result == header

    @pytest.mark.anyio
    async def test_allows_colon_delimited_admin(self):
        from unittest.mock import MagicMock
        req = MagicMock()
        req.url = "http://test/data-products/products/foo"
        header = "AE:treasury:team-1:admin"
        result = await _require_write_access(req, header)
        assert result == header

    @pytest.mark.anyio
    async def test_rejects_colon_delimited_viewer(self):
        from fastapi import HTTPException
        from unittest.mock import MagicMock
        req = MagicMock()
        req.url = "http://test/data-products/products/foo"
        header = "AE:treasury:team-1:viewer"
        with pytest.raises(HTTPException) as exc:
            await _require_write_access(req, header)
        assert exc.value.status_code == 403

    @pytest.mark.anyio
    async def test_rejects_malformed_json(self):
        from fastapi import HTTPException
        from unittest.mock import MagicMock
        req = MagicMock()
        req.url = "http://test/data-products/products/foo"
        with pytest.raises(HTTPException) as exc:
            await _require_write_access(req, "{bad json")
        assert exc.value.status_code == 400


# ---------------------------------------------------------------------------
# API integration: list products
# ---------------------------------------------------------------------------

@pytest.mark.anyio
async def test_list_products(client: AsyncClient):
    response = await client.get("/data-products/products")
    assert response.status_code == 200
    data = response.json()
    assert isinstance(data, list)


@pytest.mark.anyio
async def test_get_product_invalid_id(client: AsyncClient):
    response = await client.get("/data-products/products/../../etc/passwd")
    assert response.status_code in (400, 404, 422)


@pytest.mark.anyio
async def test_update_product_requires_auth(client: AsyncClient):
    """PATCH without X-Team-Context header should be rejected."""
    response = await client.patch(
        "/data-products/products/treasury-capital-markets-v1",
        json={"teamAccess": {"defaultAccess": "read"}},
    )
    assert response.status_code == 403


@pytest.mark.anyio
async def test_update_product_rejects_viewer(client: AsyncClient):
    """PATCH with viewer role should be rejected."""
    response = await client.patch(
        "/data-products/products/treasury-capital-markets-v1",
        json={"teamAccess": {"defaultAccess": "read"}},
        headers={"X-Team-Context": json.dumps({"country": "AE", "domain": "treasury", "role": "viewer"})},
    )
    assert response.status_code == 403


@pytest.mark.anyio
async def test_registry_endpoint(client: AsyncClient):
    response = await client.get("/data-products/registry")
    assert response.status_code == 200
    data = response.json()
    assert isinstance(data, dict)
