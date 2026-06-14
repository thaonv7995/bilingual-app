import secrets
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from api.database import get_db, User, APIKey, UserPermission
from api.auth import require_admin

router = APIRouter(prefix="/api/admin", tags=["admin"])

@router.get("/users")
def admin_list_users(admin: User = Depends(require_admin), db: Session = Depends(get_db)):
    users = db.query(User).all()
    return [{"id": u.id, "username": u.username, "is_admin": u.is_admin} for u in users]

@router.get("/apikeys")
def admin_list_apikeys(admin: User = Depends(require_admin), db: Session = Depends(get_db)):
    keys = db.query(APIKey).all()
    return [{"id": k.id, "name": k.name, "key_value": k.key_value, "is_active": k.is_active, "created_at": k.created_at} for k in keys]

@router.post("/apikeys")
def admin_create_apikey(name: str, admin: User = Depends(require_admin), db: Session = Depends(get_db)):
    key_token = f"br_live_{secrets.token_hex(16)}"
    new_key = APIKey(key_value=key_token, name=name, is_active=True)
    db.add(new_key)
    db.commit()
    db.refresh(new_key)
    return {"ok": True, "name": name, "key_value": key_token}

@router.delete("/apikeys/{key_id}")
def admin_revoke_apikey(key_id: int, admin: User = Depends(require_admin), db: Session = Depends(get_db)):
    key = db.query(APIKey).filter(APIKey.id == key_id).first()
    if not key:
        raise HTTPException(status_code=404, detail="API Key not found")
    key.is_active = False
    db.commit()
    return {"ok": True, "message": "API Key revoked"}

@router.get("/permissions")
def admin_list_permissions(admin: User = Depends(require_admin), db: Session = Depends(get_db)):
    perms = db.query(UserPermission).all()
    return [{"id": p.id, "user_id": p.user_id, "book_slug": p.book_slug} for p in perms]

@router.post("/permissions")
def admin_grant_permission(user_id: int, book_slug: str, admin: User = Depends(require_admin), db: Session = Depends(get_db)):
    # Check if exists
    exists = db.query(UserPermission).filter(
        UserPermission.user_id == user_id,
        UserPermission.book_slug == book_slug
    ).first()
    if exists:
        return {"ok": True, "message": "Permission already exists"}
        
    perm = UserPermission(user_id=user_id, book_slug=book_slug)
    db.add(perm)
    db.commit()
    return {"ok": True, "message": "Permission granted successfully"}

@router.delete("/permissions/{perm_id}")
def admin_revoke_permission(perm_id: int, admin: User = Depends(require_admin), db: Session = Depends(get_db)):
    perm = db.query(UserPermission).filter(UserPermission.id == perm_id).first()
    if not perm:
        raise HTTPException(status_code=404, detail="Permission not found")
    db.delete(perm)
    db.commit()
    return {"ok": True, "message": "Permission revoked"}
