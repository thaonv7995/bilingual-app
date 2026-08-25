/**
 * Unit tests for the open-a-book conflict rule
 * (src/features/reader/progressSync.ts): newer lastRead wins, server wins
 * ties, local survives only when strictly newer (then gets pushed up with its
 * original timestamp). Run with `npm test`.
 */
import test from 'node:test';
import assert from 'node:assert/strict';

import { resolveProgressOnOpen } from '../src/features/reader/progressSync.ts';

// Server timestamps are unix SECONDS, local ones epoch MILLISECONDS — exactly
// what the two real callers hold. 2026-01-01 00:00:00 UTC.
const T = 1_767_225_600;
const sec = (offset: number) => T + offset;
const ms = (offset: number) => (T + offset) * 1000;

const localAt = (offset: number, page = 10) => ({ page, viewMode: 'split', lastRead: ms(offset) });
const serverAt = (offset: number, page = 20) => ({ page, viewMode: 'en', lastRead: sec(offset) });

test('server newer than local → adopt the server copy, at the server time', () => {
  const r = resolveProgressOnOpen(localAt(0), serverAt(60));
  assert.equal(r.action, 'adopt');
  assert.equal(r.action === 'adopt' && r.progress.page, 20);
  assert.equal(r.action === 'adopt' && r.lastReadMs, ms(60));
});

test('exact tie → server wins (same rule as iOS)', () => {
  const r = resolveProgressOnOpen(localAt(0), serverAt(0));
  assert.equal(r.action, 'adopt');
});

test('local strictly newer → push the local copy with its ORIGINAL timestamp', () => {
  const r = resolveProgressOnOpen(localAt(60), serverAt(0));
  assert.equal(r.action, 'pushLocal');
  assert.equal(r.action === 'pushLocal' && r.progress.page, 10);
  assert.equal(r.action === 'pushLocal' && r.lastReadMs, ms(60));
});

test('no local copy → adopt whatever the server has', () => {
  const r = resolveProgressOnOpen(null, serverAt(0));
  assert.equal(r.action, 'adopt');
});

test('server never read (no lastRead) → any local copy survives and is pushed', () => {
  const r = resolveProgressOnOpen(localAt(0), { page: 1, viewMode: 'en' });
  assert.equal(r.action, 'pushLocal');
});

test('legacy local with no timestamp still beats an empty server, timestamp left for the saver to stamp', () => {
  const r = resolveProgressOnOpen({ page: 30, viewMode: 'split' }, { page: 1, viewMode: 'en' });
  assert.equal(r.action, 'pushLocal');
  assert.equal(r.action === 'pushLocal' && r.progress.page, 30);
  assert.equal(r.action === 'pushLocal' && r.lastReadMs, undefined);
});

test('legacy local with no timestamp loses to a server copy that HAS one', () => {
  const r = resolveProgressOnOpen({ page: 30, viewMode: 'split' }, serverAt(0));
  assert.equal(r.action, 'adopt');
});

test('no local and no server record → none', () => {
  assert.equal(resolveProgressOnOpen(null, { page: 1, viewMode: 'en' }).action, 'none');
  assert.equal(resolveProgressOnOpen(null, { page: 1, viewMode: 'en', lastRead: null }).action, 'none');
  assert.equal(resolveProgressOnOpen(null, null).action, 'none');
});
