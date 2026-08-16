/**
 * Voca 2.0 transport — the envelope, the typed error, and the raw endpoint calls.
 *
 * 2.0 wraps EVERY JSON response — success *and* error — in
 * `{status, code, message, data}`, so no caller may read a response body
 * directly: `unwrapVoca` is the only door in (v1's `return res.json()` handed
 * back the envelope, which made `found`/`card`/`cards` silently undefined).
 * It decides on the envelope CODE and never on the HTTP status, because the
 * backend proxy forwards Voca bodies verbatim but remaps an upstream 401 to a
 * 502 of its own — the status lies, the code doesn't.
 *
 * Only two responses are NOT enveloped and are handled explicitly here: the
 * audio GET (binary mp3) and the practice endpoints (SSE).
 */
import { apiFetch } from '@/lib/api-client';

/** Same-origin proxy that attaches the user's server-held Voca API key. */
const VOCA_BASE = '/api/voca';

/** Voca's own TTS voice id, used when the user hasn't picked one. */
export const DEFAULT_TTS_MODEL = 'edge-tts/en-US-SteffanNeural';

// -- types -------------------------------------------------------------------

export interface VocaEnvelope<T> {
  status: number;
  code: string;
  message: string;
  data: T | null;
}

export type VocaLevel = 'new' | 'learning' | 'known' | 'mastered';

/** The 2.0 Card. `id` is a number now; `slug` is the audio/detail key. */
export interface VocaCard {
  id: number;
  slug: string;
  word: string;
  ipa?: string;
  pronunciation?: string;
  frequency?: string | number;
  meaningEn?: string;
  meaningVi?: string;
  useCases?: string[];
  examples?: string[];
  memoryTip?: string;
  toeicTrap?: string;
  partOfSpeech?: string;
  topic?: string;
  tags?: string[];
  keyword?: string;
  practicePrompt?: string;
  answer?: string;
  level?: VocaLevel;
  /** Voca-side path (`/v1/audio/{slug}`) — not a path on our proxy. */
  audioUrl?: string;
  createdAt?: string;
}

export interface VocaLookupResult {
  found: boolean;
  word: string;
  matchType?: 'exact' | 'partial';
  card?: VocaCard;
  /** Up to 8 partial matches; absent on an exact hit. */
  cards?: VocaCard[];
}

/** Incremental sync page: `cards` is omitted entirely when `changed` is false. */
export interface VocaCardsPage {
  version: string | number;
  changed: boolean;
  cards?: VocaCard[];
}

/** What the audio POST answers with — the canonical key to fetch the mp3 from. */
export interface VocaAudioRef {
  audioUrl: string;
  id: string | number;
}

export interface VocaHealth {
  status: string;
  service: string;
  storage: string;
  version: string;
}

// -- errors ------------------------------------------------------------------

export class VocaError extends Error {
  code: string;
  status: number;
  constructor(code: string, message: string, status = 0) {
    super(message);
    this.name = 'VocaError';
    this.code = code;
    this.status = status;
  }
}

/** Vietnamese wording for the codes 2.0 documents; anything else falls through
 *  to Voca's own (English) message so we never swallow an unknown failure. */
const CODE_MESSAGES: Record<string, string> = {
  UNAUTHORIZED: 'API key Voca không hợp lệ — kiểm tra trong Cài đặt.',
  FORBIDDEN: 'API key Voca không có quyền cho thao tác này.',
  RATE_LIMITED: 'Voca đang quá tải (giới hạn 120 request/phút) — thử lại sau ít giây.',
  LLM_NOT_CONFIGURED: 'Voca chưa cấu hình LLM nên không tạo được thẻ mới.',
  TTS_NOT_CONFIGURED: 'Voca chưa cấu hình TTS nên không tạo được audio.',
  NOT_FOUND: 'Không tìm thấy thẻ này trong từ điển Voca.',
  AUDIO_NOT_FOUND: 'Thẻ này chưa có audio.',
  MISSING_WORD: 'Thiếu từ cần tra cứu.',
  INVALID_LEVEL: 'Cấp độ (level) không hợp lệ.',
};

function messageForCode(code: string, upstream: unknown, status: number): string {
  const mapped = CODE_MESSAGES[code];
  if (mapped) return mapped;
  if (typeof upstream === 'string' && upstream.trim()) return upstream;
  return `Voca lỗi (${code || status}).`;
}

/** Our own proxy answers with FastAPI's `{detail}` for *its* failures (missing
 *  Voca config, host unreachable) — those never carry a Voca envelope. */
