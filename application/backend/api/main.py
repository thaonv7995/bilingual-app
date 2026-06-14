import os
import secrets
import shutil
import tempfile
from pathlib import Path
from typing import Optional, List
from fastapi import FastAPI, Depends, HTTPException, status, File, UploadFile, Request, Response, Cookie
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from sqlalchemy.orm import Session

from api.database import init_db, get_db, User, Book, UserPermission, APIKey, Highlight, ReadingProgress, UserRefreshToken
from api.auth import (
    get_password_hash,
    verify_password,
    create_access_token,
    get_current_user_or_apikey,
    require_admin,
    decode_access_token,
    REFRESH_TOKEN_EXPIRE_SECONDS
)
from books_core.paths import BookPaths
from books_core.package import pack_book, unpack_book

app = FastAPI(title="Bilingual Digital Library API")

# Enable CORS for frontend flexibility
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

WORKSPACE_ROOT = Path(__file__).resolve().parents[3]
BOOKS_DIR = WORKSPACE_ROOT / "books"

# Initialize DB on Startup
@app.on_event("startup")
def startup_event():
    init_db()
    db = SessionLocal_init()
    try:
        # Create default admin user if none exists
        admin_exists = db.query(User).filter(User.is_admin == True).first()
        if not admin_exists:
            hashed_pw = get_password_hash("admin123")
            admin_user = User(username="admin", password_hash=hashed_pw, is_admin=True)
            db.add(admin_user)
            db.commit()
            print("[Startup] Created default admin user 'admin' (password: 'admin123').")

        # Sync existing books in directory into DB
        sync_books_directory_to_db(db)
    finally:
        db.close()

def SessionLocal_init():
    from api.database import SessionLocal
    return SessionLocal()

def sync_books_directory_to_db(db: Session):
    if not BOOKS_DIR.is_dir():
        return
    for item in BOOKS_DIR.iterdir():
        if item.is_dir() and item.name != "inbox" and not item.name.startswith("."):
            try:
                book_paths = BookPaths.open(item)
                metadata = book_paths.load_book_json()
                
                # Check if book already in DB
                db_book = db.query(Book).filter(Book.slug == item.name).first()
                cover_val = metadata.get("cover") or ""
                
                if not db_book:
                    new_book = Book(
                        slug=item.name,
                        title=metadata.get("title", item.name),
                        author=metadata.get("author", "Unknown"),
                        page_count=book_paths.estimate_page_count(),
                        cover_path=cover_val,
                        is_published=True
                    )
                    db.add(new_book)
                    print(f"[Startup Sync] Added book to DB: {item.name}")
                else:
                    # Sync page count and cover path if updated
                    db_book.page_count = book_paths.estimate_page_count()
                    db_book.title = metadata.get("title", db_book.title)
                    if cover_val:
                        db_book.cover_path = cover_val
            except Exception as e:
                print(f"[Startup Sync Error] Failed syncing book '{item.name}': {e}")
    db.commit()

# --- Helper function for cookie & header authentication ---
def get_user_from_request(request: Request, db: Session) -> Optional[User]:
    # 1. Try Authorization Header
    auth_header = request.headers.get("Authorization")
    token = None
    if auth_header and auth_header.startswith("Bearer "):
        token = auth_header.split(" ")[1]
    
    # 2. Try Cookie (important for iframes/images)
    if not token:
        token = request.cookies.get("jwt_token")
        
    # 3. Try Query Parameter (fallback for iframe page loads)
    if not token:
        token = request.query_params.get("token")

    if token:
        payload = decode_access_token(token)
        if payload:
            username = payload.get("sub")
            if username:
                user = db.query(User).filter(User.username == username).first()
                if user:
                    return user
                    
    # 4. Try X-API-Key
    api_key = request.headers.get("X-API-Key")
    if api_key:
        key_record = db.query(APIKey).filter(APIKey.key_value == api_key, APIKey.is_active == True).first()
        if key_record:
            return User(username=f"apikey_{key_record.name}", is_admin=True)
            
    return None

