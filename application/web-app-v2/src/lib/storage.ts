/**
 * Safe localStorage wrapper. Every access is wrapped in try/catch so a disabled
 * store (private mode), a quota-exceeded write, or malformed JSON can never throw
 * — v1 crashed chat streams and highlight creation on QuotaExceededError because
 * raw setItem ran inside state updaters (review app.js #8/#16).
 */

export function readString(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

export function writeString(key: string, value: string): boolean {
  try {
    localStorage.setItem(key, value);
    return true;
  } catch (err) {
    console.warn(`[storage] failed to write "${key}":`, err);
    return false;
  }
}

export function remove(key: string): void {
  try {
    localStorage.removeItem(key);
  } catch {
    /* ignore */
  }
}

export function readJSON<T>(key: string, fallback: T): T {
  const raw = readString(key);
  if (raw == null) return fallback;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

export function writeJSON(key: string, value: unknown): boolean {
  try {
    return writeString(key, JSON.stringify(value));
  } catch (err) {
    console.warn(`[storage] failed to serialize "${key}":`, err);
    return false;
  }
}

/** Remove every key beginning with `prefix` (e.g. per-book cache metadata). */
export function removeByPrefix(prefix: string): void {
  try {
    for (const key of Object.keys(localStorage)) {
      if (key.startsWith(prefix)) localStorage.removeItem(key);
    }
  } catch {
    /* ignore */
  }
}
