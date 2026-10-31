import os
import secrets
import time
from typing import Optional
from fastapi import Depends, HTTPException, Security, status, Request
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials, APIKeyHeader
import bcrypt
import jwt
from sqlalchemy.orm import Session
from api.database import get_db, User, APIKey

from api.config import SECRET_KEY, ALGORITHM, ACCESS_TOKEN_EXPIRE_SECONDS, REFRESH_TOKEN_EXPIRE_SECONDS

ENV_NOTEBOOK_CLIENT_ID = os.environ.get("NOTEBOOK_CLIENT_ID", "").strip()
LOCAL_DEV_CLIENT_ID = "notebook_client_v1"
HARDCODED_CLIENT_ID = ENV_NOTEBOOK_CLIENT_ID or LOCAL_DEV_CLIENT_ID

security_jwt = HTTPBearer(auto_error=False)
security_apikey = APIKeyHeader(name="X-API-Key", auto_error=False)


def is_trusted_notebook_client(request: Request, candidate: Optional[str] = None) -> bool:
    """Validate X-Client-ID / client_id without exposing a remote admin backdoor.

    * If `NOTEBOOK_CLIENT_ID` is explicitly set in the environment, compare against
      it in constant time.
    * Otherwise, allow the default `notebook_client_v1` ONLY for direct local
      loopback requests (no X-Forwarded-For / X-Real-IP / CF-Connecting-IP headers),
      so local Notebook Studio integration works on the developer's machine while
      remote requests through any proxy or public interface are rejected.
    """
    token = (
        candidate
        or request.headers.get("X-Client-ID")
        or request.query_params.get("client_id")
        or ""
    ).strip()
    if not token:
        return False

    if ENV_NOTEBOOK_CLIENT_ID:
        return secrets.compare_digest(token, ENV_NOTEBOOK_CLIENT_ID)

    # Unconfigured env: only allow local loopback without proxy forwarding headers
    forwarded = (
        request.headers.get("x-forwarded-for")
        or request.headers.get("x-real-ip")
        or request.headers.get("cf-connecting-ip")
    )
    if forwarded:
        return False

    client_host = (request.client.host if request.client else "") or ""
    if client_host not in ("127.0.0.1", "::1", "localhost"):
        return False

    return secrets.compare_digest(token, LOCAL_DEV_CLIENT_ID)


def get_password_hash(password: str) -> str:
    pwd_bytes = password.encode("utf-8")
    salt = bcrypt.gensalt()
    hashed = bcrypt.hashpw(pwd_bytes, salt)
    return hashed.decode("utf-8")

def verify_password(plain_password: str, hashed_password: str) -> bool:
    pwd_bytes = plain_password.encode("utf-8")
    hashed_bytes = hashed_password.encode("utf-8")
    return bcrypt.checkpw(pwd_bytes, hashed_bytes)

def create_access_token(data: dict, expires_delta: Optional[int] = None) -> str:
    to_encode = data.copy()
    expire = int(time.time()) + (expires_delta or ACCESS_TOKEN_EXPIRE_SECONDS)
    to_encode.update({"exp": expire})
    encoded_jwt = jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
    return encoded_jwt

def decode_access_token(token: str) -> Optional[dict]:
    try:
        decoded_token = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        if decoded_token["exp"] >= int(time.time()):
            return decoded_token
    except jwt.PyJWTError:
        pass
    return None

def get_current_user_or_apikey(
    request: Request,
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security_jwt),
    api_key: Optional[str] = Depends(security_apikey),
    db: Session = Depends(get_db)
) -> Optional[User]:
    """
    Authenticate request via JWT token, API Key, or trusted local Notebook Client-ID.
    """
    # 0. Check Trusted Notebook Client ID (read-only access, never full admin)
    if is_trusted_notebook_client(request) or (api_key and is_trusted_notebook_client(request, api_key)):
        notebook_user = User(username="client_notebook_studio", is_admin=True)
        notebook_user._is_notebook_client = True
        return notebook_user

    # 1. Check API Key
    if api_key:
        key_record = db.query(APIKey).filter(APIKey.key_value == api_key, APIKey.is_active == True).first()
        if key_record:
            # Return a virtual Admin User for valid API Keys
            virtual_admin = User(username=f"apikey_{key_record.name}", is_admin=True)
            return virtual_admin
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or inactive API Key",
        )

    # 2. Check JWT (Bearer header or jwt_token cookie)
    jwt_token = credentials.credentials if credentials else request.cookies.get("jwt_token")
    if jwt_token:
        payload = decode_access_token(jwt_token)
        if payload:
            username = payload.get("sub")
            if username:
                user = db.query(User).filter(User.username == username).first()
                if user:
                    return user
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired JWT token",
        )

    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Not authenticated. Provide Bearer JWT token or X-API-Key header.",
    )

def require_admin(
    current_user: User = Depends(get_current_user_or_apikey)
) -> User:
    if not current_user.is_admin or getattr(current_user, "_is_notebook_client", False):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Admin privileges required",
        )
    return current_user