# --- Intercepting static book files for access control ---
@app.get("/books/{slug}/output/{path:path}")
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

    # Serve the requested file safely
    file_path = BOOKS_DIR / slug / "output" / path
    if not file_path.is_file():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Book resource file not found."
        )
        
    return FileResponse(file_path)

# --- Authentication APIs ---
@app.post("/api/auth/register")
def register(username: str, password: str, db: Session = Depends(get_db)):
    user_exists = db.query(User).filter(User.username == username).first()
    if user_exists:
        raise HTTPException(status_code=400, detail="Username already registered")
        
    new_user = User(
        username=username,
        password_hash=get_password_hash(password),
        is_admin=False
    )
    db.add(new_user)
    db.commit()
    db.refresh(new_user)
    return {"ok": True, "message": "User registered successfully"}

@app.post("/api/auth/login")
def login(username: str, password: str, response: Response, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.username == username).first()
    if not user or not verify_password(password, user.password_hash):
        raise HTTPException(status_code=400, detail="Incorrect username or password")
        
    # Generate short-lived Access Token (15 mins) and long-lived Refresh Token (30 days)
    access_token = create_access_token(data={"sub": user.username})
    refresh_token = secrets.token_hex(32)
    
    # Save Refresh Token to database
    import time
    expires_at = int(time.time()) + REFRESH_TOKEN_EXPIRE_SECONDS
    new_refresh = UserRefreshToken(user_id=user.id, token=refresh_token, expires_at=expires_at)
    db.add(new_refresh)
    db.commit()
    
    # Store Access Token in Cookie (lax)
    response.set_cookie(
        key="jwt_token",
        value=access_token,
        httponly=True,
        max_age=900,
        samesite="lax"
    )
    
    # Store Refresh Token in Cookie (HttpOnly)
    response.set_cookie(
        key="refresh_token",
        value=refresh_token,
        httponly=True,
        max_age=REFRESH_TOKEN_EXPIRE_SECONDS,
        samesite="lax"
    )
    
    return {
        "access_token": access_token,
        "refresh_token": refresh_token,
        "token_type": "bearer",
        "username": user.username,
        "is_admin": user.is_admin
    }

@app.post("/api/auth/refresh")
def refresh_token_endpoint(
    response: Response,
    request: Request,
    body_payload: Optional[dict] = None,
    db: Session = Depends(get_db)
):
    """Generates a new access token using a valid refresh token."""
    # 1. Read refresh token from cookie or payload body
    refresh_token = request.cookies.get("refresh_token")
    if not refresh_token and body_payload:
        refresh_token = body_payload.get("refresh_token")
        
    if not refresh_token:
        raise HTTPException(status_code=401, detail="Refresh token missing")
        
    # 2. Check database
    db_token = db.query(UserRefreshToken).filter(UserRefreshToken.token == refresh_token).first()
    if not db_token:
        raise HTTPException(status_code=401, detail="Invalid refresh token")
        
    import time
    if db_token.expires_at < int(time.time()):
        db.delete(db_token)
        db.commit()
        raise HTTPException(status_code=401, detail="Refresh token expired")
        
    # 3. Fetch User
    user = db.query(User).filter(User.id == db_token.user_id).first()
    if not user:
        raise HTTPException(status_code=401, detail="User not found")
        
    # 4. Generate new access token and optional new rotated refresh token
    new_access_token = create_access_token(data={"sub": user.username})
    new_refresh_token = secrets.token_hex(32)
    
    # Update refresh token in DB
    db_token.token = new_refresh_token
    db_token.expires_at = int(time.time()) + REFRESH_TOKEN_EXPIRE_SECONDS
    db.commit()
    
    # Set cookies
    response.set_cookie(
        key="jwt_token",
        value=new_access_token,
        httponly=True,
        max_age=900,
        samesite="lax"
    )
    response.set_cookie(
        key="refresh_token",
        value=new_refresh_token,
        httponly=True,
        max_age=REFRESH_TOKEN_EXPIRE_SECONDS,
        samesite="lax"
    )
    
    return {
        "access_token": new_access_token,
        "refresh_token": new_refresh_token,
        "token_type": "bearer"
    }

