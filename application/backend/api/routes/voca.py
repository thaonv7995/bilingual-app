"""Voca 2.0 API proxy.

A PASS-THROUGH: Voca 2.0 answers every JSON call with the envelope
{"status","code","message","data"} and each client (web-v2, iOS) unwraps it, so
bodies are forwarded VERBATIM and never reshaped here. What this layer does own:

* the credential — the `voca_` key lives in `user_settings` server-side and is
  attached here as `X-API-Key`, so the browser never sees it;
* the origin — forced to https (the Voca host serves plain http with NO redirect,
  so a stale http:// base URL would put the key on the wire in cleartext) and
  refused for private/loopback hosts (the origin is user input -> SSRF);
* the status line — an upstream 401/403 is remapped to 502, see `_client_status`.

Errors the proxy itself raises use that same 2.0 envelope shape, so a client only
ever parses ONE shape no matter who produced the failure.
"""
import os
import asyncio
import ipaddress
from urllib.parse import quote, urlsplit

import httpx
from fastapi import APIRouter, Request, Query, Depends
from fastapi.responses import StreamingResponse, Response, JSONResponse
from sqlalchemy.orm import Session
from api.auth import get_current_user_or_apikey
from api.database import User, UserSettings, get_db

router = APIRouter(prefix="/api/voca", tags=["voca"])

# The old bridge host (voca-bridge.thaonv.online) is dead; 2.0 lives here.
DEFAULT_VOCA_ORIGIN = "https://voca.thaonv.online"

# 429 carries no X-RateLimit-* headers, so idempotent GETs just back off blindly.
MAX_RETRIES = 2
RETRY_BASE_DELAY = 0.5  # seconds, doubled per attempt: 0.5s then 1s


# ---- origin hygiene ----------------------------------------------------------

# Hostnames that never point at Voca but do point at us / our neighbours.
_BLOCKED_HOST_SUFFIXES = (".localhost", ".local", ".internal", ".home.arpa")


def _normalize_origin(raw: str) -> str:
    """Normalise a Voca API origin: drop trailing slashes, UPGRADE http:// to
    https:// (the host serves both with no redirect, so http would leak the API
    key in cleartext) and refuse anything that isn't http(s). Raises ValueError."""
    origin = (raw or "").strip().rstrip("/")
    if not origin:
        return ""
    parts = urlsplit(origin)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise ValueError(f"Voca API origin phải là URL http(s) đầy đủ: {origin}")
    if parts.scheme == "http":
        origin = "https://" + origin[len("http://"):]
    origin = origin.rstrip("/")
    # The Voca docs label `https://host/v1` the "Base URL", so users paste it here
    # verbatim — but every call below appends its own `/v1`, which would request
    # `/v1/v1/...` and 404. Strip it so both forms work. iOS normalises the same way.
    if origin.lower().endswith("/v1"):
        origin = origin[: -len("/v1")].rstrip("/")
    return origin


def _assert_public_origin(origin: str) -> None:
    """SSRF guard for the USER-supplied origin: refuse loopback/private/link-local
    targets. Literal IPs are checked with `ipaddress`; names are only checked by
    hostname (we deliberately don't resolve DNS here — this is a guard, not a
    sandbox). Raises _ProxyError(400)."""
    host = (urlsplit(origin).hostname or "").lower()
    if not host or host == "localhost" or host.endswith(_BLOCKED_HOST_SUFFIXES):
        raise _ProxyError(400, "INVALID_ORIGIN", f"Voca API origin không hợp lệ: {origin}")
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return  # a normal DNS name — good enough
    if (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_reserved
        or ip.is_multicast
        or ip.is_unspecified
    ):
        raise _ProxyError(400, "INVALID_ORIGIN", f"Voca API origin trỏ vào mạng nội bộ: {origin}")


def _env_origin() -> str:
    """VOCA_API_ORIGIN wins; VOCA_BRIDGE_ORIGIN stays readable for compat."""
    raw = (os.environ.get("VOCA_API_ORIGIN") or os.environ.get("VOCA_BRIDGE_ORIGIN") or "").strip()
    if not raw:
        return DEFAULT_VOCA_ORIGIN
    try:
        return _normalize_origin(raw)
    except ValueError as exc:
        print(f"[Voca] Ignoring invalid VOCA_API_ORIGIN ({exc}); using {DEFAULT_VOCA_ORIGIN}.")
        return DEFAULT_VOCA_ORIGIN


ENV_VOCA_ORIGIN = _env_origin()
ENV_VOCA_TOKEN = os.environ.get("VOCA_BRIDGE_TOKEN", "")


# ---- envelopes & status remap ------------------------------------------------

class _ProxyError(Exception):
    """A failure the proxy itself detected (bad origin, missing token). Carries a
    ready-made envelope so callers just hand `.response` back to the client."""

    def __init__(self, http_status: int, code: str, message: str):
        super().__init__(message)
        self.response = _envelope(http_status, code, message)


