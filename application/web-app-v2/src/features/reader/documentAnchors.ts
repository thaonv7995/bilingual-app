/**
 * Cross-platform anchor encoding for PDF & EPUB highlights.
 *
 * Pure & alias-free so `node --test` can exercise it directly.
 * - PDF rects are normalized to [0..1] from top-left of the page so PDF.js (Web)
 *   and PDFKit (iOS/macOS, bottom-left points) map highlights pixel-accurately.
 * - EPUB anchors store canonical EPUB CFI strings shared between Web & WKWebView
 *   (both running foliate-js).
 */

export interface NormalizedRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface PdfHighlightAnchor {
  kind: 'pdf';
  rects: NormalizedRect[];
  prefix?: string;
  suffix?: string;
}

export interface EpubHighlightAnchor {
  kind: 'epub';
  cfi: string;
  chapterTitle?: string;
  href?: string;
  prefix?: string;
  suffix?: string;
}

export type DocumentHighlightAnchor = PdfHighlightAnchor | EpubHighlightAnchor;

function clamp01(v: number): number {
  if (!Number.isFinite(v)) return 0;
  return Math.max(0, Math.min(1, v));
}

function round4(v: number): number {
  return Math.round(clamp01(v) * 10000) / 10000;
}

export function serializeHighlightAnchor(anchor: DocumentHighlightAnchor): string {
  if (anchor.kind === 'pdf') {
    const cleanRects = anchor.rects
      .filter((r) => r.w > 0.0005 && r.h > 0.0005)
      .map((r) => ({
        x: round4(r.x),
        y: round4(r.y),
        w: round4(r.w),
        h: round4(r.h),
      }));
    return JSON.stringify({
      kind: 'pdf',
      rects: cleanRects,
      ...(anchor.prefix ? { prefix: anchor.prefix.slice(-48) } : {}),
      ...(anchor.suffix ? { suffix: anchor.suffix.slice(0, 48) } : {}),
    });
  }
  return JSON.stringify({
    kind: 'epub',
    cfi: anchor.cfi,
    ...(anchor.chapterTitle ? { chapterTitle: anchor.chapterTitle.slice(0, 120) } : {}),
    ...(anchor.href ? { href: anchor.href.slice(0, 256) } : {}),
    ...(anchor.prefix ? { prefix: anchor.prefix.slice(-48) } : {}),
    ...(anchor.suffix ? { suffix: anchor.suffix.slice(0, 48) } : {}),
  });
}

export function parseHighlightAnchor(raw?: string | null): DocumentHighlightAnchor | null {
  if (!raw || typeof raw !== 'string') return null;
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    if (!parsed || typeof parsed !== 'object') return null;
    if (parsed.kind === 'pdf' && Array.isArray(parsed.rects)) {
      const rects: NormalizedRect[] = [];
      for (const item of parsed.rects) {
        if (!item || typeof item !== 'object') continue;
        const r = item as Record<string, unknown>;
        const x = Number(r.x);
        const y = Number(r.y);
        const w = Number(r.w);
        const h = Number(r.h);
        if ([x, y, w, h].every(Number.isFinite) && w > 0 && h > 0) {
          rects.push({ x: clamp01(x), y: clamp01(y), w: clamp01(w), h: clamp01(h) });
        }
      }
      if (rects.length === 0) return null;
      return {
        kind: 'pdf',
        rects,
        prefix: typeof parsed.prefix === 'string' ? parsed.prefix : undefined,
        suffix: typeof parsed.suffix === 'string' ? parsed.suffix : undefined,
      };
    }
    if (parsed.kind === 'epub' && typeof parsed.cfi === 'string' && parsed.cfi.trim()) {
      return {
        kind: 'epub',
        cfi: parsed.cfi.trim(),
        chapterTitle: typeof parsed.chapterTitle === 'string' ? parsed.chapterTitle : undefined,
        href: typeof parsed.href === 'string' ? parsed.href : undefined,
        prefix: typeof parsed.prefix === 'string' ? parsed.prefix : undefined,
        suffix: typeof parsed.suffix === 'string' ? parsed.suffix : undefined,
      };
    }
  } catch {
    /* ignore malformed JSON */
  }
  return null;
}

export interface RectLike {
  left: number;
  top: number;
  width: number;
  height: number;
}

/**
 * Convert DOM client rects inside a rendered PDF page box into merged,
 * normalized [0..1] top-left coordinates.
 */
export function normalizeClientRects(rects: RectLike[], pageBox: RectLike): NormalizedRect[] {
  if (!pageBox || pageBox.width <= 0 || pageBox.height <= 0) return [];
  const raw: NormalizedRect[] = [];
  for (const r of rects) {
    if (r.width < 1 || r.height < 1) continue;
    const x1 = clamp01((r.left - pageBox.left) / pageBox.width);
    const y1 = clamp01((r.top - pageBox.top) / pageBox.height);
    const x2 = clamp01((r.left + r.width - pageBox.left) / pageBox.width);
    const y2 = clamp01((r.top + r.height - pageBox.top) / pageBox.height);
    const w = x2 - x1;
    const h = y2 - y1;
    if (w > 0.001 && h > 0.001) {
      raw.push({ x: round4(x1), y: round4(y1), w: round4(w), h: round4(h) });
    }
  }
  if (raw.length <= 1) return raw;

  // Sort top-to-bottom, left-to-right and coalesce adjacent spans on the same visual line
  raw.sort((a, b) => (Math.abs(a.y - b.y) > 0.006 ? a.y - b.y : a.x - b.x));
  const merged: NormalizedRect[] = [raw[0]!];
  for (let i = 1; i < raw.length; i++) {
    const cur = raw[i]!;
    const prev = merged[merged.length - 1]!;
    const sameLine =
      Math.abs(cur.y - prev.y) < Math.max(prev.h, cur.h) * 0.55 &&
      Math.abs(cur.h - prev.h) < Math.max(prev.h, cur.h) * 0.6;
    const closeHoriz = cur.x <= prev.x + prev.w + 0.012;
    if (sameLine && closeHoriz) {
      const right = Math.max(prev.x + prev.w, cur.x + cur.w);
      const bottom = Math.max(prev.y + prev.h, cur.y + cur.h);
      const top = Math.min(prev.y, cur.y);
      const left = Math.min(prev.x, cur.x);
      merged[merged.length - 1] = {
        x: round4(left),
        y: round4(top),
        w: round4(right - left),
        h: round4(bottom - top),
      };
    } else {
      merged.push(cur);
    }
  }
  return merged;
}

export function resolveBookFormat(format?: string | null): 'bkb' | 'pdf' | 'epub' {
  if (format === 'pdf' || format === 'epub') return format;
  return 'bkb';
}
