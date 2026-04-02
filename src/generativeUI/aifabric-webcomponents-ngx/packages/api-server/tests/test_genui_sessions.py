import pytest


def _sample_messages():
    return [
        {"role": "user", "content": "build me a dashboard"},
        {"role": "assistant", "content": "here is a generated ui layout"},
    ]


def test_requires_authentication(client) -> None:
    response = client.get("/api/v1/genui/sessions")
    assert response.status_code == 401


def test_save_and_list_session_for_current_user(client, admin_headers) -> None:
    save_response = client.post(
        "/api/v1/genui/sessions/save",
        headers=admin_headers,
        json={
            "title": "Treasury dashboard",
            "messages": _sample_messages(),
            "ui_state": {"layout": "cards"},
        },
    )
    assert save_response.status_code == 201
    saved = save_response.json()
    assert saved["title"] == "Treasury dashboard"
    assert saved["is_bookmarked"] is False
    assert len(saved["messages"]) == 2

    list_response = client.get("/api/v1/genui/sessions", headers=admin_headers)
    assert list_response.status_code == 200
    body = list_response.json()
    assert body["total"] >= 1
    assert any(item["id"] == saved["id"] for item in body["sessions"])


def test_update_existing_session_and_bookmark(client, admin_headers) -> None:
    create_response = client.post(
        "/api/v1/genui/sessions/save",
        headers=admin_headers,
        json={
            "title": "Initial title",
            "messages": _sample_messages(),
        },
    )
    assert create_response.status_code == 201
    session_id = create_response.json()["id"]

    update_response = client.post(
        "/api/v1/genui/sessions/save",
        headers=admin_headers,
        json={
            "session_id": session_id,
            "title": "Updated title",
            "messages": _sample_messages() + [{"role": "user", "content": "refine spacing"}],
        },
    )
    assert update_response.status_code == 200
    assert update_response.json()["title"] == "Updated title"
    assert len(update_response.json()["messages"]) == 3

    bookmark_response = client.patch(
        f"/api/v1/genui/sessions/{session_id}/bookmark",
        headers=admin_headers,
        json={"is_bookmarked": True},
    )
    assert bookmark_response.status_code == 200
    assert bookmark_response.json()["is_bookmarked"] is True

    bookmarked_list = client.get(
        "/api/v1/genui/sessions",
        headers=admin_headers,
        params={"bookmarked_only": "true"},
    )
    assert bookmarked_list.status_code == 200
    assert any(item["id"] == session_id for item in bookmarked_list.json()["sessions"])


def test_session_isolation_between_users(client, admin_headers, viewer_headers) -> None:
    create_response = client.post(
        "/api/v1/genui/sessions/save",
        headers=admin_headers,
        json={
            "title": "Admin-only session",
            "messages": _sample_messages(),
        },
    )
    assert create_response.status_code == 201
    session_id = create_response.json()["id"]

    viewer_get = client.get(f"/api/v1/genui/sessions/{session_id}", headers=viewer_headers)
    assert viewer_get.status_code == 404

    viewer_bookmark = client.patch(
        f"/api/v1/genui/sessions/{session_id}/bookmark",
        headers=viewer_headers,
        json={"is_bookmarked": True},
    )
    assert viewer_bookmark.status_code == 404


def test_archive_and_filter_history(client, admin_headers) -> None:
    create_response = client.post(
        "/api/v1/genui/sessions/save",
        headers=admin_headers,
        json={
            "title": "Monthly close workflow",
            "messages": _sample_messages(),
        },
    )
    assert create_response.status_code == 201
    session_id = create_response.json()["id"]

    archive_response = client.delete(
        f"/api/v1/genui/sessions/{session_id}",
        headers=admin_headers,
    )
    assert archive_response.status_code == 204

    active_list = client.get("/api/v1/genui/sessions", headers=admin_headers)
    assert active_list.status_code == 200
    assert all(item["id"] != session_id for item in active_list.json()["sessions"])

    archived_list = client.get(
        "/api/v1/genui/sessions",
        headers=admin_headers,
        params={"include_archived": "true"},
    )
    assert archived_list.status_code == 200
    archived_item = next(item for item in archived_list.json()["sessions"] if item["id"] == session_id)
    assert archived_item["is_archived"] is True


def test_search_and_clone_session(client, admin_headers) -> None:
    create_response = client.post(
        "/api/v1/genui/sessions/save",
        headers=admin_headers,
        json={
            "title": "ESG compliance cockpit",
            "messages": [
                {"role": "user", "content": "build esg chart"},
                {"role": "assistant", "content": "created esg ui"},
            ],
        },
    )
    assert create_response.status_code == 201
    session_id = create_response.json()["id"]

    search_response = client.get(
        "/api/v1/genui/sessions",
        headers=admin_headers,
        params={"query": "compliance"},
    )
    assert search_response.status_code == 200
    assert any(item["id"] == session_id for item in search_response.json()["sessions"])

    clone_response = client.post(
        f"/api/v1/genui/sessions/{session_id}/clone",
        headers=admin_headers,
    )
    assert clone_response.status_code == 201
    clone = clone_response.json()
    assert clone["id"] != session_id
    assert clone["title"].startswith("ESG compliance cockpit")
    assert clone["is_bookmarked"] is False
    assert clone["is_archived"] is False
    assert len(clone["messages"]) == 2


def test_archived_only_filter(client, admin_headers) -> None:
    active = client.post(
        "/api/v1/genui/sessions/save",
        headers=admin_headers,
        json={
            "title": "Active planning",
            "messages": _sample_messages(),
        },
    )
    archived = client.post(
        "/api/v1/genui/sessions/save",
        headers=admin_headers,
        json={
            "title": "Archived planning",
            "messages": _sample_messages(),
        },
    )
    assert active.status_code == 201
    assert archived.status_code == 201

    archived_id = archived.json()["id"]
    archive_response = client.patch(
        f"/api/v1/genui/sessions/{archived_id}/archive",
        headers=admin_headers,
        json={"is_archived": True},
    )
    assert archive_response.status_code == 200
    assert archive_response.json()["is_archived"] is True

    archived_only = client.get(
        "/api/v1/genui/sessions",
        headers=admin_headers,
        params={"archived_only": "true"},
    )
    assert archived_only.status_code == 200
    sessions = archived_only.json()["sessions"]
    assert any(item["id"] == archived_id for item in sessions)
    assert all(item["is_archived"] is True for item in sessions)

