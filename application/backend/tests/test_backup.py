"""Tests for Backup & Disaster Recovery API (/api/backup/*) and full .bkb roundtrip."""

from __future__ import annotations

import json
import shutil
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from sqlalchemy import create_engine  # noqa: E402
from sqlalchemy.orm import sessionmaker  # noqa: E402

from api import config as api_config  # noqa: E402
from api.auth import create_access_token, get_password_hash, verify_password  # noqa: E402
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


def _create_sample_book_on_disk(
    books_root: Path,
    slug: str,
    title: str,
    text_suffix: str = "v1",
    default_font: str = "literata",
    default_theme: str = "warm-paper|scale:105",
) -> Path:
    book_dir = books_root / slug
    (book_dir / "output" / "en").mkdir(parents=True, exist_ok=True)
    (book_dir / "output" / "vi").mkdir(parents=True, exist_ok=True)
    (book_dir / "output" / "assets" / "images").mkdir(parents=True, exist_ok=True)

    meta = {
        "slug": slug,
        "title": title,
        "author": "Test Author",
        "page_count": 2,
        "default_font": default_font,
        "default_theme": default_theme,
    }
    (book_dir / "book.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    (book_dir / "output" / "en" / "page_0001.html").write_text(
        f"<html><body><p>Hello world {text_suffix}</p></body></html>", encoding="utf-8"
    )
    (book_dir / "output" / "vi" / "page_0001.html").write_text(
        f"<html><body><p>Xin chào thế giới {text_suffix}</p></body></html>", encoding="utf-8"
    )
    (book_dir / "output" / "assets" / "images" / "page_0001_cover_logo.png").write_bytes(b"\x89PNG\r\n\x1a\nfake")
    return book_dir


@pytest.fixture()
def isolated_env(tmp_path: Path, monkeypatch):
    """Per-test SQLite DB + temp books directory, never touching shared suite DB."""
    db_file = tmp_path / "backup_isolated.db"
    engine = create_engine(
        f"sqlite:///{db_file}", connect_args={"check_same_thread": False}
    )
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

    def _clear_tables():
        db = TestingSessionLocal()
        try:
            for model in (
                UserPermission,
                ReadingProgress,
                UserBookState,
                Highlight,
                UserSettings,
                APIKey,
                Book,
                User,
            ):
                db.query(model).delete()
            db.commit()
        finally:
            db.close()

    try:
        yield {
            "books_dir": books_dir,
            "SessionLocal": TestingSessionLocal,
            "clear_tables": _clear_tables,
        }
    finally:
        app.dependency_overrides.pop(get_db, None)
        backup_route._FINGERPRINT_CACHE.clear()
        engine.dispose()


def _auth_header(username: str) -> dict[str, str]:
    token = create_access_token({"sub": username})
    return {"Authorization": f"Bearer {token}"}


def test_manifest_and_fingerprint_determinism(isolated_env):
    books_dir = isolated_env["books_dir"]
    SessionLocal = isolated_env["SessionLocal"]
    _create_sample_book_on_disk(books_dir, "demo-book", "Demo Book", "v1")

    db = SessionLocal()
    try:
        db.add(User(username="admin_bkp", password_hash=get_password_hash("secret"), is_admin=True))
        db.add(
            Book(
                slug="demo-book",
                title="Demo Book",
                author="Test Author",
                page_count=2,
                cover_path="assets/images/page_0001_cover_logo.png",
                is_published=True,
                default_font="literata",
                default_theme="warm-paper|scale:105",
                created_at=1700000100,
            )
        )
        db.commit()
    finally:
        db.close()

    with TestClient(app) as client:
        resp1 = client.get("/api/backup/manifest", headers=_auth_header("admin_bkp"))
        assert resp1.status_code == 200
        data1 = resp1.json()
        assert data1["scope"] == "admin_full"
        assert data1["counts"]["books"] == 1
        assert len(data1["books"]) == 1
        fp1 = data1["books"][0]["contentFingerprint"]
        assert len(fp1) == 64
        assert data1["books"][0]["hasOutputDir"] is True
        assert data1["books"][0]["outputFileCount"] == 3

        # Modify page content -> fingerprint must change
        (books_dir / "demo-book" / "output" / "en" / "page_0001.html").write_text(
            "<html><body><p>Hello world changed!</p></body></html>", encoding="utf-8"
        )
        resp2 = client.get("/api/backup/manifest", headers=_auth_header("admin_bkp"))
        assert resp2.status_code == 200
        fp2 = resp2.json()["books"][0]["contentFingerprint"]
        assert fp2 != fp1


