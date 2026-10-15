import os
import re
import hashlib
import json
from pathlib import Path
from typing import Optional
from pydantic import BaseModel
import httpx
from fastapi import APIRouter, Request, HTTPException, Depends, Query
from fastapi.responses import Response
from sqlalchemy.orm import Session

from api.auth import get_current_user_or_apikey
from api.database import User, UserSettings, get_db
from api.config import APPLICATION_DIR

router = APIRouter(prefix="/api/audio", tags=["audio"])

ENV_OPENAI = os.environ.get("OPENAI_API_KEY", "")
ENV_AZURE_KEY = os.environ.get("AZURE_SPEECH_KEY", "")
ENV_AZURE_REGION = os.environ.get("AZURE_SPEECH_REGION", "eastus")
ENV_ELEVENLABS_KEY = os.environ.get("ELEVENLABS_API_KEY", "")

CACHE_DIR = APPLICATION_DIR / "data" / "audio_cache"
CACHE_DIR.mkdir(parents=True, exist_ok=True)


class SynthesizeRequest(BaseModel):
    text: str
    provider: Optional[str] = None
    voice: Optional[str] = None
    speed: Optional[str] = None
    lang: Optional[str] = "en"


def _user_settings(db: Session, user: User) -> Optional[UserSettings]:
    return db.query(UserSettings).filter(UserSettings.user_id == user.id).first()


def _get_cache_path(provider: str, voice: str, speed: str, text: str) -> Path:
    normalized = f"{provider}:{voice}:{speed}:{text.strip()}"
    digest = hashlib.sha256(normalized.encode("utf-8")).hexdigest()
    return CACHE_DIR / f"{digest}.mp3"


@router.get("/voices")
def get_supported_voices(provider: Optional[str] = Query(None)):
    """Returns curated voice presets for each supported provider."""
    voices = {
        "openai": [
            {"id": "alloy", "name": "Alloy (Neutral, balanced)", "lang": "en"},
            {"id": "echo", "name": "Echo (Warm, rounded)", "lang": "en"},
            {"id": "fable", "name": "Fable (British accent)", "lang": "en"},
            {"id": "onyx", "name": "Onyx (Deep, authoritative)", "lang": "en"},
            {"id": "nova", "name": "Nova (Energetic, friendly)", "lang": "en"},
            {"id": "shimmer", "name": "Shimmer (Expressive, clear)", "lang": "en"},
        ],
        "azure": [
            {"id": "en-US-JennyNeural", "name": "Jenny (US English, natural)", "lang": "en-US"},
            {"id": "en-US-GuyNeural", "name": "Guy (US English, male)", "lang": "en-US"},
            {"id": "en-US-AriaNeural", "name": "Aria (US English, expressive)", "lang": "en-US"},
            {"id": "en-GB-SoniaNeural", "name": "Sonia (UK English, female)", "lang": "en-GB"},
            {"id": "vi-VN-HoaiMyNeural", "name": "Hoài My (Vietnamese, female)", "lang": "vi-VN"},
            {"id": "vi-VN-NamMinhNeural", "name": "Nam Minh (Vietnamese, male)", "lang": "vi-VN"},
        ],
        "elevenlabs": [
            {"id": "21m00Tcm4TlvDq8ikWAM", "name": "Rachel (Calm, narrative)", "lang": "en"},
            {"id": "AZnzlk1XvdvUeBnXmlld", "name": "Domi (Strong, confident)", "lang": "en"},
            {"id": "EXAVITQu4vr4xnSDxMaL", "name": "Bella (Soft, gentle)", "lang": "en"},
            {"id": "ErXwobaYiN019PkySvjV", "name": "Antoni (Warm, male)", "lang": "en"},
            {"id": "MF3mGyEYCl7XYWbV9V6O", "name": "Elli (Emotional, young)", "lang": "en"},
            {"id": "TxGEqnHWrfWFTfGW9XjX", "name": "Josh (Natural, conversational)", "lang": "en"},
        ],
        "device": [
            {"id": "device-default", "name": "Device System Voice", "lang": "auto"},
        ],
    }
    if provider and provider in voices:
        return {provider: voices[provider]}
    return voices


