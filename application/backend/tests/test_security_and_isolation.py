"""Regression tests for security hardening and multi-user data isolation."""
from __future__ import annotations

import json
import sys
import zipfile
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402
from fastapi import HTTPException  # noqa: E402

from api.auth import (  # noqa: E402
    get_current_user_or_apikey,
    is_trusted_notebook_client,
    require_admin,
)
from api.database import (  # noqa: E402
    Book,
    Highlight,
    SessionLocal,
    User,
    UserPermission,
    init_db,
)
from api.routes.books import (  # noqa: E402
    create_or_update_highlight,
    delete_highlight,
    get_highlights,
    get_reading_progress,
    list_books,
    save_reading_progress,
    update_book_appearance_defaults,
    update_book_state,
)
from api.routes.chat import _validate_chat_base_url  # noqa: E402
from api.routes.notebook import _get_target_notebook_url  # noqa: E402
from api.routes.settings import get_user_settings, put_user_settings  # noqa: E402
from books_core.package import unpack_book, validate_book_slug  # noqa: E402

init_db()


def _make_user(username: str, is_admin: bool = False) -> User:
    db = SessionLocal()
    try:
        u = db.query(User).filter(User.username == username).first()
        if not u:
            u = User(username=username, password_hash="x", is_admin=is_admin)
            db.add(u)
            db.commit()
            db.refresh(u)
        return u
    finally:
        db.close()


def _fake_request(
    *,
    headers: dict[str, str] | None = None,
    query_params: dict[str, str] | None = None,
    cookies: dict[str, str] | None = None,
    client_host: str = "203.0.113.10",
):
    hdrs = {k.lower(): v for k, v in (headers or {}).items()}

    class _Headers:
        def get(self, key: str, default=None):
            return hdrs.get(key.lower(), default)

    return SimpleNamespace(
        headers=_Headers(),
        query_params=query_params or {},
        cookies=cookies or {},
        client=SimpleNamespace(host=client_host),
    )


# ---- 1. Hardcoded Client-ID & Admin Privilege Hardening ----------------------


def test_remote_notebook_client_id_is_rejected():
    # Public IP request with default notebook_client_v1 must be rejected
    req_remote = _fake_request(
        headers={"X-Client-ID": "notebook_client_v1"},
        client_host="198.51.100.42",
    )
    assert is_trusted_notebook_client(req_remote) is False

    # Loopback IP behind reverse proxy (X-Forwarded-For present) must also be rejected
    req_proxied = _fake_request(
        headers={
            "X-Client-ID": "notebook_client_v1",
            "X-Forwarded-For": "198.51.100.42",
        },
        client_host="127.0.0.1",
    )
    assert is_trusted_notebook_client(req_proxied) is False


def test_local_loopback_notebook_client_is_read_only_and_cannot_become_admin():
    req_local = _fake_request(
        headers={"X-Client-ID": "notebook_client_v1"},
        client_host="127.0.0.1",
    )
    assert is_trusted_notebook_client(req_local) is True

    db = SessionLocal()
    try:
        user = get_current_user_or_apikey(
            request=req_local, credentials=None, api_key=None, db=db
        )
        assert user.username == "client_notebook_studio"
        with pytest.raises(HTTPException) as exc:
            require_admin(current_user=user)
        assert exc.value.status_code == 403
    finally:
        db.close()


# ---- 2. Multi-user Highlight Isolation ---------------------------------------


