"""Shelf ordering for GET /api/books, plus the books.created_at migration.

The rule under test, in two tiers:

  tier 1 - books the CURRENT user has read, ordered by last_read DESC
  tier 2 - books never read, ordered by import time (created_at) DESC

Tier 1 always sits above tier 2, so reading a book moves it to position 1. This
is deliberately not a max(created_at, last_read) blend: a book read five minutes
ago outranks a book imported one minute ago. Ties break on id DESC (autoincrement
= import order) then slug, which is also how rows with a NULL created_at (they
predate the column) land in their true import order.

Like test_user_settings.py these call the route function directly against the
throwaway SQLite DB pinned by tests/conftest.py — no TestClient, no live server.
"""
from __future__ import annotations

import sys
from pathlib import Path

# `api` is a path-based namespace package (no pip install); see backend/conftest.py.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pytest  # noqa: E402
from sqlalchemy import event, inspect, text  # noqa: E402

from api.database import (  # noqa: E402
    Book,
    ReadingProgress,
    SessionLocal,
    User,
    UserPermission,
    engine,
    init_db,
    _migrate_add_book_created_at,
)
from api.routes.books import list_books  # noqa: E402

init_db()


# ---- fixtures / helpers ------------------------------------------------------

def _make_user(username: str, is_admin: bool = False) -> int:
    db = SessionLocal()
    try:
        u = db.query(User).filter(User.username == username).first()
        if not u:
            u = User(username=username, password_hash="x", is_admin=is_admin)
            db.add(u)
            db.commit()
            db.refresh(u)
        return u.id
    finally:
        db.close()


UID_A = _make_user("shelf_user_a")
UID_B = _make_user("shelf_user_b")
UID_ADMIN = _make_user("shelf_admin", is_admin=True)


def _reset_shelf() -> None:
    """Wipe every row this module owns. The DB is shared by the whole suite, but
    books / permissions / progress are used by no other module."""
    db = SessionLocal()
    try:
        db.query(ReadingProgress).delete()
        db.query(UserPermission).delete()
        db.query(Book).delete()
        db.commit()
    finally:
        db.close()


@pytest.fixture(autouse=True)
def clean_shelf():
    _reset_shelf()
    yield
    _reset_shelf()


def _add_book(db, slug: str, created_at: int | None) -> None:
    """Insert a book. created_at=None writes a genuine SQL NULL (a row imported
    before the column existed), independent of any ORM default."""
    db.add(Book(
        slug=slug,
        title=slug.upper(),
        author="Author",
        page_count=10,
        cover_path=None,
        is_published=True,
        created_at=created_at,
    ))
    db.commit()
    if created_at is None:
        db.execute(text("UPDATE books SET created_at = NULL WHERE slug = :s"), {"s": slug})
        db.commit()


def _grant(db, user_id: int, slugs) -> None:
    for s in slugs:
        db.add(UserPermission(user_id=user_id, book_slug=s))
    db.commit()


def _mark_read(db, user_id: int, slug: str, when: int) -> None:
    row = db.query(ReadingProgress).filter(
        ReadingProgress.user_id == user_id, ReadingProgress.book_slug == slug
    ).first()
    if row:
        row.last_read = when
    else:
        db.add(ReadingProgress(
            user_id=user_id, book_slug=slug, page=1, view_mode="en", last_read=when
        ))
    db.commit()


def _shelf(user_id: int):
    """Call the endpoint as `user_id` and return the raw payload."""
    db = SessionLocal()
    try:
        user = db.query(User).filter(User.id == user_id).first()
        return list_books(current_user=user, db=db)
    finally:
        db.close()


def _slugs(user_id: int):
    return [b["slug"] for b in _shelf(user_id)]


def _setup(books, reader_ids=(UID_A, UID_B)):
    """books: list of (slug, created_at). Every listed book is granted to each
    reader so ordering, not permissions, is what the assertions measure."""
    db = SessionLocal()
    try:
        for slug, created_at in books:
            _add_book(db, slug, created_at)
        for uid in reader_ids:
            _grant(db, uid, [slug for slug, _ in books])
    finally:
        db.close()


