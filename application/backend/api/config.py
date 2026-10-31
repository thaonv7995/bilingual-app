import os
import secrets
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


def _resolve_jwt_secret() -> str:
    env_secret = os.environ.get("JWT_SECRET_KEY", "").strip()
    if env_secret:
        return env_secret
    secret_file = APPLICATION_DIR / "data" / ".jwt_secret"
    try:
        if secret_file.is_file():
            stored = secret_file.read_text(encoding="utf-8").strip()
            if len(stored) >= 32:
                return stored
        secret_file.parent.mkdir(parents=True, exist_ok=True)
        generated = secrets.token_hex(32)
        secret_file.write_text(generated, encoding="utf-8")
        try:
            secret_file.chmod(0o600)
        except OSError:
            pass
        return generated
    except OSError:
        return secrets.token_hex(32)


# Security & JWT settings
SECRET_KEY = _resolve_jwt_secret()
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_SECONDS = 15 * 60  # 15 minutes
REFRESH_TOKEN_EXPIRE_SECONDS = 30 * 24 * 60 * 60  # 30 days

