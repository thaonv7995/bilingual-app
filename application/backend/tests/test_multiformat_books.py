"""Tests for native PDF & EPUB upload, streaming, highlights, progress, and backup/restore."""

from __future__ import annotations

import io
import json
import sys
import time
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from sqlalchemy import create_engine  # noqa: E402
from sqlalchemy.orm import sessionmaker  # noqa: E402

from api import config as api_config  # noqa: E402
from api.auth import create_access_token, get_password_hash  # noqa: E402
from api.database import (  # noqa: E402
    APIKey,
    Base,
    Book,
    Highlight,
    ReadingProgress,
    User,
    UserBookState,
    UserPermission,
    UserSettings,
    get_db,
)
from api.main import app  # noqa: E402
from api.routes import backup as backup_route  # noqa: E402
from api.routes import books as books_route  # noqa: E402


def _make_sample_pdf_bytes(title: str = "Clean Architecture", author: str = "Robert C. Martin", pages: int = 3) -> bytes:
    import fitz

    doc = fitz.open()
    doc.set_metadata({"title": title, "author": author})
    for idx in range(1, pages + 1):
        page = doc.new_page(width=595, height=842)
        page.insert_text((72, 100), f"{title} - Chapter {idx}", fontsize=20)
        page.insert_text((72, 150), f"This is sample searchable content on page {idx}.", fontsize=12)
    doc.set_toc([[1, "Chapter 1", 1], [1, "Chapter 2", 2]])
    raw = doc.tobytes()
    doc.close()
    return raw


