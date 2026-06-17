import time
import secrets
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Response, Request, status
from pydantic import BaseModel
from sqlalchemy.orm import Session

from api.database import get_db, User, UserRefreshToken
from api.auth import (
    get_password_hash,
    verify_password,
    create_access_token,
    decode_access_token,
    get_current_user_or_apikey,
    require_admin,
    REFRESH_TOKEN_EXPIRE_SECONDS
)

router = APIRouter(prefix="/api/auth", tags=["authentication"])

class ChangePasswordRequest(BaseModel):
    current_password: str
    new_password: str

@router.post("/register")
def register(username: str, password: str, db: Session = Depends(get_db)):
    user_exists = db.query(User).filter(User.username == username).first()
    if user_exists:
        raise HTTPException(status_code=400, detail="Username already registered")
        
    new_user = User(
        username=username,
        password_hash=get_password_hash(password),
        is_admin=False
    )
    db.add(new_user)
    db.commit()
    db.refresh(new_user)
    return {"ok": True, "message": "User registered successfully"}

@router.post("/login")
def login(username: str, password: str, response: Response, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.username == username).first()
    if not user or not verify_password(password, user.password_hash):
        raise HTTPException(status_code=400, detail="Incorrect username or password")
        
    # Generate short-lived Access Token (15 mins) and long-lived Refresh Token (30 days)
    access_token = create_access_token(data={"sub": user.username})
    refresh_token = secrets.token_hex(32)
    
    # Save Refresh Token to database
    expires_at = int(time.time()) + REFRESH_TOKEN_EXPIRE_SECONDS
    new_refresh = UserRefreshToken(user_id=user.id, token=refresh_token, expires_at=expires_at)
    db.add(new_refresh)
    db.commit()
    
    # Store Access Token in Cookie (lax)
    response.set_cookie(
        key="jwt_token",
        value=access_token,
        httponly=True,
        max_age=900,
        samesite="lax"
    )
    
    # Store Refresh Token in Cookie (HttpOnly)
    response.set_cookie(
        key="refresh_token",
        value=refresh_token,
        httponly=True,
        max_age=REFRESH_TOKEN_EXPIRE_SECONDS,
        samesite="lax"
    )
    
    return {
        "access_token": access_token,
        "refresh_token": refresh_token,
        "token_type": "bearer",
        "username": user.username,
        "is_admin": user.is_admin
    }

@router.post("/refresh")
def refresh_token_endpoint(
    response: Response,
    request: Request,
    body_payload: Optional[dict] = None,
    db: Session = Depends(get_db)
):
    """Generates a new access token using a valid refresh token."""
    # 1. Read refresh token from cookie or payload body
    refresh_token = request.cookies.get("refresh_token")
    if not refresh_token and body_payload:
        refresh_token = body_payload.get("refresh_token")
        
    if not refresh_token:
        raise HTTPException(status_code=401, detail="Refresh token missing")
        
    # 2. Check database
    db_token = db.query(UserRefreshToken).filter(UserRefreshToken.token == refresh_token).first()
    if not db_token:
        raise HTTPException(status_code=401, detail="Invalid refresh token")
        
    if db_token.expires_at < int(time.time()):
        db.delete(db_token)
        db.commit()
        raise HTTPException(status_code=401, detail="Refresh token expired")
        
    # 3. Fetch User
    user = db.query(User).filter(User.id == db_token.user_id).first()
    if not user:
        raise HTTPException(status_code=401, detail="User not found")
        
    # 4. Generate new access token and optional new rotated refresh token
    new_access_token = create_access_token(data={"sub": user.username})
    new_refresh_token = secrets.token_hex(32)
    
    # Update refresh token in DB
    db_token.token = new_refresh_token
    db_token.expires_at = int(time.time()) + REFRESH_TOKEN_EXPIRE_SECONDS
    db.commit()
    
    # Set cookies
    response.set_cookie(
        key="jwt_token",
        value=new_access_token,
        httponly=True,
        max_age=900,
        samesite="lax"
    )
    response.set_cookie(
        key="refresh_token",
        value=new_refresh_token,
        httponly=True,
        max_age=REFRESH_TOKEN_EXPIRE_SECONDS,
        samesite="lax"
    )
    
    return {
        "access_token": new_access_token,
        "refresh_token": new_refresh_token,
        "token_type": "bearer"
    }

@router.post("/logout")
def logout(response: Response, request: Request, db: Session = Depends(get_db)):
    # Delete refresh token from DB if present
    refresh_token = request.cookies.get("refresh_token")
    if refresh_token:
        db.query(UserRefreshToken).filter(UserRefreshToken.token == refresh_token).delete()
        db.commit()
        
    response.delete_cookie("jwt_token")
    response.delete_cookie("refresh_token")
    return {"ok": True}

@router.get("/me")
def get_me(current_user: User = Depends(get_current_user_or_apikey)):
    return {
        "username": current_user.username,
        "is_admin": current_user.is_admin
    }

@router.put("/change-password")
def change_password(
    payload: ChangePasswordRequest,
    current_user: User = Depends(require_admin),
    db: Session = Depends(get_db)
):
    """Change password for the currently authenticated admin user."""
    # Re-fetch the user from DB to get the real record (require_admin may return virtual user for API keys)
    db_user = db.query(User).filter(User.username == current_user.username).first()
    if not db_user:
        raise HTTPException(status_code=404, detail="User not found in database")

    # Verify current password
    if not verify_password(payload.current_password, db_user.password_hash):
        raise HTTPException(status_code=400, detail="Mật khẩu hiện tại không đúng")

    # Validate new password
    if len(payload.new_password) < 4:
        raise HTTPException(status_code=400, detail="Mật khẩu mới phải có ít nhất 4 ký tự")

    # Update password
    db_user.password_hash = get_password_hash(payload.new_password)
    db.commit()

    return {"ok": True, "message": "Đổi mật khẩu thành công"}
