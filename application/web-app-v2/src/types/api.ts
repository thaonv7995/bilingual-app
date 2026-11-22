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
export type BookFormat = 'bkb' | 'pdf' | 'epub';

export interface Book {
  /** Autoincrement row id == import order. Optional: a backend that predates the
   * shelf order omits it, and the comparator then falls through to slug. */
  id?: number | null;
  slug: string;
  title: string;
  author: string;
  pageCount: number;
  cover: string | null;
  /** Book format: 'bkb' (default bilingual HTML), 'pdf', or 'epub'. */
  format?: BookFormat;
  /** Relative URL to raw PDF/EPUB source file when format is 'pdf' or 'epub'. */
  sourceUrl?: string | null;
  isPublished: boolean;
  createdAt?: number | null;
  lastRead?: number | null;
  isFinished: boolean;
  isPriority: boolean;
  /** Per-book default font ID ('default' = original book CSS font). */
  defaultFont?: string;
  /** Per-book default paper color theme ID ('default' = original book CSS paper). */
  defaultTheme?: string;
  /** User's per-book font override ('' = use book's defaultFont). */
  readerFont?: string;
  /** User's per-book paper color override ('' = use book's defaultTheme). */
  readerTheme?: string;
}

export type BookStatePatch = Partial<
  Pick<Book, 'isFinished' | 'isPriority' | 'readerFont' | 'readerTheme'>
>;

export interface BookAppearanceDefaultsPatch {
  defaultFont?: string;
  defaultTheme?: string;
}

export type HighlightLang = 'en' | 'vi' | 'pdf' | 'epub';

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
  /** JSON anchor for PDF normalized rects or EPUB CFI ranges. */
  anchorJson?: string;
  note: string;
  createdAt: number;
}

export type ViewMode = 'en' | 'vi' | 'split';

/** GET/POST /api/books/:slug/progress. `lastRead` is unix SECONDS (the backend
 * stores `int(time.time())`), absent when the book was never read. */
export interface ReadingProgress {
  page: number;
  viewMode: ViewMode;
  locator?: string;
  progression?: number | null;
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
