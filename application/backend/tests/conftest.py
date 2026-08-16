"""Hermetic environment for the backend suite.

pytest imports this before any test module, which is the only moment early enough
to matter: `api.database` builds its engine from DATABASE_URL at import time, and
`api.routes.voca` freezes ENV_VOCA_ORIGIN / ENV_VOCA_TOKEN the same way. The test
modules do set those vars in their own preambles, but they lose the race —
`api.routes.settings` imports `api.routes.voca` (for `_normalize_origin`), so
collecting test_user_settings.py (alphabetically first) already pins voca's
constants before test_voca_proxy.py's preamble ever runs.

Two real failures this prevents, both triggered by env the server itself uses:

* `DATABASE_URL` exported (how the backend is normally configured) made the suite
  run against THAT database — the modules use `setdefault`, so an ambient value
  won and the tests created users and rewrote user_settings rows in it.
* `VOCA_API_ORIGIN` exported (documented in application/.env.example) made
  test_default_origin_is_the_2_0_host fail against a perfectly healthy backend.

The modules keep their own preambles as a fallback for direct imports; assigning
here (not `setdefault`) is what makes this file authoritative.
"""
import os
import tempfile
from pathlib import Path

# One throwaway DB shared by every module, recreated per run. Both test modules
# already shared a DB (whichever imported first chose it); this just names it.
_TEST_DB = Path(tempfile.gettempdir()) / "bilingual_backend_tests.db"
for _suffix in ("", "-wal", "-shm"):
    _stale = Path(str(_TEST_DB) + _suffix)
    if _stale.exists():
        _stale.unlink()

os.environ["DATABASE_URL"] = f"sqlite:///{_TEST_DB}"

# Cleared so the import-time constants are computed from a known-empty env
# regardless of which module triggers the import first.
for _var in ("OPENAI_API_KEY", "VOCA_API_ORIGIN", "VOCA_BRIDGE_ORIGIN", "VOCA_BRIDGE_TOKEN"):
    os.environ.pop(_var, None)
