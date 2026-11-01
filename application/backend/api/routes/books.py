import shutil
import tempfile
import time
from pathlib import Path
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, File, UploadFile, Request, Response, status, BackgroundTasks
from fastapi.responses import FileResponse, HTMLResponse
from sqlalchemy import or_
from sqlalchemy.orm import Session

from api.database import get_db, User, Book, UserPermission, Highlight, ReadingProgress, UserBookState
from api.auth import (
    get_current_user_or_apikey,
    require_admin,
    decode_access_token,
    is_trusted_notebook_client,
)
from api.config import BOOKS_DIR
from books_core.paths import BookPaths
from books_core.package import pack_book, unpack_book, validate_book_slug

router = APIRouter(prefix="/api/books", tags=["books"])
content_router = APIRouter(prefix="/books", tags=["books content"])


def _ensure_safe_slug(slug: str) -> str:
    try:
        return validate_book_slug(slug)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Invalid book slug.",
        ) from exc


# --- Helper function for cookie & header authentication ---
def get_user_from_request(request: Request, db: Session) -> Optional[User]:
    # 0. Try Trusted Notebook Client-ID first
    if is_trusted_notebook_client(request):
        notebook_user = User(username="client_notebook_studio", is_admin=True)
        notebook_user._is_notebook_client = True
        return notebook_user

    # 1. Try X-API-Key first
    api_key = request.headers.get("X-API-Key")
    if api_key:
        if is_trusted_notebook_client(request, api_key):
            notebook_user = User(username="client_notebook_studio", is_admin=True)
            notebook_user._is_notebook_client = True
            return notebook_user
        from api.database import APIKey
        key_record = db.query(APIKey).filter(APIKey.key_value == api_key, APIKey.is_active == True).first()
        if key_record:
            return User(username=f"apikey_{key_record.name}", is_admin=True)

    # Helper to decode and fetch user
    def get_user_from_jwt(t: str) -> Optional[User]:
        payload = decode_access_token(t)
        if payload and "sub" in payload:
            return db.query(User).filter(User.username == payload["sub"]).first()
        return None

    # 2. Try Authorization Header
    auth_header = request.headers.get("Authorization")
    if auth_header and auth_header.startswith("Bearer "):
        token = auth_header.split(" ")[1]
        user = get_user_from_jwt(token)
        if user: return user
    
    # 3. Try Query Parameter
    token_query = request.query_params.get("token")
    if token_query:
        user = get_user_from_jwt(token_query)
        if user: return user

    # 4. Try Cookie (important for iframes/images)
    token_cookie = request.cookies.get("jwt_token")
    if token_cookie:
        user = get_user_from_jwt(token_cookie)
        if user: return user
        
    return None

