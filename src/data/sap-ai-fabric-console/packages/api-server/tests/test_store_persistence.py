from src.store import AppStore


def test_store_persists_records_across_instances(tmp_path) -> None:
    database_path = tmp_path / "shared-store.sqlite3"

    first_store = AppStore(str(database_path))
    first_store.initialise()
    first_store.set_record(
        "models",
        "persisted-model",
        {
            "id": "persisted-model",
            "name": "Persisted Model",
            "provider": "sap-ai-core",
        },
    )
    first_store.revoke_jti("persisted-jti", 60)
    first_store.close()

    second_store = AppStore(str(database_path))
    second_store.initialise()

    assert second_store.get_record("models", "persisted-model") == {
        "id": "persisted-model",
        "name": "Persisted Model",
        "provider": "sap-ai-core",
    }
    assert second_store.is_jti_revoked("persisted-jti") is True


def test_clear_removes_persisted_state(tmp_path) -> None:
    database_path = tmp_path / "shared-store.sqlite3"

    store = AppStore(str(database_path))
    store.initialise()
    store.set_record("users", "alice", {"username": "alice", "role": "viewer"})
    store.revoke_jti("expired-jti", 60)

    store.clear()
    store.close()

    reopened_store = AppStore(str(database_path))
    reopened_store.initialise()

    assert reopened_store.get_record("users", "alice") is None
    assert reopened_store.is_jti_revoked("expired-jti") is False
