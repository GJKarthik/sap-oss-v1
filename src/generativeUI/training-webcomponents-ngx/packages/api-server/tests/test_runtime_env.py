from __future__ import annotations

import importlib


def test_hana_config_reads_secret_files(monkeypatch, tmp_path):
    monkeypatch.delenv("HANA_USER", raising=False)
    monkeypatch.delenv("HANA_PASSWORD", raising=False)

    user_secret = tmp_path / "hana_user"
    user_secret.write_text("secret-user\n", encoding="utf-8")
    password_secret = tmp_path / "hana_password"
    password_secret.write_text("secret-password\n", encoding="utf-8")

    monkeypatch.setenv("HANA_USER_FILE", str(user_secret))
    monkeypatch.setenv("HANA_PASSWORD_FILE", str(password_secret))

    import src.hana_config as hana_config

    reloaded = importlib.reload(hana_config)
    assert reloaded.HANA_USER == "secret-user"
    assert reloaded.HANA_PASSWORD == "secret-password"
