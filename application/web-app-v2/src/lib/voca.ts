/**
 * Voca vocabulary feature — lookup/create/audio plus the in-iframe panels.
 *
 * v2 change: all calls go through the same-origin backend proxy (/api/voca/*)
 * via apiFetch, so the Voca API key is server-side, never in the client (v1
 * shipped a hardcoded key). The proxy is a pass-through, so this module owns
 * the Voca 2.0 envelope — see `vocaClient.ts` for `unwrapVoca`/`VocaError`.
 *
 * Voca 2.0 moved the LLM and TTS server-side, so nothing here forwards the
 * user's own LLM/TTS settings any more (the old "configure your key first"
 * gate blocked a feature that now works without one). Card creation answers
 * with plain JSON instead of NDJSON progress, and audio is keyed by the card
 * SLUG — `id` is a number in 2.0 and points at nothing.
 *
 * Audio has one more wrinkle: 2.0 synthesises with the Voca SERVER's TTS, and a
 * server without one answers 503 TTS_NOT_CONFIGURED for every uncached word. The
 * client can no longer send a key to fix that, so `playCardAudio` falls back to
 * the device's own speech synthesis (see `speech.ts`).
 *
 * Fixes kept from v1: audio object-URLs are revoked on error/close (not only on
 * `ended`) and every JSON parse is guarded.
 */
import { escapeHtml } from '@/lib/escape';
import { useSettingsStore, type AudioSource } from '@/features/settings/settingsStore';
import { deviceSpeechAvailable, speakWithDevice } from '@/lib/speech';
import { lookupCachedWord, rememberVocaCard } from '@/lib/vocaCards';
import {
  VocaError,
  audioKeyFromRef,
  cardAudioKey,
  createVocaCard,
  fetchVocaAudio,
  generateVocaAudio,
  getVocaCard,
  lookupVocaCard,
  type VocaCard,
  type VocaLevel,
  type VocaLookupResult,
} from '@/lib/vocaClient';

export { VocaError, unwrapVoca } from '@/lib/vocaClient';
export type { VocaCard, VocaEnvelope, VocaLevel, VocaLookupResult } from '@/lib/vocaClient';
export { syncVocaCards } from '@/lib/vocaCards';

const getSettings = () => useSettingsStore.getState().settings;

/** A settings blob written before this preference existed carries no value. */
function audioSource(): AudioSource {
  const value = getSettings().audioSource;
  return value === 'voca' || value === 'device' ? value : 'auto';
}

const LEVEL_LABELS: Record<VocaLevel, string> = {
  new: 'Mới',
  learning: 'Đang học',
  known: 'Đã biết',
  mastered: 'Thành thạo',
};

export function cleanWord(value: unknown): string {
  return String(value || '')
    .replace(/\s+/g, ' ')
    .replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu, '')
    .trim()
    .slice(0, 120);
}

/** Cache-first: an exact hit in the local mirror skips the network entirely. */
export async function lookupWord(word: string): Promise<VocaLookupResult> {
  const query = cleanWord(word);
  if (!query) return { found: false, word: '' };
  const cached = lookupCachedWord(query);
  if (cached) return cached;
  return lookupVocaCard(query);
}

/**
 * Create a card and hand the caller the finished Card. 2.0 does the LLM work
 * itself, so the body is just the word — and since the response already IS the
 * card, callers render it directly instead of doing a second lookup round-trip.
 * The progress toast stays: generation still takes seconds.
 */
export async function addWordToVoca(word: string): Promise<VocaCard> {
  const normalized = cleanWord(word);
  if (!normalized) throw new VocaError('MISSING_WORD', 'Hãy chọn một từ trước.');

  const jobId = createJobId();
  showVocaProgressToast(jobId, normalized);
  try {
    const card = await createVocaCard(normalized);
    rememberVocaCard(card);
    removeVocaProgressToast(jobId);
    return card;
  } catch (err) {
    removeVocaProgressToast(jobId);
    showVocaToast(err instanceof Error ? err.message : 'Không thêm được từ.', { error: true });
    throw err;
  }
}

