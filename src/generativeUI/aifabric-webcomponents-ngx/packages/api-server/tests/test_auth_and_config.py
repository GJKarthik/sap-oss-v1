import asyncio

import bcrypt
import pytest
from jose import jwt
from pydantic import ValidationError

from src.config import DEFAULT_JWT_SECRET, Settings
from src.redis_client import is_token_revoked, revoke_token
from src import seed
from src.config import settings


def _production_settings_kwargs(**overrides):
    values = {
        "_env_file": None,
        "environment": "production",
        "jwt_secret_key": "not-the-default-secret",
        "store_backend": "hana",
        "hana_host": "hana.example.test",
        "hana_user": "DBADMIN",
        "hana_password": "super-secret-password",
        "expose_api_docs": False,
        "langchain_mcp_url": "https://langchain.example.test/mcp",
        "streaming_mcp_url": "https://streaming.example.test/mcp",
        "data_cleaning_mcp_url": "https://cleaning.example.test/mcp",
    }
    values.update(overrides)
    return values


def test_production_requires_non_default_jwt_secret() -> None:
    with pytest.raises(ValidationError):
        Settings(**_production_settings_kwargs(jwt_secret_key=DEFAULT_JWT_SECRET))


def test_production_requires_hana_store_backend() -> None:
    with pytest.raises(ValidationError):
        Settings(
            **_production_settings_kwargs(
                store_backend="sqlite",
            )
        )


def test_hana_store_backend_requires_hana_credentials() -> None:
    with pytest.raises(ValidationError):
        Settings(
            environment="test",
            jwt_secret_key="unit-test-secret",
            store_backend="hana",
            hana_host="",
            hana_user="",
            hana_password="",
        )


def test_production_rejects_localhost_mcp_dependencies() -> None:
    with pytest.raises(ValidationError):
        Settings(
            **_production_settings_kwargs(
                langchain_mcp_url="http://localhost:9140/mcp",
            )
        )


def test_production_requires_bootstrap_admin_password_pairing() -> None:
    with pytest.raises(ValidationError):
        Settings(
            **_production_settings_kwargs(
                bootstrap_admin_username="bootstrap-admin",
                bootstrap_admin_password="",
            )
        )


def test_production_defaults_disable_reference_data_seeding_and_require_mcp_dependencies() -> None:
    production_settings = Settings(**_production_settings_kwargs())

    assert production_settings.seed_reference_data is False
    assert production_settings.require_mcp_dependencies is True
    assert production_settings.expose_api_docs is False


def test_production_rejects_debug_and_docs_surfaces() -> None:
    with pytest.raises(ValidationError):
        Settings(**_production_settings_kwargs(debug=True))

    with pytest.raises(ValidationError):
        Settings(**_production_settings_kwargs(expose_api_docs=True))


def test_hana_store_prefix_is_normalized() -> None:
    hana_settings = Settings(
        environment="test",
        jwt_secret_key="unit-test-secret",
        store_backend="hana",
        hana_host="hana.example.test",
        hana_user="system",
        hana_password="secret",
        hana_store_table_prefix="sap-ai-fabric store",
    )

    assert hana_settings.hana_store_table_prefix == "SAP_AI_FABRIC_STORE"


def test_login_and_me_return_the_real_user_role(client) -> None:
    response = client.post(
        "/api/v1/auth/login",
        data={"username": "admin", "password": "changeme"},
    )

    assert response.status_code == 200
    payload = response.json()

    me_response = client.get(
        "/api/v1/auth/me",
        headers={"Authorization": f"Bearer {payload['access_token']}"},
    )

    assert me_response.status_code == 200
    assert me_response.json()["username"] == "admin"
    assert me_response.json()["role"] == "admin"


def test_me_reflects_current_role_from_store_even_with_older_access_token(client, store) -> None:
    response = client.post(
        "/api/v1/auth/login",
        data={"username": "admin", "password": "changeme"},
    )
    assert response.status_code == 200

    store.mutate_record(
        "users",
        "admin",
        lambda user: {**user, "role": "viewer"},
    )

    me_response = client.get(
        "/api/v1/auth/me",
        headers={"Authorization": f"Bearer {response.json()['access_token']}"},
    )

    assert me_response.status_code == 200
    assert me_response.json()["role"] == "viewer"


