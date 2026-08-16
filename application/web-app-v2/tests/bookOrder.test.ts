/**
 * Unit tests for the canonical shelf order (src/features/library/bookOrder.ts).
 *
 * Run with `npm test` — Node's built-in test runner executes the TypeScript
 * directly (native type stripping), so this costs the project no dependency and
 * no build step. Lives outside src/ so it stays out of the app's tsc program
 * and out of the bundle.
 */
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  compareBooks,
  effectiveLastRead,
  sortBooks,
  toEpochMs,
  type BookOrderFields,
} from '../src/features/library/bookOrder.ts';

const slugs = (books: BookOrderFields[]) => books.map((b) => b.slug);

/** Shorthand: a book row as /api/books sends it (unix SECONDS or null). */
function book(
  slug: string,
  fields: { id?: number | null; createdAt?: number | null; lastRead?: number | null } = {},
): BookOrderFields {
  return { slug, ...fields };
}

test('tier 2: never-read books order by import time, newest first', () => {
  const shelf = [
    book('oldest', { createdAt: 1_000 }),
    book('newest', { createdAt: 3_000 }),
    book('middle', { createdAt: 2_000 }),
  ];
  assert.deepEqual(slugs(sortBooks(shelf)), ['newest', 'middle', 'oldest']);
});

test('tier 1: read books order by lastRead, most recent first', () => {
  const shelf = [
    book('read-a-while-ago', { createdAt: 9_000, lastRead: 1_000 }),
    book('read-just-now', { createdAt: 1_000, lastRead: 5_000 }),
    book('read-yesterday', { createdAt: 5_000, lastRead: 3_000 }),
  ];
  assert.deepEqual(slugs(sortBooks(shelf)), ['read-just-now', 'read-yesterday', 'read-a-while-ago']);
});

test('tier 1 always sits above tier 2, even when the unread book is newer', () => {
  const shelf = [
    book('imported-one-minute-ago', { createdAt: 10_000 }),
    book('read-five-minutes-ago', { createdAt: 1, lastRead: 9_700 }),
  ];
  // The rule is NOT max(createdAt, lastRead): reading activity wins outright.
  assert.deepEqual(slugs(sortBooks(shelf)), ['read-five-minutes-ago', 'imported-one-minute-ago']);
});

test('reading any book moves it to position 1', () => {
  const shelf = [
    book('a', { id: 3, createdAt: 3_000 }),
    book('b', { id: 2, createdAt: 2_000 }),
    book('c', { id: 1, createdAt: 1_000 }),
  ];
  assert.deepEqual(slugs(sortBooks(shelf)), ['a', 'b', 'c']);

  // The oldest import, just read, jumps over both newer imports.
  const afterReadingC = shelf.map((b) => (b.slug === 'c' ? { ...b, lastRead: 4_000 } : b));
  assert.deepEqual(slugs(sortBooks(afterReadingC)), ['c', 'a', 'b']);
});

test('ties break on id DESC then slug ASC, never on input order', () => {
  const shelf = [
    book('zulu', { id: 1, createdAt: 1_000 }),
    book('alpha', { id: 1, createdAt: 1_000 }),
    book('bravo', { id: 7, createdAt: 1_000 }),
  ];
  assert.deepEqual(slugs(sortBooks(shelf)), ['bravo', 'alpha', 'zulu']);

  // Same shelf shuffled must produce the same order (total order, no ambiguity).
  const shuffled = [shelf[1]!, shelf[2]!, shelf[0]!];
  assert.deepEqual(slugs(sortBooks(shuffled)), ['bravo', 'alpha', 'zulu']);
});

test('ties inside tier 1 fall through the same tail', () => {
  const shelf = [
    book('b', { id: 1, createdAt: 5_000, lastRead: 8_000 }),
    book('a', { id: 9, createdAt: 5_000, lastRead: 8_000 }),
    book('c', { id: 4, createdAt: 6_000, lastRead: 8_000 }),
  ];
  assert.deepEqual(slugs(sortBooks(shelf)), ['c', 'a', 'b']);
});

