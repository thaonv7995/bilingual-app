"""Tests for backend runtime feature config (/api/config and api.config)."""
from __future__ import annotations

from api import config as api_config
from api.routes.config import get_app_config


def test_audiobook_is_disabled_by_default():
    assert api_config.ENABLE_AUDIOBOOK is False
    assert api_config.is_audiobook_enabled() is False
    assert get_app_config() == {"features": {"audiobookEnabled": False}}


def test_parse_bool_env_variants(monkeypatch):
    for truthy in ("1", "true", "TRUE", " yes ", "On"):
        monkeypatch.setenv("ENABLE_AUDIOBOOK", truthy)
        assert api_config._parse_bool_env("ENABLE_AUDIOBOOK", False) is True

    for falsy in ("0", "false", "FALSE", " no ", "Off"):
        monkeypatch.setenv("ENABLE_AUDIOBOOK", falsy)
        assert api_config._parse_bool_env("ENABLE_AUDIOBOOK", True) is False

    monkeypatch.setenv("ENABLE_AUDIOBOOK", "invalid")
    assert api_config._parse_bool_env("ENABLE_AUDIOBOOK", False) is False
    assert api_config._parse_bool_env("ENABLE_AUDIOBOOK", True) is True


def test_get_app_config_reflects_flag(monkeypatch):
    monkeypatch.setattr(api_config, "ENABLE_AUDIOBOOK", True)
    assert get_app_config() == {"features": {"audiobookEnabled": True}}

    monkeypatch.setattr(api_config, "ENABLE_AUDIOBOOK", False)
    assert get_app_config() == {"features": {"audiobookEnabled": False}}

