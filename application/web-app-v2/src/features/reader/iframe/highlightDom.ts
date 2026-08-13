/**
 * Imperative highlight layer that manipulates a book-page iframe document —
 * ported from v1 (app.js:4161-4550). Framework-agnostic: it reads/writes the
 * iframe DOM and calls back into React through a module-level typed context
 * (the v2 replacement for v1's `highlightAppContext` global), which ReaderView
 * refreshes every render so callbacks never see stale page/highlight state.
 */
import type { Highlight, HighlightLang } from '@/types/api';
import { HIGHLIGHT_COLORS, setToolbarIcon } from '../highlightColors';
import { loadHighlights } from '../highlightsStorage';
import { getParagraphs, segmentDocSentences } from './segmentation';

export interface SelectionInfo {
  paragraphIndex: number;
  startOffset: number;
  endOffset: number;
  text: string;
}

export interface HighlightContext {
  slug: string;
  page: number;
  createHighlight: (info: SelectionInfo, lang: HighlightLang, color: string, note?: string) => void;
  updateHighlight: (id: string, updates: Partial<Highlight>) => void;
  deleteHighlight: (id: string) => void;
  /** Voca lookup (Phase 5). Receives the raw selected text + anchor. */
  onLookup?: (text: string, doc: Document, anchorRect: DOMRect) => void;
}

let currentContext: HighlightContext | null = null;
export function setHighlightContext(ctx: HighlightContext | null): void {
  currentContext = ctx;
}

// -- selection + wrapping ----------------------------------------------------

export function getSelectionInfo(doc: Document, selection: Selection | null): SelectionInfo | null {
  if (!selection || selection.isCollapsed) return null;
  if (!selection.toString().trim()) return null;

  const range = selection.getRangeAt(0);
  let container: Node | null = range.commonAncestorContainer;
  if (container.nodeType === 3) container = container.parentElement;
  const paragraph = (container as Element | null)?.closest(
    'p, .chapter-start, .no-indent, h1, h2, h3, h4, h5, h6, li, blockquote, .section-title, .action-header, .action-title',
  );
  if (!paragraph) return null;

  const paragraphIndex = getParagraphs(doc).indexOf(paragraph as HTMLElement);
  if (paragraphIndex === -1) return null;

  const preRange = doc.createRange();
  preRange.selectNodeContents(paragraph);
  preRange.setEnd(range.startContainer, range.startOffset);
  const startOffset = preRange.toString().length;
  const endOffset = startOffset + range.toString().length;
  return { paragraphIndex, startOffset, endOffset, text: range.toString() };
}

export function wrapTextRange(
  doc: Document,
  paragraph: HTMLElement,
  startOffset: number,
  endOffset: number,
  data: Pick<Highlight, 'id' | 'color' | 'note'>,
): boolean {
  const walker = doc.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
  let charCount = 0;
  let startNode: Node | null = null;
  let startNodeOffset = 0;
  let endNode: Node | null = null;
  let endNodeOffset = 0;

  while (walker.nextNode()) {
    const node = walker.currentNode;
    const nodeLen = (node.textContent || '').length;
    if (startNode === null && charCount + nodeLen > startOffset) {
      startNode = node;
      startNodeOffset = startOffset - charCount;
    }
    if (endNode === null && charCount + nodeLen >= endOffset) {
      endNode = node;
      endNodeOffset = endOffset - charCount;
      break;
    }
    charCount += nodeLen;
  }
  if (!startNode || !endNode) return false;

  const range = doc.createRange();
  range.setStart(startNode, startNodeOffset);
  range.setEnd(endNode, endNodeOffset);

  const mark = doc.createElement('mark');
  mark.className = 'reader-highlight';
  mark.dataset.highlightId = data.id;
  mark.style.backgroundColor = data.color;
  if (data.note) {
    mark.dataset.hasNote = 'true';
    mark.title = data.note;
  }
  try {
    range.surroundContents(mark);
  } catch {
    mark.appendChild(range.extractContents());
    range.insertNode(mark);
  }
  return true;
}

export function applyStoredHighlights(
  doc: Document,
  slug: string,
  pageNum: number,
  lang: HighlightLang,
): void {
  const highlights = loadHighlights(slug)
    .filter((h) => h.page === pageNum && h.lang === lang)
    .sort((a, b) =>
      a.paragraphIndex !== b.paragraphIndex
        ? a.paragraphIndex - b.paragraphIndex
        : b.startOffset - a.startOffset,
    );
  const paragraphs = getParagraphs(doc);
  highlights.forEach((h) => {
    const paragraph = paragraphs[h.paragraphIndex];
    if (paragraph) wrapTextRange(doc, paragraph, h.startOffset, h.endOffset, h);
  });
}

