"""Public runtime configuration and feature-flag endpoint shared by Web & iOS."""
from fastapi import APIRouter

from api import config as api_config

router = APIRouter(prefix="/api", tags=["config"])


@router.get("/config")
def get_app_config():
    """Return non-sensitive runtime feature flags configured on the backend."""
    return {
        "features": api_config.get_feature_flags(),
    }