class _QueryCounter:
    """Counts SQL statements actually sent to the DB inside the block."""

    def __init__(self):
        self.statements = []

    def _on(self, conn, cursor, statement, parameters, context, executemany):
        self.statements.append(statement)

    def __enter__(self):
        event.listen(engine, "before_cursor_execute", self._on)
        return self

    def __exit__(self, *exc):
        event.remove(engine, "before_cursor_execute", self._on)
        return False


# ---- (a) read books precede unread ones --------------------------------------

def test_read_book_jumps_above_every_unread_book():
    # b1 is the OLDEST import, so only the read/unread tier can lift it.
    _setup([("b1", 1_000), ("b2", 2_000), ("b3", 3_000), ("b4", 4_000)])
    db = SessionLocal()
    try:
        _mark_read(db, UID_A, "b1", 9_000)
    finally:
        db.close()

    assert _slugs(UID_A) == ["b1", "b4", "b3", "b2"]


def test_reading_wins_over_a_newer_import_no_max_blend():
    # The iOS max(addedTime, lastRead) blend would put `fresh-import` first.
    # The rule says reading activity wins.
    _setup([("read-5-min-ago", 1_000), ("fresh-import", 100_000)])
    db = SessionLocal()
    try:
        _mark_read(db, UID_A, "read-5-min-ago", 99_700)  # older than the import
    finally:
        db.close()

    assert _slugs(UID_A) == ["read-5-min-ago", "fresh-import"]


# ---- (b) read books ordered by lastRead DESC ---------------------------------

def test_read_books_ordered_by_most_recent_last_read():
    _setup([("r1", 1_000), ("r2", 2_000), ("r3", 3_000), ("u1", 4_000)])
    db = SessionLocal()
    try:
        _mark_read(db, UID_A, "r1", 5_000)
        _mark_read(db, UID_A, "r2", 7_000)
        _mark_read(db, UID_A, "r3", 6_000)
    finally:
        db.close()

    assert _slugs(UID_A) == ["r2", "r3", "r1", "u1"]

    # Re-reading r1 moves it to position 1.
    db = SessionLocal()
    try:
        _mark_read(db, UID_A, "r1", 8_000)
    finally:
        db.close()
    assert _slugs(UID_A) == ["r1", "r2", "r3", "u1"]


# ---- (c) unread ordered by created_at DESC, NULL falls back to id DESC -------

def test_unread_books_newest_import_first():
    _setup([("old", 1_000), ("newest", 3_000), ("middle", 2_000)])
    assert _slugs(UID_A) == ["newest", "middle", "old"]


def test_null_created_at_falls_back_to_id_desc_and_ranks_below_timestamped():
    # `uploaded` is inserted FIRST, so it has the LOWEST id: plain id DESC would
    # bury it. Its real timestamp must still lift it above the NULL legacy rows,
    # which order among themselves by id DESC (legacy-2 imported after legacy-1).
    _setup([("uploaded", 1_000), ("legacy-1", None), ("legacy-2", None)])

    shelf = _shelf(UID_A)
    assert [b["slug"] for b in shelf] == ["uploaded", "legacy-2", "legacy-1"]
    # The legacy rows keep an honest NULL; the new upload carries a real stamp.
    assert [b["createdAt"] for b in shelf] == [1_000, None, None]


# ---- (d) lastRead is per user ------------------------------------------------

def test_last_read_is_per_user_and_does_not_reorder_another_shelf():
    _setup([("p1", 1_000), ("p2", 2_000), ("p3", 3_000)])
    db = SessionLocal()
    try:
        _mark_read(db, UID_A, "p1", 9_000)
    finally:
        db.close()

    assert _slugs(UID_A) == ["p1", "p3", "p2"]
    # User B has read nothing: pure import order, untouched by A's reading.
    assert _slugs(UID_B) == ["p3", "p2", "p1"]

    b_shelf = {b["slug"]: b["lastRead"] for b in _shelf(UID_B)}
    assert b_shelf == {"p1": None, "p2": None, "p3": None}
    a_shelf = {b["slug"]: b["lastRead"] for b in _shelf(UID_A)}
    assert a_shelf == {"p1": 9_000, "p2": None, "p3": None}

    # Now B reads p2; A's shelf must not move.
    db = SessionLocal()
    try:
        _mark_read(db, UID_B, "p2", 9_500)
    finally:
        db.close()
    assert _slugs(UID_B) == ["p2", "p3", "p1"]
    assert _slugs(UID_A) == ["p1", "p3", "p2"]


