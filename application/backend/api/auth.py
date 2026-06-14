import os
import time
from typing import Optional
from fastapi import Depends, HTTPException, Security, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials, APIKeyHeader
import bcrypt
import jwt
from sqlalchemy.orm import Session
from api.database import get_db, User, APIKey

from api.config import SECRET_KEY, ALGORITHM, ACCESS_TOKEN_EXPIRE_SECONDS, REFRESH_TOKEN_EXPIRE_SECONDS


security_jwt = HTTPBearer(auto_error=False)
security_apikey = APIKeyHeader(name="X-API-Key", auto_error=False)

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
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security_jwt),
    api_key: Optional[str] = Depends(security_apikey),
    db: Session = Depends(get_db)
) -> Optional[User]:
    """
    Authenticate request via JWT token or API Key.
    Returns the authenticated User object (or a dummy admin user for API Keys).
    """
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

    # 2. Check JWT
    if credentials:
        payload = decode_access_token(credentials.credentials)
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
    if not current_user.is_admin:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Admin privileges required",
        )
    return current_user
