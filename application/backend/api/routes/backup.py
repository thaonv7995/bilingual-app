"""Backup & Disaster Recovery API for macOS Vault and Admin/Personal snapshots.

Server remains the Source of Truth during normal operation; these endpoints allow:
1. `GET /api/backup/manifest` — lightweight library & DB counts plus deterministic per-book
   `contentFingerprint` hashes so scheduled syncs skip re-downloading unchanged `.bkb` archives.
2. `GET /api/backup/export` — versioned JSON snapshot of books metadata, users/permissions/API keys
   (admin only), highlights, reading progress, shelf/appearance states, and user settings
   (with optional secrets).
3. `POST /api/backup/restore` — emergency recovery (`merge` or `overwrite`) with `dryRun` diff
   preview, cross-server username->id remapping, slug path-traversal validation, and admin
   self-lockout protection.
"""

from __future__ import annotations

import hashlib
import json
import os
import time
from pathlib import Path
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import or_
from sqlalchemy.orm import Session

import api.config as api_config
from api.auth import get_current_user_or_apikey
from api.database import (
    APIKey,
    Book,
    Highlight,
    ReadingProgress,
    User,
    UserBookState,
    UserPermission,
    UserRefreshToken,
    UserSettings,
    get_db,
)
from books_core.package import validate_book_slug

router = APIRouter(prefix="/api/backup", tags=["backup"])

BACKUP_SCHEMA_VERSION = 1

# Cache: str(book_dir) -> ((file_count, total_size, max_mtime_ns), sha256_hex)
_FINGERPRINT_CACHE: dict[str, tuple[tuple[int, int, int], str]] = {}


def _books_dir() -> Path:
    return Path(api_config.BOOKS_DIR).resolve()


def _ensure_safe_slug_or_400(slug: str) -> str:
    try:
        return validate_book_slug(slug)
    except ValueError as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid book slug: {slug!r}",
        ) from exc


def _require_real_session(current_user: User) -> User:
    if getattr(current_user, "_is_notebook_client", False):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Notebook client credentials cannot access backup or restore endpoints.",
        )
    return current_user


def _compute_book_content_stats(slug: str) -> dict[str, Any]:
    """Compute output file stats and a deterministic content SHA-256 fingerprint."""
    safe_slug = _ensure_safe_slug_or_400(slug)
    books_root = _books_dir()
    book_dir = (books_root / safe_slug).resolve()
    if book_dir.parent != books_root or not book_dir.is_dir():
        return {
            "hasOutputDir": False,
            "outputFileCount": 0,
            "outputSizeBytes": 0,
            "contentFingerprint": "",
        }

    output_dir = book_dir / "output"
    files: list[tuple[str, Path, os.stat_result]] = []

    output_file_count = 0
    output_size_bytes = 0
    if output_dir.is_dir():
        for p in output_dir.rglob("*"):
            if p.is_file():
                rel = (Path("output") / p.relative_to(output_dir)).as_posix()
                st = p.stat()
                files.append((rel, p, st))
                output_file_count += 1
                output_size_bytes += st.st_size

    if not files:
        return {
            "hasOutputDir": output_dir.is_dir(),
            "outputFileCount": 0,
            "outputSizeBytes": 0,
            "contentFingerprint": "",
        }

    files.sort(key=lambda item: item[0])
    total_size = sum(item[2].st_size for item in files)
    max_mtime_ns = max(item[2].st_mtime_ns for item in files)
    stat_sig = (len(files), total_size, max_mtime_ns)

    cache_key = str(book_dir)
    cached = _FINGERPRINT_CACHE.get(cache_key)
    if cached and cached[0] == stat_sig:
        fingerprint = cached[1]
    else:
        hasher = hashlib.sha256()
        for rel, path, st in files:
            hasher.update(rel.encode("utf-8"))
            hasher.update(b"\0")
            hasher.update(str(st.st_size).encode("ascii"))
            hasher.update(b"\0")
            with path.open("rb") as fh:
                while chunk := fh.read(65536):
                    hasher.update(chunk)
        fingerprint = hasher.hexdigest()
        if len(_FINGERPRINT_CACHE) > 2048:
            _FINGERPRINT_CACHE.clear()
        _FINGERPRINT_CACHE[cache_key] = (stat_sig, fingerprint)

    return {
        "hasOutputDir": output_dir.is_dir(),
        "outputFileCount": output_file_count,
        "outputSizeBytes": output_size_bytes,
        "contentFingerprint": fingerprint,
    }


def _permitted_slugs_for_user(db: Session, user: User) -> set[str]:
    if user.is_admin:
        return {b.slug for b in db.query(Book.slug).all()}
    rows = db.query(UserPermission.book_slug).filter(UserPermission.user_id == user.id).all()
    return {r[0] for r in rows}


def _serialize_book(b: Book, stats: dict[str, Any]) -> dict[str, Any]:
    return {
        "slug": b.slug,
        "title": b.title,
        "author": b.author or "Unknown",
        "pageCount": b.page_count or 0,
        "coverPath": b.cover_path or "",
        "isPublished": bool(b.is_published),
        "defaultFont": b.default_font or "default",
        "defaultTheme": b.default_theme or "default",
        "createdAt": b.created_at or 0,
        "hasOutputDir": stats["hasOutputDir"],
        "outputFileCount": stats["outputFileCount"],
        "outputSizeBytes": stats["outputSizeBytes"],
        "contentFingerprint": stats["contentFingerprint"],
    }


