import os
import time
import httpx
from fastapi import APIRouter, Request, HTTPException, Depends
from fastapi.responses import StreamingResponse, Response, JSONResponse
from sqlalchemy.orm import Session
from api.auth import get_current_user_or_apikey
from api.database import User, UserVocaConfig, get_db

router = APIRouter(prefix="/api/voca", tags=["voca"])

ENV_VOCA_ORIGIN = os.environ.get("VOCA_BRIDGE_ORIGIN", "https://voca-bridge.thaonv.online").rstrip("/")
ENV_VOCA_TOKEN = os.environ.get("VOCA_BRIDGE_TOKEN", "")


def _resolve_bridge(db: Session, user: User):
    """Resolve the voca-bridge (origin, auth headers) for a user. Prefers the
    per-user config stored server-side (entered on the FE, kept out of the
    browser), falling back to the VOCA_BRIDGE_* env defaults."""
    cfg = db.query(UserVocaConfig).filter(UserVocaConfig.user_id == user.id).first()
    origin = ((cfg.bridge_origin or "").strip() if cfg else "") or ENV_VOCA_ORIGIN
    token = ((cfg.bridge_token or "").strip() if cfg else "") or ENV_VOCA_TOKEN
    if not token:
        raise HTTPException(status_code=503, detail="Voca bridge chưa được cấu hình (thiếu token).")
    return origin.rstrip("/"), {"Authorization": f"Bearer {token}"}


def _safe_json(resp: httpx.Response):
    try:
        return resp.json()
    except Exception:
        return {"error": {"message": resp.text[:300]}}


@router.get("/config")
def voca_config_get(
    current_user: User = Depends(get_current_user_or_apikey), db: Session = Depends(get_db)
):
    """Return the user's voca-bridge config WITHOUT the raw token — the browser
    only learns whether a token is set, never its value."""
    cfg = db.query(UserVocaConfig).filter(UserVocaConfig.user_id == current_user.id).first()
    return {
        "origin": (cfg.bridge_origin if cfg and cfg.bridge_origin else ""),
        "hasToken": bool((cfg and cfg.bridge_token) or ENV_VOCA_TOKEN),
        "usingServerDefault": not (cfg and cfg.bridge_token),
    }


@router.put("/config")
def voca_config_put(
    payload: dict,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    """Upsert the user's voca-bridge config. Conventions for `token`:
    key absent -> keep existing; "" -> clear (use env default); non-empty -> set."""
    origin = (payload.get("origin") or "").strip()
    cfg = db.query(UserVocaConfig).filter(UserVocaConfig.user_id == current_user.id).first()
    if not cfg:
        cfg = UserVocaConfig(user_id=current_user.id, bridge_origin="", bridge_token="")
        db.add(cfg)
    cfg.bridge_origin = origin
    if "token" in payload and payload.get("token") is not None:
        cfg.bridge_token = str(payload["token"]).strip()
    cfg.updated_at = int(time.time())
    db.commit()
    return {"ok": True, "origin": cfg.bridge_origin, "hasToken": bool(cfg.bridge_token or ENV_VOCA_TOKEN)}


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
    """Forward card creation, streaming the NDJSON progress back to the client.
    The client body carries the user's own LLM settings; we add the bridge token."""
    origin, bridge_headers = _resolve_bridge(db, current_user)
    headers = {**bridge_headers, "Content-Type": "application/json"}
    body = await request.body()
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
    body = await request.body()
    async with httpx.AsyncClient(timeout=120.0) as client:
        try:
            resp = await client.post(f"{origin}/v1/audio/{card_id}", content=body, headers=headers)
        except httpx.RequestError as exc:
            raise HTTPException(status_code=502, detail=f"Voca bridge unreachable: {exc}") from exc
    return JSONResponse(status_code=resp.status_code, content=_safe_json(resp))