# --- Intercepting static book files for access control ---
@content_router.get("/{slug}/output/{path:path}")
def serve_secure_book_static(slug: str, path: str, request: Request, db: Session = Depends(get_db)):
    """
    Intercepts access to books/<slug>/output/* files.
    Checks if the user is authorized (is admin, or has specific book permission).
    """
    user = get_user_from_request(request, db)
    if not user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Access Denied: Please log in first."
        )

    # Admins have access to everything
    if not user.is_admin:
        # Check permissions for regular users
        has_permission = db.query(UserPermission).filter(
            UserPermission.user_id == user.id,
            UserPermission.book_slug == slug
        ).first()
        
        if not has_permission:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Access Denied: You do not have permission to view this book."
            )

    slug = _ensure_safe_slug(slug)

    # Serve the requested file safely
    books_root = BOOKS_DIR.resolve()
    base_dir = (books_root / slug / "output").resolve()
    if base_dir.parts[:len(books_root.parts)] != books_root.parts:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Access Denied: Invalid book slug."
        )
    file_path = (base_dir / path).resolve()
    
    # Robust path traversal check
    if file_path.parts[:len(base_dir.parts)] != base_dir.parts:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Access Denied: Invalid path."
        )

    if not file_path.is_file():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Book resource file not found."
        )

    suffix = file_path.suffix.lower()

    # If it is an HTML page and embed=1 is requested, inject the Smart Quote listener
    if suffix == ".html" and request.query_params.get("embed") == "1":
        try:
            content = file_path.read_text(encoding="utf-8")
            smart_quote_script = """
<style>
.nb-quote-popover {
  position: fixed;
  z-index: 999999;
  background: #1e293b;
  color: #f8fafc;
  border: 1px solid #475569;
  border-radius: 8px;
  box-shadow: 0 10px 25px rgba(0,0,0,0.5);
  padding: 4px;
  display: flex;
  gap: 4px;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  font-size: 13px;
  animation: nbFadeIn 0.15s ease-out;
}
@keyframes nbFadeIn {
  from { opacity: 0; transform: translateY(4px); }
  to { opacity: 1; transform: translateY(0); }
}
.nb-quote-btn {
  background: #3b82f6;
  color: white;
  border: none;
  border-radius: 6px;
  padding: 6px 12px;
  cursor: pointer;
  font-weight: 500;
  display: flex;
  align-items: center;
  gap: 6px;
  transition: background 0.2s;
}
.nb-quote-btn:hover {
  background: #2563eb;
}
</style>
<script>
(function() {
  if (window.parent && window.parent !== window) {
    let popover = null;
    function hidePopover() {
      if (popover) { popover.remove(); popover = null; }
    }
    document.addEventListener('mouseup', function(e) {
      setTimeout(function() {
        const sel = window.getSelection();
        const text = sel ? sel.toString().trim() : '';
        if (!text || text.length < 2) { hidePopover(); return; }
        const range = sel.getRangeAt(0);
        const rect = range.getBoundingClientRect();
        hidePopover();
        popover = document.createElement('div');
        popover.className = 'nb-quote-popover';
        popover.innerHTML = '<button type="button" class="nb-quote-btn"><span>✦</span> Trích dẫn vào sổ</button>';
        const top = Math.max(10, rect.top - 46);
        const left = Math.max(10, rect.left + (rect.width / 2) - 80);
        popover.style.top = top + 'px';
        popover.style.left = left + 'px';
        document.body.appendChild(popover);
        popover.querySelector('.nb-quote-btn').onclick = function(evt) {
          evt.stopPropagation();
          window.parent.postMessage({
            type: 'NOTEBOOK_INSERT_QUOTE',
            quote: text,
            title: document.title,
            url: window.location.href
          }, '*');
          hidePopover();
        };
      }, 60);
    });
    document.addEventListener('mousedown', function(e) {
      if (popover && !popover.contains(e.target)) hidePopover();
    });
  }
})();
</script>
"""
            if "</body>" in content:
                content = content.replace("</body>", f"{smart_quote_script}\n</body>")
            else:
                content += smart_quote_script
            return HTMLResponse(
                content=content,
                media_type="text/html",
                headers={"Cache-Control": "private, max-age=3600"},
            )
        except Exception:
            pass

    cache_max_age = 3600 if suffix == ".html" else 86400
    return FileResponse(
        file_path,
        headers={"Cache-Control": f"private, max-age={cache_max_age}"},
    )

