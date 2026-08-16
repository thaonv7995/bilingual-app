"""Tests for the Voca 2.0 proxy (/api/voca/*).

Route coroutines are driven directly (no TestClient/lifespan) against a throwaway
SQLite DB, and every httpx.AsyncClient the proxy builds is redirected at a
MockTransport — nothing here touches the network or the real DB.

What is pinned down: the 2.0 envelope is forwarded VERBATIM, an upstream 401/403
becomes a 502 without the body changing (a literal 401 would trip the web client's
session refresh), origins are forced to https and refused when they point inside
the network, tokens must carry the voca_ prefix, and no LLM key is smuggled into a
forwarded body.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
from starlette.routing import Match

# `api` is a path-based namespace package (no pip install); ensure the backend
# root is importable even when pytest is run as the console script (see conftest).
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# Point the app's engine at a throwaway DB and clear env keys BEFORE importing
# api.* (the engine + ENV_* constants are read at import time). `setdefault` so we
# share whatever DB the sibling settings test module may already have chosen.
# NOTE: this preamble is too late to be the guarantee — importing the sibling
# module pulls in api.routes.voca via api.routes.settings, so these constants may
# already be frozen. tests/conftest.py is what actually enforces the clean env.
_TMP_DB = Path(tempfile.gettempdir()) / "bilingual_test_voca_proxy.db"
os.environ.setdefault("DATABASE_URL", f"sqlite:///{_TMP_DB}")
for _var in ("OPENAI_API_KEY", "VOCA_API_ORIGIN", "VOCA_BRIDGE_ORIGIN", "VOCA_BRIDGE_TOKEN"):
    os.environ.pop(_var, None)

from api.database import (  # noqa: E402
    SessionLocal,
    User,
    get_or_create_user_settings,
    init_db,
)
from api.routes import voca  # noqa: E402

init_db()

ORIGIN = "https://voca.example.com"
TOKEN = "voca_test_key"

# Grabbed once: a test that installs two mocks in a row must not wrap its own mock.
_REAL_ASYNC_CLIENT = httpx.AsyncClient


# ---- harness -----------------------------------------------------------------

def _user(username: str, *, origin: str = ORIGIN, token: str = TOKEN, llm_key: str = ""):
    """A user whose server-held Voca settings are exactly what the test needs."""
    db = SessionLocal()
    try:
        u = db.query(User).filter(User.username == username).first()
        if not u:
            u = User(username=username, password_hash="x", is_admin=False)
            db.add(u)
            db.commit()
            db.refresh(u)
        s = get_or_create_user_settings(db, u.id)
        # Written straight to the columns: settings.py normalises on write, and
        # these tests need to prove the proxy re-checks whatever it reads back.
        s.voca_bridge_origin = origin
        s.voca_bridge_token = token
        s.llm_api_key = llm_key
        db.commit()
        return SimpleNamespace(id=u.id)
    finally:
        db.close()


def _mock_upstream(monkeypatch, handler):
    """Redirect every httpx.AsyncClient the proxy builds at a MockTransport.
    Returns the list of requests the proxy actually sent."""
    seen: list[httpx.Request] = []

    def _handle(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return handler(request)

    def factory(*args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(_handle)
        return _REAL_ASYNC_CLIENT(*args, **kwargs)

    monkeypatch.setattr(voca.httpx, "AsyncClient", factory)
    return seen


def _always(response: httpx.Response):
    return lambda request: response


def _env(status: int, code: str = "OK", message: str = "Success", data=None) -> httpx.Response:
    """A response shaped exactly like a live Voca 2.0 one."""
    return httpx.Response(
        status, json={"status": status, "code": code, "message": message, "data": data}
    )


def _body(payload: bytes):
    """Minimal stand-in for starlette's Request (routes only call .body())."""
    return SimpleNamespace(body=lambda: asyncio.sleep(0, result=payload))


def _json_of(response) -> dict:
    return json.loads(bytes(response.body))


def _db_call(coro_factory):
    """Run a route coroutine with a real session, closing it afterwards."""
    db = SessionLocal()
    try:
        return asyncio.run(coro_factory(db))
    finally:
        db.close()


# ---- pass-through ------------------------------------------------------------

def test_lookup_forwards_envelope_verbatim_over_x_api_key(monkeypatch):
    user = _user("voca_lookup")
    payload = {"found": True, "word": "cat", "matchType": "exact", "card": {"slug": "cat"}}
    seen = _mock_upstream(monkeypatch, _always(_env(200, data=payload)))

    res = _db_call(lambda db: voca.voca_lookup(word="cat", current_user=user, db=db))

    assert str(seen[0].url) == f"{ORIGIN}/v1/cards/lookup?word=cat"
    # 2.0 standardises on X-API-Key; the 1.x Bearer header must be gone.
    assert seen[0].headers["X-API-Key"] == TOKEN
    assert "authorization" not in seen[0].headers
    assert res.status_code == 200
    assert _json_of(res) == {"status": 200, "code": "OK", "message": "Success", "data": payload}


