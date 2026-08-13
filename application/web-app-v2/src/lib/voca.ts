/**
 * Voca vocabulary client — typed port of v1's voca-client.js.
 *
 * v2 change: all calls go through the same-origin backend proxy (/api/voca/*)
 * via apiFetch, so the voca-bridge token is server-side, never in the client
 * (v1 shipped a hardcoded token). The user's own LLM/TTS settings still travel
 * in the request body for card/audio generation (hybrid model).
 *
 * Fixes vs v1: the NDJSON stream now parses its final line (v1 dropped it and
 * reported truncated streams as success), audio object-URLs are revoked on
 * error/close (not only on `ended`), and JSON parses are guarded.
 */
import { apiFetch } from '@/lib/api-client';
import { escapeHtml } from '@/lib/escape';
import { useSettingsStore, type Settings } from '@/features/settings/settingsStore';

const DEFAULT_TTS_MODEL = 'edge-tts/en-US-SteffanNeural';

export interface VocaCard {
  id?: string;
  word: string;
  ipa?: string;
  pronunciation?: string;
  meaningVi?: string;
}
export interface VocaLookupResult {
  found?: boolean;
  word?: string;
  card?: VocaCard;
  cards?: VocaCard[];
}

const getSettings = () => useSettingsStore.getState().settings;

function llmSettingsPayload(s: Settings) {
  if (!s.apiKey || !s.baseURL || !s.model) return null;
  return { apiKey: s.apiKey, baseURL: s.baseURL, model: s.model };
}

function ttsSettingsPayload(s: Settings) {
  if (s.useApiTts === false || !s.apiKey) return null;
  const baseURL = String(s.baseURL || '').trim();
  const ttsEndpoint = String(s.ttsEndpoint || '').trim();
  if (!ttsEndpoint && !baseURL) return null;
  return { apiKey: s.apiKey, baseURL, ttsEndpoint, ttsModel: s.ttsModel || DEFAULT_TTS_MODEL };
}

export function cleanWord(value: unknown): string {
  return String(value || '')
    .replace(/\s+/g, ' ')
    .replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu, '')
    .trim()
    .slice(0, 120);
}

export async function lookupWord(word: string): Promise<VocaLookupResult> {
  const query = cleanWord(word);
  if (!query) return { found: false, word: '' };
  const res = await apiFetch(`/api/voca/lookup?word=${encodeURIComponent(query)}`);
  if (!res.ok) {
    const payload = await res.json().catch(() => ({}));
    throw new Error(payload?.error?.message || `Lookup failed (${res.status})`);
  }
  return res.json() as Promise<VocaLookupResult>;
}

async function consumeCreateStream(response: Response): Promise<{ ok: boolean; message?: string }> {
  if (!response.body) return { ok: true };
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  let lastError = '';
  for (;;) {
    const { value, done } = await reader.read();
    buffer += decoder.decode(value, { stream: !done });
    const lines = buffer.split(/\r?\n/);
    // When done, keep ALL lines (incl. the last without a trailing newline).
    buffer = done ? '' : (lines.pop() ?? '');
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      let event: { type?: string; message?: string };
      try {
        event = JSON.parse(trimmed);
      } catch {
        continue;
      }
      if (event.type === 'error') lastError = event.message || 'Không tạo được thẻ.';
      if (event.type === 'done') return { ok: true, message: event.message };
    }
    if (done) break;
  }
  if (lastError) throw new Error(lastError);
  return { ok: true };
}

export async function addWordToVoca(word: string): Promise<{ ok: boolean }> {
  const normalized = cleanWord(word);
  if (!normalized) throw new Error('Hãy chọn một từ trước.');
  const llm = llmSettingsPayload(getSettings());
  if (!llm) throw new Error('Cấu hình API Key, Base URL và Model trong Cài đặt trước.');

  const jobId = createJobId();
  showVocaProgressToast(jobId, normalized);
  try {
    const res = await apiFetch('/api/voca/create', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ word: normalized, settings: llm }),
    });
    if (!res.ok) {
      const payload = await res.json().catch(() => ({}));
      throw new Error(payload?.error?.message || `Create failed (${res.status})`);
    }
    await consumeCreateStream(res);
    removeVocaProgressToast(jobId);
    return { ok: true };
  } catch (err) {
    removeVocaProgressToast(jobId);
    showVocaToast(err instanceof Error ? err.message : 'Không thêm được từ.', { error: true });
    throw err;
  }
}

