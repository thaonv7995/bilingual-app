# Voca 2.0 integration

Voca is the external vocabulary-card service behind word lookup, card creation, audio
and practice drills.

**Base URL: `https://voca.thaonv.online/v1`** — always `https`. The host answers on both
`http` and `https` with **no redirect**, so a stale `http://` base URL silently ships the
API key in cleartext; the origin is normalised to `https` before every call. The old
`voca-bridge.thaonv.online` host is **dead** (Cloudflare 502, plain-text body — not JSON),
so any config still pointing there fails in a way that looks like a Voca outage.

Auth: header `X-API-Key: voca_…` on every request. Bearer is also accepted upstream, but we
standardise on `X-API-Key`. The key must keep its `voca_` prefix — a key pasted without it
is rejected as `UNAUTHORIZED`.

## Who calls what

- **Web v2** never talks to Voca directly. It calls the backend proxy `/api/voca/*`, which
  attaches the origin + key from the caller's server-held settings (`user_settings`,
  entered in Settings, never returned to the browser). The proxy is a **pass-through**: it
  forwards Voca's body verbatim and does not reshape it.
- **iOS** goes through the same proxy. It calls `<serverUrl>/api/voca/*` authenticated with
  its own backend session, so the Voca key never reaches the device. Consequence: Voca
  features require being signed in to the book server (a locally-synced card still answers
  from the on-device snapshot).
- **One shared configuration.** Both clients read and write the same `user_settings` row, so
  entering the origin + key on web makes iOS work with no setup, and vice versa. The server
  never returns the key, so the key field is always blank once it is set — leaving it blank
  keeps the stored value.
- The envelope is unwrapped **in each client** (web v2 and iOS), not in the proxy.

Only the proxy sends `X-API-Key`; neither client ever holds the Voca key.

## Envelope

Every JSON response — success *and* error — is wrapped the same way:

```json
{ "status": 200, "code": "OK",           "message": "Success",        "data": { "…": "…" } }
{ "status": 401, "code": "UNAUTHORIZED", "message": "API key required.", "data": null }
```

Two responses are **not** enveloped: `GET /v1/audio/{slug}` (binary `audio/mpeg`) and
`POST /v1/practice/*` (`text/event-stream`).

## Endpoints

| Voca | Backend proxy (web v2) | `data` |
| :--- | :--- | :--- |
| `GET /v1/health` | `GET /api/voca/health` | `{status, service, storage, version}` — no key needed |
| `GET /v1/cards?ifChangedSince=<version>` | `GET /api/voca/cards` | `{version, changed, cards[]}`; `changed:false` omits `cards` |
| `GET /v1/cards/lookup?word=` | `GET /api/voca/lookup` | `{found, word, matchType: exact\|partial, card, cards[≤8]}` |
| `GET /v1/cards/{slug}` | `GET /api/voca/cards/{slug}` | a Card |
| `POST /v1/cards/create` body `{word}` | `POST /api/voca/create` | a Card — **plain JSON, not a stream**, and **no `settings` object**: the LLM lives server-side at Voca |
| `GET /v1/audio/{slug}` | `GET /api/voca/audio/{slug}` | binary mp3; `404 AUDIO_NOT_FOUND` → POST to generate |
| `POST /v1/audio/{slug}` body `{text?, voiceModel?}` | `POST /api/voca/audio/{slug}` | `{audioUrl, id}` — **no `settings` object** |
| `POST /v1/practice/drills` body `{count?, selectedWord?}` | `POST /api/voca/practice/drills` | SSE |
| `POST /v1/practice/reading` body `{format? part6\|part7, selectedWord?}` | `POST /api/voca/practice/reading` | SSE |

The audio/detail key is the card **`slug`**, not the numeric `id`.

**SSE format** (practice only): OpenAI `chat.completion.chunk` lines `data: {…}`, terminated
by `data: [DONE]`. Concatenate `choices[0].delta.content` across chunks; the concatenation is
itself a JSON payload — parse it once the stream ends.

## Card object

`id` (number), `slug` (string — the audio/detail key), `word`, `ipa`, `pronunciation`,
`frequency`, `meaningEn`, `meaningVi`, `useCases[]`, `examples[]`, `memoryTip`, `toeicTrap`,
`partOfSpeech`, `topic`, `tags[]`, `keyword`, `practicePrompt`, `answer`,
`level` (`new|learning|known|mastered`), `audioUrl` (`/v1/audio/{slug}`),
`createdAt` (ISO-8601 UTC).

## Errors & rate limit

`MISSING_WORD`, `INVALID_LEVEL`, `UNAUTHORIZED` (401), `FORBIDDEN` (403), `NOT_FOUND` (404),
`AUDIO_NOT_FOUND` (404), `RATE_LIMITED` (429), `LLM_NOT_CONFIGURED` (503),
`TTS_NOT_CONFIGURED` (503).

**120 requests/min per key.** A 429 returns `RATE_LIMITED` with **no `X-RateLimit-*` headers**
— there is nothing to read a reset time from, so clients back off exponentially and retry.

## Configuration

Server env (optional — a per-user value in Settings always wins):

| Var | Purpose |
| :--- | :--- |
| `VOCA_API_ORIGIN` | Voca base host. **New name, preferred.** Default `https://voca.thaonv.online`; forced to `https` |
| `VOCA_BRIDGE_ORIGIN` | Legacy alias, still read when `VOCA_API_ORIGIN` is unset |
| `VOCA_BRIDGE_TOKEN` | Server-default `voca_…` key used when a user hasn't set their own. Name unchanged for backwards compatibility |

Per-user values are set in Settings and stored server-side: `/api/user/settings` JSON keys
`vocaOrigin` / `vocaToken` → `user_settings.voca_bridge_origin` / `.voca_bridge_token`. The
JSON keys and column names are deliberately **unchanged** — no migration, no client breakage.

`VITE_VOCA_BRIDGE_ORIGIN` is **gone**. It was declared but never read: v2 has no direct Voca
origin because every call goes through the backend proxy.

## ⚠️ Rotate the committed key

The Voca API key previously hardcoded in `mobile_ios/Services/VocaService.swift` (and in the
legacy `web-app/voca-client.js`, which the backend serves **publicly**) is in this repo's git
history. Deleting it from HEAD does **not** remove it from history. Revoke it in
**Voca → Settings → API Keys**, issue a new one, and enter the new key in the app's Settings
screen (iOS) or the server `.env` (backend default).
