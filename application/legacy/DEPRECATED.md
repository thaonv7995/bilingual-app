# Legacy — scheduled for removal

Everything under `application/legacy/` is superseded and kept only as a fallback.
Do not add features here. Fixes should go to the v2 equivalent.

## `web-app-v1/`

The original vanilla-JS + Preact frontend (`application/web-app/` before the move).
Replaced by **`application/web-app-v2/`** (React + Vite).

**Is it still served?** Only as a fallback. `backend/api/main.py` serves the v2 build
when `FRONTEND_V2_DIST` points at `application/web-app-v2/dist`, and falls back to
this directory otherwise. Production sets that variable (`deploy.sh`), so production
runs v2 and never touches these files.

`backend/api/config.py` resolves this directory as `WEB_APP_DIR`.

### Why it is not deleted yet

The fallback branch in `main.py` is the only path that still serves a UI if a v2
build is missing or broken on a fresh install. Delete this directory together with
that branch, not before.

### Known state

- Speaks the **pre-2.0 Voca protocol** — no `{status, code, message, data}` envelope,
  sends a `settings` object to `/cards/create`, parses NDJSON. It will not work
  against Voca 2.0 and was not migrated.
- The Voca API token that was hardcoded in `voca-client.js` has been removed. It was
  served publicly at `/voca-client.js`, so **it must be treated as compromised** —
  revoke it in Voca → Settings → API Keys. Removing it from HEAD does not remove it
  from this repository's git history.

### Removal checklist

1. Drop the `else:` fallback branch in `backend/api/main.py` (the per-file
   `FileResponse` wiring) and the `WEB_APP_DIR` fallback in `get_favicon_v2`.
2. Remove `WEB_APP_DIR` from `backend/api/config.py`.
3. Remove the `application/legacy/web-app-v1/config.js` entries from `.gitignore`
   and the `tar --exclude` in `.github/workflows/deploy.yml`.
4. Delete this directory.
