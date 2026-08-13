import { readJSON, remove, writeJSON } from '@/lib/storage';
import { STORAGE_KEYS } from '@/lib/storageKeys';
import type { ChatMessage } from './types';

const TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7 days
const PREFIX = 'bilingual.reader.chatHistory.';

export function loadChatHistory(slug: string): ChatMessage[] {
  const data = readJSON<{ messages?: ChatMessage[] } | null>(STORAGE_KEYS.chatHistory(slug), null);
  return data?.messages ?? [];
}

export function saveChatHistory(slug: string, messages: ChatMessage[]): void {
  const clean = messages.filter((m) => !m.pending);
  if (clean.length > 0) {
    writeJSON(STORAGE_KEYS.chatHistory(slug), { messages: clean, lastUpdated: Date.now() });
  } else {
    remove(STORAGE_KEYS.chatHistory(slug));
  }
}

/** Drop chat histories not touched in 7 days (v1 app.js:1391-1423). */
export function cleanupOldChatHistories(): void {
  try {
    const now = Date.now();
    for (const key of Object.keys(localStorage)) {
      if (!key.startsWith(PREFIX)) continue;
      const data = readJSON<{ lastUpdated?: number } | null>(key, null);
      if (data?.lastUpdated && now - data.lastUpdated > TTL_MS) remove(key);
    }
  } catch {
    /* ignore */
  }
}
