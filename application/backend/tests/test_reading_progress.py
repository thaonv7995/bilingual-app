"""POST /api/books/{slug}/progress — newest-`lastRead`-wins conflict rule.

Clients (web + iOS) send `lastRead` (unix seconds, when the page turn actually
happened). The server keeps whichever copy is newest, so a delayed or
offline-replayed save from one device cannot overwrite fresher progress from
another. Clients that omit `lastRead` (older builds) are stamped with the
server clock, i.e. they keep their old always-overwrite behaviour.

Like the other modules, these call the route functions directly against the
throwaway SQLite DB pinned by tests/conftest.py — no TestClient.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402

from api.database import ReadingProgress, SessionLocal, User, init_db  # noqa: E402
from api.routes.books import get_reading_progress, save_reading_progress  # noqa: E402

init_db()

SLUG = "progress-test-book"


def _make_user(username: str) -> User:
    db = SessionLocal()
    try:
        u = db.query(User).filter(User.username == username).first()
        if not u:
            u = User(username=username, password_hash="x", is_admin=False)
            db.add(u)
            db.commit()
            db.refresh(u)
        return u
    finally:
        db.close()


USER = _make_user("progress_user")


@pytest.fixture(autouse=True)
def clean_progress():
    db = SessionLocal()
    try:
        db.query(ReadingProgress).filter(ReadingProgress.book_slug == SLUG).delete()
        db.commit()
    finally:
        db.close()
    yield


def _save(payload: dict) -> dict:
    db = SessionLocal()
    try:
        return save_reading_progress(SLUG, payload, USER, db)
    finally:
        db.close()


def _get() -> dict:
    db = SessionLocal()
    try:
        return get_reading_progress(SLUG, USER, db)
    finally:
        db.close()


def test_first_save_stores_the_client_timestamp():
    t = int(time.time()) - 100
    res = _save({"page": 7, "viewMode": "split", "lastRead": t})
    assert res["ok"] and res["stored"]
    assert _get() == {"page": 7, "viewMode": "split", "lastRead": t}


def test_newer_write_overwrites_older():
    t = int(time.time()) - 100
    _save({"page": 7, "viewMode": "en", "lastRead": t})
    res = _save({"page": 9, "viewMode": "vi", "lastRead": t + 50})
    assert res["stored"]
    assert _get() == {"page": 9, "viewMode": "vi", "lastRead": t + 50}


def test_stale_write_is_rejected_and_returns_the_authoritative_copy():
    t = int(time.time()) - 100
    _save({"page": 42, "viewMode": "split", "lastRead": t})
    res = _save({"page": 5, "viewMode": "en", "lastRead": t - 50})
    assert res["ok"] and not res["stored"]
    assert res["progress"] == {"page": 42, "viewMode": "split", "lastRead": t}
    assert _get()["page"] == 42


def test_equal_timestamps_accept_the_write():
    """Ties go to the writer — mirrors the clients, where the SERVER copy wins
    a tie on read; either way no save is silently lost to an exact tie."""
    t = int(time.time()) - 100
    _save({"page": 7, "viewMode": "en", "lastRead": t})
    res = _save({"page": 8, "viewMode": "en", "lastRead": t})
    assert res["stored"]
    assert _get()["page"] == 8


def test_missing_lastread_is_stamped_now_and_overwrites():
    """Legacy clients: no lastRead → server clock, which always beats any
    stored past timestamp (their old always-overwrite behaviour)."""
    _save({"page": 7, "viewMode": "en", "lastRead": int(time.time()) - 100})
    res = _save({"page": 12, "viewMode": "vi"})
    assert res["stored"]
    got = _get()
    assert got["page"] == 12
    assert got["lastRead"] >= int(time.time()) - 5


def test_future_timestamp_is_clamped_to_the_server_clock():
    """A device with a fast clock must not publish progress 'from the future'
    that would win every later conflict."""
    res = _save({"page": 3, "viewMode": "en", "lastRead": int(time.time()) + 10_000})
    assert res["stored"]
    assert res["progress"]["lastRead"] <= int(time.time()) + 5


def test_junk_lastread_falls_back_to_the_server_clock():
    for junk in ("yesterday", -5, 0, True, None):
        res = _save({"page": 2, "viewMode": "en", "lastRead": junk})
        assert res["stored"]
        assert res["progress"]["lastRead"] >= int(time.time()) - 5
