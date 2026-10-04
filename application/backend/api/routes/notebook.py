"""Notebook Studio Integration Router for Bilingual App.

Enables 2-way sync:
- Fetch user's notebooks from Notebook Studio
- Create a new notebook linked to the current book
- Sync highlights, vocabulary cards, or quick notes to a notebook
- Check pinned notes per page in the current book
"""
import os
import httpx
from fastapi import APIRouter, Request, Depends, HTTPException
from sqlalchemy.orm import Session

from api.auth import get_current_user_or_apikey
from api.database import User, get_db

router = APIRouter(prefix="/api/notebook", tags=["notebook"])

DEFAULT_NOTEBOOK_URL = os.environ.get("NOTEBOOK_STUDIO_URL", "http://127.0.0.1:27972").rstrip("/")
CLIENT_ID = "notebook_client_v1"


def _get_target_notebook_url(request: Request) -> str:
    """Read custom target URL from header or default to localhost."""
    custom = request.headers.get("x-notebook-base-url", "").strip().rstrip("/")
    return custom if custom else DEFAULT_NOTEBOOK_URL


def _get_forward_headers(request: Request, content_type: bool = False) -> dict:
    headers = {"X-Client-ID": CLIENT_ID}
    user = request.headers.get("x-notebook-user", "").strip()
    if user:
        headers["X-Notebook-User"] = user
    if content_type:
        headers["Content-Type"] = "application/json"
    return headers


@router.get("/status")
async def get_integration_status(request: Request):
    """Check connectivity to Notebook Studio."""
    base_url = _get_target_notebook_url(request)
    headers = _get_forward_headers(request)
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            resp = await client.get(
                f"{base_url}/api/bilingual/notebooks",
                headers=headers
            )
            if resp.status_code == 200:
                data = resp.json()
                return {
                    "ok": True,
                    "connected": True,
                    "notebookCount": len(data.get("notebooks", [])),
                    "baseUrl": base_url
                }
            return {
                "ok": False,
                "connected": False,
                "error": f"Notebook Studio phản hồi HTTP {resp.status_code}",
                "baseUrl": base_url
            }
    except Exception as e:
        return {
            "ok": False,
            "connected": False,
            "error": f"Không thể kết nối tới Notebook Studio ({str(e)})",
            "baseUrl": base_url
        }


@router.get("/notebooks")
async def list_notebooks(
    request: Request,
    current_user: User = Depends(get_current_user_or_apikey)
):
    """List notebooks from Notebook Studio."""
    base_url = _get_target_notebook_url(request)
    headers = _get_forward_headers(request)
    try:
        async with httpx.AsyncClient(timeout=4.0) as client:
            resp = await client.get(
                f"{base_url}/api/bilingual/notebooks",
                headers=headers
            )
            if resp.status_code == 200:
                return resp.json()
            return {"ok": False, "notebooks": [], "error": f"HTTP {resp.status_code}"}
    except Exception as e:
        return {"ok": False, "notebooks": [], "error": str(e), "offline": True}


@router.post("/notebooks")
async def create_notebook(
    request: Request,
    payload: dict,
    current_user: User = Depends(get_current_user_or_apikey)
):
    """Create a new notebook in Notebook Studio."""
    base_url = _get_target_notebook_url(request)
    headers = _get_forward_headers(request, content_type=True)
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.post(
                f"{base_url}/api/bilingual/notebooks",
                headers=headers,
                json=payload
            )
            if resp.status_code == 200:
                return resp.json()
            return {"ok": False, "error": f"HTTP {resp.status_code}: {resp.text}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@router.get("/books/{slug}/status")
async def get_book_notebook_status(
    slug: str,
    request: Request,
    current_user: User = Depends(get_current_user_or_apikey)
):
    """Get linked notebook and pinned pages for a specific book."""
    base_url = _get_target_notebook_url(request)
    headers = _get_forward_headers(request)
    try:
        async with httpx.AsyncClient(timeout=4.0) as client:
            resp = await client.get(
                f"{base_url}/api/bilingual/books/{slug}/notebook-status",
                headers=headers
            )
            if resp.status_code == 200:
                return resp.json()
            return {"ok": False, "linkedNotebook": None, "pagesWithNotes": [], "notes": []}
    except Exception as e:
        return {"ok": False, "linkedNotebook": None, "pagesWithNotes": [], "notes": [], "offline": True}


@router.post("/books/{slug}/link")
async def link_notebook_to_book(
    slug: str,
    request: Request,
    payload: dict,
    current_user: User = Depends(get_current_user_or_apikey)
):
    """Link a notebook to a book slug."""
    base_url = _get_target_notebook_url(request)
    headers = _get_forward_headers(request, content_type=True)
    try:
        async with httpx.AsyncClient(timeout=4.0) as client:
            resp = await client.post(
                f"{base_url}/api/bilingual/books/{slug}/link-notebook",
                headers=headers,
                json=payload
            )
            if resp.status_code == 200:
                return resp.json()
            return {"ok": False, "error": f"HTTP {resp.status_code}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@router.post("/sync")
async def sync_note_to_notebook(
    request: Request,
    payload: dict,
    current_user: User = Depends(get_current_user_or_apikey)
):
    """Push a quote, vocab card, or note to a notebook page."""
    base_url = _get_target_notebook_url(request)
    notebook_id = payload.get("notebookId")
    if not notebook_id:
        raise HTTPException(status_code=400, detail="Thiếu notebookId")

    headers = _get_forward_headers(request, content_type=True)
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.post(
                f"{base_url}/api/bilingual/notebooks/{notebook_id}/notes",
                headers=headers,
                json=payload
            )
            if resp.status_code == 200:
                return resp.json()
            return {"ok": False, "error": f"HTTP {resp.status_code}: {resp.text}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@router.get("/notebooks/{notebook_id}/page-detail")
async def get_notebook_page_detail(
    notebook_id: str,
    bookSlug: str = "",
    page: int = None,
    pageId: str = None,
    bookTitle: str = "",
    request: Request = None,
    current_user: User = Depends(get_current_user_or_apikey)
):
    """Proxy getting full page template data for a specific book page or pageId."""
    base_url = _get_target_notebook_url(request)
    headers = _get_forward_headers(request)
    params = {}
    if bookSlug:
        params["bookSlug"] = bookSlug
    if page is not None:
        params["page"] = page
    if pageId:
        params["pageId"] = pageId
    if bookTitle:
        params["bookTitle"] = bookTitle
    try:
        async with httpx.AsyncClient(timeout=4.0) as client:
            resp = await client.get(
                f"{base_url}/api/bilingual/notebooks/{notebook_id}/page-detail",
                params=params,
                headers=headers
            )
            if resp.status_code == 200:
                return resp.json()
            return {"ok": False, "error": f"HTTP {resp.status_code}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@router.put("/notebooks/{notebook_id}/page-detail")
async def update_notebook_page_detail(
    notebook_id: str,
    payload: dict,
    request: Request,
    current_user: User = Depends(get_current_user_or_apikey)
):
    """Proxy saving full page template data to Notebook Studio."""
    base_url = _get_target_notebook_url(request)
    headers = _get_forward_headers(request, content_type=True)
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.put(
                f"{base_url}/api/bilingual/notebooks/{notebook_id}/page-detail",
                headers=headers,
                json=payload
            )
            if resp.status_code == 200:
                return resp.json()
            return {"ok": False, "error": f"HTTP {resp.status_code}: {resp.text}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}