@router.post("/synthesize")
async def synthesize_speech(
    req: SynthesizeRequest,
    current_user: User = Depends(get_current_user_or_apikey),
    db: Session = Depends(get_db),
):
    """Synthesizes text to speech using configured provider, caching results."""
    text = (req.text or "").strip()
    if not text:
        raise HTTPException(status_code=400, detail="Text cannot be empty")

    s = _user_settings(db, current_user)

    # Provider resolution
    provider = (req.provider or (s.audio_provider if s and s.audio_provider else "") or "openai").lower().strip()
    speed = req.speed or (s.speech_speed if s and s.speech_speed else "1.0")
    voice = req.voice or (s.audio_voice if s and s.audio_voice else "")

    if provider == "device":
        raise HTTPException(
            status_code=400,
            detail="Provider 'device' is client-local and does not require server synthesis.",
        )

    # Check cache
    cache_path = _get_cache_path(provider, voice, speed, text)
    if cache_path.is_file() and cache_path.stat().st_size > 0:
        content = cache_path.read_bytes()
        return Response(
            content=content,
            media_type="audio/mpeg",
            headers={"X-Audio-Cache": "HIT", "Cache-Control": "public, max-age=86400"},
        )

    audio_bytes: bytes

    if provider == "openai":
        api_key = (
            ((s.llm_api_key or "").strip() if s else "")
            or ((s.realtime_api_key or "").strip() if s else "")
            or ENV_OPENAI
        )
        if not api_key:
            raise HTTPException(
                status_code=400,
                detail="OpenAI API key is required. Please configure it in Settings.",
            )

        try:
            speed_val = max(0.25, min(4.0, float(speed)))
        except (ValueError, TypeError):
            speed_val = 1.0

        chosen_voice = voice if voice in ["alloy", "echo", "fable", "onyx", "nova", "shimmer"] else "alloy"

        async with httpx.AsyncClient(timeout=60.0) as client:
            try:
                resp = await client.post(
                    "https://api.openai.com/v1/audio/speech",
                    headers={
                        "Authorization": f"Bearer {api_key}",
                        "Content-Type": "application/json",
                    },
                    json={
                        "model": "tts-1",
                        "input": text,
                        "voice": chosen_voice,
                        "speed": speed_val,
                    },
                )
            except httpx.RequestError as exc:
                raise HTTPException(status_code=502, detail=f"Failed to connect to OpenAI TTS: {exc}") from exc

        if resp.status_code >= 400:
            err_msg = resp.text[:400]
            raise HTTPException(
                status_code=resp.status_code if resp.status_code < 500 else 502,
                detail=f"OpenAI TTS error ({resp.status_code}): {err_msg}",
            )
        audio_bytes = resp.content

    elif provider == "azure":
        raw_key = ((s.azure_api_key or "").strip() if s else "") or ENV_AZURE_KEY
        if not raw_key:
            raise HTTPException(
                status_code=400,
                detail="Azure Speech Key is required. Please configure it in Settings.",
            )

        # Allow key formatted as 'key@region' or 'key:region'
        region = ENV_AZURE_REGION
        if "@" in raw_key:
            api_key, region = raw_key.split("@", 1)
        elif ":" in raw_key and not raw_key.startswith("http"):
            api_key, region = raw_key.split(":", 1)
        else:
            api_key = raw_key

        api_key = api_key.strip()
        region = region.strip() or "eastus"

        chosen_voice = voice if voice else ("vi-VN-HoaiMyNeural" if req.lang == "vi" else "en-US-JennyNeural")
        lang_tag = "vi-VN" if "vi" in chosen_voice.lower() else "en-US"

        try:
            spd_f = float(speed)
            rate_percent = int((spd_f - 1.0) * 100)
            rate_str = f"{rate_percent:+d}%"
        except (ValueError, TypeError):
            rate_str = "+0%"

        # Clean xml special characters
        escaped_text = (
            text.replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace('"', "&quot;")
            .replace("'", "&apos;")
        )

        ssml = (
            f"<speak version='1.0' xml:lang='{lang_tag}'>"
            f"<voice xml:lang='{lang_tag}' name='{chosen_voice}'>"
            f"<prosody rate='{rate_str}'>{escaped_text}</prosody>"
            f"</voice></speak>"
        )

        target_url = f"https://{region}.tts.speech.microsoft.com/cognitiveservices/v1"
        headers = {
            "Ocp-Apim-Subscription-Key": api_key,
            "Content-Type": "application/ssml+xml",
            "X-Microsoft-OutputFormat": "audio-16khz-128kbitrate-mono-mp3",
            "User-Agent": "BilingualReader",
        }

        async with httpx.AsyncClient(timeout=60.0) as client:
            try:
                resp = await client.post(target_url, headers=headers, content=ssml.encode("utf-8"))
            except httpx.RequestError as exc:
                raise HTTPException(status_code=502, detail=f"Failed to connect to Azure Speech: {exc}") from exc

        if resp.status_code >= 400:
            err_msg = resp.text[:400]
            raise HTTPException(
                status_code=resp.status_code if resp.status_code < 500 else 502,
                detail=f"Azure Speech error ({resp.status_code}): {err_msg}",
            )
        audio_bytes = resp.content

    elif provider == "elevenlabs":
        api_key = ((s.elevenlabs_api_key or "").strip() if s else "") or ENV_ELEVENLABS_KEY
        if not api_key:
            raise HTTPException(
                status_code=400,
                detail="ElevenLabs API Key is required. Please configure it in Settings.",
            )

        voice_id = voice if voice else "21m00Tcm4TlvDq8ikWAM"  # Rachel
        target_url = f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}"

        async with httpx.AsyncClient(timeout=60.0) as client:
            try:
                resp = await client.post(
                    target_url,
                    headers={
                        "xi-api-key": api_key,
                        "Content-Type": "application/json",
                        "Accept": "audio/mpeg",
                    },
                    json={
                        "text": text,
                        "model_id": "eleven_multilingual_v2",
                    },
                )
            except httpx.RequestError as exc:
                raise HTTPException(status_code=502, detail=f"Failed to connect to ElevenLabs: {exc}") from exc

        if resp.status_code >= 400:
            err_msg = resp.text[:400]
            raise HTTPException(
                status_code=resp.status_code if resp.status_code < 500 else 502,
                detail=f"ElevenLabs error ({resp.status_code}): {err_msg}",
            )
        audio_bytes = resp.content

    else:
        raise HTTPException(status_code=400, detail=f"Unsupported audio provider '{provider}'")

    # Save to cache
    try:
        cache_path.write_bytes(audio_bytes)
    except Exception as e:
        print(f"[AudioCache] Warning: could not write cache file: {e}")

    return Response(
        content=audio_bytes,
        media_type="audio/mpeg",
        headers={"X-Audio-Cache": "MISS", "Cache-Control": "public, max-age=86400"},
    )
