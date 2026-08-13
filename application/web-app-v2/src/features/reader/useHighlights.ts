import { useCallback, useEffect, useRef, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { apiFetch, apiJson } from '@/lib/api-client';
import type { Highlight, HighlightLang } from '@/types/api';
import { loadHighlights, saveHighlights } from './highlightsStorage';
import {
  reapplyHighlightsInIframes,
  removeAllReaderHighlightUI,
  type SelectionInfo,
} from './iframe/highlightDom';

function generateHighlightId(): string {
  return `hl-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 9)}`;
}

/** Union by id, server winning on conflicts — keeps locally-created highlights
 * that haven't synced yet while applying the server's copy (fixes v1's
 * empty-list clobber, review #5/#11). */
function mergeById(local: Highlight[], server: Highlight[]): Highlight[] {
  const map = new Map<string, Highlight>();
  for (const h of local) map.set(h.id, h);
  for (const h of server) map.set(h.id, h);
  return [...map.values()];
}

const post = (slug: string, h: Highlight) =>
  apiFetch(`/api/books/${encodeURIComponent(slug)}/highlights`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(h),
  }).catch(() => {
    /* offline: local copy persists; server catches up on next successful sync */
  });

/**
 * Highlight state + CRUD for the active book/page. localStorage is the source of
 * truth the imperative DOM layer reads; state mirrors it for React, and the
 * server is written through. A `ref` mirror avoids stale reads when the
 * imperative toolbar fires create/update between renders.
 */
export function useHighlights(slug: string, page: number) {
  const [highlights, setHighlights] = useState<Highlight[]>(() => loadHighlights(slug));
  const ref = useRef(highlights);
  ref.current = highlights;
  const pageRef = useRef(page);
  pageRef.current = page;
  const appliedServerRef = useRef(false);

  const { data: serverData } = useQuery({
    queryKey: ['highlights', slug],
    enabled: !!slug,
    staleTime: Infinity,
    queryFn: () =>
      apiJson<{ highlights?: Highlight[] }>(
        `/api/books/${encodeURIComponent(slug)}/highlights`,
      ).then((r) => r.highlights ?? []),
  });

  // Merge server highlights once, then repaint whatever iframes are open.
  useEffect(() => {
    if (appliedServerRef.current || serverData === undefined) return;
    appliedServerRef.current = true;
    const merged = mergeById(ref.current, serverData);
    saveHighlights(slug, merged);
    setHighlights(merged);
    ref.current = merged;
    reapplyHighlightsInIframes(slug, pageRef.current, 'en');
    reapplyHighlightsInIframes(slug, pageRef.current, 'vi');
  }, [serverData, slug]);

  const commit = useCallback(
    (next: Highlight[], repaint: { page: number; lang: HighlightLang } | null) => {
      ref.current = next;
      saveHighlights(slug, next);
      setHighlights(next);
      if (repaint) reapplyHighlightsInIframes(slug, repaint.page, repaint.lang);
      removeAllReaderHighlightUI();
    },
    [slug],
  );

  const createHighlight = useCallback(
    (info: SelectionInfo, lang: HighlightLang, color: string, note = '') => {
      const h: Highlight = {
        id: generateHighlightId(),
        page: pageRef.current,
        lang,
        color,
        text: info.text,
        startOffset: info.startOffset,
        endOffset: info.endOffset,
        paragraphIndex: info.paragraphIndex,
        note: note || '',
        createdAt: Date.now(),
      };
      commit([...ref.current, h], { page: h.page, lang });
      document
        .querySelectorAll<HTMLIFrameElement>('.reader-iframe')
        .forEach((f) => f.contentWindow?.getSelection()?.removeAllRanges());
      void post(slug, h);
    },
    [commit, slug],
  );

  const updateHighlight = useCallback(
    (id: string, updates: Partial<Highlight>) => {
      const next = ref.current.map((h) => (h.id === id ? { ...h, ...updates } : h));
      const target = next.find((h) => h.id === id);
      commit(next, target ? { page: target.page, lang: target.lang } : null);
      if (target) void post(slug, target);
    },
    [commit, slug],
  );

  const deleteHighlight = useCallback(
    (id: string) => {
      const target = ref.current.find((h) => h.id === id);
      const next = ref.current.filter((h) => h.id !== id);
      commit(next, target ? { page: target.page, lang: target.lang } : null);
      if (target) {
        void apiFetch(`/api/books/${encodeURIComponent(slug)}/highlights/${id}`, {
          method: 'DELETE',
        }).catch(() => {});
      }
    },
    [commit, slug],
  );

  return { highlights, createHighlight, updateHighlight, deleteHighlight };
}