@app.post("/api/auth/logout")
def logout(response: Response, request: Request, db: Session = Depends(get_db)):
    # Delete refresh token from DB if present
    refresh_token = request.cookies.get("refresh_token")
    if refresh_token:
        db.query(UserRefreshToken).filter(UserRefreshToken.token == refresh_token).delete()
        db.commit()
        
    response.delete_cookie("jwt_token")
    response.delete_cookie("refresh_token")
    return {"ok": True}

@app.get("/api/auth/me")
def get_me(current_user: User = Depends(get_current_user_or_apikey)):
    return {
        "username": current_user.username,
        "is_admin": current_user.is_admin
    }

# --- Books CRUD / Stream APIs ---
@app.get("/api/books")
def list_books(current_user: User = Depends(get_current_user_or_apikey), db: Session = Depends(get_db)):
    """List books available to the logged-in user."""
    if current_user.is_admin:
        # Admin sees all books
        books = db.query(Book).all()
    else:
        # Regular user sees only allowed books
        allowed_slugs = [p.book_slug for p in current_user.permissions]
        books = db.query(Book).filter(Book.slug.in_(allowed_slugs)).all()
        
    return [
        {
            "slug": b.slug,
            "title": b.title,
            "author": b.author,
            "pageCount": b.page_count,
            "cover": f"books/{b.slug}/output/{b.cover_path}" if b.cover_path else None,
            "isPublished": b.is_published
        }
        for b in books
    ]

@app.post("/api/books/upload")
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
        db_book = db.query(Book).filter(Book.slug == book_slug).first()
        if not db_book:
            db_book = Book(
                slug=book_slug,
                title=metadata.get("title", result["title"]),
                author=metadata.get("author", "Unknown"),
                page_count=book_paths.estimate_page_count(),
                cover_path=cover_val,
                is_published=True
            )
            db.add(db_book)
        else:
            db_book.page_count = book_paths.estimate_page_count()
            db_book.title = metadata.get("title", db_book.title)
            db_book.author = metadata.get("author", db_book.author)
            if cover_val:
                db_book.cover_path = cover_val
                
        db.commit()
        return {"ok": True, "slug": book_slug, "message": f"Successfully imported '{result['title']}'"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to process BKB archive: {str(e)}")
    finally:
        if tmp_path.exists():
            tmp_path.unlink()

@app.get("/api/books/{slug}/download")
def download_bkb(slug: str, current_user: User = Depends(get_current_user_or_apikey), db: Session = Depends(get_db)):
    """Download the book as a .bkb package file."""
    # Check permissions
    if not current_user.is_admin:
        has_permission = db.query(UserPermission).filter(
            UserPermission.user_id == current_user.id,
            UserPermission.book_slug == slug
        ).first()
        if not has_permission:
            raise HTTPException(status_code=403, detail="No permission to download this book")
            
    book_dir = BOOKS_DIR / slug
    if not book_dir.is_dir():
        raise HTTPException(status_code=404, detail="Book directory not found")
        
    # Create temp directory for packing
    with tempfile.TemporaryDirectory() as tmp_dir:
        bkb_out_path = Path(tmp_dir) / f"{slug}.bkb"
        try:
            pack_book(book_dir, bkb_out_path)
            return FileResponse(
                bkb_out_path,
                media_type="application/octet-stream",
                filename=f"{slug}.bkb"
            )
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Failed to package book: {e}")

@app.delete("/api/books/{slug}")
def delete_book(slug: str, current_user: User = Depends(require_admin), db: Session = Depends(get_db)):
    """Delete a book from DB and filesystem."""
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
    
    db.commit()
    
    # Remove physical directory
    book_dir = BOOKS_DIR / slug
    if book_dir.is_dir():
        shutil.rmtree(book_dir, ignore_errors=True)
        
    return {"ok": True, "message": f"Successfully deleted book '{slug}'"}

# --- Highlights Sync APIs ---
@app.get("/api/books/{slug}/highlights")
def get_highlights(slug: str, current_user: User = Depends(get_current_user_or_apikey), db: Session = Depends(get_db)):
    """Fetch all highlights for a specific book."""
    # Check permissions
    if not current_user.is_admin:
        has_perm = db.query(UserPermission).filter(
            UserPermission.user_id == current_user.id,
            UserPermission.book_slug == slug
        ).first()
        if not has_perm:
            raise HTTPException(status_code=403, detail="No permission to read this book")
            
    highlights = db.query(Highlight).filter(Highlight.book_slug == slug).all()
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

@app.post("/api/books/{slug}/highlights")
def create_or_update_highlight(
    slug: str,
    highlight_data: dict,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db)
):
    """Add or edit a highlight sentence."""
    if not current_user.is_admin:
        has_perm = db.query(UserPermission).filter(
            UserPermission.user_id == current_user.id,
            UserPermission.book_slug == slug
        ).first()
        if not has_perm:
            raise HTTPException(status_code=403, detail="No permission")

    hl_id = highlight_data.get("id")
    if not hl_id:
        raise HTTPException(status_code=400, detail="Highlight ID is required")

    db_hl = db.query(Highlight).filter(Highlight.id == hl_id).first()
    if not db_hl:
        db_hl = Highlight(
            id=hl_id,
            book_slug=slug,
            page=highlight_data.get("page"),
            lang=highlight_data.get("lang"),
            color=highlight_data.get("color"),
            text=highlight_data.get("text"),
            start_offset=highlight_data.get("startOffset", 0),
            end_offset=highlight_data.get("endOffset", 0),
            paragraph_index=highlight_data.get("paragraphIndex", 0),
            note=highlight_data.get("note", ""),
            username=current_user.username
        )
        db.add(db_hl)
    else:
        # Update fields
        db_hl.color = highlight_data.get("color", db_hl.color)
        db_hl.note = highlight_data.get("note", db_hl.note)
        
    db.commit()
    return {"ok": True}

