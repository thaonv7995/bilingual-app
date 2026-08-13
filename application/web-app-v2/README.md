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
