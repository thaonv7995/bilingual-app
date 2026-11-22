import os
import time
from typing import Optional, List
from sqlalchemy import create_engine, Column, Integer, Float, String, Boolean, ForeignKey, Text, UniqueConstraint, event
from sqlalchemy.orm import declarative_base, sessionmaker, relationship

from sqlalchemy.pool import NullPool
from api.config import WORKSPACE_ROOT

_DEFAULT_DB_PATH = WORKSPACE_ROOT / "bilingual_reader.db"
DATABASE_URL = os.environ.get("DATABASE_URL", f"sqlite:///{_DEFAULT_DB_PATH}")

engine = create_engine(
    DATABASE_URL,
    connect_args={"check_same_thread": False, "timeout": 30} if DATABASE_URL.startswith("sqlite") else {},
    poolclass=NullPool if DATABASE_URL.startswith("sqlite") else None
)

@event.listens_for(engine, "connect")
def set_sqlite_pragma(dbapi_connection, connection_record):
    if DATABASE_URL.startswith("sqlite"):
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA journal_mode=WAL")
        cursor.execute("PRAGMA synchronous=NORMAL")
        cursor.close()

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)
    username = Column(String, unique=True, index=True, nullable=False)
    password_hash = Column(String, nullable=False)
    is_admin = Column(Boolean, default=False)

    permissions = relationship("UserPermission", back_populates="user", cascade="all, delete-orphan")

class Book(Base):
    __tablename__ = "books"

    id = Column(Integer, primary_key=True, index=True)
    slug = Column(String, unique=True, index=True, nullable=False)
    title = Column(String, nullable=False)
    author = Column(String, nullable=True)
    page_count = Column(Integer, default=0)
    cover_path = Column(String, nullable=True)
    is_published = Column(Boolean, default=True)
    format = Column(String, nullable=True, default="bkb", server_default="bkb")
    source_filename = Column(String, nullable=True, default="", server_default="")
    default_font = Column(String, nullable=True, default="default")
    default_theme = Column(String, nullable=True, default="default")
    # Import time (unix seconds). NULLABLE on purpose: rows that predate this
    # column keep NULL, and the shelf ordering falls back to `id` for them —
    # id is autoincrement, i.e. import order, so the fallback is exact. New
    # uploads get a real timestamp and therefore outrank every legacy row.
    created_at = Column(Integer, nullable=True, default=lambda: int(time.time()))

class UserPermission(Base):
    __tablename__ = "user_permissions"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    book_slug = Column(String, nullable=False)

    user = relationship("User", back_populates="permissions")

class APIKey(Base):
    __tablename__ = "api_keys"

    id = Column(Integer, primary_key=True, index=True)
    key_value = Column(String, unique=True, index=True, nullable=False)
    name = Column(String, nullable=False)
    is_active = Column(Boolean, default=True)
    created_at = Column(Integer, default=lambda: int(time.time()))

class Highlight(Base):
    __tablename__ = "highlights"

    id = Column(String, primary_key=True, index=True) # e.g. hl-xxxxx
    book_slug = Column(String, index=True, nullable=False)
    page = Column(Integer, nullable=False)
    lang = Column(String, nullable=False) # 'en' | 'vi'
    color = Column(String, nullable=False)
    text = Column(Text, nullable=False)
    start_offset = Column(Integer, default=0)
    end_offset = Column(Integer, default=0)
    paragraph_index = Column(Integer, default=0)
    anchor_json = Column(Text, nullable=True, default="")
    note = Column(Text, nullable=True, default="")
    created_at = Column(Integer, default=lambda: int(time.time()))
    username = Column(String, nullable=True) # highlight linked to user (optional)

class ReadingProgress(Base):
    __tablename__ = "reading_progress"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    book_slug = Column(String, index=True, nullable=False)
    page = Column(Integer, default=1)
    view_mode = Column(String, default="en")
    locator = Column(Text, nullable=True, default="")
    progression = Column(Float, nullable=True, default=None)
    last_read = Column(Integer, default=lambda: int(time.time()))

class UserBookState(Base):
    """Per-user library organisation, shared by the web and mobile clients."""
    __tablename__ = "user_book_states"
    __table_args__ = (UniqueConstraint("user_id", "book_slug", name="uq_user_book_state"),)

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    book_slug = Column(String, nullable=False, index=True)
    is_finished = Column(Boolean, nullable=False, default=False)
    on_shelf = Column(Boolean, nullable=False, default=False)
    is_priority = Column(Boolean, nullable=False, default=False)
    reader_font = Column(String, nullable=True, default="")
    reader_theme = Column(String, nullable=True, default="")

class UserRefreshToken(Base):
    __tablename__ = "user_refresh_tokens"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    token = Column(String, unique=True, index=True, nullable=False)
    expires_at = Column(Integer, nullable=False)