def _envelope(status: int, code: str, message: str) -> JSONResponse:
    """A REAL Voca 2.0-shaped error envelope. The old proxy invented a third shape
    ({"error": {"message": ...}}) for non-JSON bodies and left FastAPI's
    {"detail": ...} for unreachable hosts; emitting the envelope everywhere means
    clients parse ONE shape whoever produced the failure."""
    return JSONResponse(
        status_code=status,
        content={"status": status, "code": code, "message": message, "data": None},
    )


def _client_status(upstream_status: int) -> int:
    """Remap an upstream 401/403 to 502; pass everything else through.

    NON-OBVIOUS, DO NOT "SIMPLIFY": the web client reaches this proxy through
    apiFetch, which treats ANY 401 as "app session expired", fires a token refresh
    and can log the user out (web-app-v2/src/lib/api-client.ts). A Voca
    UNAUTHORIZED (wrong voca_ key) must not do that, so the *status line* becomes
    502 while the body still carries {"status":401,"code":"UNAUTHORIZED",...} for
    the client to render. Every other status is forwarded untouched — notably 404
    (the audio flow POSTs to generate on 404), 429 and 503."""
    return 502 if upstream_status in (401, 403) else upstream_status


def _forward(resp: httpx.Response) -> JSONResponse:
    """Forward a Voca JSON response verbatim (only the status line may change)."""
    headers = {}
    if resp.status_code == 429:
        # No X-RateLimit-* upstream, so hand the client at least a backoff hint.
        headers["Retry-After"] = resp.headers.get("Retry-After", "2")
    try:
        payload = resp.json()
    except Exception:
        # Not JSON (a proxy in front of Voca died, say) — synthesise the envelope
        # rather than invent a shape only this branch would ever produce.
        text = (resp.text or "").strip()[:300] or f"Voca API returned {resp.status_code}."
        payload = {
            "status": resp.status_code, "code": "UPSTREAM_ERROR", "message": text, "data": None,
        }
    return JSONResponse(
        status_code=_client_status(resp.status_code), content=payload, headers=headers
    )


def _unreachable(exc: httpx.RequestError) -> JSONResponse:
    return _envelope(502, "VOCA_UNREACHABLE", f"Voca API unreachable: {exc}")


# ---- request plumbing --------------------------------------------------------

def _resolve_voca(db: Session, user: User, *, require_token: bool = True):
    """Resolve the Voca API (origin, auth headers) in ONE settings query, from the
    server-held per-user settings (entered on the FE, kept out of the browser) and
    falling back to the env defaults. The DB columns keep their legacy
    `voca_bridge_*` names on purpose — renaming them would need a migration."""
    s = db.query(UserSettings).filter(UserSettings.user_id == user.id).first()
    raw_origin = ((s.voca_bridge_origin or "").strip() if s else "")
    token = ((s.voca_bridge_token or "").strip() if s else "") or ENV_VOCA_TOKEN
    if raw_origin:
        try:
            origin = _normalize_origin(raw_origin)
        except ValueError as exc:
            raise _ProxyError(400, "INVALID_ORIGIN", str(exc)) from exc
        _assert_public_origin(origin)  # only the user-supplied origin is untrusted
    else:
        origin = ENV_VOCA_ORIGIN
    if require_token and not token:
        raise _ProxyError(503, "VOCA_NOT_CONFIGURED", "Voca API chưa được cấu hình (thiếu token).")
    # 2.0 standardises on X-API-Key (Bearer is also accepted upstream).
    return origin, ({"X-API-Key": token} if token else {})


async def _get_with_retry(client: httpx.AsyncClient, url: str, **kwargs) -> httpx.Response:
    """GETs are idempotent, so a 429 is worth a couple of exponential-backoff
    retries. POSTs (create / audio generate / practice) are never retried."""
    resp = await client.get(url, **kwargs)
    for attempt in range(MAX_RETRIES):
        if resp.status_code != 429:
            break
        await asyncio.sleep(RETRY_BASE_DELAY * (2 ** attempt))
        resp = await client.get(url, **kwargs)
    return resp


async def _forward_get(db: Session, user: User, path: str, *, params=None,
                       timeout: float = 30.0, require_token: bool = True):
    try:
        origin, headers = _resolve_voca(db, user, require_token=require_token)
    except _ProxyError as exc:
        return exc.response
    async with httpx.AsyncClient(timeout=timeout) as client:
        try:
            resp = await _get_with_retry(client, f"{origin}{path}", params=params, headers=headers)
        except httpx.RequestError as exc:
            return _unreachable(exc)
    return _forward(resp)


