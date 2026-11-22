import { View } from 'foliate-js/view.js';
import { Overlayer } from 'foliate-js/overlayer.js';

if (!customElements.get('foliate-view')) {
  customElements.define('foliate-view', View);
}

function post(payload) {
  try {
    window.webkit?.messageHandlers?.epubBridge?.postMessage(payload);
  } catch (err) {
    console.warn('[BilingualEpub] bridge post failed:', err);
  }
}

let view = null;
let currentHighlights = [];
let currentAppearance = {
  fontFamily: '"Iowan Old Style", "Palatino Linotype", Georgia, serif',
  googleFontUrl: '',
  fontScale: 100,
  lineHeight: '1.68',
  marginPct: '6%',
  paper: '#fcfbf7',
  ink: '#1f2328',
  isDark: false,
  flow: 'paginated',
  maxColumns: 2,
};
let activeChapterTitle = '';
let activeVisibleText = '';
let activeEstimatedPage = 1;
let totalVirtualPages = 1;

function buildCss(a) {
  const linkColor = a.isDark ? '#7dd3fc' : '#2563eb';
  const fontSizePx = Math.round(17 * ((a.fontScale || 100) / 100));
  return `
    @namespace epub "http://www.idpf.org/2007/ops";
    html {
      color-scheme: ${a.isDark ? 'dark' : 'light'};
      background-color: ${a.paper} !important;
      color: ${a.ink} !important;
      font-size: ${fontSizePx}px !important;
      -webkit-font-smoothing: antialiased;
    }
    body {
      background-color: ${a.paper} !important;
      color: ${a.ink} !important;
      font-family: ${a.fontFamily} !important;
      line-height: ${a.lineHeight} !important;
      text-align: justify;
      hyphens: auto;
      -webkit-hyphens: auto;
    }
    p, li, blockquote, dd, dt, div, span {
      font-family: ${a.fontFamily};
      line-height: ${a.lineHeight};
      color: inherit;
    }
    h1, h2, h3, h4, h5, h6 {
      font-family: ${a.fontFamily} !important;
      color: ${a.ink} !important;
      text-align: left;
      break-after: avoid;
    }
    a, a:visited { color: ${linkColor} !important; }
    img, svg { max-width: 100% !important; height: auto !important; }
  `;
}

function injectFontLink(doc, url) {
  const head = doc?.head || doc?.documentElement;
  if (!head) return;
  const existing = doc.getElementById('bilingual-epub-font-link');
  if (url) {
    if (existing) {
      if (existing.href !== url) existing.href = url;
    } else {
      const link = doc.createElement('link');
      link.id = 'bilingual-epub-font-link';
      link.rel = 'stylesheet';
      link.href = url;
      head.appendChild(link);
    }
  } else if (existing) {
    existing.remove();
  }
}

function applyAppearanceToView() {
  document.documentElement.style.backgroundColor = currentAppearance.paper;
  document.body.style.backgroundColor = currentAppearance.paper;
  if (!view?.renderer) return;
  const r = view.renderer;
  r.setAttribute('flow', currentAppearance.flow || 'paginated');
  r.setAttribute('gap', currentAppearance.marginPct || '6%');
  r.setAttribute('max-inline-size', currentAppearance.maxColumns > 1 ? '720px' : '820px');
  r.setAttribute('max-column-count', String(currentAppearance.maxColumns || 1));
  r.setStyles?.(buildCss(currentAppearance));
  for (const c of r.getContents?.() ?? []) {
    if (c.doc) injectFontLink(c.doc, currentAppearance.googleFontUrl);
  }
}

function toHostRect(doc, localRect) {
  const frame = doc?.defaultView?.frameElement;
  if (!frame) {
    return {
      x: localRect.left,
      y: localRect.top,
      width: localRect.width,
      height: localRect.height,
    };
  }
  const fb = frame.getBoundingClientRect();
  return {
    x: fb.left + localRect.left,
    y: fb.top + localRect.top,
    width: localRect.width,
    height: localRect.height,
  };
}

function flattenToc(items, level = 0, out = []) {
  for (const item of items || []) {
    if (out.length >= 600) break;
    out.push({
      label: (item.label || 'Chapter').trim(),
      href: item.href || '',
      level,
    });
    if (item.subitems?.length) flattenToc(item.subitems, level + 1, out);
  }
  return out;
}

