import os
import json
import httpx
from fastapi import APIRouter, Request, HTTPException, Depends
from fastapi.responses import StreamingResponse, Response, JSONResponse
from sqlalchemy.orm import Session
from api.auth import get_current_user_or_apikey
from api.database import User, UserSettings, get_db

router = APIRouter(prefix="/api/voca", tags=["voca"])

ENV_VOCA_ORIGIN = os.environ.get("VOCA_BRIDGE_ORIGIN", "https://voca-bridge.thaonv.online").rstrip("/")
ENV_VOCA_TOKEN = os.environ.get("VOCA_BRIDGE_TOKEN", "")
ENV_OPENAI = os.environ.get("OPENAI_API_KEY", "")


def _resolve_bridge(db: Session, user: User):
    """Resolve the voca-bridge (origin, auth headers) for a user from the
    server-held per-user settings (entered on the FE, kept out of the browser),
    falling back to the VOCA_BRIDGE_* env defaults."""
    s = db.query(UserSettings).filter(UserSettings.user_id == user.id).first()
    origin = ((s.voca_bridge_origin or "").strip() if s else "") or ENV_VOCA_ORIGIN
    token = ((s.voca_bridge_token or "").strip() if s else "") or ENV_VOCA_TOKEN
    if not token:
        raise HTTPException(status_code=503, detail="Voca bridge chưa được cấu hình (thiếu token).")
    return origin.rstrip("/"), {"Authorization": f"Bearer {token}"}


def _resolve_llm_key(db: Session, user: User) -> str:
    """The user's server-held LLM key (falls back to the OPENAI_API_KEY env)."""
    s = db.query(UserSettings).filter(UserSettings.user_id == user.id).first()
    return ((s.llm_api_key or "").strip() if s else "") or ENV_OPENAI


def _inject_llm_key(body: bytes, key: str) -> bytes:
    """Inject the server-held LLM key into the forwarded body's settings.apiKey so
    the browser never sends it. Leaves the body untouched if it isn't the expected
    JSON shape (the bridge then reports the missing key)."""
    if not key:
        return body
    try:
        data = json.loads(body.decode("utf-8"))
    except Exception:
        return body
    if isinstance(data.get("settings"), dict):
        data["settings"]["apiKey"] = key
        return json.dumps(data).encode("utf-8")
    return body


def _safe_json(resp: httpx.Response):
    try:
        return resp.json()
    except Exception:
        return {"error": {"message": resp.text[:300]}}


@router.get("/lookup")
async def voca_lookup(
    word: str,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    origin, headers = _resolve_bridge(db, current_user)
    async with httpx.AsyncClient(timeout=30.0) as client:
        try:
            resp = await client.get(
                f"{origin}/v1/cards/lookup", params={"word": word}, headers=headers
            )
        except httpx.RequestError as exc:
            raise HTTPException(status_code=502, detail=f"Voca bridge unreachable: {exc}") from exc
    return JSONResponse(status_code=resp.status_code, content=_safe_json(resp))


@router.post("/create")
async def voca_create(
    request: Request,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    """Forward card creation, streaming the NDJSON progress back to the client. The
    server attaches both the bridge token and the user's server-held LLM key."""
    origin, bridge_headers = _resolve_bridge(db, current_user)
    headers = {**bridge_headers, "Content-Type": "application/json"}
    body = _inject_llm_key(await request.body(), _resolve_llm_key(db, current_user))
    client = httpx.AsyncClient(timeout=120.0)
    try:
        upstream = await client.send(
            client.build_request("POST", f"{origin}/v1/cards/create", content=body, headers=headers),
            stream=True,
        )
    except httpx.RequestError as exc:
        await client.aclose()
        raise HTTPException(status_code=502, detail=f"Voca bridge unreachable: {exc}") from exc

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
        media_type=upstream.headers.get("content-type", "application/x-ndjson"),
    )


@router.get("/audio/{card_id}")
async def voca_audio_get(
    card_id: str,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    origin, headers = _resolve_bridge(db, current_user)
    async with httpx.AsyncClient(timeout=60.0) as client:
        try:
            resp = await client.get(f"{origin}/v1/audio/{card_id}", headers=headers)
        except httpx.RequestError as exc:
            raise HTTPException(status_code=502, detail=f"Voca bridge unreachable: {exc}") from exc
    # Preserve the upstream status (esp. 404 -> client then POSTs to generate).
    return Response(
        content=resp.content,
        status_code=resp.status_code,
        media_type=resp.headers.get("content-type", "application/octet-stream"),
    )


@router.post("/audio/{card_id}")
async def voca_audio_generate(
    card_id: str,
    request: Request,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    origin, bridge_headers = _resolve_bridge(db, current_user)
    headers = {**bridge_headers, "Content-Type": "application/json"}
    body = _inject_llm_key(await request.body(), _resolve_llm_key(db, current_user))
    async with httpx.AsyncClient(timeout=120.0) as client:
        try:
            resp = await client.post(f"{origin}/v1/audio/{card_id}", content=body, headers=headers)
        except httpx.RequestError as exc:
            raise HTTPException(status_code=502, detail=f"Voca bridge unreachable: {exc}") from exc
    return JSONResponse(status_code=resp.status_code, content=_safe_json(resp))
