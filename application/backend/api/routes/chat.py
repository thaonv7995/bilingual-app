import json
import httpx
from fastapi import APIRouter, Request, HTTPException
from fastapi.responses import StreamingResponse

router = APIRouter(prefix="/api/chat", tags=["chat"])

@router.post("")
@router.post("/")
async def chat_proxy(request: Request):
    """Proxies completions requests to LLMs directly to bypass CORS."""
    body = await request.body()
    try:
        data = json.loads(body.decode("utf-8"))
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid request body")
        
    base_url = data.get("baseURL", "https://api.openai.com/v1").rstrip("/")
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
    
    async def event_generator():
        async with httpx.AsyncClient(timeout=120.0) as client:
            async with client.stream("POST", target_url, json=payload, headers=headers) as r:
                async for chunk in r.aiter_bytes():
                    yield chunk

    return StreamingResponse(event_generator(), media_type="text/event-stream")