def test_personal_scope_isolation_and_restore_permissions(isolated_env):
    books_dir = isolated_env["books_dir"]
    SessionLocal = isolated_env["SessionLocal"]
    _create_sample_book_on_disk(books_dir, "allowed-book", "Allowed Book")
    _create_sample_book_on_disk(books_dir, "secret-book", "Secret Book")

    db = SessionLocal()
    try:
        admin = User(username="adm_iso", password_hash=get_password_hash("adm"), is_admin=True)
        alice = User(username="alice", password_hash=get_password_hash("alicepw"), is_admin=False)
        bob = User(username="bob", password_hash=get_password_hash("bobpw"), is_admin=False)
        db.add_all([admin, alice, bob])
        db.flush()

        db.add_all([
            Book(slug="allowed-book", title="Allowed", author="A", page_count=2, is_published=True, created_at=100),
            Book(slug="secret-book", title="Secret", author="B", page_count=2, is_published=True, created_at=101),
            UserPermission(user_id=alice.id, book_slug="allowed-book"),
            UserPermission(user_id=bob.id, book_slug="secret-book"),
            Highlight(
                id="hl-alice",
                book_slug="allowed-book",
                page=1,
                lang="en",
                color="#fef08a",
                text="Hello",
                note="Alice note",
                username="alice",
                created_at=1000,
            ),
            Highlight(
                id="hl-bob",
                book_slug="secret-book",
                page=1,
                lang="en",
                color="#fef08a",
                text="Secret",
                note="Bob secret note",
                username="bob",
                created_at=1001,
            ),
            ReadingProgress(user_id=alice.id, book_slug="allowed-book", page=2, view_mode="split", last_read=200),
            ReadingProgress(user_id=bob.id, book_slug="secret-book", page=9, view_mode="en", last_read=900),
            UserSettings(user_id=alice.id, ai_model="gpt-4o-mini", llm_api_key="sk-alice"),
            UserSettings(user_id=bob.id, ai_model="gpt-4.1", llm_api_key="sk-bob-secret"),
        ])
        db.commit()
    finally:
        db.close()

    with TestClient(app) as client:
        alice_hdr = _auth_header("alice")
        manifest_resp = client.get("/api/backup/manifest", headers=alice_hdr)
        assert manifest_resp.status_code == 200
        m = manifest_resp.json()
        assert m["scope"] == "personal"
        assert [b["slug"] for b in m["books"]] == ["allowed-book"]
        assert m["counts"]["highlights"] == 1

        export_resp = client.get("/api/backup/export?include_secrets=false", headers=alice_hdr)
        assert export_resp.status_code == 200
        snap = export_resp.json()
        assert snap["scope"] == "personal"
        assert snap["users"] == []
        assert snap["permissions"] == []
        assert snap["apiKeys"] == []
        assert [h["id"] for h in snap["highlights"]] == ["hl-alice"]
        assert len(snap["readingProgress"]) == 1
        assert snap["userSettings"][0]["llmApiKey"] is None

        # Alice cannot restore an admin snapshot
        admin_snap = client.get("/api/backup/export", headers=_auth_header("adm_iso")).json()
        forbid = client.post(
            "/api/backup/restore",
            headers=alice_hdr,
            json={"snapshot": admin_snap, "mode": "merge", "dryRun": True},
        )
        assert forbid.status_code == 403

        # Delete Alice's highlight, then restore from her personal snapshot
        del_resp = client.delete("/api/books/allowed-book/highlights/hl-alice", headers=alice_hdr)
        assert del_resp.status_code == 200

        restored = client.post(
            "/api/backup/restore",
            headers=alice_hdr,
            json={"snapshot": snap, "mode": "merge", "dryRun": False},
        )
        assert restored.status_code == 200
        assert restored.json()["summary"]["highlights"]["created"] == 1


