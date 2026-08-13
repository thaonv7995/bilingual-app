import os
import httpx
from fastapi import APIRouter, Request, HTTPException, Depends
from fastapi.responses import StreamingResponse, Response, JSONResponse
from api.auth import get_current_user_or_apikey
from api.database import User

router = APIRouter(prefix="/api/voca", tags=["voca"])

VOCA_ORIGIN = os.environ.get("VOCA_BRIDGE_ORIGIN", "https://voca-bridge.thaonv.online").rstrip("/")


def _bridge_headers() -> dict:
    """Server-held voca-bridge token (hybrid model): the token lives in the
    backend env and never reaches the browser, unlike v1 which shipped it."""
    token = os.environ.get("VOCA_BRIDGE_TOKEN", "")
    if not token:
        raise HTTPException(status_code=503, detail="Voca bridge is not configured on the server.")
    return {"Authorization": f"Bearer {token}"}


def _safe_json(resp: httpx.Response):
    try:
        return resp.json()
    except Exception:
        return {"error": {"message": resp.text[:300]}}


@router.get("/lookup")
async def voca_lookup(word: str, current_user: User = Depends(get_current_user_or_apikey)):
    headers = _bridge_headers()
    async with httpx.AsyncClient(timeout=30.0) as client:
        try:
            resp = await client.get(
                f"{VOCA_ORIGIN}/v1/cards/lookup", params={"word": word}, headers=headers
            )
        except httpx.RequestError as exc:
            raise HTTPException(status_code=502, detail=f"Voca bridge unreachable: {exc}") from exc
    return JSONResponse(status_code=resp.status_code, content=_safe_json(resp))


@router.post("/create")
async def voca_create(request: Request, current_user: User = Depends(get_current_user_or_apikey)):
    """Forward card creation, streaming the NDJSON progress back to the client.
    The client body carries the user's own LLM settings; we add the bridge token."""
    headers = {**_bridge_headers(), "Content-Type": "application/json"}
    body = await request.body()
    client = httpx.AsyncClient(timeout=120.0)
    try:
        upstream = await client.send(
            client.build_request("POST", f"{VOCA_ORIGIN}/v1/cards/create", content=body, headers=headers),
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
async def voca_audio_get(card_id: str, current_user: User = Depends(get_current_user_or_apikey)):
    headers = _bridge_headers()
    async with httpx.AsyncClient(timeout=60.0) as client:
        try:
            resp = await client.get(f"{VOCA_ORIGIN}/v1/audio/{card_id}", headers=headers)
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
    card_id: str, request: Request, current_user: User = Depends(get_current_user_or_apikey)
):
    headers = {**_bridge_headers(), "Content-Type": "application/json"}
    body = await request.body()
    async with httpx.AsyncClient(timeout=120.0) as client:
        try:
            resp = await client.post(f"{VOCA_ORIGIN}/v1/audio/{card_id}", content=body, headers=headers)
        except httpx.RequestError as exc:
            raise HTTPException(status_code=502, detail=f"Voca bridge unreachable: {exc}") from exc
    return JSONResponse(status_code=resp.status_code, content=_safe_json(resp))
