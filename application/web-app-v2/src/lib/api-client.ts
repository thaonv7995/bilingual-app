/**
 * API client for the FastAPI backend.
 *
 * Auth model (v2): the access token lives **in memory only** (this module's
 * `accessToken`), never in localStorage — so an XSS payload can't read it. The
 * refresh token lives in an HttpOnly cookie the browser sends automatically with
 * `credentials: 'include'`; refresh needs no token in JS.
 *
 * The refresh dedupe (single-flight via a module promise + `navigator.locks`) is
 * ported from v1's sound implementation (app.js:245-259) so concurrent 401s and
 * multiple tabs don't stampede `/api/auth/refresh`.
 */
import type { ApiErrorBody } from '@/types/api';

const API_BASE = import.meta.env.VITE_API_BASE ?? '';
const REFRESH_LOCK = 'bilingual-reader-auth-refresh';

let accessToken = '';
let refreshInFlight: Promise<string> | null = null;
let onSessionExpired: (() => void) | null = null;

export class AuthRefreshError extends Error {
  status: number;
  terminal: boolean;
  constructor(message: string, status = 0, terminal = false) {
    super(message);
    this.name = 'AuthRefreshError';
    this.status = status;
    this.terminal = terminal;
  }
}

/** Error thrown by `apiFetch` for non-2xx responses, carrying the parsed detail. */
export class ApiError extends Error {
  status: number;
  constructor(message: string, status: number) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
  }
}

// -- access token (in memory) ------------------------------------------------

export function setAccessToken(token: string): void {
  accessToken = token || '';
}

export function getAccessToken(): string {
  return accessToken;
}

export function clearAccessToken(): void {
  accessToken = '';
}

/** Registered by the auth store so a terminal refresh failure clears the user. */
export function registerSessionExpiredHandler(handler: () => void): void {
  onSessionExpired = handler;
}

// -- token expiry helpers (decode JWT exp) -----------------------------------

const REFRESH_WINDOW_MS = 60 * 1000;

export function getAccessTokenExpiryMs(token: string): number {
  if (!token) return 0;
  try {
    const payloadPart = token.split('.')[1];
    if (!payloadPart) return 0;
    const normalized = payloadPart.replace(/-/g, '+').replace(/_/g, '/');
    const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=');
    const payload = JSON.parse(atob(padded)) as { exp?: number };
    return Number(payload.exp ?? 0) * 1000;
  } catch {
    return 0;
  }
}

export function accessTokenExpiresSoon(token: string, windowMs = REFRESH_WINDOW_MS): boolean {
  const expiryMs = getAccessTokenExpiryMs(token);
  return !expiryMs || expiryMs - Date.now() <= windowMs;
}

// -- refresh -----------------------------------------------------------------

async function performRefresh(expected: string): Promise<string> {
  // Another tab/request may have already refreshed into a still-valid token.
  if (expected && accessToken && accessToken !== expected && !accessTokenExpiresSoon(accessToken)) {
    return accessToken;
  }

  const res = await fetch(`${API_BASE}/api/auth/refresh`, {
    method: 'POST',
    credentials: 'include', // refresh token travels in the HttpOnly cookie
  });

  if (!res.ok) {
    const terminal = res.status === 400 || res.status === 401 || res.status === 403;
    throw new AuthRefreshError(
      terminal ? 'Refresh token is invalid or expired.' : 'Token refresh temporarily failed.',
      res.status,
      terminal,
    );
  }

  const data = (await res.json()) as { access_token?: string };
  if (!data.access_token) {
    throw new AuthRefreshError('Token refresh returned no access token.', res.status, false);
  }
  setAccessToken(data.access_token);
  return data.access_token;
}

/** Refresh the access token, deduped across concurrent callers and tabs. */
export function refreshAccessToken(expected = ''): Promise<string> {
  if (refreshInFlight) return refreshInFlight;

  const task = () => performRefresh(expected);
  const promise: Promise<string> = navigator.locks?.request
    ? (navigator.locks.request(REFRESH_LOCK, task) as unknown as Promise<string>)
    : task();

  refreshInFlight = promise;
  return promise.finally(() => {
    if (refreshInFlight === promise) refreshInFlight = null;
  });
}

/** Proactively refresh if the in-memory token is missing or about to expire. */
export async function ensureFreshAccessToken(force = false): Promise<string> {
  if (!force && accessToken && !accessTokenExpiresSoon(accessToken)) return accessToken;
  try {
    return await refreshAccessToken(accessToken);
  } catch (err) {
    if (err instanceof AuthRefreshError && err.terminal) onSessionExpired?.();
    throw err;
  }
}

// -- fetch wrapper -----------------------------------------------------------

function normalizeUrl(path: string): string {
  if (/^https?:\/\//i.test(path)) return path;
  const rel = path.startsWith('/') ? path : `/${path}`;
  return `${API_BASE}${rel}`;
}

function detailToMessage(detail: ApiErrorBody['detail'], fallback: string): string {
  if (typeof detail === 'string') return detail;
  if (Array.isArray(detail)) {
    const msg = detail.map((d) => d?.msg).filter(Boolean).join('; ');
    if (msg) return msg;
  }
  return fallback;
}

interface ApiFetchOptions extends RequestInit {
  /** Set false to skip the automatic 401 refresh+retry (used by refresh itself). */
  allowRefresh?: boolean;
}

/**
 * Fetch against the backend with the in-memory bearer token attached. On 401 it
 * refreshes once and retries. Returns the raw Response — callers decide how to
 * read the body (see `apiJson` for the common JSON case).
 */
export async function apiFetch(path: string, options: ApiFetchOptions = {}): Promise<Response> {
  const { allowRefresh = true, headers, ...rest } = options;

  const buildHeaders = (token: string): HeadersInit => {
    const h = new Headers(headers);
    if (token) h.set('Authorization', `Bearer ${token}`);
    return h;
  };

  const url = normalizeUrl(path);
  let res = await fetch(url, { ...rest, headers: buildHeaders(accessToken), credentials: 'include' });

  if (res.status === 401 && allowRefresh) {
    try {
      const fresh = await ensureFreshAccessToken(true);
      res = await fetch(url, { ...rest, headers: buildHeaders(fresh), credentials: 'include' });
    } catch {
      // refresh failed; fall through and let the caller see the 401
    }
  }
  return res;
}

/** Convenience: apiFetch + JSON parse, throwing `ApiError` on non-2xx or empty body. */
export async function apiJson<T>(path: string, options: ApiFetchOptions = {}): Promise<T> {
  const res = await apiFetch(path, options);
  if (!res.ok) {
    const body = (await res.json().catch(() => ({}))) as ApiErrorBody;
    throw new ApiError(detailToMessage(body.detail, `Request failed (${res.status})`), res.status);
  }
  if (res.status === 204) return undefined as T;
  const text = await res.text();
  if (!text) return undefined as T;
  return JSON.parse(text) as T;
}