def test_highlights_are_isolated_per_user():
    user_a = _make_user("hl_user_a")
    user_b = _make_user("hl_user_b")
    slug = "isolated-book"

    db = SessionLocal()
    try:
        db.query(Highlight).filter(Highlight.book_slug == slug).delete()
        db.query(UserPermission).filter(UserPermission.book_slug == slug).delete()
        db.query(Book).filter(Book.slug == slug).delete()
        db.add(Book(slug=slug, title="Isolated Book", page_count=10, is_published=True))
        db.add(UserPermission(user_id=user_a.id, book_slug=slug))
        db.add(UserPermission(user_id=user_b.id, book_slug=slug))
        db.commit()

        # User A creates a highlight with a private note
        create_or_update_highlight(
            slug,
            {
                "id": "hl-user-a-1",
                "page": 1,
                "lang": "en",
                "color": "#ffeb3b",
                "text": "Secret passage",
                "note": "User A private note",
            },
            current_user=user_a,
            db=db,
        )

        # User A sees their highlight
        res_a = get_highlights(slug, current_user=user_a, db=db)
        assert len(res_a["highlights"]) == 1
        assert res_a["highlights"][0]["note"] == "User A private note"

        # User B must NOT see User A's highlight
        res_b = get_highlights(slug, current_user=user_b, db=db)
        assert res_b["highlights"] == []

        # User B cannot overwrite User A's highlight by ID
        with pytest.raises(HTTPException) as exc:
            create_or_update_highlight(
                slug,
                {"id": "hl-user-a-1", "color": "#ff0000", "note": "Hacked"},
                current_user=user_b,
                db=db,
            )
        assert exc.value.status_code == 403

        # User B cannot delete User A's highlight
        with pytest.raises(HTTPException) as exc:
            delete_highlight(slug, "hl-user-a-1", current_user=user_b, db=db)
        assert exc.value.status_code == 403
    finally:
        db.query(Highlight).filter(Highlight.book_slug == slug).delete()
        db.commit()
        db.close()


# ---- 3. Book Slug Path Traversal Protection ----------------------------------


@pytest.mark.parametrize(
    "bad_slug",
    [
        "",
        "../evil",
        "../../etc",
        "foo/bar",
        "foo\\bar",
        ".hidden",
        "book..slug",
    ],
)
def test_validate_book_slug_rejects_traversal(bad_slug: str):
    with pytest.raises(ValueError):
        validate_book_slug(bad_slug)


def test_unpack_book_rejects_malicious_manifest_slug(tmp_path: Path):
    bkb_file = tmp_path / "malicious.bkb"
    with zipfile.ZipFile(bkb_file, "w") as zf:
        zf.writestr(
            "manifest.json",
            json.dumps({"slug": "../escaped-folder", "title": "Evil"}),
        )
        zf.writestr("output/en/page_0001.html", "<p>Hi</p>")

    dest = tmp_path / "books"
    with pytest.raises(ValueError, match="Invalid book slug"):
        unpack_book(bkb_file, dest)
    assert not (tmp_path / "escaped-folder").exists()


# ---- 4. SSRF Guards in Chat & Notebook Proxies -------------------------------


@pytest.mark.parametrize(
    "bad_url",
    [
        "http://api.openai.com/v1",
        "https://localhost:11434/v1",
        "https://127.0.0.1:8080/v1",
        "https://10.0.0.5/v1",
        "https://192.168.1.20/v1",
        "https://169.254.169.254/latest/meta-data",
        "https://[::1]:8000/v1",
        "https://llm.internal/v1",
    ],
)
def test_chat_base_url_blocks_private_and_non_https_targets(bad_url: str):
    with pytest.raises(HTTPException) as exc:
        _validate_chat_base_url(bad_url)
    assert exc.value.status_code == 400


@pytest.mark.parametrize(
    "bad_notebook_url",
    [
        "http://169.254.169.254/latest/meta-data",
        "http://10.0.0.5:27972",
        "http://192.168.1.5:27972",
        "http://127.0.0.1:22",
        "http://localhost:6379",
        "ftp://127.0.0.1:27972",
    ],
)
def test_notebook_target_url_blocks_ssrf(bad_notebook_url: str):
    req = _fake_request(headers={"x-notebook-base-url": bad_notebook_url})
    with pytest.raises(HTTPException) as exc:
        _get_target_notebook_url(req)
    assert exc.value.status_code == 400


def test_notebook_target_url_allows_default_loopback_port():
    req = _fake_request(headers={"x-notebook-base-url": "http://localhost:27972/"})
    assert _get_target_notebook_url(req) == "http://localhost:27972"