def test_admin_sees_every_book_and_still_gets_its_own_ordering():
    # The admin has no UserPermission rows at all — the admin branch must still
    # return the whole shelf, ordered by the admin's own reading.
    _setup([("a1", 1_000), ("a2", 2_000), ("a3", 3_000)], reader_ids=(UID_A,))
    db = SessionLocal()
    try:
        _mark_read(db, UID_A, "a3", 9_000)      # another user's reading: irrelevant
        _mark_read(db, UID_ADMIN, "a1", 8_000)
    finally:
        db.close()

    assert _slugs(UID_ADMIN) == ["a1", "a3", "a2"]


def test_non_admin_still_only_sees_permitted_books():
    _setup([("perm-1", 1_000)], reader_ids=(UID_A,))
    db = SessionLocal()
    try:
        _add_book(db, "secret", 5_000)  # granted to nobody
    finally:
        db.close()

    assert _slugs(UID_A) == ["perm-1"]
    assert _slugs(UID_B) == []


# ---- (e) bounded query count -------------------------------------------------

def test_query_count_is_bounded_and_independent_of_shelf_size():
    counts = {}
    for n in (3, 30):
        _reset_shelf()
        slugs = [f"q-{i:03d}" for i in range(n)]
        _setup([(s, 1_000 + i) for i, s in enumerate(slugs)], reader_ids=(UID_A,))
        db = SessionLocal()
        try:
            for i in range(0, n, 3):  # a third of the shelf has progress rows
                _mark_read(db, UID_A, slugs[i], 5_000 + i)
        finally:
            db.close()

        db = SessionLocal()
        try:
            user = db.query(User).filter(User.id == UID_A).first()
            with _QueryCounter() as counter:
                payload = list_books(current_user=user, db=db)
        finally:
            db.close()

        assert len(payload) == n
        counts[n] = len(counter.statements)

    # A per-book progress query would make this grow 3 -> 30.
    assert counts[3] == counts[30], counter.statements
    # permissions lazy-load + books + progress. Generous ceiling, still O(1).
    assert counts[30] <= 4, counter.statements


# ---- (f) migration -----------------------------------------------------------

def test_created_at_migration_is_idempotent_and_keeps_legacy_rows_null():
    def _has_column() -> bool:
        return any(c["name"] == "created_at" for c in inspect(engine).get_columns("books"))

    assert _has_column()  # init_db() at import time

    try:
        # Simulate a database from before the column existed.
        with engine.begin() as conn:
            conn.execute(text("ALTER TABLE books DROP COLUMN created_at"))
            conn.execute(text(
                "INSERT INTO books (slug, title, author, page_count, is_published) "
                "VALUES ('pre-existing', 'Pre Existing', 'A', 1, 1)"
            ))
        assert not _has_column()

        _migrate_add_book_created_at()
        assert _has_column()

        with engine.begin() as conn:
            value = conn.execute(
                text("SELECT created_at FROM books WHERE slug = 'pre-existing'")
            ).scalar()
        # Honest NULL, not an invented timestamp.
        assert value is None

        # Second and third runs are no-ops: no error, no duplicate column, and
        # nothing rewritten.
        with engine.begin() as conn:
            conn.execute(text("UPDATE books SET created_at = 4242 WHERE slug = 'pre-existing'"))
        _migrate_add_book_created_at()
        _migrate_add_book_created_at()

        columns = [c["name"] for c in inspect(engine).get_columns("books")]
        assert columns.count("created_at") == 1
        with engine.begin() as conn:
            assert conn.execute(
                text("SELECT created_at FROM books WHERE slug = 'pre-existing'")
            ).scalar() == 4242
    finally:
        # Never leave the schema broken for whatever runs next.
        if not _has_column():
            _migrate_add_book_created_at()