export async function playCardAudio(card: VocaCard | string): Promise<void> {
  const cardId = typeof card === 'string' ? card : card?.id;
  if (!cardId) throw new Error('Thiếu card id.');
  const path = `/api/voca/audio/${encodeURIComponent(cardId)}`;

  let res = await apiFetch(path);
  if (res.status === 404) {
    const tts = ttsSettingsPayload(getSettings());
    if (!tts) throw new Error('Cấu hình TTS trong Cài đặt, hoặc tạo audio trong app Voca trước.');
    const gen = await apiFetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ settings: tts }),
    });
    if (!gen.ok) {
      const payload = await gen.json().catch(() => ({}));
      throw new Error(payload?.error?.message || `Audio generation failed (${gen.status})`);
    }
    res = await apiFetch(path);
  }
  if (!res.ok) throw new Error(`Audio request failed (${res.status})`);

  const objectUrl = URL.createObjectURL(await res.blob());
  const audio = new Audio(objectUrl);
  const cleanup = () => URL.revokeObjectURL(objectUrl);
  audio.addEventListener('ended', cleanup, { once: true });
  audio.addEventListener('error', cleanup, { once: true });
  try {
    await audio.play();
  } catch (err) {
    cleanup();
    throw err;
  }
}

// -- toasts (self-contained, ported from voca-client.js:211-315) -------------

function ensureVocaToastStyles(): void {
  if (document.querySelector('[data-voca-toast-style]')) return;
  const style = document.createElement('style');
  style.dataset.vocaToastStyle = 'true';
  style.textContent = `
    .voca-toast { position: fixed; right: 20px; bottom: 20px; z-index: 100000;
      display: flex; align-items: center; gap: 10px; max-width: 320px;
      padding: 12px 16px; border-radius: 10px; color: #fff;
      font-family: 'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, sans-serif; font-size: 13px;
      box-shadow: 0 20px 25px -5px rgba(0,0,0,0.25); opacity: 0; transform: translateY(20px);
      transition: all 0.3s ease; border: 1px solid rgba(255,255,255,0.08); background: rgba(30, 41, 59, 0.95); }
    .voca-toast-progress { min-width: 120px; }
    .voca-toast.voca-show { opacity: 1; transform: translateY(0); }
    .voca-toast-success { background: rgba(21, 128, 61, 0.95); }
    .voca-toast-error { background: rgba(185, 28, 28, 0.95); }
    .voca-toast-icon { width: 20px; height: 20px; border-radius: 50%; background: rgba(255,255,255,0.2);
      display: flex; align-items: center; justify-content: center; font-weight: 800; font-size: 11px; }
    .voca-toast-title { font-weight: 700; font-size: 13px; }
    .voca-toast-text { font-weight: 500; font-size: 12px; opacity: 0.9; }
    .voca-spinner { width: 14px; height: 14px; border: 2px solid rgba(255,255,255,0.3);
      border-top-color: #fff; border-radius: 50%; animation: vocaSpin 0.8s linear infinite; }
    @keyframes vocaSpin { to { transform: rotate(360deg); } }
  `;
  document.documentElement.appendChild(style);
}

const progressToasts = new Map<string, HTMLElement>();

function layoutVocaToasts(): void {
  let offset = 20;
  for (const toast of document.querySelectorAll<HTMLElement>('.voca-toast.voca-show')) {
    toast.style.bottom = `${offset}px`;
    offset += toast.getBoundingClientRect().height + 12;
  }
}

