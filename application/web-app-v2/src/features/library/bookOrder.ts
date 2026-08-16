/**
 * Canonical library shelf order — the single definition the web app sorts by,
 * mirrored by the backend (`list_books._shelf_key` in api/routes/books.py) and
 * by iOS (`BookshelfView.sortedBooks`). Point at THIS file in review.
 *
 * The rule, in two tiers:
 *
 *   tier 1 — books the user HAS read (lastRead > 0), most recently read first
 *   tier 2 — books never read, most recently imported first (createdAt DESC)
 *
 * Tier 1 always sits above tier 2, so reading any book moves it to position 1.
 * Reading activity beats import recency; this is deliberately NOT the
 * max(createdAt, lastRead) blend iOS used to do — a book read five minutes ago
 * outranks a book imported one minute ago.
 *
 * Ties inside a tier break on createdAt DESC, then id DESC (id is autoincrement,
 * i.e. import order), then slug ASC. The order is therefore total: it never
 * depends on what the database, or the network, happened to hand us.
 *
 * Everything here is pure — no localStorage, no React, no clock — so it can be
 * unit-tested directly (see tests/bookOrder.test.ts).
 */

/**
 * The only fields the order looks at. Structural on purpose, so `Book` (and any
 * future row shape) satisfies it with no conversion step.
 */
export interface BookOrderFields {
  slug: string;
  /** Autoincrement row id == import order. Optional: /api/books doesn't send it today. */
  id?: number | null;
  /** Import time, unix seconds from the server (null on rows imported before the column existed). */
  createdAt?: number | null;
  /** Last-read time. For sorting this must be the EFFECTIVE value — see `effectiveLastRead`. */
  lastRead?: number | null;
}

/**
 * Boundary between unix SECONDS and MILLISECONDS. 1e11 ms is 1973-03-03 and
 * 1e11 s is the year 5138, so no timestamp this app can see is ambiguous.
 * We need this because the server stores seconds (`int(time.time())`) while the
 * local progress cache stores `Date.now()` in ms — comparing them raw would make
 * every locally-read book beat every server-read one.
 */
const MS_CUTOFF = 1e11;

/** Normalise a timestamp to epoch milliseconds. Junk, null and non-positive → 0. */
export function toEpochMs(value: number | null | undefined): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return 0;
  return value < MS_CUTOFF ? value * 1000 : value;
}

/**
 * Merge the two sources of "when did the user last read this": the server copy
 * that arrived with the book list, and the local cache written by the reader.
 * The local one can be NEWER than the server's (saved while offline, or before
 * the debounced POST landed), hence max() rather than a preference order.
 * Returns epoch milliseconds; 0 means "never read" (tier 2).
 */
export function effectiveLastRead(
  serverLastRead: number | null | undefined,
  localLastRead: number | null | undefined,
): number {
  return Math.max(toEpochMs(serverLastRead), toEpochMs(localLastRead));
}

function idOf(book: BookOrderFields): number {
  return typeof book.id === 'number' && Number.isFinite(book.id) ? book.id : 0;
}

/**
 * Comparator for `Array.prototype.sort`. `lastRead` on both sides must already
 * be the effective value (`effectiveLastRead`) — `sortBooks` does that for you.
 */
export function compareBooks(a: BookOrderFields, b: BookOrderFields): number {
  const aRead = toEpochMs(a.lastRead);
  const bRead = toEpochMs(b.lastRead);

  // Tier: read books above never-read books, whatever the timestamps say.
  const aTier = aRead > 0 ? 0 : 1;
  const bTier = bRead > 0 ? 0 : 1;
  if (aTier !== bTier) return aTier - bTier;

  // Tier 1: most recently read first. (Both are 0 inside tier 2.)
  if (aRead !== bRead) return bRead - aRead;

  // Tier 2 (and read-at-the-same-instant ties): newest import first.
  const aCreated = toEpochMs(a.createdAt);
  const bCreated = toEpochMs(b.createdAt);
  if (aCreated !== bCreated) return bCreated - aCreated;

  // Deterministic tail: import order, then slug. Carries rows with no createdAt.
  const aId = idOf(a);
  const bId = idOf(b);
  if (aId !== bId) return bId - aId;

  if (a.slug < b.slug) return -1;
  if (a.slug > b.slug) return 1;
  return 0;
}

/**
 * Order a shelf. Returns a new array; the input is not mutated.
 *
 * `getLocalLastRead` supplies the client-side half of `effectiveLastRead` (the
 * reader's local progress cache). Pass it in rather than reading storage here so
 * this module stays pure and testable.
 */
export function sortBooks<T extends BookOrderFields>(
  books: readonly T[],
  getLocalLastRead: (book: T) => number | null | undefined = () => null,
): T[] {
  return books
    .map((book) => ({
      book,
      key: {
        slug: book.slug,
        id: book.id,
        createdAt: book.createdAt,
        lastRead: effectiveLastRead(book.lastRead, getLocalLastRead(book)),
      } satisfies BookOrderFields,
    }))
    .sort((a, b) => compareBooks(a.key, b.key))
    .map((entry) => entry.book);
}