test('null / undefined / junk timestamps are treated as "unknown", not as now', () => {
  const shelf = [
    book('no-timestamps-low-id', { id: 2 }),
    book('no-timestamps-high-id', { id: 8 }),
    book('null-created', { id: 5, createdAt: null, lastRead: null }),
    book('has-created', { id: 1, createdAt: 500 }),
  ];
  // A real createdAt outranks every row that has none; those fall to id DESC.
  assert.deepEqual(slugs(sortBooks(shelf)), [
    'has-created',
    'no-timestamps-high-id',
    'null-created',
    'no-timestamps-low-id',
  ]);

  // A null/0/negative lastRead means never read — tier 2, not "read at epoch".
  assert.deepEqual(
    slugs(sortBooks([book('unread', { lastRead: 0, createdAt: 1 }), book('read', { lastRead: 5 })])),
    ['read', 'unread'],
  );
});

test('toEpochMs normalises seconds to milliseconds and rejects junk', () => {
  assert.equal(toEpochMs(1_700_000_000), 1_700_000_000_000); // unix seconds -> ms
  assert.equal(toEpochMs(1_700_000_000_000), 1_700_000_000_000); // already ms, untouched
  assert.equal(toEpochMs(null), 0);
  assert.equal(toEpochMs(undefined), 0);
  assert.equal(toEpochMs(0), 0);
  assert.equal(toEpochMs(-5), 0);
  assert.equal(toEpochMs(NaN), 0);
  assert.equal(toEpochMs(Infinity), 0);
});

test('effectiveLastRead takes the newer of server and local across units', () => {
  const serverSeconds = 1_700_000_000; // == 1_700_000_000_000 ms
  const localMsNewer = 1_700_000_060_000; // one minute later, saved offline
  const localMsOlder = 1_699_999_940_000;

  assert.equal(effectiveLastRead(serverSeconds, localMsNewer), localMsNewer);
  assert.equal(effectiveLastRead(serverSeconds, localMsOlder), 1_700_000_000_000);
  assert.equal(effectiveLastRead(serverSeconds, null), 1_700_000_000_000);
  assert.equal(effectiveLastRead(null, localMsNewer), localMsNewer);
  assert.equal(effectiveLastRead(null, null), 0);
});

test('local progress can outrank the server list without a refetch', () => {
  // Server thinks "a" was read last; the user has since read "c" offline.
  const shelf = [
    book('a', { id: 1, createdAt: 100, lastRead: 1_700_000_000 }),
    book('b', { id: 2, createdAt: 200 }),
    book('c', { id: 3, createdAt: 300 }),
  ];
  const localLastRead: Record<string, number | undefined> = { c: 1_700_000_060_000 };

  assert.deepEqual(slugs(sortBooks(shelf, (b) => localLastRead[b.slug])), ['c', 'a', 'b']);
});

test('sortBooks does not mutate its input and preserves the caller item type', () => {
  const shelf = [
    { slug: 'b', title: 'B', createdAt: 1 },
    { slug: 'a', title: 'A', createdAt: 2 },
  ];
  const sorted = sortBooks(shelf);
  assert.deepEqual(slugs(shelf), ['b', 'a']); // untouched
  assert.deepEqual(slugs(sorted), ['a', 'b']);
  assert.equal(sorted[0]!.title, 'A'); // extra fields survive
  assert.equal(sorted[0], shelf[1]); // same object, not a copy
});

test('compareBooks is antisymmetric and returns 0 only for identical keys', () => {
  const a = book('a', { id: 1, createdAt: 10, lastRead: 20 });
  const b = book('b', { id: 2, createdAt: 30 });
  assert.ok(compareBooks(a, b) < 0);
  assert.ok(compareBooks(b, a) > 0);
  assert.equal(compareBooks(a, { ...a }), 0);
});