class UserSettings(Base):
    """Single source of truth for settings shared by web and mobile clients.

    Secrets are stored here but are never returned to clients. Public preferences
    are returned by `/api/user/settings`, so every signed-in device uses the same
    AI, audio, reader and library configuration.

    The `voca_bridge_*` column names predate the Voca 2.0 rename and are kept
    deliberately — renaming them buys nothing and costs a migration."""
    __tablename__ = "user_settings"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), unique=True, nullable=False)
    llm_api_key = Column(String, nullable=True, default="")
    realtime_api_key = Column(String, nullable=True, default="")

    # Companion / realtime AI preferences
    ai_provider = Column(String, nullable=True, default="openai")
    ai_base_url = Column(String, nullable=True, default="https://api.openai.com/v1")
    ai_model = Column(String, nullable=True, default="gpt-4o-mini")
    realtime_model = Column(String, nullable=True, default="gpt-realtime-mini")
    realtime_voice = Column(String, nullable=True, default="alloy")

    # Audiobook / TTS settings
    audio_provider = Column(String, nullable=True, default="device")
    audio_source = Column(String, nullable=True, default="auto")
    audio_voice = Column(String, nullable=True, default="")
    audio_voice_en = Column(String, nullable=True, default="")
    audio_voice_vi = Column(String, nullable=True, default="")
    tts_model = Column(String, nullable=True, default="edge-tts/en-US-SteffanNeural")
    azure_api_key = Column(String, nullable=True, default="")
    elevenlabs_api_key = Column(String, nullable=True, default="")
    speech_speed = Column(String, nullable=True, default="1.0")

    # Reader and library preferences
    layout_mode = Column(String, nullable=True, default="en-vi")
    hide_finished_books = Column(Boolean, nullable=False, default=True)

    voca_bridge_origin = Column(String, nullable=True, default="")
    voca_bridge_token = Column(String, nullable=True, default="")
    updated_at = Column(Integer, default=lambda: int(time.time()))

def get_or_create_user_settings(db, user_id: int) -> "UserSettings":
    row = db.query(UserSettings).filter(UserSettings.user_id == user_id).first()
    if not row:
        row = UserSettings(user_id=user_id)
        db.add(row)
        db.commit()
        db.refresh(row)
    return row

def _migrate_voca_config_to_user_settings():
    """One-time, idempotent copy of the older user_voca_config rows (added earlier
    in the v2 work) into the consolidated user_settings table."""
    from sqlalchemy import inspect, text
    if "user_voca_config" not in inspect(engine).get_table_names():
        return
    db = SessionLocal()
    try:
        rows = db.execute(
            text("SELECT user_id, bridge_origin, bridge_token FROM user_voca_config")
        ).fetchall()
        for user_id, origin, token in rows:
            if db.query(UserSettings).filter(UserSettings.user_id == user_id).first():
                continue
            db.add(UserSettings(
                user_id=user_id,
                voca_bridge_origin=origin or "",
                voca_bridge_token=token or "",
            ))
        db.commit()
    except Exception as e:  # pragma: no cover - defensive
        db.rollback()
        print(f"[Migration] user_voca_config -> user_settings skipped: {e}")
        return
    finally:
        db.close()
    # Copy succeeded — drop the now-redundant legacy table so it stops lingering.
    try:
        with engine.begin() as conn:
            conn.execute(text("DROP TABLE IF EXISTS user_voca_config"))
    except Exception as e:  # pragma: no cover - defensive
        print(f"[Migration] dropping user_voca_config skipped: {e}")

def _migrate_add_book_created_at():
    """Idempotent: add books.created_at when an older database lacks it.

    Existing rows are deliberately left NULL rather than back-filled with an
    invented timestamp — list_books falls back to `books.id` (autoincrement =
    import order) for them, which reproduces the true import order exactly,
    while any fabricated value would only look precise. Runs on every start;
    after the first one it inspects, sees the column and returns."""
    from sqlalchemy import inspect, text
    insp = inspect(engine)
    if "books" not in insp.get_table_names():
        return
    if any(col["name"] == "created_at" for col in insp.get_columns("books")):
        return
    try:
        with engine.begin() as conn:
            conn.execute(text("ALTER TABLE books ADD COLUMN created_at INTEGER"))
    except Exception as e:  # pragma: no cover - defensive
        print(f"[Migration] books.created_at skipped: {e}")

def _migrate_add_audio_settings():
    """Idempotent: add audio provider/voice/speed/key columns to user_settings if missing."""
    from sqlalchemy import inspect, text
    insp = inspect(engine)
    if "user_settings" not in insp.get_table_names():
        return
    existing_cols = {col["name"] for col in insp.get_columns("user_settings")}
    cols_to_add = [
        ("audio_provider", "TEXT DEFAULT 'device'"),
        ("audio_voice", "TEXT DEFAULT ''"),
        ("audio_voice_en", "TEXT DEFAULT ''"),
        ("audio_voice_vi", "TEXT DEFAULT ''"),
        ("azure_api_key", "TEXT DEFAULT ''"),
        ("elevenlabs_api_key", "TEXT DEFAULT ''"),
        ("speech_speed", "TEXT DEFAULT '1.0'"),
    ]
    with engine.begin() as conn:
        for col_name, col_type in cols_to_add:
            if col_name not in existing_cols:
                try:
                    conn.execute(text(f"ALTER TABLE user_settings ADD COLUMN {col_name} {col_type}"))
                except Exception as e:
                    print(f"[Migration] user_settings.{col_name} skipped: {e}")


