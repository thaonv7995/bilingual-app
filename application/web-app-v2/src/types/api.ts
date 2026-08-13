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

/** GET /api/books item. */
export interface Book {
  slug: string;
  title: string;
  author: string;
  pageCount: number;
  cover: string | null;
  isPublished: boolean;
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

/** GET/POST /api/books/:slug/progress. */
export interface ReadingProgress {
  page: number;
  viewMode: ViewMode;
  lastRead?: string;
}

/** GET /api/books/:slug/manifest. */
export interface BookManifest {
  files: string[];
}

/** FastAPI error body. `detail` may be a string or a validation-error array. */
export interface ApiErrorBody {
  detail?: string | Array<{ msg?: string; [k: string]: unknown }>;
}