async def _forward_post(db: Session, user: User, path: str, body: bytes, *, timeout: float = 120.0):
    """The body is forwarded AS-IS. Voca 2.0 takes no `settings` object — its LLM
    and TTS keys are server-side there — and injecting the user's own LLM key (as
    the 1.x proxy did) would hand it to the Voca host for nothing."""
    try:
        origin, headers = _resolve_voca(db, user)
    except _ProxyError as exc:
        return exc.response
    async with httpx.AsyncClient(timeout=timeout) as client:
        try:
            resp = await client.post(
                f"{origin}{path}", content=body,
                headers={**headers, "Content-Type": "application/json"},
            )
        except httpx.RequestError as exc:
            return _unreachable(exc)
    return _forward(resp)


async def _forward_sse(db: Session, user: User, path: str, body: bytes):
    """Practice endpoints stream OpenAI-style SSE chunks, so they keep the
    streaming machinery (aiter_bytes + closing the client in a `finally`) that
    /create no longer needs."""
    try:
        origin, headers = _resolve_voca(db, user)
    except _ProxyError as exc:
        return exc.response
    # No read timeout: an SSE stream may idle between chunks.
    client = httpx.AsyncClient(timeout=httpx.Timeout(30.0, read=None))
    request = client.build_request(
        "POST", f"{origin}{path}", content=body,
        headers={**headers, "Content-Type": "application/json", "Accept": "text/event-stream"},
    )
    try:
        upstream = await client.send(request, stream=True)
    except httpx.RequestError as exc:
        await client.aclose()
        return _unreachable(exc)

    if upstream.status_code >= 400:
        # A failure before the stream starts comes back as a JSON envelope, not as
        # SSE — read it and forward it like any other JSON (incl. the 401 remap,
        # which matters most here: an SSE 401 would trip the client's refresh).
        await upstream.aread()
        await upstream.aclose()
        await client.aclose()
        return _forward(upstream)

    async def gen():
        try:
            async for chunk in upstream.aiter_bytes():
                yield chunk
        finally:
            await upstream.aclose()
            await client.aclose()

    return StreamingResponse(
        gen(),
        status_code=upstream.status_code,
        media_type="text/event-stream",
        # Stop nginx buffering the stream into uselessness.
        headers={"X-Accel-Buffering": "no", "Cache-Control": "no-cache"},
    )


# ---- routes ------------------------------------------------------------------
# Declaration order matters: the literal paths (/health, /lookup, /cards) are
# declared BEFORE /cards/{slug} so the parameterised route can never shadow them.

@router.get("/health")
async def voca_health(
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    """Connectivity check. /v1/health needs no key, and this is the "test my
    connection" route, so a missing token must NOT hard-fail it."""
    return await _forward_get(db, current_user, "/v1/health", timeout=10.0, require_token=False)


@router.get("/lookup")
async def voca_lookup(
    word: str,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    return await _forward_get(db, current_user, "/v1/cards/lookup", params={"word": word})


@router.get("/cards")
async def voca_cards(
    if_changed_since: str | None = Query(default=None, alias="ifChangedSince"),
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    """Full or incremental deck sync; with ifChangedSince the upstream answers
    changed:false and omits `cards`."""
    params = {"ifChangedSince": if_changed_since} if if_changed_since else None
    return await _forward_get(db, current_user, "/v1/cards", params=params)


@router.get("/cards/{slug}")
async def voca_card_detail(
    slug: str,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    return await _forward_get(db, current_user, f"/v1/cards/{quote(slug, safe='')}")


@router.post("/create")
async def voca_create(
    request: Request,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    """Card creation. NOT a stream any more: 2.0 answers with a plain JSON
    envelope whose data is the finished Card (it just takes a few seconds)."""
    return await _forward_post(db, current_user, "/v1/cards/create", await request.body())


@router.get("/audio/{card_id}")
async def voca_audio_get(
    card_id: str,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    """Binary mp3 (`card_id` is the card SLUG), so the bytes pass through as-is."""
    try:
        origin, headers = _resolve_voca(db, current_user)
    except _ProxyError as exc:
        return exc.response
    async with httpx.AsyncClient(timeout=60.0) as client:
        try:
            resp = await client.get(
                f"{origin}/v1/audio/{quote(card_id, safe='')}", headers=headers
            )
        except httpx.RequestError as exc:
            return _unreachable(exc)
    # Preserve the upstream status (esp. 404 -> client then POSTs to generate);
    # only 401/403 are remapped, and the envelope body still says which it was.
    return Response(
        content=resp.content,
        status_code=_client_status(resp.status_code),
        media_type=resp.headers.get("content-type", "application/octet-stream"),
    )


@router.post("/audio/{card_id}")
async def voca_audio_generate(
    card_id: str,
    request: Request,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    return await _forward_post(
        db, current_user, f"/v1/audio/{quote(card_id, safe='')}", await request.body()
    )


@router.post("/practice/drills")
async def voca_practice_drills(
    request: Request,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    return await _forward_sse(db, current_user, "/v1/practice/drills", await request.body())


@router.post("/practice/reading")
async def voca_practice_reading(
    request: Request,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    return await _forward_sse(db, current_user, "/v1/practice/reading", await request.body())
