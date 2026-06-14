import shutil
import tempfile
import time
from pathlib import Path
from typing import Optional, List
from fastapi import APIRouter, Depends, HTTPException, File, UploadFile, Request, Response, status
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from api.database import get_db, User, Book, UserPermission, Highlight, ReadingProgress
from api.auth import (
    get_current_user_or_apikey,
    require_admin,
    decode_access_token,
    decode_access_token
)
from api.config import BOOKS_DIR
from books_core.paths import BookPaths
from books_core.package import pack_book, unpack_book

router = APIRouter(prefix="/api/books", tags=["books"])
content_router = APIRouter(prefix="/books", tags=["books content"])

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
        from api.database import APIKey
        key_record = db.query(APIKey).filter(APIKey.key_value == api_key, APIKey.is_active == True).first()
        if key_record:
            return User(username=f"apikey_{key_record.name}", is_admin=True)
            
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

    # Serve the requested file safely
    file_path = BOOKS_DIR / slug / "output" / path
    if not file_path.is_file():
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Book resource file not found."
        )
        
    return FileResponse(file_path)

# --- Books CRUD APIs ---
@router.get("")
@router.get("/")
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

@router.get("/{slug}/download")
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

@router.delete("/{slug}")
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
@router.get("/{slug}/highlights")
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

@router.post("/{slug}/highlights")
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

@router.delete("/{slug}/highlights/{hl_id}")
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
@router.get("/{slug}/progress")
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

@router.post("/{slug}/progress")
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
