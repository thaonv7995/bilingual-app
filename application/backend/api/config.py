import os
from pathlib import Path

# Paths
API_DIR = Path(__file__).resolve().parent
BACKEND_DIR = API_DIR.parent
APPLICATION_DIR = BACKEND_DIR.parent
WORKSPACE_ROOT = APPLICATION_DIR.parent
BOOKS_DIR = WORKSPACE_ROOT / "books"
# Legacy v1 frontend. Only served when FRONTEND_V2_DIST is unset (see main.py);
# production runs v2. Kept under application/legacy/ pending removal.
WEB_APP_DIR = APPLICATION_DIR / "legacy" / "web-app-v1"

# Security & JWT settings
SECRET_KEY = os.environ.get("JWT_SECRET_KEY", "bilingual_reader_super_secret_key")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_SECONDS = 15 * 60  # 15 minutes
REFRESH_TOKEN_EXPIRE_SECONDS = 30 * 24 * 60 * 60  # 30 days
