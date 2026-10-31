import ipaddress
import os
import json
from urllib.parse import urlsplit
import httpx
from fastapi import APIRouter, Request, HTTPException, Depends
from fastapi.responses import StreamingResponse
from sqlalchemy.orm import Session
from api.auth import get_current_user_or_apikey
from api.database import User, UserSettings, get_db

router = APIRouter(prefix="/api/chat", tags=["chat"])

ENV_OPENAI = os.environ.get("OPENAI_API_KEY", "")

_BLOCKED_HOST_SUFFIXES = (".localhost", ".local", ".internal", ".home.arpa")


def _validate_chat_base_url(raw_url: str) -> tuple[str, str]:
    """Validate and normalize the upstream LLM base URL against SSRF.
    Returns (normalized_base_url, hostname).
    """
    base_url = (raw_url or "https://api.openai.com/v1").strip().rstrip("/")
    parts = urlsplit(base_url)
    if parts.scheme != "https" or not parts.hostname or parts.username or parts.password:
        raise HTTPException(status_code=400, detail="Invalid or disallowed base URL")

    host = parts.hostname.lower()
    if host == "localhost" or host.endswith(_BLOCKED_HOST_SUFFIXES):
        raise HTTPException(status_code=400, detail="Invalid or disallowed base URL")

    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return base_url, host

    if (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_reserved
        or ip.is_multicast
        or ip.is_unspecified
    ):
        raise HTTPException(status_code=400, detail="Invalid or disallowed base URL")

    return base_url, host


def _user_settings(db: Session, user: User):
    if getattr(user, "id", None) is None:
        return None
    return db.query(UserSettings).filter(UserSettings.user_id == user.id).first()

@router.post("")
@router.post("/")
async def chat_proxy(
    request: Request,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    """Proxies completions requests to LLMs directly to bypass CORS."""
    body = await request.body()
    try:
        data = json.loads(body.decode("utf-8"))
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid request body")

    base_url, host = _validate_chat_base_url(data.get("baseURL", "https://api.openai.com/v1"))

    target_url = f"{base_url}/chat/completions"
    # Key resolution: the server-held per-user key is authoritative; ENV_OPENAI is
    # only attached when talking to api.openai.com so a custom baseURL can never
    # exfiltrate the server's environment key.
    s = _user_settings(db, current_user)
    env_fallback = ENV_OPENAI if host == "api.openai.com" else ""
    api_key = ((s.llm_api_key or "").strip() if s else "") or env_fallback or data.get("apiKey", "")

    headers = {
        "Content-Type": "application/json",
        "Accept": "text/event-stream"
    }
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
        
    payload = {
        "model": data.get("model", "gpt-4o-mini"),
        "messages": data.get("messages", []),
        "stream": data.get("stream", False)
    }

    client = httpx.AsyncClient(timeout=120.0)
    try:
        upstream = await client.send(
            client.build_request("POST", target_url, json=payload, headers=headers),
            stream=True,
        )
    except httpx.RequestError as exc:
        await client.aclose()
        raise HTTPException(status_code=502, detail=f"Could not reach AI provider: {exc}") from exc

    if upstream.status_code >= 400:
        error_body = (await upstream.aread()).decode("utf-8", errors="replace")[:500]
        await upstream.aclose()
        await client.aclose()
        raise HTTPException(
            status_code=502,
            detail=f"AI provider returned {upstream.status_code}: {error_body}",
        )

    async def event_generator():
        try:
            async for chunk in upstream.aiter_bytes():
                yield chunk
        finally:
            await upstream.aclose()
            await client.aclose()

    return StreamingResponse(event_generator(), media_type="text/event-stream")


@router.post("/realtime/session")
async def realtime_session_proxy(
    request: Request,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    """Proxies request to OpenAI to create an ephemeral realtime session client_secret."""
    body = await request.body()
    try:
        data = json.loads(body.decode("utf-8"))
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid request body")

    # Prefer the dedicated realtime key, then the general LLM key, then env; a
    # client-sent key is only a last-resort fallback.
    s = _user_settings(db, current_user)
    api_key = (
        ((s.realtime_api_key or "").strip() if s else "")
        or ((s.llm_api_key or "").strip() if s else "")
        or ENV_OPENAI
        or data.get("apiKey", "")
    )
    if not api_key:
        raise HTTPException(status_code=400, detail="OpenAI API Key is required. Please set it in Settings or backend environment.")
        
    session_config = data.get("session", {})
    
    # Send request to OpenAI client_secrets endpoint
    target_url = "https://api.openai.com/v1/realtime/client_secrets"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    }
    payload = {
        "session": session_config
    }
    
    client = httpx.AsyncClient(timeout=30.0)
    try:
        response = await client.post(target_url, json=payload, headers=headers)
    except httpx.RequestError as exc:
        await client.aclose()
        raise HTTPException(status_code=502, detail=f"Failed to connect to OpenAI: {exc}") from exc
    finally:
        await client.aclose()
            
    if response.status_code >= 400:
        error_body = response.text[:500]
        raise HTTPException(
            status_code=response.status_code,
            detail=f"OpenAI returned error: {error_body}"
        )
        
    return response.json()