function messageForProxyError(body: Record<string, unknown>, status: number): string {
  const detail = body.detail;
  if (typeof detail === 'string' && detail.trim()) return detail;
  const message = body.message;
  if (typeof message === 'string' && message.trim()) return message;
  return `Không gọi được Voca (${status}).`;
}

/**
 * Parse a Voca JSON response and hand back `data`, throwing `VocaError` on a
 * transport failure or a non-OK envelope code.
 */
export async function unwrapVoca<T>(res: Response): Promise<T> {
  const text = await res.text();
  // Partial: a body that never reached Voca carries no envelope at all.
  let body: Partial<VocaEnvelope<T>> & Record<string, unknown> = {};
  try {
    if (text) body = JSON.parse(text) as Partial<VocaEnvelope<T>> & Record<string, unknown>;
  } catch {
    /* not JSON (CDN error page, dead host) — handled as a proxy error below */
  }

  const code = typeof body.code === 'string' ? body.code : '';
  if (code && code !== 'OK') throw new VocaError(code, messageForCode(code, body.message, res.status), res.status);
  if (!res.ok) throw new VocaError('UNKNOWN', messageForProxyError(body, res.status), res.status);
  if (!code) throw new VocaError('BAD_RESPONSE', 'Voca trả về dữ liệu không hợp lệ.', res.status);
  return body.data as T;
}

// -- rate-limit backoff ------------------------------------------------------

const RATE_LIMIT_RETRIES = 2;

/**
 * Retry a *read* on RATE_LIMITED only. 2.0 caps keys at 120 req/min and sends
 * no `X-RateLimit-*`/`Retry-After` header, so the delay is a blind exponential
 * with jitter (jitter matters: a page can fire several lookups at once).
 * Never wrapped around card/audio generation — those aren't idempotent.
 */
export async function withRateLimitRetry<T>(run: () => Promise<T>): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    try {
      return await run();
    } catch (err) {
      const limited = err instanceof VocaError && err.code === 'RATE_LIMITED';
      if (!limited || attempt >= RATE_LIMIT_RETRIES) throw err;
      const delay = 400 * 2 ** attempt + Math.random() * 250;
      await new Promise((resolve) => setTimeout(resolve, delay));
    }
  }
}

// -- cards -------------------------------------------------------------------

/** Fallback audio key for a card that predates the `slug` field. */
export function slugifyWord(word: string): string {
  return String(word || '')
    .trim()
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

/** 2.0 keys audio and card detail by SLUG — `id` is a number and useless here. */
export function cardAudioKey(card: VocaCard | string): string {
  if (typeof card === 'string') return card.trim();
  return String(card?.slug || '').trim() || slugifyWord(card?.word || '');
}

export function lookupVocaCard(word: string): Promise<VocaLookupResult> {
  return withRateLimitRetry(async () =>
    unwrapVoca<VocaLookupResult>(await apiFetch(`${VOCA_BASE}/lookup?word=${encodeURIComponent(word)}`)),
  );
}

/** Full card detail (the rich fields a lookup list doesn't carry). */
export function getVocaCard(slug: string): Promise<VocaCard> {
  return withRateLimitRetry(async () =>
    unwrapVoca<VocaCard>(await apiFetch(`${VOCA_BASE}/cards/${encodeURIComponent(slug)}`)),
  );
}

/** Incremental listing: pass the version we already hold to get `changed:false`. */
export function fetchVocaCardsPage(since?: string | number): Promise<VocaCardsPage> {
  const query = since != null && since !== '' ? `?ifChangedSince=${encodeURIComponent(String(since))}` : '';
  return withRateLimitRetry(async () => unwrapVoca<VocaCardsPage>(await apiFetch(`${VOCA_BASE}/cards${query}`)));
}

/**
 * Create a card. 2.0 answers with plain JSON (v1 streamed NDJSON progress) and
 * runs the LLM server-side, so the body is just the word — no settings, and no
 * client-side precondition on the user's own LLM config.
 */
export async function createVocaCard(word: string): Promise<VocaCard> {
  const res = await apiFetch(`${VOCA_BASE}/create`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ word }),
  });
  return unwrapVoca<VocaCard>(res);
}

// -- audio -------------------------------------------------------------------

function audioPath(key: string): string {
  return `${VOCA_BASE}/audio/${encodeURIComponent(key)}`;
}

/**
 * Fetch the mp3 for an audio key. Success is binary, so it can't be unwrapped;
 * a failure IS enveloped, and a missing recording (`AUDIO_NOT_FOUND`) is a
 * normal branch — it means "generate it first", so we return null, not throw.
 */