async function syncHighlights() {
  if (!view) return;
  for (const hl of currentHighlights) {
    if (hl.cfi) {
      try {
        await view.addAnnotation({ value: hl.cfi });
      } catch {
        /* ignore */
      }
    }
  }
}

function extractSelectionFromDoc(doc, index) {
  const sel = doc?.defaultView?.getSelection?.();
  const text = sel?.toString().trim() || '';
  if (!sel || sel.isCollapsed || text.length < 1 || !view) return;
  try {
    const range = sel.getRangeAt(0);
    const cfi = view.getCFI(index, range);
    const rect = toHostRect(doc, range.getBoundingClientRect());
    post({
      type: 'textSelected',
      cfi,
      text,
      chapterTitle: activeChapterTitle,
      page: activeEstimatedPage,
      rect,
    });
  } catch {
    /* ignore */
  }
}

async function openBlob(blob, lastLocation, estimatedTotalPages) {
  const host = document.getElementById('epub-root');
  if (!host) return;
  if (view) {
    try {
      view.close();
    } catch {
      /* ignore */
    }
  }
  host.innerHTML = '';
  totalVirtualPages = Math.max(1, Number(estimatedTotalPages) || 1);

  view = document.createElement('foliate-view');
  host.appendChild(view);

  view.addEventListener('relocate', (ev) => {
    const d = ev.detail || {};
    const fraction = typeof d.fraction === 'number' ? d.fraction : 0;
    const total = d.location?.total || totalVirtualPages;
    const current =
      d.location?.current != null
        ? Math.max(1, d.location.current + 1)
        : Math.max(1, Math.round(fraction * total));
    activeEstimatedPage = current;
    totalVirtualPages = total;
    if (d.tocItem?.label) activeChapterTitle = d.tocItem.label.trim();

    try {
      const txt = d.range?.toString().replace(/\s+/g, ' ').trim();
      if (txt && txt.length > 20) {
        activeVisibleText = txt.slice(0, 6000);
      } else {
        const doc = view?.renderer?.getContents?.()?.[0]?.doc;
        activeVisibleText = (doc?.body?.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 6000);
      }
    } catch {
      /* ignore */
    }

    post({
      type: 'relocate',
      cfi: d.cfi || '',
      fraction,
      page: current,
      totalPages: total,
      chapterTitle: activeChapterTitle,
      chapterHref: d.tocItem?.href || '',
      visibleText: activeVisibleText,
    });
  });

  view.addEventListener('load', (ev) => {
    const { doc, index } = ev.detail || {};
    if (!doc) return;
    injectFontLink(doc, currentAppearance.googleFontUrl);

    let selTimer = null;
    const scheduleSelectionCheck = () => {
      clearTimeout(selTimer);
      selTimer = setTimeout(() => extractSelectionFromDoc(doc, index), 140);
    };

    doc.addEventListener('mouseup', () => scheduleSelectionCheck());
    doc.addEventListener('touchend', () => scheduleSelectionCheck());
    doc.addEventListener('selectionchange', () => {
      const sel = doc.defaultView?.getSelection?.();
      if (!sel || sel.isCollapsed) {
        post({ type: 'selectionCleared' });
      } else {
        scheduleSelectionCheck();
      }
    });

    doc.addEventListener('click', (e) => {
      const target = e.target;
      if (target?.closest?.('a, button, input, textarea')) return;
      const sel = doc.defaultView?.getSelection?.();
      if (sel && !sel.isCollapsed && sel.toString().trim().length > 0) return;

      const frame = doc.defaultView?.frameElement;
      const fb = frame ? frame.getBoundingClientRect() : { left: 0, width: window.innerWidth };
      const clientX = fb.left + e.clientX;
      const ratio = clientX / Math.max(window.innerWidth, 1);
      if (currentAppearance.flow !== 'scrolled') {
        if (ratio < 0.2) {
          view?.prev();
          return;
        }
        if (ratio > 0.8) {
          view?.next();
          return;
        }
      }
      post({ type: 'tapCenter' });
    });

    doc.addEventListener('keydown', (ke) => {
      if (ke.key === 'ArrowRight' || ke.key === 'PageDown') {
        ke.preventDefault();
        view?.next();
      } else if (ke.key === 'ArrowLeft' || ke.key === 'PageUp') {
        ke.preventDefault();
        view?.prev();
      }
    });
  });

  view.addEventListener('draw-annotation', (ev) => {
    const { draw, annotation } = ev.detail || {};
    const hl = currentHighlights.find((h) => h.cfi === annotation?.value);
    draw?.(Overlayer.highlight, { color: hl?.color || '#fde047' });
  });

  view.addEventListener('create-overlay', () => {
    void syncHighlights();
  });

  view.addEventListener('show-annotation', (ev) => {
    const { value, range } = ev.detail || {};
    const hl = currentHighlights.find((h) => h.cfi === value);
    if (!hl || !range) return;
    const doc = range.startContainer?.ownerDocument;
    const rect = doc ? toHostRect(doc, range.getBoundingClientRect()) : { x: 200, y: 200, width: 40, height: 20 };
    post({
      type: 'highlightClicked',
      id: hl.id,
      cfi: hl.cfi,
      rect,
    });
  });

  const file = new File([blob], 'book.epub', { type: 'application/epub+zip' });
  await view.open(file);
  applyAppearanceToView();
  await view.init({
    lastLocation: lastLocation || undefined,
    showTextStart: !lastLocation,
  });
  await syncHighlights();

  post({
    type: 'ready',
    toc: flattenToc(view.book?.toc ?? []),
    title: view.book?.metadata?.title || '',
  });
}

