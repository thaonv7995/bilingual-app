"""Per-user settings/secrets API.

Secrets (LLM API key, realtime API key, Voca API token) are entered on the FE but
persisted server-side in `user_settings` and NEVER returned to the browser.
GET reports only booleans (whether a secret is configured); PUT upserts using the
"key absent = keep, empty string = clear, non-empty = set" convention.

The JSON keys (vocaOrigin/vocaToken) and DB columns (voca_bridge_*) keep their
older names on purpose — renaming them would break clients / need a migration.
Voca 2.0 rules are enforced on write: the token must carry the mandated `voca_`
prefix and the origin is normalised (https forced, see `_normalize_origin`).
"""
import os
import time
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from api.auth import get_current_user_or_apikey
from api.database import User, UserSettings, get_db, get_or_create_user_settings
from api.routes.voca import _normalize_origin

router = APIRouter(prefix="/api/user", tags=["settings"])

ENV_OPENAI = os.environ.get("OPENAI_API_KEY", "")
ENV_VOCA_TOKEN = os.environ.get("VOCA_BRIDGE_TOKEN", "")

VOCA_TOKEN_PREFIX = "voca_"


def _public_view(s: UserSettings | None) -> dict:
    """Never expose raw secrets — only whether each one is set (env counts)."""
    llm = (s.llm_api_key if s else "") or ""
    realtime = (s.realtime_api_key if s else "") or ""
    voca_token = (s.voca_bridge_token if s else "") or ""
    return {
        "hasLlmKey": bool(llm or ENV_OPENAI),
        "hasRealtimeKey": bool(realtime or llm or ENV_OPENAI),
        "vocaOrigin": (s.voca_bridge_origin if s and s.voca_bridge_origin else ""),
        "hasVocaToken": bool(voca_token or ENV_VOCA_TOKEN),
    }


@router.get("/settings")
def get_user_settings(
    current_user: User = Depends(get_current_user_or_apikey), db: Session = Depends(get_db)
):
    s = db.query(UserSettings).filter(UserSettings.user_id == current_user.id).first()
    return _public_view(s)


@router.put("/settings")
def put_user_settings(
    payload: dict,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    s = get_or_create_user_settings(db, current_user.id)
    if payload.get("llmApiKey") is not None and "llmApiKey" in payload:
        s.llm_api_key = str(payload["llmApiKey"]).strip()
    if payload.get("realtimeApiKey") is not None and "realtimeApiKey" in payload:
        s.realtime_api_key = str(payload["realtimeApiKey"]).strip()
    if payload.get("vocaOrigin") is not None and "vocaOrigin" in payload:
        # Store the normalised form so the proxy never has to trust what it reads
        # back (and so the user sees the https:// it will actually be called on).
        try:
            s.voca_bridge_origin = _normalize_origin(str(payload["vocaOrigin"]))
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
    if payload.get("vocaToken") is not None and "vocaToken" in payload:
        token = str(payload["vocaToken"]).strip()
        # The 2.0 spec mandates the prefix; catching it here beats a 401 later.
        if token and not token.startswith(VOCA_TOKEN_PREFIX):
            raise HTTPException(
                status_code=400,
                detail=f"Voca API token phải bắt đầu bằng '{VOCA_TOKEN_PREFIX}'.",
            )
        s.voca_bridge_token = token
    s.updated_at = int(time.time())
    db.commit()
    db.refresh(s)
    return _public_view(s)