def _make_sample_epub_bytes(title: str = "Atomic Habits", author: str = "James Clear") -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        zf.writestr(
            "META-INF/container.xml",
            """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>""",
        )
        zf.writestr(
            "OEBPS/content.opf",
            f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:12345</dc:identifier>
    <dc:title>{title}</dc:title>
    <dc:creator>{author}</dc:creator>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="cover-img" href="images/cover.png" media-type="image/png" properties="cover-image"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>""",
        )
        zf.writestr(
            "OEBPS/ch1.xhtml",
            "<html><body><h1>Chapter 1</h1><p>Tiny changes, remarkable results.</p></body></html>",
        )
        zf.writestr(
            "OEBPS/ch2.xhtml",
            "<html><body><h1>Chapter 2</h1><p>How habits shape your identity.</p></body></html>",
        )
        zf.writestr("OEBPS/images/cover.png", b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDRfake")
    return buf.getvalue()


@pytest.fixture()
def env(tmp_path: Path, monkeypatch):
    db_file = tmp_path / "multiformat.db"
    engine = create_engine(f"sqlite:///{db_file}", connect_args={"check_same_thread": False})
    TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    Base.metadata.create_all(bind=engine)

    def _override_get_db():
        db = TestingSessionLocal()
        try:
            yield db
        finally:
            db.close()

    backup_route._FINGERPRINT_CACHE.clear()
    books_dir = tmp_path / "books"
    books_dir.mkdir(parents=True, exist_ok=True)

    app.dependency_overrides[get_db] = _override_get_db
    monkeypatch.setattr("api.main.SessionLocal_init", TestingSessionLocal)
    monkeypatch.setattr(api_config, "BOOKS_DIR", books_dir)
    monkeypatch.setattr(books_route, "BOOKS_DIR", books_dir)
    monkeypatch.setattr("api.main.BOOKS_DIR", books_dir)

    db = TestingSessionLocal()
    admin = User(username="admin", password_hash=get_password_hash("secret"), is_admin=True)
    reader = User(username="reader", password_hash=get_password_hash("secret"), is_admin=False)
    db.add_all([admin, reader])
    db.commit()
    db.close()

    try:
        yield {
            "books_dir": books_dir,
            "SessionLocal": TestingSessionLocal,
            "admin_headers": {"Authorization": f"Bearer {create_access_token({'sub': 'admin'})}"},
            "reader_headers": {"Authorization": f"Bearer {create_access_token({'sub': 'reader'})}"},
        }
    finally:
        app.dependency_overrides.clear()
        backup_route._FINGERPRINT_CACHE.clear()
        engine.dispose()


def test_pdf_upload_stream_download_highlights_and_backup_roundtrip(env):
    client = TestClient(app)
    pdf_bytes = _make_sample_pdf_bytes()

    # 1. Upload PDF
    res = client.post(
        "/api/books/upload",
        files={"file": ("Clean Architecture.pdf", pdf_bytes, "application/pdf")},
        headers=env["admin_headers"],
    )
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["ok"] is True
    assert body["slug"] == "clean-architecture"
    assert body["format"] == "pdf"

    # 2. Verify list_books returns format, pageCount, cover, sourceUrl
    listed = client.get("/api/books", headers=env["admin_headers"]).json()
    assert len(listed) == 1
    book = listed[0]
    assert book["format"] == "pdf"
    assert book["title"] == "Clean Architecture"
    assert book["author"] == "Robert C. Martin"
    assert book["pageCount"] == 3
    assert book["sourceUrl"] == "books/clean-architecture/source"
    assert book["cover"] == "books/clean-architecture/output/assets/cover.png"

    # 3. Access control on /books/{slug}/source (unauthorized user denied)
    unauth = client.get("/books/clean-architecture/source", headers=env["reader_headers"])
    assert unauth.status_code == 403

    # 4. Authorized Range stream & native download return exact PDF bytes
    streamed = client.get(
        "/books/clean-architecture/source",
        headers={**env["admin_headers"], "Range": "bytes=0-15"},
    )
    assert streamed.status_code in (200, 206)
    assert streamed.content.startswith(b"%PDF-")

    downloaded = client.get("/api/books/clean-architecture/download", headers=env["admin_headers"])
    assert downloaded.status_code == 200
    assert downloaded.content == pdf_bytes
    assert "clean-architecture.pdf" in downloaded.headers.get("content-disposition", "")

    # 5. Normalized PDF highlight anchorJson + progress sync
    anchor = json.dumps({"kind": "pdf", "rects": [{"x": 0.12, "y": 0.18, "w": 0.45, "h": 0.025}]})
    hl_res = client.post(
        "/api/books/clean-architecture/highlights",
        json={
            "id": "hl-pdf-1",
            "page": 2,
            "lang": "pdf",
            "color": "#fde047",
            "text": "sample searchable content",
            "anchorJson": anchor,
            "note": "Important architecture note",
        },
        headers=env["admin_headers"],
    )
    assert hl_res.status_code == 200
    hls = client.get("/api/books/clean-architecture/highlights", headers=env["admin_headers"]).json()["highlights"]
    assert len(hls) == 1
    assert hls[0]["anchorJson"] == anchor

    now = int(time.time())
    prog_res = client.post(
        "/api/books/clean-architecture/progress",
        json={"page": 2, "viewMode": "en", "progression": 0.66, "lastRead": now},
        headers=env["admin_headers"],
    )
    assert prog_res.status_code == 200
    assert prog_res.json()["progress"]["progression"] == pytest.approx(0.66)

    # 6. Backup manifest & export snapshot include format, fingerprint, anchorJson, progression
    manifest = client.get("/api/backup/manifest", headers=env["admin_headers"]).json()
    assert manifest["books"][0]["format"] == "pdf"
    assert manifest["books"][0]["hasOutputDir"] is True
    assert manifest["books"][0]["outputSizeBytes"] == len(pdf_bytes)
    assert len(manifest["books"][0]["contentFingerprint"]) == 64

    snapshot = client.get("/api/backup/export", headers=env["admin_headers"]).json()
    assert snapshot["books"][0]["format"] == "pdf"
    assert snapshot["highlights"][0]["anchorJson"] == anchor
    assert snapshot["readingProgress"][0]["progression"] == pytest.approx(0.66)


def test_epub_upload_locator_progress_highlights_and_restore(env):
    client = TestClient(app)
    epub_bytes = _make_sample_epub_bytes()

    res = client.post(
        "/api/books/upload",
        files={"file": ("Atomic Habits.epub", epub_bytes, "application/epub+zip")},
        headers=env["admin_headers"],
    )
    assert res.status_code == 200, res.text
    assert res.json()["slug"] == "atomic-habits"
    assert res.json()["format"] == "epub"

    listed = client.get("/api/books", headers=env["admin_headers"]).json()
    book = listed[0]
    assert book["format"] == "epub"
    assert book["title"] == "Atomic Habits"
    assert book["author"] == "James Clear"
    assert book["cover"] == "books/atomic-habits/output/assets/cover.png"

    downloaded = client.get("/api/books/atomic-habits/download", headers=env["admin_headers"])
    assert downloaded.status_code == 200
    assert downloaded.content == epub_bytes
    assert "atomic-habits.epub" in downloaded.headers.get("content-disposition", "")

    cfi = "epubcfi(/6/4!/4/2/4,/1:0,/1:12)"
    anchor = json.dumps({"kind": "epub", "cfi": cfi, "chapterTitle": "Chapter 1"})
    client.post(
        "/api/books/atomic-habits/highlights",
        json={
            "id": "hl-epub-1",
            "page": 1,
            "lang": "epub",
            "color": "#93c5fd",
            "text": "Tiny changes",
            "anchorJson": anchor,
            "note": "Core idea",
        },
        headers=env["admin_headers"],
    )
    now = int(time.time())
    client.post(
        "/api/books/atomic-habits/progress",
        json={"page": 2, "viewMode": "en", "locator": cfi, "progression": 0.42, "lastRead": now},
        headers=env["admin_headers"],
    )

    snapshot = client.get("/api/backup/export", headers=env["admin_headers"]).json()
    assert snapshot["readingProgress"][0]["locator"] == cfi
    assert snapshot["readingProgress"][0]["progression"] == pytest.approx(0.42)

    # Simulate disaster: delete book + DB records, then re-upload .epub + restore snapshot
    del_res = client.delete("/api/books/atomic-habits", headers=env["admin_headers"])
    assert del_res.status_code == 200

    reup = client.post(
        "/api/books/upload?slug=atomic-habits",
        files={"file": ("atomic-habits.epub", epub_bytes, "application/epub+zip")},
        headers=env["admin_headers"],
    )
    assert reup.status_code == 200

    restore_res = client.post(
        "/api/backup/restore",
        json={"snapshot": snapshot, "mode": "merge", "dryRun": False},
        headers=env["admin_headers"],
    )
    assert restore_res.status_code == 200, restore_res.text

    restored_hl = client.get("/api/books/atomic-habits/highlights", headers=env["admin_headers"]).json()["highlights"]
    assert len(restored_hl) == 1
    assert restored_hl[0]["anchorJson"] == anchor

    restored_prog = client.get("/api/books/atomic-habits/progress", headers=env["admin_headers"]).json()
    assert restored_prog["locator"] == cfi
    assert restored_prog["progression"] == pytest.approx(0.42)


def test_reject_invalid_extension_and_corrupt_pdf(env):
    client = TestClient(app)
    bad_ext = client.post(
        "/api/books/upload",
        files={"file": ("notes.txt", b"hello", "text/plain")},
        headers=env["admin_headers"],
    )
    assert bad_ext.status_code == 400

    bad_pdf = client.post(
        "/api/books/upload",
        files={"file": ("fake.pdf", b"not-a-pdf", "application/pdf")},
        headers=env["admin_headers"],
    )
    assert bad_pdf.status_code == 400
