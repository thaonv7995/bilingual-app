import os
import json
import httpx
from fastapi import APIRouter, Request, HTTPException, Depends
from fastapi.responses import StreamingResponse
from api.auth import get_current_user_or_apikey
from api.database import User

router = APIRouter(prefix="/api/chat", tags=["chat"])

@router.post("")
@router.post("/")
async def chat_proxy(request: Request, current_user: User = Depends(get_current_user_or_apikey)):
    """Proxies completions requests to LLMs directly to bypass CORS."""
    body = await request.body()
    try:
        data = json.loads(body.decode("utf-8"))
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid request body")
        
    base_url = data.get("baseURL", "https://api.openai.com/v1").rstrip("/")
    if not base_url.startswith("https://") or "localhost" in base_url or "127.0.0.1" in base_url:
        raise HTTPException(status_code=400, detail="Invalid or disallowed base URL")
        
    target_url = f"{base_url}/chat/completions"
    api_key = data.get("apiKey", "")
    
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
async def realtime_session_proxy(request: Request, current_user: User = Depends(get_current_user_or_apikey)):
    """Proxies request to OpenAI to create an ephemeral realtime session client_secret."""
    body = await request.body()
    try:
        data = json.loads(body.decode("utf-8"))
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid request body")
        
    api_key = data.get("apiKey", "") or os.environ.get("OPENAI_API_KEY", "")
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

