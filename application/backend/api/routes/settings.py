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
    """Return shared public preferences plus secret availability flags."""
    llm = (s.llm_api_key if s else "") or ""
    realtime = (s.realtime_api_key if s else "") or ""
    voca_token = (s.voca_bridge_token if s else "") or ""
    voice_en = (s.audio_voice_en if s and s.audio_voice_en else "") or (s.audio_voice if s and s.audio_voice else "")
    voice_vi = (s.audio_voice_vi if s and s.audio_voice_vi else "")
    return {
        "provider": (s.ai_provider if s and s.ai_provider else "openai"),
        "baseURL": (
            s.ai_base_url
            if s and s.ai_base_url
            else "https://api.openai.com/v1"
        ),
        "model": (s.ai_model if s and s.ai_model else "gpt-4o-mini"),
        "realtimeModel": (
            s.realtime_model
            if s and s.realtime_model
            else "gpt-realtime-mini"
        ),
        "realtimeVoice": (
            s.realtime_voice if s and s.realtime_voice else "alloy"
        ),
        "hasLlmKey": bool(llm or ENV_OPENAI),
        "hasRealtimeKey": bool(realtime or llm or ENV_OPENAI),
        "audioProvider": (s.audio_provider if s and s.audio_provider else "device"),
        "audioSource": (s.audio_source if s and s.audio_source else "auto"),
        "audioVoice": (s.audio_voice if s and s.audio_voice else ""),
        "audioVoiceEn": voice_en,
        "audioVoiceVi": voice_vi,
        "ttsModel": (
            s.tts_model
            if s and s.tts_model
            else "edge-tts/en-US-SteffanNeural"
        ),
        "speechSpeed": (s.speech_speed if s and s.speech_speed else "1.0"),
        "hasAzureKey": bool((s.azure_api_key if s else "") or ""),
        "hasElevenLabsKey": bool((s.elevenlabs_api_key if s else "") or ""),
        "layoutMode": (s.layout_mode if s and s.layout_mode else "en-vi"),
        "hideFinishedBooks": (
            s.hide_finished_books
            if s and s.hide_finished_books is not None
            else True
        ),
        "vocaOrigin": (s.voca_bridge_origin if s and s.voca_bridge_origin else ""),
        "hasVocaToken": bool(voca_token or ENV_VOCA_TOKEN),
    }


@router.get("/settings")
def get_user_settings(
    current_user: User = Depends(get_current_user_or_apikey), db: Session = Depends(get_db)
):
    if getattr(current_user, "id", None) is None:
        return _public_view(None)
    s = db.query(UserSettings).filter(UserSettings.user_id == current_user.id).first()
    return _public_view(s)


@router.put("/settings")
def put_user_settings(
    payload: dict,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    if getattr(current_user, "id", None) is None:
        raise HTTPException(status_code=400, detail="API keys cannot store personal user settings")
    s = get_or_create_user_settings(db, current_user.id)

    public_fields = {
        "provider": ("ai_provider", "openai"),
        "baseURL": ("ai_base_url", "https://api.openai.com/v1"),
        "model": ("ai_model", "gpt-4o-mini"),
        "realtimeModel": ("realtime_model", "gpt-realtime-mini"),
        "realtimeVoice": ("realtime_voice", "alloy"),
        "audioProvider": ("audio_provider", "device"),
        "audioSource": ("audio_source", "auto"),
        "audioVoice": ("audio_voice", ""),
        "audioVoiceEn": ("audio_voice_en", ""),
        "audioVoiceVi": ("audio_voice_vi", ""),
        "ttsModel": ("tts_model", "edge-tts/en-US-SteffanNeural"),
        "speechSpeed": ("speech_speed", "1.0"),
        "layoutMode": ("layout_mode", "en-vi"),
    }
    for payload_key, (attribute_name, default_value) in public_fields.items():
        if payload_key in payload and payload[payload_key] is not None:
            value = str(payload[payload_key]).strip()
            setattr(s, attribute_name, value or default_value)

    if "hideFinishedBooks" in payload and payload["hideFinishedBooks"] is not None:
        if not isinstance(payload["hideFinishedBooks"], bool):
            raise HTTPException(
                status_code=422,
                detail="hideFinishedBooks must be a boolean",
            )
        s.hide_finished_books = payload["hideFinishedBooks"]

    if payload.get("llmApiKey") is not None and "llmApiKey" in payload:
        s.llm_api_key = str(payload["llmApiKey"]).strip()
    if payload.get("realtimeApiKey") is not None and "realtimeApiKey" in payload:
        s.realtime_api_key = str(payload["realtimeApiKey"]).strip()

    if payload.get("azureApiKey") is not None and "azureApiKey" in payload:
        s.azure_api_key = str(payload["azureApiKey"]).strip()

    if payload.get("elevenLabsApiKey") is not None and "elevenLabsApiKey" in payload:
        s.elevenlabs_api_key = str(payload["elevenLabsApiKey"]).strip()

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