window.BilingualEpub = {
  async openFromUrl(url, token, lastLocation, estimatedTotalPages) {
    try {
      const headers = token ? { Authorization: `Bearer ${token}` } : {};
      const res = await fetch(url, { headers });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const blob = await res.blob();
      await openBlob(blob, lastLocation, estimatedTotalPages);
    } catch (err) {
      post({ type: 'error', message: String(err?.message || err) });
    }
  },
  async openFromBase64(b64, lastLocation, estimatedTotalPages) {
    try {
      const bin = atob(b64);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      const blob = new Blob([bytes], { type: 'application/epub+zip' });
      await openBlob(blob, lastLocation, estimatedTotalPages);
    } catch (err) {
      post({ type: 'error', message: String(err?.message || err) });
    }
  },
  next() {
    return view?.next();
  },
  prev() {
    return view?.prev();
  },
  goTo(target) {
    return view?.goTo(target);
  },
  goToFraction(f) {
    return view?.goToFraction(Number(f) || 0);
  },
  setAppearance(patch) {
    currentAppearance = { ...currentAppearance, ...(patch || {}) };
    applyAppearanceToView();
  },
  async setHighlights(list) {
    const oldCfis = new Set(currentHighlights.map((h) => h.cfi).filter(Boolean));
    currentHighlights = Array.isArray(list) ? list : [];
    const newCfis = new Set(currentHighlights.map((h) => h.cfi).filter(Boolean));
    if (view) {
      for (const oldCfi of oldCfis) {
        if (!newCfis.has(oldCfi)) {
          try {
            await view.deleteAnnotation({ value: oldCfi });
          } catch {
            /* ignore */
          }
        }
      }
      await syncHighlights();
    }
  },
  clearSelection() {
    for (const c of view?.renderer?.getContents?.() ?? []) {
      c.doc?.defaultView?.getSelection?.()?.removeAllRanges();
    }
  },
  getPageContext() {
    let selected = '';
    for (const c of view?.renderer?.getContents?.() ?? []) {
      const s = c.doc?.defaultView?.getSelection?.()?.toString().trim();
      if (s) {
        selected = s;
        break;
      }
    }
    return JSON.stringify({
      chapterTitle: activeChapterTitle,
      visibleText: activeVisibleText,
      selectedText: selected,
      page: activeEstimatedPage,
    });
  },
  async search(query) {
    if (!view || !query?.trim()) {
      post({ type: 'searchResults', results: [] });
      return;
    }
    const results = [];
    try {
      for await (const res of view.search({ query: query.trim() })) {
        if (res.subitems?.length) {
          for (const sub of res.subitems) {
            results.push({
              cfi: sub.cfi,
              label: res.label || '',
              pre: sub.excerpt?.pre || '',
              match: sub.excerpt?.match || '',
              post: sub.excerpt?.post || '',
            });
            if (results.length >= 50) break;
          }
        } else if (res.cfi) {
          results.push({
            cfi: res.cfi,
            label: res.label || '',
            pre: res.excerpt?.pre || '',
            match: res.excerpt?.match || '',
            post: res.excerpt?.post || '',
          });
        }
        if (results.length >= 50) break;
      }
    } catch {
      /* ignore */
    }
    post({ type: 'searchResults', results });
  },
};
