import os
import time
from typing import Optional, List
from sqlalchemy import create_engine, Column, Integer, String, Boolean, ForeignKey, Text, event
from sqlalchemy.orm import declarative_base, sessionmaker, relationship

from sqlalchemy.pool import NullPool

DATABASE_URL = os.environ.get("DATABASE_URL", "sqlite:///./bilingual_reader.db")

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
    last_read = Column(Integer, default=lambda: int(time.time()))

class UserRefreshToken(Base):
    __tablename__ = "user_refresh_tokens"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    token = Column(String, unique=True, index=True, nullable=False)
    expires_at = Column(Integer, nullable=False)

class UserSettings(Base):
    """Per-user server-held secrets & config. Secrets (LLM / realtime API keys,
    voca-bridge token) are entered on the FE but stored here server-side and NEVER
    returned to the browser — the /api/chat, /api/voca proxies attach them. Empty
    values fall back to the relevant env defaults (OPENAI_API_KEY, VOCA_BRIDGE_*)."""
    __tablename__ = "user_settings"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), unique=True, nullable=False)
    llm_api_key = Column(String, nullable=True, default="")
    realtime_api_key = Column(String, nullable=True, default="")
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

def init_db():
    Base.metadata.create_all(bind=engine)
    _migrate_voca_config_to_user_settings()

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