def test_full_admin_disaster_recovery_roundtrip_across_fresh_server(isolated_env, tmp_path: Path):
    books_dir = isolated_env["books_dir"]
    SessionLocal = isolated_env["SessionLocal"]
    _clear_all_tables = isolated_env["clear_tables"]
    _create_sample_book_on_disk(
        books_dir,
        "atomic-book",
        "Atomic Book",
        default_font="merriweather",
        default_theme="sepia|scale:110",
    )

    db = SessionLocal()
    try:
        # Deliberately give reader a non-1 id before wipe
        dummy = User(username="temp_deleted_later", password_hash=get_password_hash("x"), is_admin=False)
        admin = User(username="primary_admin", password_hash=get_password_hash("adm-pass-1"), is_admin=True)
        reader = User(username="family_reader", password_hash=get_password_hash("family-pw-99"), is_admin=False)
        db.add_all([dummy, admin, reader])
        db.flush()

        db.add_all([
            Book(
                slug="atomic-book",
                title="Atomic Habits Backup",
                author="James Clear",
                page_count=2,
                cover_path="assets/images/page_0001_cover_logo.png",
                is_published=False,
                default_font="merriweather",
                default_theme="sepia|scale:110",
                created_at=1700000500,
            ),
            UserPermission(user_id=reader.id, book_slug="atomic-book"),
            APIKey(key_value="bkb_key_12345", name="automation", is_active=True, created_at=1700000600),
            Highlight(
                id="hl-1",
                book_slug="atomic-book",
                page=1,
                lang="en",
                color="#93c5fd",
                text="Tiny changes",
                start_offset=0,
                end_offset=12,
                paragraph_index=0,
                note="Great quote",
                username="family_reader",
                created_at=1700000700,
            ),
            ReadingProgress(
                user_id=reader.id,
                book_slug="atomic-book",
                page=2,
                view_mode="split",
                last_read=1700000800,
            ),
            UserBookState(
                user_id=reader.id,
                book_slug="atomic-book",
                is_finished=False,
                on_shelf=True,
                is_priority=True,
                reader_font="lora",
                reader_theme="dark|scale:115",
            ),
            UserSettings(
                user_id=reader.id,
                ai_provider="openai",
                ai_base_url="https://api.openai.com/v1",
                ai_model="gpt-4o",
                llm_api_key="sk-secret-llm",
                voca_bridge_origin="https://voca.example.com",
                voca_bridge_token="voca_secret_abc",
                layout_mode="vi-en",
                hide_finished_books=False,
                updated_at=1700000900,
            ),
        ])
        db.commit()
    finally:
        db.close()

    with TestClient(app) as client:
        adm_hdr = _auth_header("primary_admin")
        # 1. Pull full snapshot + .bkb from server (Mac Vault behavior)
        manifest = client.get("/api/backup/manifest", headers=adm_hdr).json()
        orig_fp = manifest["books"][0]["contentFingerprint"]

        snap_resp = client.get("/api/backup/export?include_secrets=true", headers=adm_hdr)
        assert snap_resp.status_code == 200
        snapshot = snap_resp.json()
        assert snapshot["includesSecrets"] is True
        assert any(u["username"] == "family_reader" for u in snapshot["users"])

        bkb_resp = client.get("/api/books/atomic-book/download", headers=adm_hdr)
        assert bkb_resp.status_code == 200
        local_bkb = tmp_path / "vault_atomic-book.bkb"
        local_bkb.write_bytes(bkb_resp.content)
        with zipfile.ZipFile(local_bkb, "r") as zf:
            assert "manifest.json" in zf.namelist()
            assert "output/en/page_0001.html" in zf.namelist()

    # 2. Simulate total server wipe & fresh rebuild with a recovery admin
    _clear_all_tables()
    for p in list(books_dir.iterdir()):
        if p.is_dir():
            shutil.rmtree(p)
    backup_route._FINGERPRINT_CACHE.clear()

    db = SessionLocal()
    try:
        db.add(User(username="recovery_admin", password_hash=get_password_hash("rec-pw"), is_admin=True))
        db.commit()
    finally:
        db.close()

    with TestClient(app) as client:
        rec_hdr = _auth_header("recovery_admin")

        # 3a. Dry-run BEFORE uploading .bkb -> detects missingFiles & shows planned creations
        dry = client.post(
            "/api/backup/restore",
            headers=rec_hdr,
            json={
                "snapshot": snapshot,
                "mode": "overwrite",
                "dryRun": True,
                "restoreUsers": True,
                "restorePermissions": True,
                "restoreBooksMetadata": True,
                "restoreApiKeys": True,
                "restoreHighlights": True,
                "restoreProgress": True,
                "restoreStates": True,
                "restoreSettings": True,
                "restoreSecrets": True,
            },
        )
        assert dry.status_code == 200
        dry_body = dry.json()
        assert dry_body["dryRun"] is True
        assert dry_body["summary"]["books"]["missingFiles"] == ["atomic-book"]
        assert dry_body["summary"]["users"]["created"] == 3
        assert dry_body["summary"]["highlights"]["created"] == 1
        # Verify dry-run wrote nothing!
        db_check = SessionLocal()
        try:
            assert db_check.query(User).count() == 1
            assert db_check.query(Highlight).count() == 0
        finally:
            db_check.close()

        # 3b. Upload .bkb from Mac vault, then simulate server admin overriding defaults to verify restore wins
        with local_bkb.open("rb") as fh:
            up = client.post(
                "/api/books/upload",
                headers=rec_hdr,
                files={"file": ("atomic-book.bkb", fh, "application/octet-stream")},
            )
        assert up.status_code == 200
        db_tweak = SessionLocal()
        try:
            bk = db_tweak.query(Book).filter(Book.slug == "atomic-book").first()
            bk.default_font = "default"
            bk.is_published = True
            db_tweak.commit()
        finally:
            db_tweak.close()

        # 3c. Execute actual restore!
        apply_resp = client.post(
            "/api/backup/restore",
            headers=rec_hdr,
            json={
                "snapshot": snapshot,
                "mode": "overwrite",
                "dryRun": False,
                "restoreUsers": True,
                "restorePermissions": True,
                "restoreBooksMetadata": True,
                "restoreApiKeys": True,
                "restoreHighlights": True,
                "restoreProgress": True,
                "restoreStates": True,
                "restoreSettings": True,
                "restoreSecrets": True,
            },
        )
        assert apply_resp.status_code == 200
        res_body = apply_resp.json()
        assert res_body["summary"]["books"]["missingFiles"] == []
        assert res_body["summary"]["users"]["created"] == 3
        assert res_body["summary"]["permissions"]["created"] == 1
        assert res_body["summary"]["apiKeys"]["created"] == 1
        assert res_body["summary"]["highlights"]["created"] == 1
        assert res_body["summary"]["readingProgress"]["created"] == 1
        assert res_body["summary"]["userBookStates"]["created"] == 1
        assert res_body["summary"]["userSettings"]["created"] == 1

        # 4. Verify restored server state & fingerprints match
        restored_manifest = client.get("/api/backup/manifest", headers=rec_hdr).json()
        assert restored_manifest["books"][0]["contentFingerprint"] == orig_fp

        db_verify = SessionLocal()
        try:
            # recovery_admin was NOT locked out/deleted!
            assert db_verify.query(User).filter(User.username == "recovery_admin").first() is not None
            r_user = db_verify.query(User).filter(User.username == "family_reader").first()
            assert r_user is not None
            assert verify_password("family-pw-99", r_user.password_hash)

            perm = db_verify.query(UserPermission).filter(UserPermission.user_id == r_user.id).first()
            assert perm is not None and perm.book_slug == "atomic-book"

            r_book = db_verify.query(Book).filter(Book.slug == "atomic-book").first()
            assert r_book is not None
            assert r_book.default_font == "merriweather"
            assert r_book.default_theme == "sepia|scale:110"
            assert r_book.is_published is False

            r_prog = db_verify.query(ReadingProgress).filter(ReadingProgress.user_id == r_user.id).first()
            assert r_prog is not None and r_prog.page == 2 and r_prog.view_mode == "split"

            r_state = db_verify.query(UserBookState).filter(UserBookState.user_id == r_user.id).first()
            assert r_state is not None and r_state.is_priority is True and r_state.reader_font == "lora"

            r_settings = db_verify.query(UserSettings).filter(UserSettings.user_id == r_user.id).first()
            assert r_settings is not None
            assert r_settings.llm_api_key == "sk-secret-llm"
            assert r_settings.voca_bridge_token == "voca_secret_abc"
            assert r_settings.layout_mode == "vi-en"
            assert r_settings.hide_finished_books is False
        finally:
            db_verify.close()