# --- Books CRUD APIs ---
@router.get("")
@router.get("/")
def list_books(current_user: User = Depends(get_current_user_or_apikey), db: Session = Depends(get_db)):
    """List books available to the logged-in user, already in shelf order.

    The order is server-authoritative so an unmodified client renders it right:

      tier 1 - books THIS user has read, most recently read first
      tier 2 - books never read, most recently imported first (created_at DESC)

    Tier 1 always sits above tier 2, so reading a book moves it to position 1 —
    reading activity beats import recency, this is not a max(created, read) blend.
    Ties break on id DESC (autoincrement, i.e. import order) then slug, which is
    also what carries rows whose created_at is NULL (imported before the column
    existed) into their correct place.
    """
    if current_user.is_admin:
        # Admin sees all books
        books = db.query(Book).order_by(Book.id.desc()).all()
    else:
        # Regular user sees only allowed books
        allowed_slugs = [p.book_slug for p in current_user.permissions]
        books = db.query(Book).filter(Book.slug.in_(allowed_slugs)).order_by(Book.id.desc()).all()

    # One query for the whole shelf, joined in Python by slug. Per-book queries
    # would be dozens of round-trips on an endpoint hit at every app launch.
    # `id is None` covers the virtual admin minted for API keys: it is not a
    # persisted user and therefore owns no progress.
    last_read_by_slug = {}
    state_by_slug = {}
    if books and current_user.id is not None:
        rows = db.query(ReadingProgress.book_slug, ReadingProgress.last_read).filter(
            ReadingProgress.user_id == current_user.id
        ).all()
        last_read_by_slug = {slug: last_read for slug, last_read in rows if last_read}
        states = db.query(UserBookState).filter(UserBookState.user_id == current_user.id).all()
        state_by_slug = {state.book_slug: state for state in states}

    def _shelf_key(b: Book):
        last_read = last_read_by_slug.get(b.slug)
        state = state_by_slug.get(b.slug)
        return (
            0 if state and state.is_priority else 1,
            0 if last_read else 1,      # tier: read books first
            -(last_read or 0),          # tier 1: most recently read first
            -(b.created_at or 0),       # tier 2: newest import first
            -b.id,                      # NULL created_at -> id DESC (import order)
            b.slug,                     # total order, never database-arbitrary
        )

    books.sort(key=_shelf_key)

    return [
        {
            # Autoincrement row id == import order. Sent because the clients
            # re-sort with this same key: without it their tie-break degenerates
            # to slug (alphabetical), which silently loses the import order for
            # every row whose created_at is NULL — i.e. the whole shelf of any
            # library that predates the created_at column.
            "id": b.id,
            "slug": b.slug,
            "title": b.title,
            "author": b.author,
            "pageCount": b.page_count,
            "cover": f"books/{b.slug}/output/{b.cover_path}" if b.cover_path else None,
            "isPublished": b.is_published,
            "createdAt": b.created_at,
            "lastRead": last_read_by_slug.get(b.slug),
            "isFinished": bool(state_by_slug.get(b.slug) and state_by_slug[b.slug].is_finished),
            "onShelf": bool(state_by_slug.get(b.slug) and state_by_slug[b.slug].on_shelf),
            "isPriority": bool(state_by_slug.get(b.slug) and state_by_slug[b.slug].is_priority),
            "defaultFont": (b.default_font if getattr(b, "default_font", None) else "default") or "default",
            "defaultTheme": (b.default_theme if getattr(b, "default_theme", None) else "default") or "default",
            "readerFont": (state_by_slug[b.slug].reader_font if state_by_slug.get(b.slug) and getattr(state_by_slug[b.slug], "reader_font", None) else "") or "",
            "readerTheme": (state_by_slug[b.slug].reader_theme if state_by_slug.get(b.slug) and getattr(state_by_slug[b.slug], "reader_theme", None) else "") or "",
        }
        for b in books
    ]

