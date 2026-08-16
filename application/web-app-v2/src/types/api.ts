/** Shapes returned by the FastAPI backend (application/backend/api). */

export interface User {
  username: string;
  is_admin: boolean;
}

/** POST /api/auth/login response. Tokens are also set as HttpOnly cookies. */
export interface AuthResponse {
  access_token: string;
  refresh_token?: string;
  token_type: string;
  username: string;
  is_admin: boolean;
}

/** GET /api/books item. `createdAt` (import time) and `lastRead` (this user's
 * last read of this book) are unix SECONDS, or null when unknown / never read —
 * they drive the shelf order, see features/library/bookOrder.ts. Optional so the
 * client still typechecks against a backend that predates them. */
export interface Book {
  /** Autoincrement row id == import order. Optional: a backend that predates the
   * shelf order omits it, and the comparator then falls through to slug. */
  id?: number | null;
  slug: string;
  title: string;
  author: string;
  pageCount: number;
  cover: string | null;
  isPublished: boolean;
  createdAt?: number | null;
  lastRead?: number | null;
}

export type HighlightLang = 'en' | 'vi';

/** GET/POST /api/books/:slug/highlights item. `color` is the CSS hex the mark is
 * painted with (v1 stores the value, not a palette name). */
export interface Highlight {
  id: string;
  page: number;
  lang: HighlightLang;
  color: string;
  text: string;
  startOffset: number;
  endOffset: number;
  paragraphIndex: number;
  note: string;
  createdAt: number;
}

export type ViewMode = 'en' | 'vi' | 'split';

/** GET/POST /api/books/:slug/progress. `lastRead` is unix SECONDS (the backend
 * stores `int(time.time())`), absent when the book was never read. */
export interface ReadingProgress {
  page: number;
  viewMode: ViewMode;
  lastRead?: number | null;
}

/** GET /api/books/:slug/manifest. */
export interface BookManifest {
  files: string[];
}

/** FastAPI error body. `detail` may be a string or a validation-error array. */
export interface ApiErrorBody {
  detail?: string | Array<{ msg?: string; [k: string]: unknown }>;
}