def test_cards_sync_and_detail_routes(monkeypatch):
    user = _user("voca_cards")
    seen = _mock_upstream(monkeypatch, _always(_env(200, data={"version": "v2", "changed": False})))

    res = _db_call(lambda db: voca.voca_cards(if_changed_since="v1", current_user=user, db=db))
    assert str(seen[-1].url) == f"{ORIGIN}/v1/cards?ifChangedSince=v1"
    assert _json_of(res)["data"] == {"version": "v2", "changed": False}

    _db_call(lambda db: voca.voca_cards(if_changed_since=None, current_user=user, db=db))
    assert str(seen[-1].url) == f"{ORIGIN}/v1/cards"

    _db_call(lambda db: voca.voca_card_detail(slug="cat", current_user=user, db=db))
    assert str(seen[-1].url) == f"{ORIGIN}/v1/cards/cat"


@pytest.mark.parametrize("path, expected", [
    ("/api/voca/health", "voca_health"),
    ("/api/voca/lookup", "voca_lookup"),
    ("/api/voca/cards", "voca_cards"),
    ("/api/voca/cards/cat", "voca_card_detail"),
])
def test_card_detail_route_does_not_shadow_the_literal_routes(path, expected):
    """/cards/{slug} is greedy and routing is first-match, so it has to be
    declared last — resolve the paths the way starlette will."""
    scope = {"type": "http", "method": "GET", "path": path, "headers": [], "path_params": {}}
    matched = [r for r in voca.router.routes if r.matches(scope)[0] == Match.FULL]
    assert matched and matched[0].name == expected


def test_health_works_without_a_token(monkeypatch):
    """/health is the "test my connection" route — a missing token must not 503."""
    user = _user("voca_health", token="")
    seen = _mock_upstream(monkeypatch, _always(_env(200, data={"status": "ok"})))

    res = _db_call(lambda db: voca.voca_health(current_user=user, db=db))

    assert str(seen[0].url) == f"{ORIGIN}/v1/health"
    assert "x-api-key" not in seen[0].headers
    assert res.status_code == 200


# ---- status handling ---------------------------------------------------------

@pytest.mark.parametrize("upstream_status, code", [(401, "UNAUTHORIZED"), (403, "FORBIDDEN")])
def test_upstream_401_403_remapped_to_502_with_body_preserved(monkeypatch, upstream_status, code):
    user = _user(f"voca_{upstream_status}")
    _mock_upstream(monkeypatch, _always(_env(upstream_status, code=code, message="API key required.")))

    res = _db_call(lambda db: voca.voca_lookup(word="cat", current_user=user, db=db))

    # The status LINE is remapped so apiFetch doesn't read it as "app session
    # expired" and log the user out...
    assert res.status_code == 502
    # ...but the body is still the untouched Voca envelope.
    assert _json_of(res) == {
        "status": upstream_status, "code": code, "message": "API key required.", "data": None,
    }


def test_other_upstream_statuses_pass_through(monkeypatch):
    user = _user("voca_passthrough")
    for status, code in ((404, "NOT_FOUND"), (503, "LLM_NOT_CONFIGURED")):
        _mock_upstream(monkeypatch, _always(_env(status, code=code, message="nope")))
        res = _db_call(lambda db: voca.voca_lookup(word="cat", current_user=user, db=db))
        assert res.status_code == status
        assert _json_of(res)["code"] == code


def test_audio_404_passes_through_for_the_generate_flow(monkeypatch):
    """The client POSTs to generate exactly when the GET 404s — don't remap it."""
    user = _user("voca_audio")
    _mock_upstream(monkeypatch, _always(_env(404, code="AUDIO_NOT_FOUND", message="missing")))

    res = _db_call(lambda db: voca.voca_audio_get(card_id="cat", current_user=user, db=db))

    assert res.status_code == 404
    assert json.loads(res.body)["code"] == "AUDIO_NOT_FOUND"


def test_non_json_upstream_becomes_an_upstream_error_envelope(monkeypatch):
    """The dead 1.x host answered Cloudflare HTML; clients still get one shape."""
    user = _user("voca_html")
    _mock_upstream(monkeypatch, _always(httpx.Response(502, text="<html>Bad gateway</html>")))

    res = _db_call(lambda db: voca.voca_lookup(word="cat", current_user=user, db=db))

    assert res.status_code == 502
    assert _json_of(res) == {
        "status": 502, "code": "UPSTREAM_ERROR", "message": "<html>Bad gateway</html>", "data": None,
    }