@router.patch("/{slug}/state")
def update_book_state(
    slug: str,
    state_data: dict,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    """Update this user's organisational flags and per-book appearance preferences."""
    slug = _ensure_safe_slug(slug)
    book = db.query(Book).filter(Book.slug == slug).first()
    if not book:
        raise HTTPException(status_code=404, detail="Book not found")
    if not current_user.is_admin:
        has_permission = db.query(UserPermission).filter(
            UserPermission.user_id == current_user.id,
            UserPermission.book_slug == slug,
        ).first()
        if not has_permission:
            raise HTTPException(status_code=403, detail="No permission to manage this book")
    if current_user.id is None:
        raise HTTPException(status_code=400, detail="API keys cannot own a personal shelf")

    allowed_bool = {
        "isFinished": "is_finished",
        "onShelf": "on_shelf",
        "isPriority": "is_priority",
    }
    allowed_str = {
        "readerFont": "reader_font",
        "readerTheme": "reader_theme",
    }
    supplied_bool = {key: value for key, value in state_data.items() if key in allowed_bool}
    supplied_str = {key: value for key, value in state_data.items() if key in allowed_str}

    if not supplied_bool and not supplied_str:
        raise HTTPException(status_code=422, detail="No valid state fields supplied")
    if any(not isinstance(value, bool) for value in supplied_bool.values()):
        raise HTTPException(status_code=422, detail="State fields must be booleans")
    if any(not isinstance(value, str) or len(value) > 512 for value in supplied_str.values()):
        raise HTTPException(status_code=422, detail="Appearance fields must be short strings")

    state = db.query(UserBookState).filter(
        UserBookState.user_id == current_user.id,
        UserBookState.book_slug == slug,
    ).first()
    if not state:
        state = UserBookState(user_id=current_user.id, book_slug=slug)
        db.add(state)
    for json_key, value in supplied_bool.items():
        setattr(state, allowed_bool[json_key], value)
    for json_key, value in supplied_str.items():
        setattr(state, allowed_str[json_key], value.strip())
    # The current UI exposes one library state at a time: priority, finished,
    # or normal (both false). Keep legacy `on_shelf` data inert as normal.
    if supplied_bool.get("isPriority") is True:
        state.is_finished = False
        state.on_shelf = False
    elif supplied_bool.get("isFinished") is True:
        state.is_priority = False
        state.on_shelf = False
    db.commit()
    db.refresh(state)
    result = {
        "isFinished": state.is_finished,
        "onShelf": state.on_shelf,
        "isPriority": state.is_priority,
    }
    if "readerFont" in supplied_str or state.reader_font:
        result["readerFont"] = state.reader_font or ""
    if "readerTheme" in supplied_str or state.reader_theme:
        result["readerTheme"] = state.reader_theme or ""
    return result


@router.patch("/{slug}/appearance-defaults")
def update_book_appearance_defaults(
    slug: str,
    payload: dict,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    """Update a book's default font and paper color theme (persisted in DB and book.json)."""
    slug = _ensure_safe_slug(slug)
    book = db.query(Book).filter(Book.slug == slug).first()
    if not book:
        raise HTTPException(status_code=404, detail="Book not found")
    if not current_user.is_admin:
        has_permission = db.query(UserPermission).filter(
            UserPermission.user_id == current_user.id,
            UserPermission.book_slug == slug,
        ).first()
        if not has_permission:
            raise HTTPException(status_code=403, detail="No permission to configure this book")

    default_font = payload.get("defaultFont")
    default_theme = payload.get("defaultTheme")
    if default_font is None and default_theme is None:
        raise HTTPException(status_code=422, detail="Provide defaultFont and/or defaultTheme")

    if default_font is not None:
        if not isinstance(default_font, str) or len(default_font) > 128:
            raise HTTPException(status_code=422, detail="Invalid defaultFont")
        book.default_font = default_font.strip() or "default"

    if default_theme is not None:
        if not isinstance(default_theme, str) or len(default_theme) > 512:
            raise HTTPException(status_code=422, detail="Invalid defaultTheme")
        book.default_theme = default_theme.strip() or "default"

    db.commit()
    db.refresh(book)

    # Also persist into books/<slug>/book.json if present so exports (.bkb) and startup sync retain it
    book_dir = BOOKS_DIR / slug
    if (book_dir / "book.json").is_file():
        try:
            import json
            book_json_path = book_dir / "book.json"
            meta = json.loads(book_json_path.read_text(encoding="utf-8"))
            meta["default_font"] = book.default_font or "default"
            meta["default_theme"] = book.default_theme or "default"
            book_json_path.write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        except Exception as exc:
            print(f"[Book Defaults] Could not update book.json for '{slug}': {exc}")

    return {
        "slug": book.slug,
        "defaultFont": book.default_font or "default",
        "defaultTheme": book.default_theme or "default",
    }

@router.post("/upload")
def upload_bkb(
    file: UploadFile = File(...),
    current_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Admin endpoint to upload a .bkb package file."""
    if not file.filename.endswith(".bkb"):
        raise HTTPException(status_code=400, detail="Only .bkb packages are supported")
        
    # Save uploaded file to temp file
    with tempfile.NamedTemporaryFile(suffix=".bkb", delete=False) as tmp:
        shutil.copyfileobj(file.file, tmp)
        tmp_path = Path(tmp.name)
        
    try:
        # Unpack the book into workspace books folder
        result = unpack_book(tmp_path, BOOKS_DIR)
        
        # Sync the new book to Database
        book_slug = result["slug"]
        book_paths = BookPaths.open(BOOKS_DIR / book_slug)
        metadata = book_paths.load_book_json()
        
        cover_val = metadata.get("cover") or ""
        if not cover_val:
            for possible_cover in ["assets/cover.jpg", "assets/cover.png", "assets/images/page_0001_cover_logo.png"]:
                if (BOOKS_DIR / book_slug / "output" / possible_cover).is_file():
                    cover_val = possible_cover
                    break
        db_book = db.query(Book).filter(Book.slug == book_slug).first()
        if not db_book:
            db_book = Book(
                slug=book_slug,
                title=metadata.get("title", result["title"]),
                author=metadata.get("author", "Unknown"),
                page_count=book_paths.estimate_page_count(),
                cover_path=cover_val,
                is_published=True,
                default_font=metadata.get("default_font") or "default",
                default_theme=metadata.get("default_theme") or "default",
                created_at=int(time.time())
            )
            db.add(db_book)
        else:
            db_book.page_count = book_paths.estimate_page_count()
            db_book.title = metadata.get("title", db_book.title)
            db_book.author = metadata.get("author", db_book.author)
            if cover_val:
                db_book.cover_path = cover_val
            if metadata.get("default_font"):
                db_book.default_font = metadata["default_font"]
            if metadata.get("default_theme"):
                db_book.default_theme = metadata["default_theme"]
                
        db.commit()
        return {"ok": True, "slug": book_slug, "message": f"Successfully imported '{result['title']}'"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to process BKB archive: {str(e)}")
    finally:
        if tmp_path.exists():
            tmp_path.unlink()

@router.get("/{slug}/download")
def download_bkb(
    slug: str,
    background_tasks: BackgroundTasks,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db)
):
    """Download the book as a .bkb package file."""
    slug = _ensure_safe_slug(slug)
    # Check permissions
    if not current_user.is_admin:
        has_permission = db.query(UserPermission).filter(
            UserPermission.user_id == current_user.id,
            UserPermission.book_slug == slug
        ).first()
        if not has_permission:
            raise HTTPException(status_code=403, detail="No permission to download this book")
            
    book_dir = (BOOKS_DIR / slug).resolve()
    if book_dir.parent != BOOKS_DIR.resolve() or not book_dir.is_dir():
        raise HTTPException(status_code=404, detail="Book directory not found")
        
    # Create a unique temp file (not inside a TemporaryDirectory that deletes itself on return)
    tmp_file = tempfile.NamedTemporaryFile(suffix=".bkb", delete=False)
    tmp_file.close()
    bkb_out_path = Path(tmp_file.name)
    
    try:
        pack_book(book_dir, bkb_out_path)
        # Register a background task to delete the file after response is sent
        background_tasks.add_task(bkb_out_path.unlink, missing_ok=True)
        return FileResponse(
            bkb_out_path,
            media_type="application/octet-stream",
            filename=f"{slug}.bkb"
        )
    except Exception as e:
        if bkb_out_path.exists():
            bkb_out_path.unlink()
        raise HTTPException(status_code=500, detail=f"Failed to package book: {e}")

@router.get("/{slug}/manifest")
def get_book_manifest(slug: str, current_user: User = Depends(get_current_user_or_apikey), db: Session = Depends(get_db)):
    """Return a manifest of all file paths under output/ for downloading."""
    slug = _ensure_safe_slug(slug)
    # Check permissions
    if not current_user.is_admin:
        has_permission = db.query(UserPermission).filter(
            UserPermission.user_id == current_user.id,
            UserPermission.book_slug == slug
        ).first()
        if not has_permission:
            raise HTTPException(status_code=403, detail="No permission to access this book")
            
    book_dir = BOOKS_DIR / slug / "output"
    if not book_dir.is_dir():
        raise HTTPException(status_code=404, detail="Book output directory not found")
        
    files = []
    for p in book_dir.rglob("*"):
        if p.is_file():
            # Get path relative to the output folder
            rel_path = p.relative_to(book_dir)
            files.append(str(rel_path))
            
    return {"files": files}

@router.delete("/{slug}")
def delete_book(slug: str, current_user: User = Depends(require_admin), db: Session = Depends(get_db)):
    """Delete a book from DB and filesystem."""
    slug = _ensure_safe_slug(slug)
    db_book = db.query(Book).filter(Book.slug == slug).first()
    if not db_book:
        raise HTTPException(status_code=404, detail="Book not found in DB")
        
    # Remove from DB
    db.delete(db_book)
    
    # Remove associated permissions
    db.query(UserPermission).filter(UserPermission.book_slug == slug).delete()
    
    # Remove associated highlights
    db.query(Highlight).filter(Highlight.book_slug == slug).delete()
    
    # Remove associated progress
    db.query(ReadingProgress).filter(ReadingProgress.book_slug == slug).delete()

    # Remove personal shelf metadata
    db.query(UserBookState).filter(UserBookState.book_slug == slug).delete()
    
    db.commit()
    
    # Remove physical directory
    book_dir = (BOOKS_DIR / slug).resolve()
    if book_dir.parent == BOOKS_DIR.resolve() and book_dir.is_dir():
        shutil.rmtree(book_dir, ignore_errors=True)
        
    return {"ok": True, "message": f"Successfully deleted book '{slug}'"}

# --- Highlights Sync APIs ---
@router.get("/{slug}/highlights")
def get_highlights(slug: str, current_user: User = Depends(get_current_user_or_apikey), db: Session = Depends(get_db)):
    """Fetch all highlights for a specific book owned by the current user."""
    slug = _ensure_safe_slug(slug)
    # Check permissions
    if not current_user.is_admin:
        has_perm = db.query(UserPermission).filter(
            UserPermission.user_id == current_user.id,
            UserPermission.book_slug == slug
        ).first()
        if not has_perm:
            raise HTTPException(status_code=403, detail="No permission to read this book")
            
    highlights = db.query(Highlight).filter(
        Highlight.book_slug == slug,
        or_(Highlight.username == current_user.username, Highlight.username.is_(None)),
    ).all()
    return {
        "highlights": [
            {
                "id": h.id,
                "page": h.page,
                "lang": h.lang,
                "color": h.color,
                "text": h.text,
                "startOffset": h.start_offset,
                "endOffset": h.end_offset,
                "paragraphIndex": h.paragraph_index,
                "note": h.note,
                "createdAt": h.created_at
            }
            for h in highlights
        ]
    }

@router.post("/{slug}/highlights")
def create_or_update_highlight(
    slug: str,
    highlight_data: dict,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db)
):
    """Add or edit a highlight sentence."""
    slug = _ensure_safe_slug(slug)
    if not current_user.is_admin:
        has_perm = db.query(UserPermission).filter(
            UserPermission.user_id == current_user.id,
            UserPermission.book_slug == slug
        ).first()
        if not has_perm:
            raise HTTPException(status_code=403, detail="No permission")

    hl_id = highlight_data.get("id")
    if not hl_id or not isinstance(hl_id, str):
        raise HTTPException(status_code=400, detail="Highlight ID is required")

    db_hl = db.query(Highlight).filter(Highlight.id == hl_id).first()
    if not db_hl:
        page = highlight_data.get("page")
        lang = highlight_data.get("lang")
        color = highlight_data.get("color")
        text = highlight_data.get("text")
        if page is None or not lang or not color or text is None:
            raise HTTPException(status_code=422, detail="Missing required highlight fields (page, lang, color, text)")
        db_hl = Highlight(
            id=hl_id,
            book_slug=slug,
            page=int(page),
            lang=str(lang),
            color=str(color),
            text=str(text),
            start_offset=int(highlight_data.get("startOffset", 0)),
            end_offset=int(highlight_data.get("endOffset", 0)),
            paragraph_index=int(highlight_data.get("paragraphIndex", 0)),
            note=str(highlight_data.get("note", "") or ""),
            username=current_user.username
        )
        db.add(db_hl)
    else:
        # Prevent IDOR / cross-user collision: check ownership and book slug
        if db_hl.username and db_hl.username != current_user.username:
            raise HTTPException(status_code=403, detail="Not allowed to modify this highlight")
        if db_hl.book_slug != slug:
            raise HTTPException(status_code=400, detail="Highlight does not belong to this book")
            
        # Update fields
        db_hl.color = highlight_data.get("color", db_hl.color)
        db_hl.note = highlight_data.get("note", db_hl.note)
        
    db.commit()
    return {"ok": True}

@router.delete("/{slug}/highlights/{hl_id}")
def delete_highlight(
    slug: str,
    hl_id: str,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db)
):
    """Delete a highlight by ID."""
    slug = _ensure_safe_slug(slug)
    db_hl = db.query(Highlight).filter(Highlight.id == hl_id, Highlight.book_slug == slug).first()
    if not db_hl:
        raise HTTPException(status_code=404, detail="Highlight not found")
        
    # Prevent IDOR: Check ownership
    if db_hl.username and db_hl.username != current_user.username and not current_user.is_admin:
        raise HTTPException(status_code=403, detail="Not allowed to delete this highlight")
        
    db.delete(db_hl)
    db.commit()
    return {"ok": True}

# --- Reading Progress Sync APIs ---
@router.get("/{slug}/progress")
def get_reading_progress(
    slug: str,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db)
):
    """Retrieve the logged-in user's reading progress for a book."""
    if current_user.id is None:
        return {"page": 1, "viewMode": "en"}
    progress = db.query(ReadingProgress).filter(
        ReadingProgress.user_id == current_user.id,
        ReadingProgress.book_slug == slug
    ).first()
    
    if not progress:
        return {"page": 1, "viewMode": "en"}
        
    return {
        "page": progress.page,
        "viewMode": progress.view_mode,
        "lastRead": progress.last_read
    }

@router.post("/{slug}/progress")
def save_reading_progress(
    slug: str,
    progress_data: dict,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db)
):
    """Save the logged-in user's reading progress — newest `lastRead` wins.

    Clients send `lastRead` (unix seconds: when the page turn actually happened)
    so a delayed or offline-replayed POST from one device cannot overwrite newer
    progress already saved from another. Requests without `lastRead` (older
    clients) are stamped with the server clock, which reproduces their previous
    always-overwrite behaviour. The response always carries the authoritative
    stored progress so a rejected (stale) writer can reconcile.
    """
    if current_user.id is None:
        raise HTTPException(status_code=400, detail="API keys cannot save personal reading progress")
    page = progress_data.get("page", 1)
    view_mode = progress_data.get("viewMode", "en")

    now = int(time.time())
    last_read = progress_data.get("lastRead")
    if isinstance(last_read, (int, float)) and not isinstance(last_read, bool) and last_read > 0:
        # Clamp to the server clock so a device with a fast clock can't publish
        # progress "from the future" that would win every later conflict.
        last_read = min(int(last_read), now)
    else:
        last_read = now

    progress = db.query(ReadingProgress).filter(
        ReadingProgress.user_id == current_user.id,
        ReadingProgress.book_slug == slug
    ).first()

    if progress and progress.last_read and progress.last_read > last_read:
        return {
            "ok": True,
            "stored": False,
            "progress": {
                "page": progress.page,
                "viewMode": progress.view_mode,
                "lastRead": progress.last_read,
            },
        }

    if not progress:
        progress = ReadingProgress(
            user_id=current_user.id,
            book_slug=slug,
            page=page,
            view_mode=view_mode,
            last_read=last_read
        )
        db.add(progress)
    else:
        progress.page = page
        progress.view_mode = view_mode
        progress.last_read = last_read

    db.commit()
    return {
        "ok": True,
        "stored": True,
        "progress": {"page": page, "viewMode": view_mode, "lastRead": last_read},
    }
