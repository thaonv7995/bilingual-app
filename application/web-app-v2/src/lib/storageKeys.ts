/** Central registry of localStorage keys, matching v1's namespacing so a user's
 * existing saved progress/highlights/settings carry over to v2 unchanged. */
export const STORAGE_KEYS = {
  progress: (slug: string) => `bilingual.reader.progress.${slug}`,
  highlights: (slug: string) => `bilingual.reader.highlights.${slug}`,
  chatHistory: (slug: string) => `bilingual.reader.chatHistory.${slug}`,
  settings: 'bilingual.reader.settings',
  viewMode: 'bilingual.reader.viewMode',
  zoomMode: 'bilingual.reader.zoomMode',
  zoomScale: 'bilingual.reader.zoomScale',
  chatOpen: 'bilingual.reader.chatOpen',
  chatWidth: 'bilingual.reader.chatWidth',
  layoutMode: 'bilingual.reader.layoutMode',
  bookCachePrefix: 'bilingual.reader.bookCache.',
} as const;