export function fetchVocaAudio(key: string): Promise<Blob | null> {
  return withRateLimitRetry(async () => {
    const res = await apiFetch(audioPath(key));
    if (res.ok) return res.blob();
    try {
      await unwrapVoca<unknown>(res);
    } catch (err) {
      if (!(err instanceof VocaError)) throw err;
      const missing =
        err.code === 'AUDIO_NOT_FOUND' || err.code === 'NOT_FOUND' || (err.code === 'UNKNOWN' && res.status === 404);
      if (!missing) throw err;
    }
    return null;
  });
}

/**
 * Ask Voca to synthesise the audio. `text` is only sent when we want something
 * other than the card's own word spoken; TTS itself is configured server-side
 * at Voca now, so all we choose is the voice.
 */
export function generateVocaAudio(
  key: string,
  options: { voiceModel?: string; text?: string } = {},
): Promise<VocaAudioRef> {
  const body: { voiceModel: string; text?: string } = {
    voiceModel: options.voiceModel?.trim() || DEFAULT_TTS_MODEL,
  };
  if (options.text) body.text = options.text;
  return apiFetch(audioPath(key), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  }).then((res) => unwrapVoca<VocaAudioRef>(res));
}

/** The generated ref is authoritative: fetch what Voca says it stored, not the
 *  key we guessed (the two differ whenever our slug fallback kicked in). */
export function audioKeyFromRef(ref: VocaAudioRef | null, fallback: string): string {
  if (ref?.id != null && String(ref.id).trim()) return String(ref.id).trim();
  const fromUrl = String(ref?.audioUrl || '')
    .split('/')
    .filter(Boolean)
    .pop();
  return fromUrl || fallback;
}

// -- health ------------------------------------------------------------------

/**
 * Settings-screen probe. `/health` takes no key, so it only proves the origin is
 * a live Voca — an unreachable host and a wrong key are different bugs, and the
 * caller pairs this with a cards read to exercise the key itself.
 */
export function checkVocaHealth(): Promise<VocaHealth> {
  return withRateLimitRetry(async () => unwrapVoca<VocaHealth>(await apiFetch(`${VOCA_BASE}/health`)));
}

// -- practice (SSE) ----------------------------------------------------------

export interface VocaDrillsRequest {
  count?: number;
  selectedWord?: string;
}

export interface VocaReadingRequest {
  format?: 'part6' | 'part7';
  selectedWord?: string;
}

/**
 * Drain an OpenAI-style `chat.completion.chunk` stream: concatenate every
 * `choices[0].delta.content`, stop at `[DONE]`, and parse the concatenation —
 * Voca streams a JSON payload one token at a time. Keeps v1's fix for the final
 * unterminated line (dropping it reported a truncated stream as success).
 */
async function consumeSseJson<T>(res: Response): Promise<T> {
  // Errors arrive as a normal envelope even on the SSE routes.
  if (!res.ok) return unwrapVoca<T>(res);
  if (!res.body) throw new VocaError('BAD_RESPONSE', 'Voca không trả về nội dung.', res.status);

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  let content = '';
  for (;;) {
    const { value, done } = await reader.read();
    buffer += decoder.decode(value, { stream: !done });
    const lines = buffer.split(/\r?\n/);
    buffer = done ? '' : (lines.pop() ?? '');
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue; // comments / keep-alives
      const payload = trimmed.slice(5).trim();
      if (!payload || payload === '[DONE]') continue;
      try {
        const chunk = JSON.parse(payload) as { choices?: { delta?: { content?: string } }[] };
        content += chunk.choices?.[0]?.delta?.content ?? '';
      } catch {
        /* partial frame — the next read completes it */
      }
    }
    if (done) break;
  }

  try {
    return JSON.parse(content) as T;
  } catch {
    throw new VocaError('BAD_RESPONSE', 'Voca trả về nội dung luyện tập không hợp lệ.', res.status);
  }
}

function postPractice<T>(path: string, body: unknown): Promise<T> {
  return apiFetch(`${VOCA_BASE}/practice/${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body ?? {}),
  }).then((res) => consumeSseJson<T>(res));
}

// No practice UI exists yet — these are client-only for now, exported so a
// future drills/reading screen has a typed entry point instead of re-deriving
// the SSE handling. The payload shape is whatever Voca's prompt returns, hence
// the caller-supplied generic.
export function fetchPracticeDrills<T = unknown>(request: VocaDrillsRequest = {}): Promise<T> {
  return postPractice<T>('drills', request);
}

export function fetchPracticeReading<T = unknown>(request: VocaReadingRequest = {}): Promise<T> {
  return postPractice<T>('reading', request);
}