function createJobId(): string {
  return `voca-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function showVocaProgressToast(jobId: string, word: string): void {
  ensureVocaToastStyles();
  const toast = document.createElement('div');
  toast.className = 'voca-toast voca-toast-progress';
  toast.innerHTML = `<span class="voca-spinner"></span><span class="voca-toast-title">${escapeHtml(word)}</span>`;
  document.documentElement.appendChild(toast);
  progressToasts.set(jobId, toast);
  requestAnimationFrame(() => toast.classList.add('voca-show'));
  layoutVocaToasts();
}

function removeVocaProgressToast(jobId: string): void {
  const toast = progressToasts.get(jobId);
  if (!toast) return;
  toast.classList.remove('voca-show');
  progressToasts.delete(jobId);
  setTimeout(() => {
    toast.remove();
    layoutVocaToasts();
  }, 300);
}

export function showVocaError(message: string): void {
  showVocaToast(message, { error: true });
}

function showVocaToast(message: string, { error = false }: { error?: boolean } = {}): void {
  ensureVocaToastStyles();
  const toast = document.createElement('div');
  toast.className = `voca-toast ${error ? 'voca-toast-error' : 'voca-toast-success'}`;
  toast.innerHTML = `<span class="voca-toast-icon">${error ? '!' : '✓'}</span><span class="voca-toast-text">${escapeHtml(message)}</span>`;
  document.documentElement.appendChild(toast);
  requestAnimationFrame(() => toast.classList.add('voca-show'));
  layoutVocaToasts();
  setTimeout(() => {
    toast.classList.remove('voca-show');
    setTimeout(() => {
      toast.remove();
      layoutVocaToasts();
    }, 300);
  }, error ? 4500 : 3000);
}

// -- lookup panels (injected into the book iframe document) ------------------

function speakerSvg(): string {
  return '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M11 5 6 9H3v6h3l5 4V5Z"></path><path d="M15.5 8.5a5 5 0 0 1 0 7"></path><path d="M18.5 5.5a9 9 0 0 1 0 13"></path></svg>';
}

function positionVocaLookupPanel(doc: Document, panel: HTMLElement, anchorRect: DOMRect): void {
  const margin = 12;
  const gap = 12;
  const viewport = doc.documentElement;
  const vw = viewport.clientWidth || doc.defaultView?.innerWidth || 0;
  const vh = viewport.clientHeight || doc.defaultView?.innerHeight || 0;
  const anchorLeft = Number(anchorRect?.left) || 0;
  const anchorTop = Number(anchorRect?.top) || 0;
  const anchorWidth = Number(anchorRect?.width) || 0;
  const anchorHeight = Number(anchorRect?.height) || 0;

  panel.style.transform = 'none';
  panel.style.visibility = 'hidden';
  panel.style.left = '0px';
  panel.style.top = '0px';
  doc.body.appendChild(panel);

  const panelWidth = panel.offsetWidth;
  const panelHeight = panel.offsetHeight;
  const anchorCenterX = anchorLeft + anchorWidth / 2;

  let top = anchorTop - gap - panelHeight;
  if (top < margin) top = anchorTop + anchorHeight + gap;
  if (top + panelHeight > vh - margin) top = Math.max(margin, vh - margin - panelHeight);

  let left = anchorCenterX - panelWidth / 2;
  const maxLeft = Math.max(margin, vw - margin - panelWidth);
  left = Math.max(margin, Math.min(maxLeft, left));

  panel.style.left = `${left}px`;
  panel.style.top = `${top}px`;
  panel.style.visibility = 'visible';
}

export function removeVocaLookupPanel(doc: Document | null): void {
  doc?.querySelectorAll('.voca-lookup-panel').forEach((el) => el.remove());
}

export function showVocaLookupResults(
  doc: Document,
  anchorRect: DOMRect,
  query: string,
  result: VocaLookupResult,
): void {
  const cards = Array.isArray(result?.cards) && result.cards.length
    ? result.cards
    : result?.card
      ? [result.card]
      : [];
  if (cards.length === 0) return showVocaNotFoundPanel(doc, anchorRect, query);
  if (cards.length === 1) return showVocaLookupPanel(doc, anchorRect, cards[0]!);
  showVocaLookupMultiPanel(doc, anchorRect, query, cards);
}

export function showVocaLookupPanel(doc: Document, anchorRect: DOMRect, card: VocaCard): void {
  removeVocaLookupPanel(doc);
  const panel = doc.createElement('div');
  panel.className = 'voca-lookup-panel';
  const ipa = card.ipa || card.pronunciation || '';

  const head = doc.createElement('div');
  head.className = 'voca-lookup-panel__head';
  const wordEl = doc.createElement('span');
  wordEl.className = 'voca-lookup-panel__word';
  wordEl.textContent = card.word;
  const voiceBtn = doc.createElement('button');
  voiceBtn.type = 'button';
  voiceBtn.className = 'voca-lookup-panel__voice';
  voiceBtn.title = 'Phát âm';
  voiceBtn.innerHTML = speakerSvg();
  voiceBtn.addEventListener('click', async (e) => {
    e.stopPropagation();
    voiceBtn.disabled = true;
    voiceBtn.textContent = '…';
    try {
      await playCardAudio(card);
    } catch (err) {
      showVocaToast(err instanceof Error ? err.message : 'Không phát được audio.', { error: true });
    } finally {
      voiceBtn.disabled = false;
      voiceBtn.innerHTML = speakerSvg();
    }
  });
  head.append(wordEl, voiceBtn);
  panel.appendChild(head);

  if (ipa) {
    const ipaEl = doc.createElement('div');
    ipaEl.className = 'voca-lookup-panel__ipa';
    ipaEl.textContent = ipa.startsWith('/') ? ipa : `/${ipa}/`;
    panel.appendChild(ipaEl);
  }
  if (card.meaningVi) {
    const meaningEl = doc.createElement('div');
    meaningEl.className = 'voca-lookup-panel__meaning';
    meaningEl.textContent = card.meaningVi;
    panel.appendChild(meaningEl);
  }

  panel.addEventListener('mousedown', (e) => e.stopPropagation());
  panel.addEventListener('mouseup', (e) => e.stopPropagation());
  positionVocaLookupPanel(doc, panel, anchorRect);
}

function showVocaLookupMultiPanel(
  doc: Document,
  anchorRect: DOMRect,
  query: string,
  cards: VocaCard[],
): void {
  removeVocaLookupPanel(doc);
  const panel = doc.createElement('div');
  panel.className = 'voca-lookup-panel voca-lookup-panel--multi';

  const queryEl = doc.createElement('div');
  queryEl.className = 'voca-lookup-panel__query';
  queryEl.textContent = query;
  const hintEl = doc.createElement('div');
  hintEl.className = 'voca-lookup-panel__hint';
  hintEl.textContent = `${cards.length} kết quả trong từ điển`;
  const list = doc.createElement('div');
  list.className = 'voca-lookup-panel__list';

  cards.forEach((card) => {
    const item = doc.createElement('button');
    item.type = 'button';
    item.className = 'voca-lookup-panel__item';
    const w = doc.createElement('span');
    w.className = 'voca-lookup-panel__item-word';
    w.textContent = card.word;
    const m = doc.createElement('span');
    m.className = 'voca-lookup-panel__item-meaning';
    m.textContent = card.meaningVi || '';
    item.append(w, m);
    item.addEventListener('click', (e) => {
      e.stopPropagation();
      showVocaLookupPanel(doc, anchorRect, card);
    });
    list.appendChild(item);
  });

  panel.append(queryEl, hintEl, list);
  panel.addEventListener('mousedown', (e) => e.stopPropagation());
  panel.addEventListener('mouseup', (e) => e.stopPropagation());
  positionVocaLookupPanel(doc, panel, anchorRect);
}

export function showVocaNotFoundPanel(doc: Document, anchorRect: DOMRect, word: string): void {
  removeVocaLookupPanel(doc);
  const panel = doc.createElement('div');
  panel.className = 'voca-lookup-panel voca-lookup-panel--empty';

  const wordEl = doc.createElement('div');
  wordEl.className = 'voca-lookup-panel__word';
  wordEl.textContent = word;
  const hintEl = doc.createElement('div');
  hintEl.className = 'voca-lookup-panel__hint';
  hintEl.textContent = 'Chưa có trong từ điển';
  const addBtn = doc.createElement('button');
  addBtn.type = 'button';
  addBtn.className = 'voca-lookup-panel__create';
  addBtn.textContent = 'Thêm vào Voca';
  addBtn.addEventListener('click', async (e) => {
    e.stopPropagation();
    panel.remove();
    try {
      await addWordToVoca(word);
      const result = await lookupWord(word);
      if (result.found) showVocaLookupResults(doc, anchorRect, word, result);
    } catch {
      showVocaNotFoundPanel(doc, anchorRect, word);
    }
  });

  panel.append(wordEl, hintEl, addBtn);
  panel.addEventListener('mousedown', (e) => e.stopPropagation());
  panel.addEventListener('mouseup', (e) => e.stopPropagation());
  positionVocaLookupPanel(doc, panel, anchorRect);
}

export function getVocaLookupPanelCss(): string {
  return `
    .voca-lookup-panel { position: fixed; z-index: 2147483000; box-sizing: border-box;
      min-width: 200px; max-width: min(300px, calc(100vw - 24px)); padding: 10px 12px; border-radius: 12px;
      background: #ffffff !important; background-image: none !important;
      border: 1px solid rgba(15, 23, 42, 0.18);
      box-shadow: 0 16px 36px rgba(15, 23, 42, 0.24), 0 0 0 1px rgba(255, 255, 255, 0.92) inset;
      color: #0f172a; font-family: 'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, sans-serif;
      font-size: 13px; opacity: 1 !important; isolation: isolate; overflow: hidden;
      backdrop-filter: none !important; -webkit-backdrop-filter: none !important; }
    .voca-lookup-panel::before { content: ''; position: absolute; inset: 0; z-index: -1; border-radius: inherit; background: #ffffff; pointer-events: none; }
    .voca-lookup-panel > * { position: relative; z-index: 1; }
    .voca-lookup-panel--multi { max-width: min(320px, calc(100vw - 24px)); }
    .voca-lookup-panel__query { font-weight: 700; font-size: 13px; margin-bottom: 2px; }
    .voca-lookup-panel__list { margin-top: 8px; display: flex; flex-direction: column; gap: 6px; max-height: 220px; overflow-y: auto; }
    .voca-lookup-panel__item { width: 100%; text-align: left; border: 1px solid rgba(15, 23, 42, 0.1);
      border-radius: 8px; padding: 8px 10px; background: #f8fafc; cursor: pointer; font-family: inherit; color: inherit;
      display: flex; flex-direction: column; gap: 2px; transition: background 0.15s ease, border-color 0.15s ease; }
    .voca-lookup-panel__item:hover { background: #eff6ff; border-color: rgba(37, 99, 235, 0.25); }
    .voca-lookup-panel__item-word { font-weight: 700; font-size: 12px; line-height: 1.35; }
    .voca-lookup-panel__item-meaning { font-size: 11px; color: #475569; line-height: 1.35;
      display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
    .voca-lookup-panel__head { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
    .voca-lookup-panel__word { font-weight: 700; font-size: 14px; }
    .voca-lookup-panel__hint { margin-top: 4px; color: #64748b; font-size: 12px; line-height: 1.4; }
    .voca-lookup-panel__create { margin-top: 10px; width: 100%; border: 0; border-radius: 8px; padding: 8px 12px;
      background: #2563eb; color: #fff; font-family: inherit; font-size: 12px; font-weight: 700;
      cursor: pointer; transition: background 0.15s ease, opacity 0.15s ease; }
    .voca-lookup-panel__create:hover:not(:disabled) { background: #1d4ed8; }
    .voca-lookup-panel__create:disabled { opacity: 0.65; cursor: wait; }
    .voca-lookup-panel__voice { border: 1px solid rgba(2, 132, 199, 0.18); background: #e0f2fe; border-radius: 8px;
      width: 30px; height: 30px; cursor: pointer; font-size: 16px; line-height: 1; color: #075985;
      display: inline-flex; align-items: center; justify-content: center; padding: 0; flex-shrink: 0; }
    .voca-lookup-panel__voice svg { width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
    .voca-lookup-panel__voice:disabled { opacity: 0.5; cursor: wait; }
    .voca-lookup-panel__ipa { margin-top: 4px; color: #475569; font-size: 12px; }
    .voca-lookup-panel__meaning { margin-top: 6px; color: #1e293b; line-height: 1.45; }
  `;
}
