# Bilingual Reader — Web App v2

React + TypeScript + Vite rewrite of `application/web-app/` (v1 Preact + htm).
Same features and UI, modular structure, with the security/logic issues from the
review fixed. Talks to the same FastAPI backend (`application/backend`, port 27099).

**v1 keeps running until v2 reaches parity.** The backend still serves v1; cutover
(Phase 10) swaps the static-serving routes to v2's `dist/`.

## Develop

```bash
npm install
npm run dev        # http://localhost:5173, proxies /api and /books to :27099
```

Start the backend separately so the proxy has a target:

```bash
# from repo root
python server.py   # uvicorn on :27099
```

## Scripts

| Command | Purpose |
| --- | --- |
| `npm run dev` | Vite dev server + HMR, proxy to backend |
| `npm run build` | Typecheck + production build to `dist/` |
| `npm run preview` | Serve the built `dist/` locally |
| `npm run typecheck` | `tsc --noEmit` |
| `npm run lint` | ESLint |
| `npm run format` | Prettier |

## Structure

Two Vite entry points sharing one `src/`:

- `index.html` → `src/main.tsx` → reader SPA (`src/app/App.tsx`)
- `admin.html` → `src/admin-main.tsx` → admin (`src/features/admin/AdminApp.tsx`)

```
src/
  app/         routes + providers (React Query, Router)
  features/    auth · library · reader · highlights · chat · voice · settings · admin
  lib/         api-client · voca · storage · sse · escape
  components/  shared UI (Toast, Modal, Dropdown, Icon)
  styles/      tokens.css + per-feature CSS Modules
  types/       API + domain types
```

### Conventions

- **Server state** → TanStack Query, keyed by book slug (fixes cross-book races).
- **Global client state** → Zustand (`authStore`, `settingsStore`, `readerStore`).
- **Auth** → access token in memory only; refresh token in an HttpOnly cookie.
- **Reader iframe DOM** (highlights, segmentation, popups) stays **imperative** in
  `features/reader/iframe/*`, invoked from the iframe `onLoad` — it does not map onto
  React's declarative model.
- **No secrets in the client.** Provider keys live in the backend env; users may
  override with their own key in Settings.

## Deployment & cutover

The build is served by the **same FastAPI backend**. Cutover is **opt-in** via an
env var, so v1 stays the default until you flip it:

```bash
cd application/web-app-v2 && npm ci && npm run build   # produces dist/
# then run the backend with:
export FRONTEND_V2_DIST="$PWD/dist"                    # serve v2 (React SPA)
#   unset  -> backend serves the legacy v1 files (default)
```

When `FRONTEND_V2_DIST` is set, `api/main.py` serves `dist/` with an SPA
fallback (`/read/:slug/page/:n` → `index.html`), `/admin` → `admin.html`, and the
service worker/manifest; `/api/*` and `/books/*` keep routing to the backend. CI
(`.github/workflows/deploy.yml`) builds `dist/` and ships it in the release
tarball.

### Server env vars

| Var | Purpose |
| --- | --- |
| `FRONTEND_V2_DIST` | Path to `dist/` to serve v2 (unset = legacy v1) |
| `OPENAI_API_KEY` | Server fallback key for `/api/chat` + realtime (hybrid; users can still override in Settings) |
| `VOCA_API_ORIGIN` | Voca API base URL (new name, preferred). Default `https://voca.thaonv.online`; forced to `https` |
| `VOCA_BRIDGE_ORIGIN` | Legacy alias for the above, still read when `VOCA_API_ORIGIN` is unset |
| `VOCA_BRIDGE_TOKEN` | Server-default Voca API key (`voca_…` prefix required), server-side only. Users can set their own in Settings |
| `JWT_SECRET_KEY` | Set a strong secret — don't ship the default |

v2 has **no** client-side Voca origin — every Voca call goes through the backend
`/api/voca/*` proxy, which is a verbatim pass-through of Voca's envelope (unwrapped
here in `lib/voca.ts`). See [voca-integration.md](../docs/voca-integration.md).

### Owner follow-ups (from the security review)

- **Rotate the Voca API key** — the key previously hardcoded in
  `VocaService.swift` (and in the legacy, publicly served `web-app/voca-client.js`) is in
  git history; removing it from HEAD does **not** remove it from history. Revoke it in
  Voca → Settings → API Keys and issue a new one.
- **Rotate the Gemini key** exposed by v1 (was in `config.js`).
- Change the default `admin` / `admin123` credentials.
- Tighten backend CORS from `allow_origin_regex=".*"` to the deployed origin.
- Add a CSRF token to the cookie-based `/api/auth/refresh` + `/logout`
  (SameSite=lax already blocks most cross-site use).