def test_unreachable_upstream_becomes_a_voca_unreachable_envelope(monkeypatch):
    user = _user("voca_down")

    def _boom(request):
        raise httpx.ConnectError("nope", request=request)

    _mock_upstream(monkeypatch, _boom)
    res = _db_call(lambda db: voca.voca_lookup(word="cat", current_user=user, db=db))

    assert res.status_code == 502
    body = _json_of(res)
    assert body["code"] == "VOCA_UNREACHABLE" and body["data"] is None
    assert "detail" not in body


def test_missing_token_reports_a_configuration_envelope(monkeypatch):
    user = _user("voca_no_token", token="")
    seen = _mock_upstream(monkeypatch, _always(_env(200)))

    res = _db_call(lambda db: voca.voca_lookup(word="cat", current_user=user, db=db))

    assert res.status_code == 503
    assert _json_of(res)["code"] == "VOCA_NOT_CONFIGURED"
    assert seen == []


# ---- rate limiting -----------------------------------------------------------

def test_rate_limited_get_retries_then_succeeds(monkeypatch):
    user = _user("voca_429")
    monkeypatch.setattr(voca, "RETRY_BASE_DELAY", 0)
    replies = iter([_env(429, code="RATE_LIMITED"), _env(429, code="RATE_LIMITED"), _env(200)])
    seen = _mock_upstream(monkeypatch, lambda request: next(replies))

    res = _db_call(lambda db: voca.voca_lookup(word="cat", current_user=user, db=db))

    assert len(seen) == 3  # initial + MAX_RETRIES
    assert res.status_code == 200


def test_rate_limited_get_gives_up_with_a_retry_after_hint(monkeypatch):
    user = _user("voca_429_hard")
    monkeypatch.setattr(voca, "RETRY_BASE_DELAY", 0)
    seen = _mock_upstream(monkeypatch, _always(_env(429, code="RATE_LIMITED")))

    res = _db_call(lambda db: voca.voca_lookup(word="cat", current_user=user, db=db))

    assert len(seen) == voca.MAX_RETRIES + 1
    assert res.status_code == 429
    assert res.headers["Retry-After"]  # upstream sends no X-RateLimit-* headers


def test_post_create_is_never_retried(monkeypatch):
    user = _user("voca_429_post")
    monkeypatch.setattr(voca, "RETRY_BASE_DELAY", 0)
    seen = _mock_upstream(monkeypatch, _always(_env(429, code="RATE_LIMITED")))

    _db_call(lambda db: voca.voca_create(
        request=_body(b'{"word":"cat"}'), current_user=user, db=db
    ))

    assert len(seen) == 1


# ---- origin hygiene ----------------------------------------------------------

def test_default_origin_is_the_2_0_host():
    assert voca.ENV_VOCA_ORIGIN == "https://voca.thaonv.online"
    assert "voca-bridge" not in voca.ENV_VOCA_ORIGIN


def test_http_origin_is_upgraded_to_https(monkeypatch):
    """The host serves http with no redirect, so http would leak the key."""
    user = _user("voca_http", origin="http://voca.example.com/")
    seen = _mock_upstream(monkeypatch, _always(_env(200)))

    _db_call(lambda db: voca.voca_lookup(word="cat", current_user=user, db=db))

    assert str(seen[0].url).startswith("https://voca.example.com/v1/")


@pytest.mark.parametrize("stored", [
    "https://voca.example.com/v1",
    "https://voca.example.com/v1/",
    "http://voca.example.com/v1",
    "https://voca.example.com/V1",
])
def test_origin_with_trailing_v1_does_not_double_the_path(monkeypatch, stored):
    """The Voca docs call `https://host/v1` the "Base URL", so users paste it in
    verbatim. Every call appends its own `/v1`, so without stripping we request
    `/v1/v1/cards/lookup` and Voca 404s — which is exactly what shipped in v0.5.0."""
    user = _user("voca_v1_suffix", origin=stored)
    seen = _mock_upstream(monkeypatch, _always(_env(200)))

    _db_call(lambda db: voca.voca_lookup(word="cat", current_user=user, db=db))

    assert str(seen[0].url) == "https://voca.example.com/v1/cards/lookup?word=cat"
    assert "/v1/v1/" not in str(seen[0].url)


@pytest.mark.parametrize("origin", [
    "http://127.0.0.1:9000",
    "https://localhost:8787",
    "http://10.0.0.5",
    "https://192.168.1.10:8080",
    "http://169.254.169.254",
    "https://[::1]:8080",
    "http://voca.internal",
])
def test_private_origins_are_rejected(monkeypatch, origin):
    user = _user("voca_ssrf", origin=origin)
    seen = _mock_upstream(monkeypatch, _always(_env(200)))

    res = _db_call(lambda db: voca.voca_lookup(word="cat", current_user=user, db=db))

    assert res.status_code == 400
    assert _json_of(res)["code"] == "INVALID_ORIGIN"
    assert seen == []  # nothing left the box