# ---- 5. Virtual Admin (id=None) Safety on User Endpoints ---------------------


def test_virtual_apikey_user_does_not_500_on_user_id_endpoints():
    virtual_user = User(username="apikey_ci", is_admin=True)
    db = SessionLocal()
    try:
        settings_view = get_user_settings(current_user=virtual_user, db=db)
        assert settings_view["provider"] == "openai"

        with pytest.raises(HTTPException) as exc:
            put_user_settings({"model": "gpt-4o"}, current_user=virtual_user, db=db)
        assert exc.value.status_code == 400

        prog = get_reading_progress("some-book", current_user=virtual_user, db=db)
        assert prog == {"page": 1, "viewMode": "en"}

        with pytest.raises(HTTPException) as exc:
            save_reading_progress("some-book", {"page": 2}, current_user=virtual_user, db=db)
        assert exc.value.status_code == 400
    finally:
        db.close()


# ---- 6. Per-Book Default Font & Color + User Override -----------------------


def test_per_book_default_appearance_and_user_override():
    init_db()
    db = SessionLocal()
    slug = "test-appearance-book"
    try:
        db.query(UserPermission).filter(UserPermission.book_slug == slug).delete()
        db.query(Book).filter(Book.slug == slug).delete()
        db.query(User).filter(User.username.in_(["reader_one", "reader_two"])).delete()
        db.commit()

        u1 = User(username="reader_one", password_hash="x", is_admin=False)
        u2 = User(username="reader_two", password_hash="x", is_admin=False)
        db.add_all([u1, u2])
        db.commit()
        db.refresh(u1)
        db.refresh(u2)

        book = Book(slug=slug, title="Appearance Test Book", author="Tester", page_count=10)
        db.add(book)
        db.add_all([
            UserPermission(user_id=u1.id, book_slug=slug),
            UserPermission(user_id=u2.id, book_slug=slug),
        ])
        db.commit()

        # Initially both defaults are 'default' and user overrides are ''
        u1_books = list_books(current_user=u1, db=db)
        b_view = next(b for b in u1_books if b["slug"] == slug)
        assert b_view["defaultFont"] == "default"
        assert b_view["defaultTheme"] == "default"
        assert b_view["readerFont"] == ""
        assert b_view["readerTheme"] == ""

        # Configure book's default font and paper theme
        res_def = update_book_appearance_defaults(
            slug,
            {"defaultFont": "literata", "defaultTheme": "paper-sepia"},
            current_user=u1,
            db=db,
        )
        assert res_def["defaultFont"] == "literata"
        assert res_def["defaultTheme"] == "paper-sepia"

        # User 1 sets a personal override while reading; User 2 keeps book defaults
        res_state = update_book_state(
            slug,
            {"readerFont": "inter", "readerTheme": "paper-dark"},
            current_user=u1,
            db=db,
        )
        assert res_state["readerFont"] == "inter"
        assert res_state["readerTheme"] == "paper-dark"

        u1_view = next(b for b in list_books(current_user=u1, db=db) if b["slug"] == slug)
        u2_view = next(b for b in list_books(current_user=u2, db=db) if b["slug"] == slug)

        assert u1_view["defaultFont"] == "literata"
        assert u1_view["defaultTheme"] == "paper-sepia"
        assert u1_view["readerFont"] == "inter"
        assert u1_view["readerTheme"] == "paper-dark"

        assert u2_view["defaultFont"] == "literata"
        assert u2_view["defaultTheme"] == "paper-sepia"
        assert u2_view["readerFont"] == ""
        assert u2_view["readerTheme"] == ""
    finally:
        db.query(UserPermission).filter(UserPermission.book_slug == slug).delete()
        db.query(Book).filter(Book.slug == slug).delete()
        db.query(User).filter(User.username.in_(["reader_one", "reader_two"])).delete()
        db.commit()
        db.close()