def test_merge_restore_preserves_newer_server_progress(isolated_env):
    books_dir = isolated_env["books_dir"]
    SessionLocal = isolated_env["SessionLocal"]
    _create_sample_book_on_disk(books_dir, "merge-book", "Merge Book")

    db = SessionLocal()
    try:
        adm = User(username="merge_adm", password_hash=get_password_hash("adm"), is_admin=True)
        db.add(adm)
        db.flush()
        db.add(Book(slug="merge-book", title="Merge Book", author="A", page_count=10, is_published=True))
        # Newer progress on server (page 8, last_read=2000)
        db.add(ReadingProgress(user_id=adm.id, book_slug="merge-book", page=8, view_mode="split", last_read=2000))
        db.commit()
    finally:
        db.close()

    older_snapshot = {
        "version": 1,
        "exportedAt": 1000,
        "scope": "admin_full",
        "includesSecrets": False,
        "books": [],
        "users": [],
        "permissions": [],
        "apiKeys": [],
        "highlights": [
            {
                "id": "hl-new-from-backup",
                "bookSlug": "merge-book",
                "username": "merge_adm",
                "page": 3,
                "lang": "en",
                "color": "#fef08a",
                "text": "Missing hl",
                "startOffset": 0,
                "endOffset": 5,
                "paragraphIndex": 0,
                "note": "Restored highlight",
                "createdAt": 1000,
            }
        ],
        "readingProgress": [
            {
                "username": "merge_adm",
                "bookSlug": "merge-book",
                "page": 3,
                "viewMode": "en",
                "lastRead": 1000,
            }
        ],
        "userBookStates": [],
        "userSettings": [],
    }

    with TestClient(app) as client:
        resp = client.post(
            "/api/backup/restore",
            headers=_auth_header("merge_adm"),
            json={"snapshot": older_snapshot, "mode": "merge", "dryRun": False},
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["summary"]["highlights"]["created"] == 1
        assert body["summary"]["readingProgress"]["skipped"] == 1

        # Progress on server stays page 8
        prog = client.get("/api/books/merge-book/progress", headers=_auth_header("merge_adm")).json()
        assert prog["page"] == 8