export function reapplyHighlightsInIframes(slug: string, pageNum: number, lang: HighlightLang): void {
  const selector = lang === 'en' ? '.en-pane-iframe' : '.vi-pane-iframe';
  const iframe = document.querySelector<HTMLIFrameElement>(selector);
  const doc = iframe?.contentDocument;
  if (!doc) return;
  removeReaderHighlightUI(doc);
  doc.querySelectorAll('mark.reader-highlight').forEach((el) => {
    const parent = el.parentNode;
    if (!parent) return;
    while (el.firstChild) parent.insertBefore(el.firstChild, el);
    parent.removeChild(el);
  });
  segmentDocSentences(doc);
  applyStoredHighlights(doc, slug, pageNum, lang);
}

// -- transient UI cleanup ----------------------------------------------------

export function removeReaderHighlightUI(doc: Document | null): void {
  if (!doc) return;
  doc
    .querySelectorAll('.reader-highlight-toolbar, .reader-highlight-sticky, .voca-lookup-panel')
    .forEach((el) => el.remove());
}

export function removeAllReaderHighlightUI(): void {
  document.querySelectorAll<HTMLIFrameElement>('.reader-iframe').forEach((iframe) => {
    if (iframe.contentDocument) removeReaderHighlightUI(iframe.contentDocument);
  });
}

// -- sticky note + toolbar ---------------------------------------------------

interface ToolbarOptions {
  mode: 'create' | 'edit';
  lang: HighlightLang;
  selectionInfo?: SelectionInfo;
  highlightId?: string;
}

function showReaderStickyNote(
  doc: Document,
  anchorRect: DOMRect,
  options: ToolbarOptions & { color: string; note: string },
): void {
  doc.querySelectorAll('.reader-highlight-sticky').forEach((el) => el.remove());

  const noteEl = doc.createElement('div');
  noteEl.className = 'reader-highlight-sticky';
  const noteWidth = 168;
  let noteX = anchorRect.right + 6;
  if (noteX + noteWidth > doc.documentElement.clientWidth - 8) {
    noteX = Math.max(8, anchorRect.left - noteWidth - 6);
  }
  noteEl.style.left = `${noteX}px`;
  noteEl.style.top = `${anchorRect.top}px`;

  const textarea = doc.createElement('textarea');
  textarea.className = 'reader-highlight-sticky__input';
  textarea.placeholder = 'Ghi chú...';
  textarea.value = options.note || '';

  const footer = doc.createElement('div');
  footer.className = 'reader-highlight-sticky__footer';

  const cancelBtn = doc.createElement('button');
  cancelBtn.className = 'reader-highlight-sticky__btn';
  cancelBtn.type = 'button';
  cancelBtn.textContent = '✕';
  cancelBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    noteEl.remove();
  });

  const saveBtn = doc.createElement('button');
  saveBtn.className = 'reader-highlight-sticky__btn reader-highlight-sticky__btn--save';
  saveBtn.type = 'button';
  saveBtn.textContent = '✓';

  const handleSave = () => {
    const text = textarea.value;
    if (options.mode === 'create' && options.selectionInfo) {
      currentContext?.createHighlight(options.selectionInfo, options.lang, options.color, text);
    } else if (options.highlightId) {
      currentContext?.updateHighlight(options.highlightId, { note: text });
    }
    noteEl.remove();
  };

  saveBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    handleSave();
  });
  textarea.addEventListener('keydown', (e) => {
    e.stopPropagation();
    if (e.key === 'Escape') noteEl.remove();
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      handleSave();
    }
  });

  footer.append(cancelBtn, saveBtn);
  noteEl.append(textarea, footer);
  noteEl.addEventListener('mousedown', (e) => e.stopPropagation());
  noteEl.addEventListener('mouseup', (e) => e.stopPropagation());
  doc.body.appendChild(noteEl);
  textarea.focus();
}

