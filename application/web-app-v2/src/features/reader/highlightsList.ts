import type { Highlight, HighlightLang, ViewMode } from '@/types/api';

export function sortHighlights(highlights: Highlight[]): Highlight[] {
  return [...highlights].sort(
    (a, b) => a.page - b.page || (a.createdAt || 0) - (b.createdAt || 0) || a.id.localeCompare(b.id),
  );
}

export function filterAndSortHighlights(
  highlights: Highlight[],
  options: { currentPage: number; onlyCurrentPage: boolean },
): Highlight[] {
  const filtered = options.onlyCurrentPage
    ? highlights.filter((h) => h.page === options.currentPage)
    : highlights;
  return sortHighlights(filtered);
}

export function clampReaderPage(target: number, totalPages: number): number {
  const maxPage = Math.max(1, totalPages || 1);
  if (!Number.isFinite(target)) return 1;
  return Math.max(1, Math.min(maxPage, Math.trunc(target)));
}

export function resolveInitialReferenceViewMode(
  mainViewMode: ViewMode,
  highlightLang: HighlightLang,
): ViewMode {
  if (mainViewMode === 'split') return 'split';
  return highlightLang === 'vi' ? 'vi' : 'en';
}

