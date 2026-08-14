"""Tests for the server-side per-user secrets: /api/user/settings logic, the voca
LLM-key injection, and the user_voca_config -> user_settings migration.

These call the route functions directly (no TestClient/lifespan) against a
temporary SQLite DB, so they don't touch the real DB or need a live server.
"""
from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from types import SimpleNamespace

# Point the app's engine at a throwaway DB and clear env keys BEFORE importing
# api.* (the engine + ENV_* constants are read at import time).
_TMP_DB = Path(tempfile.gettempdir()) / "bilingual_test_user_settings.db"
for _suffix in ("", "-wal", "-shm"):
    p = Path(str(_TMP_DB) + _suffix)
    if p.exists():
        p.unlink()
os.environ["DATABASE_URL"] = f"sqlite:///{_TMP_DB}"
os.environ.pop("OPENAI_API_KEY", None)
os.environ.pop("VOCA_BRIDGE_TOKEN", None)

from api.database import (  # noqa: E402
    SessionLocal,
    User,
    UserSettings,
    engine,
    get_or_create_user_settings,
    init_db,
    _migrate_voca_config_to_user_settings,
)
from api.routes.settings import get_user_settings, put_user_settings  # noqa: E402
from api.routes.voca import _inject_llm_key  # noqa: E402
from sqlalchemy import text  # noqa: E402

init_db()


def _make_user(username: str) -> int:
    db = SessionLocal()
    try:
        u = db.query(User).filter(User.username == username).first()
        if not u:
            u = User(username=username, password_hash="x", is_admin=False)
            db.add(u)
            db.commit()
            db.refresh(u)
        return u.id
    finally:
        db.close()


# ---- /api/user/settings GET/PUT ---------------------------------------------

def test_user_settings_get_default_is_empty():
    uid = _make_user("get_default")
    db = SessionLocal()
    try:
        view = get_user_settings(current_user=SimpleNamespace(id=uid), db=db)
    finally:
        db.close()
    assert view == {
        "hasLlmKey": False,
        "hasRealtimeKey": False,
        "vocaOrigin": "",
        "hasVocaToken": False,
    }


def test_put_sets_secret_and_get_never_leaks_it():
    uid = _make_user("set_secret")
    user = SimpleNamespace(id=uid)
    db = SessionLocal()
    try:
        put_user_settings({"llmApiKey": "sk-secret-123"}, current_user=user, db=db)
        view = get_user_settings(current_user=user, db=db)
        assert view["hasLlmKey"] is True
        # hasRealtimeKey is true because the llm key is a fallback for realtime.
        assert view["hasRealtimeKey"] is True
        # The raw secret must never appear in the public view.
        assert "sk-secret-123" not in json.dumps(view)
        # ...but it IS stored server-side.
        row = db.query(UserSettings).filter(UserSettings.user_id == uid).first()
        assert row.llm_api_key == "sk-secret-123"
    finally:
        db.close()


def test_put_token_conventions_absent_keeps_empty_clears():
    uid = _make_user("token_conv")
    user = SimpleNamespace(id=uid)
    db = SessionLocal()
    try:
        put_user_settings({"llmApiKey": "sk-1"}, current_user=user, db=db)
        # absent llmApiKey -> keep existing
        put_user_settings({"vocaOrigin": "https://bridge"}, current_user=user, db=db)
        view = get_user_settings(current_user=user, db=db)
        assert view["hasLlmKey"] is True
        assert view["vocaOrigin"] == "https://bridge"
        # empty string -> clear
        put_user_settings({"llmApiKey": ""}, current_user=user, db=db)
        assert get_user_settings(current_user=user, db=db)["hasLlmKey"] is False
    finally:
        db.close()


def test_voca_token_and_origin_roundtrip():
    uid = _make_user("voca_rt")
    user = SimpleNamespace(id=uid)
    db = SessionLocal()
    try:
        put_user_settings(
            {"vocaOrigin": "https://voca", "vocaToken": "brg-tok"}, current_user=user, db=db
        )
        view = get_user_settings(current_user=user, db=db)
        assert view["vocaOrigin"] == "https://voca"
        assert view["hasVocaToken"] is True
        assert "brg-tok" not in json.dumps(view)
    finally:
        db.close()


def test_get_or_create_user_settings_is_idempotent():
    uid = _make_user("goc")
    db = SessionLocal()
    try:
        a = get_or_create_user_settings(db, uid)
        b = get_or_create_user_settings(db, uid)
        assert a.id == b.id
        assert db.query(UserSettings).filter(UserSettings.user_id == uid).count() == 1
    finally:
        db.close()


# ---- voca _inject_llm_key ----------------------------------------------------

def test_inject_llm_key_sets_settings_apikey():
    body = json.dumps({"word": "cat", "settings": {"baseURL": "u", "model": "m"}}).encode()
    out = json.loads(_inject_llm_key(body, "sk-key"))
    assert out["settings"]["apiKey"] == "sk-key"
    assert out["word"] == "cat"


def test_inject_llm_key_noops_without_key_or_shape():
    body = json.dumps({"settings": {"model": "m"}}).encode()
    # no key -> unchanged
    assert _inject_llm_key(body, "") == body
    # non-JSON -> unchanged
    assert _inject_llm_key(b"not json", "k") == b"not json"
    # no settings dict -> unchanged
    b2 = json.dumps({"word": "x"}).encode()
    assert _inject_llm_key(b2, "k") == b2


# ---- migration user_voca_config -> user_settings -----------------------------

def test_migration_copies_legacy_voca_config():
    uid = _make_user("legacy_voca")
    # Recreate the legacy table + a row (the model was removed from the ORM).
    with engine.begin() as conn:
        conn.execute(
            text(
                "CREATE TABLE IF NOT EXISTS user_voca_config "
                "(id INTEGER PRIMARY KEY, user_id INTEGER, bridge_origin TEXT, "
                "bridge_token TEXT, updated_at INTEGER)"
            )
        )
        conn.execute(
            text(
                "INSERT INTO user_voca_config (user_id, bridge_origin, bridge_token) "
                "VALUES (:u, :o, :t)"
            ),
            {"u": uid, "o": "https://legacy", "t": "legacy-tok"},
        )
    _migrate_voca_config_to_user_settings()
    db = SessionLocal()
    try:
        row = db.query(UserSettings).filter(UserSettings.user_id == uid).first()
        assert row is not None
        assert row.voca_bridge_origin == "https://legacy"
        assert row.voca_bridge_token == "legacy-tok"
    finally:
        db.close()