@app.delete("/api/books/{slug}/highlights/{hl_id}")
def delete_highlight(
    slug: str,
    hl_id: str,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db)
):
    """Delete a highlight by ID."""
    db_hl = db.query(Highlight).filter(Highlight.id == hl_id, Highlight.book_slug == slug).first()
    if not db_hl:
        raise HTTPException(status_code=404, detail="Highlight not found")
        
    db.delete(db_hl)
    db.commit()
    return {"ok": True}

# --- Reading Progress Sync APIs ---
@app.get("/api/books/{slug}/progress")
def get_reading_progress(
    slug: str,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db)
):
    """Retrieve the logged-in user's reading progress for a book."""
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

@app.post("/api/books/{slug}/progress")
def save_reading_progress(
    slug: str,
    progress_data: dict,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db)
):
    """Save or update the logged-in user's reading progress."""
    page = progress_data.get("page", 1)
    view_mode = progress_data.get("viewMode", "en")
    
    progress = db.query(ReadingProgress).filter(
        ReadingProgress.user_id == current_user.id,
        ReadingProgress.book_slug == slug
    ).first()
    
    import time
    if not progress:
        progress = ReadingProgress(
            user_id=current_user.id,
            book_slug=slug,
            page=page,
            view_mode=view_mode,
            last_read=int(time.time())
        )
        db.add(progress)
    else:
        progress.page = page
        progress.view_mode = view_mode
        progress.last_read = int(time.time())
        
    db.commit()
    return {"ok": True}

# --- Admin Portal APIs ---
@app.get("/api/admin/users")
def admin_list_users(admin: User = Depends(require_admin), db: Session = Depends(get_db)):
    users = db.query(User).all()
    return [{"id": u.id, "username": u.username, "is_admin": u.is_admin} for u in users]

