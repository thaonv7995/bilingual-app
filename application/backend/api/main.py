from pathlib import Path
from fastapi import FastAPI, Depends
from fastapi.responses import FileResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from sqlalchemy.orm import Session

from api.database import init_db, User, Book
from api.auth import get_password_hash
from api.config import WORKSPACE_ROOT, BOOKS_DIR, WEB_APP_DIR
from api.routes import auth, books, admin, chat
from books_core.paths import BookPaths

app = FastAPI(title="Bilingual Digital Library API")

# Enable CORS for frontend flexibility
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include Modular Routers
app.include_router(auth.router)
app.include_router(books.router)
app.include_router(books.content_router)
app.include_router(admin.router)
app.include_router(chat.router)

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
                if not cover_val:
                    for possible_cover in ["assets/cover.jpg", "assets/cover.png", "assets/images/page_0001_cover_logo.png"]:
                        if (item / "output" / possible_cover).is_file():
                            cover_val = possible_cover
                            break
                
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
                    # Sync page count, author and cover path if updated
                    db_book.page_count = book_paths.estimate_page_count()
                    db_book.title = metadata.get("title", db_book.title)
                    db_book.author = metadata.get("author", db_book.author)
                    if cover_val:
                        db_book.cover_path = cover_val
            except Exception as e:
                print(f"[Startup Sync Error] Failed syncing book '{item.name}': {e}")
    db.commit()

# --- Serve Web Frontend ---
# Serve root files first (index.html, favicon.png, config.js, app.js, reader.css, sw.js, and libs/)
app.mount("/libs", StaticFiles(directory=WEB_APP_DIR / "libs"), name="libs")

@app.get("/favicon.png")
def get_favicon():
    return FileResponse(WEB_APP_DIR / "favicon.png")

@app.get("/config.js")
def get_config():
    return FileResponse(WEB_APP_DIR / "config.js")

@app.get("/app.js")
def get_app_js():
    return FileResponse(WEB_APP_DIR / "app.js")

@app.get("/voca-client.js")
def get_voca_client_js():
    return FileResponse(WEB_APP_DIR / "voca-client.js")

@app.get("/reader.css")
def get_reader_css():
    return FileResponse(WEB_APP_DIR / "reader.css")

@app.get("/sw.js")
def get_sw():
    return FileResponse(WEB_APP_DIR / "sw.js")

@app.get("/admin.html")
@app.get("/admin")
def get_admin():
    return FileResponse(WEB_APP_DIR / "admin.html")

@app.get("/admin.js")
def get_admin_js():
    return FileResponse(WEB_APP_DIR / "admin.js")

@app.get("/")
@app.get("/index.html")
def get_index():
    return FileResponse(WEB_APP_DIR / "index.html")