def _migrate_add_unified_user_settings():
    """Idempotently add cross-platform preferences to older databases."""
    from sqlalchemy import inspect, text

    inspector = inspect(engine)
    if "user_settings" not in inspector.get_table_names():
        return

    existing_columns = {
        column["name"] for column in inspector.get_columns("user_settings")
    }
    columns_to_add = [
        ("ai_provider", "TEXT DEFAULT 'openai'"),
        ("ai_base_url", "TEXT DEFAULT 'https://api.openai.com/v1'"),
        ("ai_model", "TEXT DEFAULT 'gpt-4o-mini'"),
        ("realtime_model", "TEXT DEFAULT 'gpt-realtime-mini'"),
        ("realtime_voice", "TEXT DEFAULT 'alloy'"),
        ("audio_source", "TEXT DEFAULT 'auto'"),
        ("tts_model", "TEXT DEFAULT 'edge-tts/en-US-SteffanNeural'"),
        ("layout_mode", "TEXT DEFAULT 'en-vi'"),
        ("hide_finished_books", "BOOLEAN NOT NULL DEFAULT 1"),
    ]

    with engine.begin() as connection:
        for column_name, column_definition in columns_to_add:
            if column_name in existing_columns:
                continue
            try:
                connection.execute(
                    text(
                        f"ALTER TABLE user_settings "
                        f"ADD COLUMN {column_name} {column_definition}"
                    )
                )
            except Exception as error:
                print(
                    f"[Migration] user_settings.{column_name} skipped: {error}"
                )

def _migrate_add_book_appearance_columns():
    """Idempotently add per-book default font/theme on books and per-user overrides on user_book_states."""
    from sqlalchemy import inspect, text

    inspector = inspect(engine)
    table_names = set(inspector.get_table_names())

    with engine.begin() as connection:
        if "books" in table_names:
            book_cols = {col["name"] for col in inspector.get_columns("books")}
            for col_name, col_def in [
                ("default_font", "TEXT DEFAULT 'default'"),
                ("default_theme", "TEXT DEFAULT 'default'"),
            ]:
                if col_name not in book_cols:
                    try:
                        connection.execute(text(f"ALTER TABLE books ADD COLUMN {col_name} {col_def}"))
                    except Exception as error:
                        print(f"[Migration] books.{col_name} skipped: {error}")

        if "user_book_states" in table_names:
            state_cols = {col["name"] for col in inspector.get_columns("user_book_states")}
            for col_name, col_def in [
                ("reader_font", "TEXT DEFAULT ''"),
                ("reader_theme", "TEXT DEFAULT ''"),
            ]:
                if col_name not in state_cols:
                    try:
                        connection.execute(
                            text(f"ALTER TABLE user_book_states ADD COLUMN {col_name} {col_def}")
                        )
                    except Exception as error:
                        print(f"[Migration] user_book_states.{col_name} skipped: {error}")


def _migrate_add_multiformat_columns():
    """Idempotently add multi-format book (pdf/epub), highlight anchor, and progress locator columns."""
    from sqlalchemy import inspect, text

    inspector = inspect(engine)
    table_names = set(inspector.get_table_names())

    with engine.begin() as connection:
        if "books" in table_names:
            cols = {col["name"] for col in inspector.get_columns("books")}
            for col_name, col_def in [
                ("format", "TEXT NOT NULL DEFAULT 'bkb'"),
                ("source_filename", "TEXT DEFAULT ''"),
            ]:
                if col_name not in cols:
                    try:
                        connection.execute(text(f"ALTER TABLE books ADD COLUMN {col_name} {col_def}"))
                    except Exception as error:
                        print(f"[Migration] books.{col_name} skipped: {error}")

        if "highlights" in table_names:
            cols = {col["name"] for col in inspector.get_columns("highlights")}
            if "anchor_json" not in cols:
                try:
                    connection.execute(text("ALTER TABLE highlights ADD COLUMN anchor_json TEXT DEFAULT ''"))
                except Exception as error:
                    print(f"[Migration] highlights.anchor_json skipped: {error}")

        if "reading_progress" in table_names:
            cols = {col["name"] for col in inspector.get_columns("reading_progress")}
            for col_name, col_def in [
                ("locator", "TEXT DEFAULT ''"),
                ("progression", "REAL"),
            ]:
                if col_name not in cols:
                    try:
                        connection.execute(
                            text(f"ALTER TABLE reading_progress ADD COLUMN {col_name} {col_def}")
                        )
                    except Exception as error:
                        print(f"[Migration] reading_progress.{col_name} skipped: {error}")


def init_db():
    Base.metadata.create_all(bind=engine)
    _migrate_voca_config_to_user_settings()
    _migrate_add_book_created_at()
    _migrate_add_audio_settings()
    _migrate_add_unified_user_settings()
    _migrate_add_book_appearance_columns()
    _migrate_add_multiformat_columns()

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