function showReaderHighlightToolbar(doc: Document, anchorRect: DOMRect, options: ToolbarOptions): void {
  removeReaderHighlightUI(doc);
  const existing =
    options.highlightId && currentContext?.slug
      ? loadHighlights(currentContext.slug).find((h) => h.id === options.highlightId)
      : null;

  const toolbar = doc.createElement('div');
  toolbar.className = 'reader-highlight-toolbar';
  toolbar.style.left = `${anchorRect.left + anchorRect.width / 2}px`;
  toolbar.style.top = `${anchorRect.top - 6}px`;

  const colors = doc.createElement('div');
  colors.className = 'reader-highlight-toolbar__colors';
  HIGHLIGHT_COLORS.forEach((c) => {
    const btn = doc.createElement('button');
    btn.type = 'button';
    btn.className = 'reader-highlight-toolbar__color';
    btn.style.backgroundColor = c.value;
    btn.title = c.label;
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      if (options.mode === 'create' && options.selectionInfo) {
        currentContext?.createHighlight(options.selectionInfo, options.lang, c.value);
      } else if (options.highlightId) {
        currentContext?.updateHighlight(options.highlightId, { color: c.value });
      }
    });
    colors.appendChild(btn);
  });
  toolbar.appendChild(colors);

  const noteBtn = doc.createElement('button');
  noteBtn.type = 'button';
  noteBtn.className = 'reader-highlight-toolbar__icon';
  noteBtn.title = 'Ghi chú';
  setToolbarIcon(noteBtn, 'note');
  noteBtn.addEventListener('click', (e) => {
    e.stopPropagation();
    toolbar.remove();
    showReaderStickyNote(doc, anchorRect, {
      ...options,
      color: existing?.color || HIGHLIGHT_COLORS[0]!.value,
      note: existing?.note || '',
    });
  });
  toolbar.appendChild(noteBtn);

  const text = options.selectionInfo?.text || existing?.text;
  if (options.lang === 'en' && text) {
    const lookupBtn = doc.createElement('button');
    lookupBtn.type = 'button';
    lookupBtn.className = 'reader-highlight-toolbar__icon';
    lookupBtn.title = 'Tra cứu Voca';
    setToolbarIcon(lookupBtn, 'book');
    lookupBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      toolbar.remove();
      currentContext?.onLookup?.(text, doc, anchorRect);
    });
    toolbar.appendChild(lookupBtn);
  }

  if (options.mode === 'edit' && options.highlightId) {
    const delBtn = doc.createElement('button');
    delBtn.type = 'button';
    delBtn.className = 'reader-highlight-toolbar__icon reader-highlight-toolbar__icon--danger';
    delBtn.title = 'Xóa';
    setToolbarIcon(delBtn, 'trash');
    delBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      currentContext?.deleteHighlight(options.highlightId!);
    });
    toolbar.appendChild(delBtn);
  }

  toolbar.addEventListener('mousedown', (e) => e.stopPropagation());
  toolbar.addEventListener('mouseup', (e) => e.stopPropagation());
  doc.body.appendChild(toolbar);
}

// -- cross-pane sentence sync (transient, distinct from persistent marks) -----

export function highlightSentenceAcrossIframes(sentenceId: string): void {
  document.querySelectorAll<HTMLIFrameElement>('.en-pane-iframe, .vi-pane-iframe').forEach((iframe) => {
    const doc = iframe.contentDocument;
    if (!doc) return;
    doc.querySelectorAll('.sentence-node.highlight-sync').forEach((el) => el.classList.remove('highlight-sync'));
    doc.querySelector(`.sentence-node[data-sentence-id="${sentenceId}"]`)?.classList.add('highlight-sync');
  });
}

export function clearAllHighlights(): void {
  document.querySelectorAll<HTMLIFrameElement>('.en-pane-iframe, .vi-pane-iframe').forEach((iframe) => {
    iframe.contentDocument
      ?.querySelectorAll('.sentence-node.highlight-sync')
      .forEach((el) => el.classList.remove('highlight-sync'));
  });
}

// -- listeners ---------------------------------------------------------------

export function registerIframeHighlightListeners(
  win: Window,
  doc: Document,
  lang: HighlightLang,
): void {
  doc.addEventListener('mousedown', (e) => {
    const target = e.target as Element;
    if (target.closest('mark.reader-highlight, .reader-highlight-toolbar, .reader-highlight-sticky, .voca-lookup-panel')) return;
    removeReaderHighlightUI(doc);
  });

  doc.addEventListener('mouseup', (e) => {
    const target = e.target as Element;
    if (target.closest('.reader-highlight-toolbar, .reader-highlight-sticky, .voca-lookup-panel')) return;

    setTimeout(() => {
      if (target.closest('.reader-highlight-toolbar, .reader-highlight-sticky, .voca-lookup-panel')) return;

      const selection = win.getSelection();
      const selectedText = selection?.toString().trim() || '';
      const clickedMark = target.closest<HTMLElement>('mark.reader-highlight');

      if (clickedMark) {
        const highlightId = clickedMark.dataset.highlightId!;
        const rect = clickedMark.getBoundingClientRect();
        showReaderHighlightToolbar(doc, rect, { mode: 'edit', lang, highlightId });
        if (currentContext?.slug) {
          const existing = loadHighlights(currentContext.slug).find((h) => h.id === highlightId);
          if (existing?.note) {
            showReaderStickyNote(doc, rect, {
              mode: 'edit',
              lang,
              highlightId,
              color: existing.color,
              note: existing.note,
            });
          }
        }
        selection?.removeAllRanges();
        return;
      }

      if (selectedText.length > 2 && selection) {
        const info = getSelectionInfo(doc, selection);
        if (info) {
          const rect = selection.getRangeAt(0).getBoundingClientRect();
          showReaderHighlightToolbar(doc, rect, { mode: 'create', lang, selectionInfo: info });
        }
        return;
      }

      let sentenceNode: Element | null = null;
      if (selectedText.length > 0) {
        sentenceNode = selection?.anchorNode?.parentElement?.closest('.sentence-node') ?? null;
      } else {
        sentenceNode = target.closest('.sentence-node');
      }
      if (sentenceNode) {
        highlightSentenceAcrossIframes((sentenceNode as HTMLElement).dataset.sentenceId!);
      } else {
        removeReaderHighlightUI(doc);
        clearAllHighlights();
      }
    }, 10);
  });
}