def test_refresh_rotates_and_revokes_the_previous_refresh_token(client) -> None:
    response = client.post(
        "/api/v1/auth/login",
        data={"username": "admin", "password": "changeme"},
    )
    assert response.status_code == 200

    refresh_token = response.json()["refresh_token"]

    refresh_response = client.post(
        "/api/v1/auth/refresh",
        json={"refresh_token": refresh_token},
    )
    assert refresh_response.status_code == 200

    replay_response = client.post(
        "/api/v1/auth/refresh",
        json={"refresh_token": refresh_token},
    )
    assert replay_response.status_code == 401


def test_refresh_uses_current_role_from_store(client, store) -> None:
    response = client.post(
        "/api/v1/auth/login",
        data={"username": "admin", "password": "changeme"},
    )
    assert response.status_code == 200

    store.mutate_record(
        "users",
        "admin",
        lambda user: {**user, "role": "viewer"},
    )

    refresh_response = client.post(
        "/api/v1/auth/refresh",
        json={"refresh_token": response.json()["refresh_token"]},
    )

    assert refresh_response.status_code == 200

    claims = jwt.decode(
        refresh_response.json()["access_token"],
        settings.jwt_secret_key,
        algorithms=[settings.jwt_algorithm],
    )
    assert claims["role"] == "viewer"

    me_response = client.get(
        "/api/v1/auth/me",
        headers={"Authorization": f"Bearer {refresh_response.json()['access_token']}"},
    )
    assert me_response.status_code == 200
    assert me_response.json()["role"] == "viewer"


def test_inactive_user_cannot_refresh(client, store) -> None:
    response = client.post(
        "/api/v1/auth/login",
        data={"username": "admin", "password": "changeme"},
    )
    assert response.status_code == 200

    store.mutate_record(
        "users",
        "admin",
        lambda user: {**user, "is_active": False},
    )

    refresh_response = client.post(
        "/api/v1/auth/refresh",
        json={"refresh_token": response.json()["refresh_token"]},
    )

    assert refresh_response.status_code == 401


def test_logout_revokes_access_and_refresh_tokens(client) -> None:
    response = client.post(
        "/api/v1/auth/login",
        data={"username": "admin", "password": "changeme"},
    )
    assert response.status_code == 200
    token = response.json()["access_token"]
    refresh_token = response.json()["refresh_token"]
    headers = {"Authorization": f"Bearer {token}"}

    logout_response = client.post(
        "/api/v1/auth/logout",
        headers=headers,
        json={"refresh_token": refresh_token},
    )
    assert logout_response.status_code == 200

    me_response = client.get("/api/v1/auth/me", headers=headers)
    assert me_response.status_code == 401

    refresh_response = client.post(
        "/api/v1/auth/refresh",
        json={"refresh_token": refresh_token},
    )
    assert refresh_response.status_code == 401


def test_seed_store_skips_default_admin_outside_demo_envs(monkeypatch, store) -> None:
    store.clear()
    monkeypatch.setattr(seed.settings, "environment", "production")
    monkeypatch.setattr(seed.settings, "bootstrap_admin_username", "")
    monkeypatch.setattr(seed.settings, "bootstrap_admin_password", "")

    seed.seed_store()

    assert store.has_record("users", "admin") is False


def test_seed_store_can_bootstrap_configured_admin(monkeypatch, store) -> None:
    store.clear()
    monkeypatch.setattr(seed.settings, "environment", "production")
    monkeypatch.setattr(seed.settings, "bootstrap_admin_username", "bootstrap-admin")
    monkeypatch.setattr(seed.settings, "bootstrap_admin_password", "bootstrap-secret")
    monkeypatch.setattr(seed.settings, "bootstrap_admin_email", "bootstrap@example.com")

    seed.seed_store()

    user = store.get_record("users", "bootstrap-admin")
    assert user is not None
    assert user["role"] == "admin"
    assert user["email"] == "bootstrap@example.com"
    assert bcrypt.checkpw("bootstrap-secret".encode(), user["hashed_password"].encode())


@pytest.mark.asyncio
async def test_revoked_tokens_expire_and_are_cleaned_up(store) -> None:
    await revoke_token("expiring-jti", 1)
    assert await is_token_revoked("expiring-jti") is True

    await asyncio.sleep(1.1)

    assert await is_token_revoked("expiring-jti") is False
    assert "expiring-jti" not in store.revoked_jtis