def _serialize_user_settings(
    s: UserSettings, username: str, include_secrets: bool
) -> dict[str, Any]:
    data: dict[str, Any] = {
        "username": username,
        "aiProvider": s.ai_provider or "openai",
        "aiBaseUrl": s.ai_base_url or "https://api.openai.com/v1",
        "aiModel": s.ai_model or "gpt-4o-mini",
        "realtimeModel": s.realtime_model or "gpt-realtime-mini",
        "realtimeVoice": s.realtime_voice or "alloy",
        "audioProvider": s.audio_provider or "device",
        "audioSource": s.audio_source or "auto",
        "audioVoice": s.audio_voice or "",
        "audioVoiceEn": s.audio_voice_en or "",
        "audioVoiceVi": s.audio_voice_vi or "",
        "ttsModel": s.tts_model or "edge-tts/en-US-SteffanNeural",
        "speechSpeed": s.speech_speed or "1.0",
        "layoutMode": s.layout_mode or "en-vi",
        "hideFinishedBooks": True if s.hide_finished_books is None else bool(s.hide_finished_books),
        "vocaOrigin": s.voca_bridge_origin or "",
        "updatedAt": s.updated_at or 0,
        "hasLlmKey": bool(s.llm_api_key),
        "hasRealtimeKey": bool(s.realtime_api_key),
        "hasAzureKey": bool(s.azure_api_key),
        "hasElevenLabsKey": bool(s.elevenlabs_api_key),
        "hasVocaToken": bool(s.voca_bridge_token),
        "llmApiKey": None,
        "realtimeApiKey": None,
        "azureApiKey": None,
        "elevenlabsApiKey": None,
        "vocaToken": None,
    }
    if include_secrets:
        data["llmApiKey"] = s.llm_api_key or ""
        data["realtimeApiKey"] = s.realtime_api_key or ""
        data["azureApiKey"] = s.azure_api_key or ""
        data["elevenlabsApiKey"] = s.elevenlabs_api_key or ""
        data["vocaToken"] = s.voca_bridge_token or ""
    return data