@pytest.mark.parametrize("origin", ["file:///etc/passwd", "gopher://voca.example.com", "voca.example.com"])
def test_non_http_origins_are_rejected(monkeypatch, origin):
    user = _user("voca_scheme", origin=origin)
    seen = _mock_upstream(monkeypatch, _always(_env(200)))

    res = _db_call(lambda db: voca.voca_lookup(word="cat", current_user=user, db=db))

    assert res.status_code == 400
    assert _json_of(res)["code"] == "INVALID_ORIGIN"
    assert seen == []


def test_normalize_origin_strips_slashes_and_rejects_junk():
    assert voca._normalize_origin("  https://voca.example.com///  ") == "https://voca.example.com"
    assert voca._normalize_origin("http://voca.example.com/") == "https://voca.example.com"
    assert voca._normalize_origin("https://voca.example.com/v1") == "https://voca.example.com"
    assert voca._normalize_origin("https://voca.example.com/v1//") == "https://voca.example.com"
    # Only a trailing `/v1` is a docs artefact; a host that genuinely lives under
    # a path must keep it.
    assert voca._normalize_origin("https://voca.example.com/api") == "https://voca.example.com/api"
    assert voca._normalize_origin("") == ""
    with pytest.raises(ValueError):
        voca._normalize_origin("ftp://voca.example.com")


# ---- no key injection --------------------------------------------------------

def test_create_forwards_the_body_untouched(monkeypatch):
    """2.0 takes no settings object; injecting the user's LLM key (as 1.x did)
    would hand it to the Voca host for nothing."""
    user = _user("voca_create", llm_key="sk-super-secret")
    raw = json.dumps({"word": "cat"}).encode()
    seen = _mock_upstream(monkeypatch, _always(_env(200, data={"slug": "cat"})))

    res = _db_call(lambda db: voca.voca_create(request=_body(raw), current_user=user, db=db))

    assert seen[0].content == raw
    assert b"sk-super-secret" not in seen[0].content
    assert b"apiKey" not in seen[0].content
    assert str(seen[0].url) == f"{ORIGIN}/v1/cards/create"
    # Plain JSON now, not an NDJSON stream.
    assert _json_of(res)["data"] == {"slug": "cat"}


def test_audio_generate_forwards_the_body_untouched(monkeypatch):
    user = _user("voca_audio_gen", llm_key="sk-super-secret")
    raw = json.dumps({"voiceModel": "edge-tts/en-US-SteffanNeural"}).encode()
    seen = _mock_upstream(monkeypatch, _always(_env(200, data={"audioUrl": "/v1/audio/cat"})))

    _db_call(lambda db: voca.voca_audio_generate(
        card_id="cat", request=_body(raw), current_user=user, db=db
    ))

    assert seen[0].content == raw
    assert b"sk-super-secret" not in seen[0].content


def test_llm_key_injection_helper_is_gone():
    assert not hasattr(voca, "_inject_llm_key")


# ---- practice SSE ------------------------------------------------------------

def test_practice_drills_streams_sse(monkeypatch):
    user = _user("voca_drills")
    chunks = b'data: {"choices":[{"delta":{"content":"{"}}]}\n\ndata: [DONE]\n\n'
    seen = _mock_upstream(monkeypatch, _always(
        httpx.Response(200, content=chunks, headers={"content-type": "text/event-stream"})
    ))

    async def _drive(db):
        res = await voca.voca_practice_drills(
            request=_body(b'{"count":5}'), current_user=user, db=db
        )
        streamed = b"".join([part async for part in res.body_iterator])
        return res, streamed

    res, streamed = _db_call(_drive)

    assert seen[0].headers["Accept"] == "text/event-stream"
    assert str(seen[0].url) == f"{ORIGIN}/v1/practice/drills"
    assert res.media_type == "text/event-stream"
    assert res.headers["X-Accel-Buffering"] == "no"
    assert streamed == chunks


def test_practice_reading_401_is_remapped_before_streaming(monkeypatch):
    """An SSE 401 would trip apiFetch's refresh just as badly as a JSON one."""
    user = _user("voca_reading")
    _mock_upstream(monkeypatch, _always(_env(401, code="UNAUTHORIZED", message="API key required.")))

    res = _db_call(lambda db: voca.voca_practice_reading(
        request=_body(b'{"format":"part7"}'), current_user=user, db=db
    ))

    assert res.status_code == 502
    assert _json_of(res)["status"] == 401
    assert _json_of(res)["code"] == "UNAUTHORIZED"
