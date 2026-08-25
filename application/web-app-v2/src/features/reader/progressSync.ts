/**
 * The unified open-a-book conflict rule, shared in spirit with iOS
 * (`ReaderView.loadProgress`) and enforced server-side by
 * POST /api/books/:slug/progress (newest `lastRead` wins):
 *
 *   - The backend is the source of trust when opening a book: its copy is
 *     adopted whenever its `lastRead` is at least as new as the local one
 *     (server wins ties).
 *   - The local copy survives only when it is STRICTLY newer — i.e. a save the
 *     server never received (offline, lost debounce) — and is then pushed up
 *     with its ORIGINAL timestamp, never re-stamped: opening a book is not a
 *     reading action.
 *   - A server response with no `lastRead` means "never read anywhere"; any
 *     local copy (even a legacy one with no timestamp) beats it.
 *
 * Pure and alias-free so `npm test` (node --test) can exercise it directly —
 * see tests/progressSync.test.ts.
 */
import { toEpochMs } from '../library/bookOrder.ts';

/** The fields the rule looks at. Structural so both `LocalProgress` (lastRead
 * in epoch ms) and the server's `ReadingProgress` (unix seconds) satisfy it —
 * `toEpochMs` normalises the units. */
export interface ProgressStamp {
  page: number;
  viewMode: string;
  lastRead?: number | null;
}

export type OpenResolution<L extends ProgressStamp, S extends ProgressStamp> =
  /** Server copy is authoritative: apply it, cache it locally with the
   * server's own timestamp (`lastReadMs`), send nothing. */
  | { action: 'adopt'; progress: S; lastReadMs: number }
  /** Local copy is strictly newer than what the server knows: keep it and
   * POST it up with its original timestamp (undefined = legacy entry with no
   * timestamp; the saver stamps "now" for those). */
  | { action: 'pushLocal'; progress: L; lastReadMs: number | undefined }
  /** Nothing anywhere: stay on the defaults. */
  | { action: 'none' };

export function resolveProgressOnOpen<L extends ProgressStamp, S extends ProgressStamp>(
  local: L | null | undefined,
  server: S | null | undefined,
): OpenResolution<L, S> {
  const serverMs = toEpochMs(server?.lastRead);
  const localMs = toEpochMs(local?.lastRead);

  if (server && serverMs > 0 && serverMs >= localMs) {
    return { action: 'adopt', progress: server, lastReadMs: serverMs };
  }
  if (local) {
    return { action: 'pushLocal', progress: local, lastReadMs: localMs > 0 ? localMs : undefined };
  }
  return { action: 'none' };
}