@router.get("/manifest")
def get_backup_manifest(
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    """Lightweight manifest of books (with fingerprints) and record counts for incremental sync."""
    current_user = _require_real_session(current_user)
    is_admin = bool(current_user.is_admin)
    scope = "admin_full" if is_admin else "personal"

    if is_admin:
        books = db.query(Book).order_by(Book.slug.asc()).all()
        user_count = db.query(User).count()
        perm_count = db.query(UserPermission).count()
        hl_count = db.query(Highlight).count()
        prog_count = db.query(ReadingProgress).count()
        state_count = db.query(UserBookState).count()
        settings_count = db.query(UserSettings).count()
        apikey_count = db.query(APIKey).count()
    else:
        permitted = _permitted_slugs_for_user(db, current_user)
        books = (
            db.query(Book).filter(Book.slug.in_(permitted)).order_by(Book.slug.asc()).all()
            if permitted
            else []
        )
        user_count = 1
        perm_count = len(permitted)
        hl_count = (
            db.query(Highlight)
            .filter(
                Highlight.book_slug.in_(permitted) if permitted else False,
                or_(Highlight.username == current_user.username, Highlight.username.is_(None)),
            )
            .count()
            if permitted
            else 0
        )
        prog_count = (
            db.query(ReadingProgress)
            .filter(ReadingProgress.user_id == current_user.id)
            .count()
        )
        state_count = (
            db.query(UserBookState)
            .filter(UserBookState.user_id == current_user.id)
            .count()
        )
        settings_count = (
            db.query(UserSettings)
            .filter(UserSettings.user_id == current_user.id)
            .count()
        )
        apikey_count = 0

    serialized_books = []
    for b in books:
        stats = _compute_book_content_stats(b.slug)
        serialized_books.append(_serialize_book(b, stats))

    return {
        "version": BACKUP_SCHEMA_VERSION,
        "generatedAt": int(time.time()),
        "scope": scope,
        "username": current_user.username,
        "counts": {
            "books": len(serialized_books),
            "users": user_count,
            "permissions": perm_count,
            "highlights": hl_count,
            "readingProgress": prog_count,
            "userBookStates": state_count,
            "userSettings": settings_count,
            "apiKeys": apikey_count,
        },
        "books": serialized_books,
    }


@router.get("/export")
def export_backup_snapshot(
    include_secrets: bool = Query(False),
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    """Export complete server snapshot (admin) or personal backup snapshot (regular user)."""
    current_user = _require_real_session(current_user)
    is_admin = bool(current_user.is_admin)
    scope = "admin_full" if is_admin else "personal"

    users_by_id = {u.id: u.username for u in db.query(User).all()}

    if is_admin:
        books = db.query(Book).order_by(Book.slug.asc()).all()
        users_rows = db.query(User).order_by(User.id.asc()).all()
        perm_rows = db.query(UserPermission).all()
        apikey_rows = db.query(APIKey).all()
        hl_rows = db.query(Highlight).order_by(Highlight.created_at.asc()).all()
        prog_rows = db.query(ReadingProgress).all()
        state_rows = db.query(UserBookState).all()
        settings_rows = db.query(UserSettings).all()
    else:
        permitted = _permitted_slugs_for_user(db, current_user)
        books = (
            db.query(Book).filter(Book.slug.in_(permitted)).order_by(Book.slug.asc()).all()
            if permitted
            else []
        )
        users_rows = []
        perm_rows = []
        apikey_rows = []
        hl_rows = (
            db.query(Highlight)
            .filter(
                Highlight.book_slug.in_(permitted),
                or_(Highlight.username == current_user.username, Highlight.username.is_(None)),
            )
            .order_by(Highlight.created_at.asc())
            .all()
            if permitted
            else []
        )
        prog_rows = (
            db.query(ReadingProgress)
            .filter(
                ReadingProgress.user_id == current_user.id,
                ReadingProgress.book_slug.in_(permitted) if permitted else False,
            )
            .all()
            if permitted
            else []
        )
        state_rows = (
            db.query(UserBookState)
            .filter(
                UserBookState.user_id == current_user.id,
                UserBookState.book_slug.in_(permitted) if permitted else False,
            )
            .all()
            if permitted
            else []
        )
        settings_rows = (
            db.query(UserSettings)
            .filter(UserSettings.user_id == current_user.id)
            .all()
        )

    serialized_books = [
        _serialize_book(b, _compute_book_content_stats(b.slug)) for b in books
    ]

    serialized_users = [
        {
            "username": u.username,
            "passwordHash": u.password_hash,
            "isAdmin": bool(u.is_admin),
        }
        for u in users_rows
    ]

    serialized_permissions = []
    for p in perm_rows:
        uname = users_by_id.get(p.user_id)
        if uname:
            serialized_permissions.append({"username": uname, "bookSlug": p.book_slug})

    serialized_apikeys = [
        {
            "name": k.name,
            "isActive": bool(k.is_active),
            "createdAt": k.created_at or 0,
            "keyValue": k.key_value if (is_admin and include_secrets) else None,
        }
        for k in apikey_rows
    ]

    serialized_highlights = [
        {
            "id": h.id,
            "bookSlug": h.book_slug,
            "username": h.username or current_user.username,
            "page": h.page,
            "lang": h.lang,
            "color": h.color,
            "text": h.text,
            "startOffset": h.start_offset or 0,
            "endOffset": h.end_offset or 0,
            "paragraphIndex": h.paragraph_index or 0,
            "note": h.note or "",
            "createdAt": h.created_at or 0,
        }
        for h in hl_rows
    ]

    serialized_progress = []
    for pr in prog_rows:
        uname = users_by_id.get(pr.user_id)
        if uname:
            serialized_progress.append(
                {
                    "username": uname,
                    "bookSlug": pr.book_slug,
                    "page": pr.page or 1,
                    "viewMode": pr.view_mode or "en",
                    "lastRead": pr.last_read or 0,
                }
            )

    serialized_states = []
    for st in state_rows:
        uname = users_by_id.get(st.user_id)
        if uname:
            serialized_states.append(
                {
                    "username": uname,
                    "bookSlug": st.book_slug,
                    "isFinished": bool(st.is_finished),
                    "onShelf": bool(st.on_shelf),
                    "isPriority": bool(st.is_priority),
                    "readerFont": st.reader_font or "",
                    "readerTheme": st.reader_theme or "",
                }
            )

    serialized_settings = []
    for s in settings_rows:
        uname = users_by_id.get(s.user_id)
        if uname:
            serialized_settings.append(_serialize_user_settings(s, uname, include_secrets))

    return {
        "version": BACKUP_SCHEMA_VERSION,
        "exportedAt": int(time.time()),
        "scope": scope,
        "exportedBy": current_user.username,
        "includesSecrets": bool(include_secrets),
        "books": serialized_books,
        "users": serialized_users,
        "permissions": serialized_permissions,
        "apiKeys": serialized_apikeys,
        "highlights": serialized_highlights,
        "readingProgress": serialized_progress,
        "userBookStates": serialized_states,
        "userSettings": serialized_settings,
    }


def _restore_users(
    db: Session,
    items: list[dict[str, Any]],
    mode: str,
    current_user: User,
    apply: bool,
    warnings: list[str],
) -> tuple[dict[str, int], dict[str, User], set[str]]:
    counts = {"created": 0, "updated": 0, "skipped": 0, "deleted": 0}
    db_users = {u.username: u for u in db.query(User).all()}
    known_usernames = set(db_users.keys())
    snapshot_usernames: set[str] = set()

    for raw in items:
        username = str(raw.get("username") or "").strip()
        password_hash = str(raw.get("passwordHash") or "").strip()
        is_admin = bool(raw.get("isAdmin", False))
        if not username:
            counts["skipped"] += 1
            continue
        snapshot_usernames.add(username)
        known_usernames.add(username)

        existing = db_users.get(username)
        if not existing:
            if not password_hash:
                counts["skipped"] += 1
                warnings.append(f"Skipped creating user '{username}': missing passwordHash.")
                continue
            counts["created"] += 1
            if apply:
                new_user = User(username=username, password_hash=password_hash, is_admin=is_admin)
                db.add(new_user)
                db.flush()
                db_users[username] = new_user
        else:
            if mode == "overwrite":
                target_admin = True if username == current_user.username else is_admin
                if username == current_user.username and not is_admin:
                    warnings.append(
                        f"Preserved admin privilege for active session user '{username}'."
                    )
                new_hash = password_hash or existing.password_hash
                changed = (existing.password_hash != new_hash) or (
                    bool(existing.is_admin) != target_admin
                )
                if changed:
                    counts["updated"] += 1
                    if apply:
                        existing.password_hash = new_hash
                        existing.is_admin = target_admin
                else:
                    counts["skipped"] += 1
            else:
                counts["skipped"] += 1

    if mode == "overwrite" and snapshot_usernames:
        for uname, u_obj in list(db_users.items()):
            if uname in snapshot_usernames:
                continue
            if uname == current_user.username:
                warnings.append(
                    f"Preserved active session user '{uname}' (not deleted by overwrite)."
                )
                continue
            counts["deleted"] += 1
            known_usernames.discard(uname)
            if apply:
                db.query(UserPermission).filter(UserPermission.user_id == u_obj.id).delete()
                db.query(ReadingProgress).filter(ReadingProgress.user_id == u_obj.id).delete()
                db.query(UserBookState).filter(UserBookState.user_id == u_obj.id).delete()
                db.query(UserSettings).filter(UserSettings.user_id == u_obj.id).delete()
                db.query(UserRefreshToken).filter(UserRefreshToken.user_id == u_obj.id).delete()
                db.delete(u_obj)
                db_users.pop(uname, None)

    return counts, db_users, known_usernames


def _restore_books_metadata(
    db: Session,
    items: list[dict[str, Any]],
    mode: str,
    apply: bool,
) -> dict[str, Any]:
    counts: dict[str, Any] = {"updated": 0, "unchanged": 0, "missingFiles": []}
    db_books = {b.slug: b for b in db.query(Book).all()}

    for raw in items:
        slug = _ensure_safe_slug_or_400(str(raw.get("slug") or ""))
        db_book = db_books.get(slug)
        if not db_book:
            counts["missingFiles"].append(slug)
            continue

        title = raw.get("title")
        author = raw.get("author")
        page_count = raw.get("pageCount")
        cover_path = raw.get("coverPath")
        is_published = raw.get("isPublished")
        default_font = raw.get("defaultFont")
        default_theme = raw.get("defaultTheme")
        created_at = raw.get("createdAt")

        changed = False
        if mode == "overwrite":
            if title and db_book.title != str(title):
                changed = True
                if apply:
                    db_book.title = str(title)
            if author is not None and (db_book.author or "") != str(author):
                changed = True
                if apply:
                    db_book.author = str(author)
            if isinstance(page_count, int) and page_count > 0 and db_book.page_count != page_count:
                changed = True
                if apply:
                    db_book.page_count = page_count
            if cover_path and (db_book.cover_path or "") != str(cover_path):
                changed = True
                if apply:
                    db_book.cover_path = str(cover_path)
            if isinstance(is_published, bool) and bool(db_book.is_published) != is_published:
                changed = True
                if apply:
                    db_book.is_published = is_published
            if default_font and (db_book.default_font or "default") != str(default_font):
                changed = True
                if apply:
                    db_book.default_font = str(default_font)
            if default_theme and (db_book.default_theme or "default") != str(default_theme):
                changed = True
                if apply:
                    db_book.default_theme = str(default_theme)
            if isinstance(created_at, int) and created_at > 0 and db_book.created_at != created_at:
                changed = True
                if apply:
                    db_book.created_at = created_at
        else:
            # Merge: only fill defaults/missing admin customizations without clobbering server edits
            if default_font and (not db_book.default_font or db_book.default_font == "default") and default_font != "default":
                changed = True
                if apply:
                    db_book.default_font = str(default_font)
            if default_theme and (not db_book.default_theme or db_book.default_theme == "default") and default_theme != "default":
                changed = True
                if apply:
                    db_book.default_theme = str(default_theme)
            if cover_path and not db_book.cover_path:
                changed = True
                if apply:
                    db_book.cover_path = str(cover_path)

        if changed:
            counts["updated"] += 1
            if apply:
                book_json_path = _books_dir() / slug / "book.json"
                if book_json_path.is_file():
                    try:
                        meta = json.loads(book_json_path.read_text(encoding="utf-8"))
                        meta["title"] = db_book.title
                        meta["author"] = db_book.author or "Unknown"
                        meta["default_font"] = db_book.default_font or "default"
                        meta["default_theme"] = db_book.default_theme or "default"
                        book_json_path.write_text(
                            json.dumps(meta, indent=2, ensure_ascii=False) + "\n",
                            encoding="utf-8",
                        )
                    except Exception:
                        pass
        else:
            counts["unchanged"] += 1

    return counts


def _restore_permissions(
    db: Session,
    items: list[dict[str, Any]],
    mode: str,
    db_users: dict[str, User],
    known_usernames: set[str],
    apply: bool,
    warnings: list[str],
) -> dict[str, int]:
    counts = {"created": 0, "unchanged": 0, "skipped": 0, "deleted": 0}
    desired_pairs: set[tuple[str, str]] = set()
    for raw in items:
        uname = str(raw.get("username") or "").strip()
        slug = _ensure_safe_slug_or_400(str(raw.get("bookSlug") or ""))
        if not uname or uname not in known_usernames:
            counts["skipped"] += 1
            if uname:
                warnings.append(f"Skipped permission for unknown user '{uname}' on '{slug}'.")
            continue
        desired_pairs.add((uname, slug))

    user_id_to_name = {u.id: u.username for u in db_users.values() if u.id is not None}
    existing_rows = db.query(UserPermission).all()
    existing_map: dict[tuple[str, str], UserPermission] = {}
    for row in existing_rows:
        uname = user_id_to_name.get(row.user_id)
        if uname:
            existing_map[(uname, row.book_slug)] = row

    for pair in sorted(desired_pairs):
        if pair in existing_map:
            counts["unchanged"] += 1
        else:
            counts["created"] += 1
            if apply:
                user_obj = db_users.get(pair[0])
                if user_obj and user_obj.id is not None:
                    db.add(UserPermission(user_id=user_obj.id, book_slug=pair[1]))

    if mode == "overwrite":
        for pair, row in existing_map.items():
            if pair not in desired_pairs:
                counts["deleted"] += 1
                if apply:
                    db.delete(row)

    return counts


def _restore_apikeys(
    db: Session,
    items: list[dict[str, Any]],
    mode: str,
    apply: bool,
    includes_secrets: bool,
) -> dict[str, int]:
    counts = {"created": 0, "updated": 0, "skipped": 0, "deleted": 0}
    existing_by_value = {k.key_value: k for k in db.query(APIKey).all()}
    seen_values: set[str] = set()

    for raw in items:
        key_val = str(raw.get("keyValue") or "").strip()
        name = str(raw.get("name") or "").strip() or "restored-key"
        is_active = bool(raw.get("isActive", True))
        created_at = int(raw.get("createdAt") or int(time.time()))
        if not key_val:
            counts["skipped"] += 1
            continue
        seen_values.add(key_val)
        existing = existing_by_value.get(key_val)
        if not existing:
            counts["created"] += 1
            if apply:
                db.add(
                    APIKey(
                        key_value=key_val,
                        name=name,
                        is_active=is_active,
                        created_at=created_at,
                    )
                )
        elif mode == "overwrite" and (
            existing.name != name or bool(existing.is_active) != is_active
        ):
            counts["updated"] += 1
            if apply:
                existing.name = name
                existing.is_active = is_active
        else:
            counts["skipped"] += 1

    if mode == "overwrite" and includes_secrets:
        for val, row in existing_by_value.items():
            if val not in seen_values:
                counts["deleted"] += 1
                if apply:
                    db.delete(row)

    return counts


def _restore_highlights(
    db: Session,
    items: list[dict[str, Any]],
    mode: str,
    current_user: User,
    permitted_for_non_admin: set[str],
    apply: bool,
) -> dict[str, int]:
    counts = {"created": 0, "updated": 0, "skipped": 0, "deleted": 0}
    existing_by_id = {h.id: h for h in db.query(Highlight).all()}
    seen_ids: set[str] = set()

    for raw in items:
        hl_id = str(raw.get("id") or "").strip()
        slug = _ensure_safe_slug_or_400(str(raw.get("bookSlug") or ""))
        owner = str(raw.get("username") or current_user.username).strip()
        page = raw.get("page")
        lang = str(raw.get("lang") or "").strip()
        color = str(raw.get("color") or "").strip()
        text = raw.get("text")
        if not hl_id or page is None or not lang or not color or text is None:
            counts["skipped"] += 1
            continue

        if not current_user.is_admin:
            if owner != current_user.username or slug not in permitted_for_non_admin:
                counts["skipped"] += 1
                continue

        seen_ids.add(hl_id)
        existing = existing_by_id.get(hl_id)
        note_val = str(raw.get("note") or "")
        start_offset = int(raw.get("startOffset") or 0)
        end_offset = int(raw.get("endOffset") or 0)
        paragraph_idx = int(raw.get("paragraphIndex") or 0)
        created_at = int(raw.get("createdAt") or int(time.time()))

        if not existing:
            counts["created"] += 1
            if apply:
                db.add(
                    Highlight(
                        id=hl_id,
                        book_slug=slug,
                        page=int(page),
                        lang=lang,
                        color=color,
                        text=str(text),
                        start_offset=start_offset,
                        end_offset=end_offset,
                        paragraph_index=paragraph_idx,
                        note=note_val,
                        created_at=created_at,
                        username=owner,
                    )
                )
        else:
            if existing.username and existing.username != owner and not current_user.is_admin:
                counts["skipped"] += 1
                continue
            if mode == "overwrite":
                changed = (
                    existing.book_slug != slug
                    or existing.page != int(page)
                    or existing.lang != lang
                    or existing.color != color
                    or existing.text != str(text)
                    or existing.start_offset != start_offset
                    or existing.end_offset != end_offset
                    or existing.paragraph_index != paragraph_idx
                    or (existing.note or "") != note_val
                    or (existing.username or "") != owner
                )
                if changed:
                    counts["updated"] += 1
                    if apply:
                        existing.book_slug = slug
                        existing.page = int(page)
                        existing.lang = lang
                        existing.color = color
                        existing.text = str(text)
                        existing.start_offset = start_offset
                        existing.end_offset = end_offset
                        existing.paragraph_index = paragraph_idx
                        existing.note = note_val
                        existing.username = owner
                else:
                    counts["skipped"] += 1
            else:
                if not existing.note and note_val:
                    counts["updated"] += 1
                    if apply:
                        existing.note = note_val
                else:
                    counts["skipped"] += 1

    if mode == "overwrite":
        for hl_id, row in existing_by_id.items():
            if hl_id in seen_ids:
                continue
            if not current_user.is_admin:
                if row.username != current_user.username or row.book_slug not in permitted_for_non_admin:
                    continue
            counts["deleted"] += 1
            if apply:
                db.delete(row)

    return counts


def _restore_progress(
    db: Session,
    items: list[dict[str, Any]],
    mode: str,
    current_user: User,
    db_users: dict[str, User],
    known_usernames: set[str],
    permitted_for_non_admin: set[str],
    prefer_snapshot_progress: bool,
    apply: bool,
    warnings: list[str],
) -> dict[str, int]:
    counts = {"created": 0, "updated": 0, "skipped": 0, "deleted": 0}
    user_id_to_name = {u.id: u.username for u in db_users.values() if u.id is not None}
    existing_rows = db.query(ReadingProgress).all()
    existing_map: dict[tuple[str, str], ReadingProgress] = {}
    for r in existing_rows:
        uname = user_id_to_name.get(r.user_id)
        if uname:
            existing_map[(uname, r.book_slug)] = r

    seen_keys: set[tuple[str, str]] = set()
    for raw in items:
        uname = str(raw.get("username") or current_user.username).strip()
        slug = _ensure_safe_slug_or_400(str(raw.get("bookSlug") or ""))
        if not current_user.is_admin:
            if uname != current_user.username or slug not in permitted_for_non_admin:
                counts["skipped"] += 1
                continue
        if uname not in known_usernames:
            counts["skipped"] += 1
            warnings.append(f"Skipped readingProgress for unknown user '{uname}' on '{slug}'.")
            continue

        page = int(raw.get("page") or 1)
        view_mode = str(raw.get("viewMode") or "en")
        last_read = int(raw.get("lastRead") or 0)
        key = (uname, slug)
        seen_keys.add(key)
        existing = existing_map.get(key)

        if not existing:
            counts["created"] += 1
            if apply:
                u_obj = db_users.get(uname)
                if u_obj and u_obj.id is not None:
                    db.add(
                        ReadingProgress(
                            user_id=u_obj.id,
                            book_slug=slug,
                            page=page,
                            view_mode=view_mode,
                            last_read=last_read,
                        )
                    )
        else:
            should_update = False
            if mode == "overwrite":
                should_update = (
                    existing.page != page
                    or existing.view_mode != view_mode
                    or (existing.last_read or 0) != last_read
                )
            else:
                if prefer_snapshot_progress or last_read > (existing.last_read or 0):
                    should_update = (
                        existing.page != page
                        or existing.view_mode != view_mode
                        or (existing.last_read or 0) != last_read
                    )
            if should_update:
                counts["updated"] += 1
                if apply:
                    existing.page = page
                    existing.view_mode = view_mode
                    existing.last_read = last_read
            else:
                counts["skipped"] += 1

    if mode == "overwrite":
        for key, row in existing_map.items():
            if key in seen_keys:
                continue
            if not current_user.is_admin and (
                key[0] != current_user.username or key[1] not in permitted_for_non_admin
            ):
                continue
            counts["deleted"] += 1
            if apply:
                db.delete(row)

    return counts


def _restore_states(
    db: Session,
    items: list[dict[str, Any]],
    mode: str,
    current_user: User,
    db_users: dict[str, User],
    known_usernames: set[str],
    permitted_for_non_admin: set[str],
    apply: bool,
    warnings: list[str],
) -> dict[str, int]:
    counts = {"created": 0, "updated": 0, "skipped": 0, "deleted": 0}
    user_id_to_name = {u.id: u.username for u in db_users.values() if u.id is not None}
    existing_map: dict[tuple[str, str], UserBookState] = {}
    for r in db.query(UserBookState).all():
        uname = user_id_to_name.get(r.user_id)
        if uname:
            existing_map[(uname, r.book_slug)] = r

    seen_keys: set[tuple[str, str]] = set()
    for raw in items:
        uname = str(raw.get("username") or current_user.username).strip()
        slug = _ensure_safe_slug_or_400(str(raw.get("bookSlug") or ""))
        if not current_user.is_admin:
            if uname != current_user.username or slug not in permitted_for_non_admin:
                counts["skipped"] += 1
                continue
        if uname not in known_usernames:
            counts["skipped"] += 1
            warnings.append(f"Skipped bookState for unknown user '{uname}' on '{slug}'.")
            continue

        is_finished = bool(raw.get("isFinished", False))
        on_shelf = bool(raw.get("onShelf", False))
        is_priority = bool(raw.get("isPriority", False))
        reader_font = str(raw.get("readerFont") or "")
        reader_theme = str(raw.get("readerTheme") or "")
        key = (uname, slug)
        seen_keys.add(key)
        existing = existing_map.get(key)

        if not existing:
            counts["created"] += 1
            if apply:
                u_obj = db_users.get(uname)
                if u_obj and u_obj.id is not None:
                    db.add(
                        UserBookState(
                            user_id=u_obj.id,
                            book_slug=slug,
                            is_finished=is_finished,
                            on_shelf=on_shelf,
                            is_priority=is_priority,
                            reader_font=reader_font,
                            reader_theme=reader_theme,
                        )
                    )
        else:
            if mode == "overwrite":
                changed = (
                    bool(existing.is_finished) != is_finished
                    or bool(existing.on_shelf) != on_shelf
                    or bool(existing.is_priority) != is_priority
                    or (existing.reader_font or "") != reader_font
                    or (existing.reader_theme or "") != reader_theme
                )
                if changed:
                    counts["updated"] += 1
                    if apply:
                        existing.is_finished = is_finished
                        existing.on_shelf = on_shelf
                        existing.is_priority = is_priority
                        existing.reader_font = reader_font
                        existing.reader_theme = reader_theme
                else:
                    counts["skipped"] += 1
            else:
                changed = False
                if reader_font and not existing.reader_font:
                    changed = True
                    if apply:
                        existing.reader_font = reader_font
                if reader_theme and not existing.reader_theme:
                    changed = True
                    if apply:
                        existing.reader_theme = reader_theme
                if changed:
                    counts["updated"] += 1
                else:
                    counts["skipped"] += 1

    if mode == "overwrite":
        for key, row in existing_map.items():
            if key in seen_keys:
                continue
            if not current_user.is_admin and (
                key[0] != current_user.username or key[1] not in permitted_for_non_admin
            ):
                continue
            counts["deleted"] += 1
            if apply:
                db.delete(row)

    return counts


def _restore_settings(
    db: Session,
    items: list[dict[str, Any]],
    mode: str,
    current_user: User,
    db_users: dict[str, User],
    known_usernames: set[str],
    restore_secrets: bool,
    includes_secrets: bool,
    apply: bool,
    warnings: list[str],
) -> dict[str, int]:
    counts = {"created": 0, "updated": 0, "skipped": 0, "deleted": 0}
    user_id_to_name = {u.id: u.username for u in db_users.values() if u.id is not None}
    existing_map: dict[str, UserSettings] = {}
    for r in db.query(UserSettings).all():
        uname = user_id_to_name.get(r.user_id)
        if uname:
            existing_map[uname] = r

    public_map = {
        "aiProvider": ("ai_provider", "openai"),
        "aiBaseUrl": ("ai_base_url", "https://api.openai.com/v1"),
        "aiModel": ("ai_model", "gpt-4o-mini"),
        "realtimeModel": ("realtime_model", "gpt-realtime-mini"),
        "realtimeVoice": ("realtime_voice", "alloy"),
        "audioProvider": ("audio_provider", "device"),
        "audioSource": ("audio_source", "auto"),
        "audioVoice": ("audio_voice", ""),
        "audioVoiceEn": ("audio_voice_en", ""),
        "audioVoiceVi": ("audio_voice_vi", ""),
        "ttsModel": ("tts_model", "edge-tts/en-US-SteffanNeural"),
        "speechSpeed": ("speech_speed", "1.0"),
        "layoutMode": ("layout_mode", "en-vi"),
        "vocaOrigin": ("voca_bridge_origin", ""),
    }
    secret_map = {
        "llmApiKey": "llm_api_key",
        "realtimeApiKey": "realtime_api_key",
        "azureApiKey": "azure_api_key",
        "elevenlabsApiKey": "elevenlabs_api_key",
        "vocaToken": "voca_bridge_token",
    }

    for raw in items:
        uname = str(raw.get("username") or current_user.username).strip()
        if not current_user.is_admin and uname != current_user.username:
            counts["skipped"] += 1
            continue
        if uname not in known_usernames:
            counts["skipped"] += 1
            warnings.append(f"Skipped userSettings for unknown user '{uname}'.")
            continue

        existing = existing_map.get(uname)
        snap_updated = int(raw.get("updatedAt") or 0)
        hide_finished = bool(raw.get("hideFinishedBooks", True))

        if not existing:
            counts["created"] += 1
            if apply:
                u_obj = db_users.get(uname)
                if u_obj and u_obj.id is not None:
                    row = UserSettings(user_id=u_obj.id, updated_at=snap_updated or int(time.time()))
                    for json_k, (attr, default_v) in public_map.items():
                        setattr(row, attr, str(raw.get(json_k) if raw.get(json_k) is not None else default_v))
                    row.hide_finished_books = hide_finished
                    if restore_secrets and includes_secrets:
                        for json_k, attr in secret_map.items():
                            val = raw.get(json_k)
                            if val is not None:
                                setattr(row, attr, str(val))
                    db.add(row)
        else:
            if mode == "merge" and snap_updated <= (existing.updated_at or 0):
                # Still fill missing secrets if requested and currently empty
                secret_filled = False
                if restore_secrets and includes_secrets:
                    for json_k, attr in secret_map.items():
                        val = str(raw.get(json_k) or "")
                        if val and not getattr(existing, attr):
                            secret_filled = True
                            if apply:
                                setattr(existing, attr, val)
                if secret_filled:
                    counts["updated"] += 1
                else:
                    counts["skipped"] += 1
                continue

            changed = False
            for json_k, (attr, default_v) in public_map.items():
                new_val = str(raw.get(json_k) if raw.get(json_k) is not None else default_v)
                if (getattr(existing, attr) or "") != new_val:
                    changed = True
                    if apply:
                        setattr(existing, attr, new_val)
            if bool(existing.hide_finished_books) != hide_finished:
                changed = True
                if apply:
                    existing.hide_finished_books = hide_finished
            if restore_secrets and includes_secrets:
                for json_k, attr in secret_map.items():
                    if json_k in raw and raw[json_k] is not None:
                        new_secret = str(raw[json_k])
                        if mode == "overwrite" or (new_secret and not getattr(existing, attr)):
                            if (getattr(existing, attr) or "") != new_secret:
                                changed = True
                                if apply:
                                    setattr(existing, attr, new_secret)
            if changed:
                counts["updated"] += 1
                if apply and snap_updated:
                    existing.updated_at = snap_updated
            else:
                counts["skipped"] += 1

    return counts


@router.post("/restore")
def restore_backup_snapshot(
    payload: dict[str, Any],
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    """Preview (dryRun=true) or execute server disaster recovery from a backup snapshot."""
    current_user = _require_real_session(current_user)
    snapshot = payload.get("snapshot")
    if not isinstance(snapshot, dict) or snapshot.get("version") != BACKUP_SCHEMA_VERSION:
        raise HTTPException(
            status_code=422,
            detail=f"Invalid backup snapshot (expected version == {BACKUP_SCHEMA_VERSION}).",
        )

    mode = str(payload.get("mode") or "merge").lower()
    if mode not in ("merge", "overwrite"):
        raise HTTPException(status_code=422, detail="mode must be 'merge' or 'overwrite'.")

    dry_run = bool(payload.get("dryRun", False))
    apply = not dry_run

    restore_users_flag = bool(payload.get("restoreUsers", True))
    restore_perms_flag = bool(payload.get("restorePermissions", True))
    restore_books_flag = bool(payload.get("restoreBooksMetadata", True))
    restore_apikeys_flag = bool(payload.get("restoreApiKeys", False))
    restore_highlights_flag = bool(payload.get("restoreHighlights", True))
    restore_progress_flag = bool(payload.get("restoreProgress", True))
    restore_states_flag = bool(payload.get("restoreStates", True))
    restore_settings_flag = bool(payload.get("restoreSettings", True))
    restore_secrets_flag = bool(payload.get("restoreSecrets", False))
    prefer_snapshot_progress = bool(payload.get("preferSnapshotProgress", False))

    if not current_user.is_admin:
        # Regular accounts can ONLY restore their own personal data, never users/permissions/global state.
        if (
            (restore_users_flag and snapshot.get("users"))
            or (restore_perms_flag and snapshot.get("permissions"))
            or (restore_apikeys_flag and snapshot.get("apiKeys"))
            or snapshot.get("scope") == "admin_full"
        ):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Admin privileges required to restore server users, permissions, or admin snapshots.",
            )
        restore_users_flag = False
        restore_perms_flag = False
        restore_books_flag = False
        restore_apikeys_flag = False

    includes_secrets = bool(snapshot.get("includesSecrets", False))
    warnings: list[str] = []
    if restore_secrets_flag and not includes_secrets:
        warnings.append("Snapshot was exported without secrets; API secrets were not modified.")

    permitted_for_non_admin = (
        set() if current_user.is_admin else _permitted_slugs_for_user(db, current_user)
    )

    if restore_users_flag and current_user.is_admin:
        users_summary, db_users, known_usernames = _restore_users(
            db,
            snapshot.get("users") or [],
            mode,
            current_user,
            apply,
            warnings,
        )
    else:
        users_summary = {"created": 0, "updated": 0, "skipped": len(snapshot.get("users") or []), "deleted": 0}
        db_users = {u.username: u for u in db.query(User).all()}
        known_usernames = set(db_users.keys())

    if restore_books_flag and current_user.is_admin:
        books_summary = _restore_books_metadata(db, snapshot.get("books") or [], mode, apply)
    else:
        books_summary = {"updated": 0, "unchanged": 0, "missingFiles": []}

    if restore_perms_flag and current_user.is_admin:
        perms_summary = _restore_permissions(
            db, snapshot.get("permissions") or [], mode, db_users, known_usernames, apply, warnings
        )
    else:
        perms_summary = {"created": 0, "unchanged": 0, "skipped": 0, "deleted": 0}

    if restore_apikeys_flag and current_user.is_admin:
        apikeys_summary = _restore_apikeys(
            db, snapshot.get("apiKeys") or [], mode, apply, includes_secrets and restore_secrets_flag
        )
    else:
        apikeys_summary = {"created": 0, "updated": 0, "skipped": 0, "deleted": 0}

    if restore_highlights_flag:
        highlights_summary = _restore_highlights(
            db,
            snapshot.get("highlights") or [],
            mode,
            current_user,
            permitted_for_non_admin,
            apply,
        )
    else:
        highlights_summary = {"created": 0, "updated": 0, "skipped": 0, "deleted": 0}

    if restore_progress_flag:
        progress_summary = _restore_progress(
            db,
            snapshot.get("readingProgress") or [],
            mode,
            current_user,
            db_users,
            known_usernames,
            permitted_for_non_admin,
            prefer_snapshot_progress,
            apply,
            warnings,
        )
    else:
        progress_summary = {"created": 0, "updated": 0, "skipped": 0, "deleted": 0}

    if restore_states_flag:
        states_summary = _restore_states(
            db,
            snapshot.get("userBookStates") or [],
            mode,
            current_user,
            db_users,
            known_usernames,
            permitted_for_non_admin,
            apply,
            warnings,
        )
    else:
        states_summary = {"created": 0, "updated": 0, "skipped": 0, "deleted": 0}

    if restore_settings_flag:
        settings_summary = _restore_settings(
            db,
            snapshot.get("userSettings") or [],
            mode,
            current_user,
            db_users,
            known_usernames,
            restore_secrets_flag,
            includes_secrets,
            apply,
            warnings,
        )
    else:
        settings_summary = {"created": 0, "updated": 0, "skipped": 0, "deleted": 0}

    if apply:
        db.commit()

    return {
        "ok": True,
        "dryRun": dry_run,
        "mode": mode,
        "scope": "admin_full" if current_user.is_admin else "personal",
        "summary": {
            "books": books_summary,
            "users": users_summary,
            "permissions": perms_summary,
            "apiKeys": apikeys_summary,
            "highlights": highlights_summary,
            "readingProgress": progress_summary,
            "userBookStates": states_summary,
            "userSettings": settings_summary,
        },
        "warnings": warnings,
    }