/** Play a card's pronunciation from Voca, generating it there the first time. */
async function playVocaAudio(card: VocaCard | string): Promise<void> {
  const key = cardAudioKey(card);
  if (!key) throw new VocaError('MISSING_WORD', 'Thiếu slug của thẻ.');

  let blob = await fetchVocaAudio(key);
  if (!blob) {
    const ref = await generateVocaAudio(key, { voiceModel: getSettings().ttsModel });
    // Fetch what Voca says it stored, not the key we asked with.
    blob = await fetchVocaAudio(audioKeyFromRef(ref, key));
  }
  if (!blob) throw new VocaError('AUDIO_NOT_FOUND', 'Không tải được audio của thẻ này.');

  const objectUrl = URL.createObjectURL(blob);
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

/** What the device says: the English headword, never the Vietnamese meaning. */
function spokenText(card: VocaCard | string): string {
  return String((typeof card === 'string' ? card : card?.word) || '').trim();
}

/**
 * Every Voca audio failure may fall back to the device EXCEPT `UNAUTHORIZED`: a
 * bad API key is the user's to fix, and quietly speaking the word anyway would
 * hide a real misconfiguration behind working-sounding audio. Everything else —
 * TTS_NOT_CONFIGURED, AUDIO_NOT_FOUND after a generate attempt, RATE_LIMITED, an
 * unreachable proxy, a decode/autoplay rejection from <audio> — all mean the same
 * thing to the user ("no mp3"), which is exactly what the device voice is for.
 */
function canFallBackToDevice(err: unknown): boolean {
  return !(err instanceof VocaError && err.code === 'UNAUTHORIZED');
}

let deviceVoiceNoticed = false;

/** Once per page load — repeating it on every word would be noise, not news. */
function noticeDeviceVoiceOnce(): void {
  if (deviceVoiceNoticed) return;
  deviceVoiceNoticed = true;
  showVocaToast('Voca chưa bật TTS — đang đọc bằng giọng thiết bị.', { info: true });
}

/**
 * Play a card's pronunciation, honouring the user's audio-source preference:
 * `voca` behaves exactly as before, `device` never touches the network, and
 * `auto` tries Voca first and falls back to the device voice.
 */
export async function playCardAudio(card: VocaCard | string): Promise<void> {
  const source = audioSource();

  // `device`: nothing is awaited before `speak()`, so the click that got us here
  // is still the user gesture Safari demands. (`auto` spends that gesture on the
  // Voca round-trip before it can know it failed — which is half the reason this
  // preference exists.)
  if (source === 'device') {
    const text = spokenText(card);
    if (!text) throw new VocaError('MISSING_WORD', 'Thẻ này không có từ để đọc.');
    return speakWithDevice(text);
  }

  try {
    await playVocaAudio(card);
  } catch (err) {
    const text = spokenText(card);
    if (source === 'voca' || !canFallBackToDevice(err) || !text || !deviceSpeechAvailable()) throw err;
    noticeDeviceVoiceOnce();
    try {
      await speakWithDevice(text);
    } catch {
      // Surface the Voca failure, not the speech one: Voca's message is the
      // actionable half ("chưa cấu hình TTS"), a speech-engine error is a dead end.
      throw err;
    }
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
    .voca-toast-info { background: rgba(29, 78, 216, 0.95); }
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

/**
 * `info` exists for notices that are neither a win nor a failure — the device
 * voice fallback is the first: a green ✓ would claim success the user didn't ask
 * for, and red would call a working fallback an error.
 */
function showVocaToast(message: string, { error = false, info = false }: { error?: boolean; info?: boolean } = {}): void {
  ensureVocaToastStyles();
  const variant = error ? 'error' : info ? 'info' : 'success';
  const toast = document.createElement('div');
  toast.className = `voca-toast voca-toast-${variant}`;
  const icon = error ? '!' : info ? 'i' : '✓';
  toast.innerHTML = `<span class="voca-toast-icon">${icon}</span><span class="voca-toast-text">${escapeHtml(message)}</span>`;
  document.documentElement.appendChild(toast);
  requestAnimationFrame(() => toast.classList.add('voca-show'));
  layoutVocaToasts();
  setTimeout(() => {
    toast.classList.remove('voca-show');
    setTimeout(() => {
      toast.remove();
      layoutVocaToasts();
    }, 300);
  }, error ? 4500 : info ? 4000 : 3000);
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
  // 2.0 says whether the hit is exact, so we no longer make the user pick from
  // a list when Voca already knows which card they meant.
  if (result?.matchType === 'exact' && result.card) return showVocaLookupPanel(doc, anchorRect, result.card);
  const cards = Array.isArray(result?.cards) && result.cards.length
    ? result.cards
    : result?.card
      ? [result.card]
      : [];
  if (cards.length === 0) return showVocaNotFoundPanel(doc, anchorRect, query);
  if (cards.length === 1) return showVocaLookupPanel(doc, anchorRect, cards[0]!);
  showVocaLookupMultiPanel(doc, anchorRect, query, cards);
}

/** Lookup lists carry a trimmed card; the detail endpoint has the rest. */
function hasRichDetail(card: VocaCard): boolean {
  return Boolean(card.meaningEn || card.partOfSpeech || card.examples?.length);
}

function renderCardDetail(doc: Document, body: HTMLElement, card: VocaCard): void {
  body.textContent = '';
  const add = (className: string, text: string) => {
    const el = doc.createElement('div');
    el.className = className;
    el.textContent = text;
    body.appendChild(el);
  };

  const ipa = card.ipa || card.pronunciation || '';
  if (ipa) add('voca-lookup-panel__ipa', ipa.startsWith('/') ? ipa : `/${ipa}/`);

  const chips = [card.partOfSpeech, card.level ? LEVEL_LABELS[card.level] : ''].filter(Boolean) as string[];
  if (chips.length) {
    const meta = doc.createElement('div');
    meta.className = 'voca-lookup-panel__meta';
    chips.forEach((text) => {
      const chip = doc.createElement('span');
      chip.className = 'voca-lookup-panel__chip';
      chip.textContent = text;
      meta.appendChild(chip);
    });
    body.appendChild(meta);
  }

  if (card.meaningVi) add('voca-lookup-panel__meaning', card.meaningVi);
  if (card.meaningEn) add('voca-lookup-panel__gloss', card.meaningEn);
  const example = card.examples?.[0];
  if (example) add('voca-lookup-panel__example', example);
}

export function showVocaLookupPanel(doc: Document, anchorRect: DOMRect, card: VocaCard): void {
  removeVocaLookupPanel(doc);
  const panel = doc.createElement('div');
  panel.className = 'voca-lookup-panel';

  const head = doc.createElement('div');
  head.className = 'voca-lookup-panel__head';
  const wordEl = doc.createElement('span');
  wordEl.className = 'voca-lookup-panel__word';
  wordEl.textContent = card.word;
  const voiceBtn = doc.createElement('button');
  voiceBtn.type = 'button';
  voiceBtn.className = 'voca-lookup-panel__voice';
  voiceBtn.title = 'Phát âm';
  voiceBtn.setAttribute('aria-label', 'Phát âm');
  voiceBtn.innerHTML = speakerSvg();
  voiceBtn.addEventListener('click', async (e) => {
    e.stopPropagation();
    // Nothing may await before `playCardAudio` — on the device-voice path this
    // click IS the user gesture Safari requires (see `speech.ts`).
    voiceBtn.disabled = true;
    voiceBtn.setAttribute('aria-busy', 'true');
    voiceBtn.textContent = '…';
    try {
      await playCardAudio(card);
    } catch (err) {
      showVocaToast(err instanceof Error ? err.message : 'Không phát được audio.', { error: true });
    } finally {
      // Always re-enable: a failed word must stay replayable after the user
      // fixes the cause (and the fallback can succeed on the next tap).
      voiceBtn.disabled = false;
      voiceBtn.removeAttribute('aria-busy');
      voiceBtn.innerHTML = speakerSvg();
    }
  });
  head.append(wordEl, voiceBtn);
  panel.appendChild(head);

  const body = doc.createElement('div');
  body.className = 'voca-lookup-panel__body';
  renderCardDetail(doc, body, card);
  panel.appendChild(body);

  // Enrich in the background when we only have the trimmed card (a list hit).
  if (!hasRichDetail(card) && card.slug) {
    void getVocaCard(card.slug)
      .then((full) => {
        if (panel.isConnected) renderCardDetail(doc, body, full);
      })
      .catch(() => {
        /* the trimmed card is still useful — leave it as is */
      });
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
    m.textContent = card.meaningVi || card.meaningEn || '';
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
      // The create response IS the card — no second lookup round-trip.
      showVocaLookupPanel(doc, anchorRect, await addWordToVoca(word));
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
    .voca-lookup-panel__meta { margin-top: 6px; display: flex; flex-wrap: wrap; gap: 4px; }
    .voca-lookup-panel__chip { border-radius: 999px; padding: 2px 8px; background: #f1f5f9;
      border: 1px solid rgba(15, 23, 42, 0.08); color: #475569; font-size: 10px; font-weight: 700;
      text-transform: uppercase; letter-spacing: 0.02em; }
    .voca-lookup-panel__meaning { margin-top: 6px; color: #1e293b; line-height: 1.45; }
    .voca-lookup-panel__gloss { margin-top: 4px; color: #475569; font-size: 12px; line-height: 1.45; }
    .voca-lookup-panel__example { margin-top: 6px; padding-left: 8px; border-left: 2px solid rgba(37, 99, 235, 0.25);
      color: #334155; font-size: 12px; font-style: italic; line-height: 1.45; }
  `;
}
