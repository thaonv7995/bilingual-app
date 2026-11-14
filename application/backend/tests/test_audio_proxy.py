import json
import pytest
from types import SimpleNamespace
from fastapi import HTTPException
import httpx

from api import config as api_config
from api.database import SessionLocal, User, UserSettings, init_db
from api.routes import audio
from api.routes.settings import put_user_settings

init_db()


def _make_user(username: str) -> int:
    db = SessionLocal()
    try:
        u = db.query(User).filter(User.username == username).first()
        if not u:
            u = User(username=username, password_hash="x", is_admin=False)
            db.add(u)
            db.commit()
            db.refresh(u)
        return u.id
    finally:
        db.close()


@pytest.mark.anyio
async def test_audio_endpoints_blocked_when_disabled():
    with pytest.raises(HTTPException) as exc:
        audio.get_supported_voices()
    assert exc.value.status_code == 403

    uid = _make_user("audio_disabled")
    user = SimpleNamespace(id=uid)
    db = SessionLocal()
    try:
        with pytest.raises(HTTPException) as exc:
            await audio.synthesize_speech(
                audio.SynthesizeRequest(text="Hello", provider="openai"),
                current_user=user,
                db=db,
            )
        assert exc.value.status_code == 403
    finally:
        db.close()


def test_get_supported_voices(monkeypatch):
    monkeypatch.setattr(api_config, "ENABLE_AUDIOBOOK", True)
    voices = audio.get_supported_voices()
    assert "openai" in voices
    assert "azure" in voices
    assert "elevenlabs" in voices
    assert any(v["id"] == "alloy" for v in voices["openai"])


@pytest.mark.anyio
async def test_synthesize_speech_validation(monkeypatch):
    monkeypatch.setattr(api_config, "ENABLE_AUDIOBOOK", True)
    uid = _make_user("audio_valid")
    user = SimpleNamespace(id=uid)
    db = SessionLocal()
    try:
        # Empty text fails
        with pytest.raises(HTTPException) as exc:
            await audio.synthesize_speech(
                audio.SynthesizeRequest(text="   "),
                current_user=user,
                db=db,
            )
        assert exc.value.status_code == 400

        # Device provider fails on server synthesis
        with pytest.raises(HTTPException) as exc:
            await audio.synthesize_speech(
                audio.SynthesizeRequest(text="Hello", provider="device"),
                current_user=user,
                db=db,
            )
        assert exc.value.status_code == 400
        assert "device" in exc.value.detail.lower()
    finally:
        db.close()


@pytest.mark.anyio
async def test_synthesize_openai_mocked_and_cached(monkeypatch, tmp_path):
    monkeypatch.setattr(api_config, "ENABLE_AUDIOBOOK", True)
    monkeypatch.setattr(audio, "CACHE_DIR", tmp_path)
    uid = _make_user("audio_openai")
    user = SimpleNamespace(id=uid)
    db = SessionLocal()
    try:
        put_user_settings({"llmApiKey": "sk-fake-openai"}, current_user=user, db=db)

        mock_called = 0
        fake_mp3 = b"FAKE_MP3_STREAM_CONTENT_12345"

        async def mock_post(self, url, *args, **kwargs):
            nonlocal mock_called
            mock_called += 1
            assert "api.openai.com" in str(url)
            return httpx.Response(200, content=fake_mp3, headers={"Content-Type": "audio/mpeg"})

        monkeypatch.setattr(httpx.AsyncClient, "post", mock_post)

        # First call: cache MISS
        res1 = await audio.synthesize_speech(
            audio.SynthesizeRequest(text="The quick brown fox", provider="openai", voice="alloy"),
            current_user=user,
            db=db,
        )
        assert res1.body == fake_mp3
        assert res1.headers["X-Audio-Cache"] == "MISS"
        assert mock_called == 1

        # Second call with same parameters: cache HIT, mock not called again!
        res2 = await audio.synthesize_speech(
            audio.SynthesizeRequest(text="The quick brown fox", provider="openai", voice="alloy"),
            current_user=user,
            db=db,
        )
        assert res2.body == fake_mp3
        assert res2.headers["X-Audio-Cache"] == "HIT"
        assert mock_called == 1
    finally:
        db.close()
