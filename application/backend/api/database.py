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

def init_db():
    Base.metadata.create_all(bind=engine)

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
