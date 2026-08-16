/**
 * Local mirror of the user's Voca cards (2.0 capability).
 *
 * `GET /cards` is incremental: we send back the version we already hold and 2.0
 * answers `{changed:false}` with no card payload when nothing moved, so polling
 * costs almost nothing. Reader lookups read this mirror first, which makes the
 * common case instant and keeps us clear of the 120 req/min ceiling — the
 * network lookup is only for words we've never synced.
 */
import { readJSON, writeJSON } from '@/lib/storage';
import { STORAGE_KEYS } from '@/lib/storageKeys';
import { fetchVocaCardsPage, type VocaCard, type VocaLookupResult } from '@/lib/vocaClient';

export interface VocaCardsCache {
  version: string | number;
  cards: VocaCard[];
}

const EMPTY_CACHE: VocaCardsCache = { version: '', cards: [] };

/** A stale mirror only costs one wasted network lookup, so poll gently. */
const SYNC_INTERVAL_MS = 5 * 60_000;

let syncInFlight: Promise<VocaCardsCache> | null = null;
let lastSyncAt = 0;
// Parsed once per session: a whole deck is a lot of JSON to re-parse per lookup.
let memo: VocaCardsCache | null = null;

export function readVocaCards(): VocaCardsCache {
  if (memo) return memo;
  const cached = readJSON<VocaCardsCache>(STORAGE_KEYS.vocaCards, EMPTY_CACHE);
  memo = Array.isArray(cached?.cards) ? cached : EMPTY_CACHE;
  return memo;
}

function writeVocaCards(cache: VocaCardsCache): VocaCardsCache {
  memo = cache;
  writeJSON(STORAGE_KEYS.vocaCards, cache);
  return cache;
}

/**
 * Pull anything that changed since the version we hold. Deduped and throttled:
 * ReaderView calls it on every book open, and several tabs may do so at once.
 */
export function syncVocaCards(options: { force?: boolean } = {}): Promise<VocaCardsCache> {
  if (syncInFlight) return syncInFlight;
  if (!options.force && Date.now() - lastSyncAt < SYNC_INTERVAL_MS) return Promise.resolve(readVocaCards());

  const task = (async () => {
    const current = readVocaCards();
    const page = await fetchVocaCardsPage(current.version);
    lastSyncAt = Date.now();
    // `changed:false` omits `cards` entirely — keep what we have.
    if (!page.changed || !Array.isArray(page.cards)) {
      return page.version != null && page.version !== current.version
        ? writeVocaCards({ ...current, version: page.version })
        : current;
    }
    return writeVocaCards({ version: page.version, cards: page.cards });
  })();

  syncInFlight = task;
  return task.finally(() => {
    if (syncInFlight === task) syncInFlight = null;
  });
}

/** Upsert a single card (after a create) so the next lookup hits the mirror. */
export function rememberVocaCard(card: VocaCard): void {
  if (!card?.word) return;
  const cache = readVocaCards();
  const key = cardKey(card);
  const cards = cache.cards.filter((c) => cardKey(c) !== key);
  cards.push(card);
  writeVocaCards({ ...cache, cards });
}

function cardKey(card: VocaCard): string {
  return String(card?.slug || card?.word || '').toLowerCase();
}

function normalize(value: string): string {
  return String(value || '').trim().toLowerCase();
}

export function findCachedCard(word: string): VocaCard | null {
  const query = normalize(word);
  if (!query) return null;
  return readVocaCards().cards.find((c) => normalize(c.word) === query || normalize(c.slug) === query) ?? null;
}

/**
 * Cache-first lookup. Only an EXACT hit answers locally: a partial miss can't
 * be told apart from "never synced", so those still go to Voca.
 */
export function lookupCachedWord(word: string): VocaLookupResult | null {
  const card = findCachedCard(word);
  if (!card) return null;
  return { found: true, word, matchType: 'exact', card };
}