@app.get("/api/admin/apikeys")
def admin_list_apikeys(admin: User = Depends(require_admin), db: Session = Depends(get_db)):
    keys = db.query(APIKey).all()
    return [{"id": k.id, "name": k.name, "key_value": k.key_value, "is_active": k.is_active, "created_at": k.created_at} for k in keys]

@app.post("/api/admin/apikeys")
def admin_create_apikey(name: str, admin: User = Depends(require_admin), db: Session = Depends(get_db)):
    key_token = f"br_live_{secrets.token_hex(16)}"
    new_key = APIKey(key_value=key_token, name=name, is_active=True)
    db.add(new_key)
    db.commit()
    db.refresh(new_key)
    return {"ok": True, "name": name, "key_value": key_token}

@app.delete("/api/admin/apikeys/{key_id}")
def admin_revoke_apikey(key_id: int, admin: User = Depends(require_admin), db: Session = Depends(get_db)):
    key = db.query(APIKey).filter(APIKey.id == key_id).first()
    if not key:
        raise HTTPException(status_code=404, detail="API Key not found")
    key.is_active = False
    db.commit()
    return {"ok": True, "message": "API Key revoked"}

@app.get("/api/admin/permissions")
def admin_list_permissions(admin: User = Depends(require_admin), db: Session = Depends(get_db)):
    perms = db.query(UserPermission).all()
    return [{"id": p.id, "user_id": p.user_id, "book_slug": p.book_slug} for p in perms]

@app.post("/api/admin/permissions")
def admin_grant_permission(user_id: int, book_slug: str, admin: User = Depends(require_admin), db: Session = Depends(get_db)):
    # Check if exists
    exists = db.query(UserPermission).filter(
        UserPermission.user_id == user_id,
        UserPermission.book_slug == book_slug
    ).first()
    if exists:
        return {"ok": True, "message": "Permission already exists"}
        
    perm = UserPermission(user_id=user_id, book_slug=book_slug)
    db.add(perm)
    db.commit()
    return {"ok": True, "message": "Permission granted successfully"}

@app.delete("/api/admin/permissions/{perm_id}")
def admin_revoke_permission(perm_id: int, admin: User = Depends(require_admin), db: Session = Depends(get_db)):
    perm = db.query(UserPermission).filter(UserPermission.id == perm_id).first()
    if not perm:
        raise HTTPException(status_code=404, detail="Permission not found")
    db.delete(perm)
    db.commit()
    return {"ok": True, "message": "Permission revoked"}

# --- Proxy Chat API (Forwarding chat requests to LLMs) ---
@app.post("/api/chat")
async def chat_proxy(request: Request):
    """Proxies completions requests to LLMs directly to bypass CORS."""
    import httpx
    body = await request.body()
    try:
        import json
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

# --- Serve Web Frontend ---
# Serve root files first (index.html, favicon.png, config.js, app.js, reader.css, sw.js, and libs/)
app.mount("/libs", StaticFiles(directory=WORKSPACE_ROOT / "libs"), name="libs")

@app.get("/favicon.png")
def get_favicon():
    return FileResponse(WORKSPACE_ROOT / "favicon.png")

@app.get("/config.js")
def get_config():
    return FileResponse(WORKSPACE_ROOT / "config.js")

@app.get("/app.js")
def get_app_js():
    return FileResponse(WORKSPACE_ROOT / "app.js")

@app.get("/reader.css")
def get_reader_css():
    return FileResponse(WORKSPACE_ROOT / "reader.css")

@app.get("/sw.js")
def get_sw():
    return FileResponse(WORKSPACE_ROOT / "sw.js")

@app.get("/admin.html")
@app.get("/admin")
def get_admin():
    return FileResponse(WORKSPACE_ROOT / "admin.html")

@app.get("/admin.js")
def get_admin_js():
    return FileResponse(WORKSPACE_ROOT / "admin.js")

@app.get("/")
@app.get("/index.html")
def get_index():
    return FileResponse(WORKSPACE_ROOT / "index.html")
