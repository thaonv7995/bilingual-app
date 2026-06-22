const DEFAULT_VOCA_BRIDGE_ORIGIN = 'https://voca-bridge.thaonv.online';
const DEFAULT_VOCA_API_TOKEN = 'voca_55c2ac41266be58e43d0ef2b5817b4c9053a2ed7410fcefd';
const DEFAULT_TTS_MODEL = 'edge-tts/en-US-SteffanNeural';

let getSettings = () => ({});

export function configureVocaClient(settingsProvider) {
  getSettings = settingsProvider;
}

export function defaultVocaSettings() {
  return {
    vocaBridgeOrigin: DEFAULT_VOCA_BRIDGE_ORIGIN,
    vocaBridgeToken: DEFAULT_VOCA_API_TOKEN,
    ttsEndpoint: '',
    ttsModel: DEFAULT_TTS_MODEL,
    useApiTts: true,
  };
}

function resolvedBridgeOrigin(settings) {
  const trimmed = String(settings?.vocaBridgeOrigin || '').trim().replace(/\/+$/, '');
  return trimmed || DEFAULT_VOCA_BRIDGE_ORIGIN;
}

function bridgeToken(settings) {
  return String(settings?.vocaBridgeToken || '').trim() || DEFAULT_VOCA_API_TOKEN;
}

function authHeaders(settings) {
  const token = bridgeToken(settings);
  return token ? { Authorization: `Bearer ${token}` } : {};
}

function bridgeUrl(settings, pathname) {
  const base = resolvedBridgeOrigin(settings);
  const suffix = pathname.startsWith('/') ? pathname : `/${pathname}`;
  return `${base}${suffix}`;
}

export function llmSettingsPayload(settings) {
  if (!settings?.apiKey || !settings?.baseURL || !settings?.model) return null;
  return {
    apiKey: settings.apiKey,
    baseURL: settings.baseURL,
    model: settings.model,
  };
}

function ttsSettingsPayload(settings) {
  if (settings?.useApiTts === false || !settings?.apiKey) return null;
  const baseURL = String(settings.baseURL || '').trim();
  const ttsEndpoint = String(settings.ttsEndpoint || '').trim();
  if (!ttsEndpoint && !baseURL) return null;
  return {
    apiKey: settings.apiKey,
    baseURL,
    ttsEndpoint,
    ttsModel: settings.ttsModel || DEFAULT_TTS_MODEL,
  };
}

export function cleanWord(value) {
  return String(value || '')
    .replace(/\s+/g, ' ')
    .replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$/gu, '')
    .trim()
    .slice(0, 120);
}

export async function checkVocaHealth() {
  const settings = getSettings();
  try {
    const response = await fetch(bridgeUrl(settings, '/v1/health'), {
      headers: { ...authHeaders(settings) },
    });
    if (!response.ok) return false;
    const payload = await response.json();
    return Boolean(payload?.ok);
  } catch {
    return false;
  }
}

export async function lookupWord(word) {
  const settings = getSettings();
  const query = cleanWord(word);
  if (!query) return { found: false, word: '' };
  const response = await fetch(
    `${bridgeUrl(settings, '/v1/cards/lookup')}?word=${encodeURIComponent(query)}`,
    { headers: { ...authHeaders(settings) } },
  );
  if (!response.ok) {
    const payload = await response.json().catch(() => ({}));
    throw new Error(payload?.error?.message || `Lookup failed (${response.status})`);
  }
  return response.json();
}

async function consumeCreateStream(response) {
  if (!response.body) {
    return { ok: true };
  }
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  let lastError = '';
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const lines = buffer.split(/\r?\n/);
    buffer = lines.pop() || '';
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      let event;
      try {
        event = JSON.parse(trimmed);
      } catch {
        continue;
      }
      if (event.type === 'error') {
        lastError = event.message || 'Cannot create card.';
      }
      if (event.type === 'done') {
        return { ok: true, message: event.message };
      }
    }
  }
  if (lastError) throw new Error(lastError);
  return { ok: true };
}

export async function addWordToVoca(word) {
  const settings = getSettings();
  const normalized = cleanWord(word);
  if (!normalized) throw new Error('Select a word first.');
  const llm = llmSettingsPayload(settings);
  if (!llm) {
    throw new Error('Configure AI API Key, Base URL, and Model in Settings first.');
  }

  const jobId = createJobId();
  showVocaProgressToast(jobId, normalized);

  try {
    const response = await fetch(bridgeUrl(settings, '/v1/cards/create'), {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...authHeaders(settings),
      },
      body: JSON.stringify({ word: normalized, settings: llm }),
    });

    if (!response.ok) {
      const payload = await response.json().catch(() => ({}));
      throw new Error(payload?.error?.message || `Create failed (${response.status})`);
    }

    await consumeCreateStream(response);
    removeVocaProgressToast(jobId);
    return { ok: true };
  } catch (error) {
    removeVocaProgressToast(jobId);
    showVocaToast(error instanceof Error ? error.message : 'Cannot add word.', { error: true });
    throw error;
  }
}

export async function playCardAudio(card) {
  const settings = getSettings();
  const cardId = card?.id || card;
  if (!cardId) throw new Error('Missing card id.');

  const audioUrl = bridgeUrl(settings, `/v1/audio/${encodeURIComponent(cardId)}`);
  let response = await fetch(audioUrl, { headers: { ...authHeaders(settings) } });

  if (response.status === 404) {
    const tts = ttsSettingsPayload(settings);
    if (!tts) {
      throw new Error('Configure AI settings for TTS, or generate audio in Voca app first.');
    }
    const generated = await fetch(audioUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...authHeaders(settings),
      },
      body: JSON.stringify({ settings: tts }),
    });
    if (!generated.ok) {
      const payload = await generated.json().catch(() => ({}));
      throw new Error(payload?.error?.message || `Audio generation failed (${generated.status})`);
    }
    response = await fetch(audioUrl, { headers: { ...authHeaders(settings) } });
  }

  if (!response.ok) {
    throw new Error(`Audio request failed (${response.status})`);
  }

  const blob = await response.blob();
  const objectUrl = URL.createObjectURL(blob);
  const audio = new Audio(objectUrl);
  audio.addEventListener('ended', () => URL.revokeObjectURL(objectUrl), { once: true });
  await audio.play();
}

function ensureVocaToastStyles() {
  if (document.querySelector('[data-voca-toast-style]')) return;
  const style = document.createElement('style');
  style.dataset.vocaToastStyle = 'true';
  style.textContent = `
    .voca-toast {
      position: fixed; right: 20px; bottom: 20px; z-index: 100000;
      display: flex; align-items: center; gap: 10px; max-width: 320px; min-width: auto;
      padding: 12px 16px; border-radius: 10px; color: #fff;
      font-family: 'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, sans-serif; font-size: 13px;
      box-shadow: 0 20px 25px -5px rgba(0,0,0,0.25);
      opacity: 0; transform: translateY(20px); transition: all 0.3s ease;
      border: 1px solid rgba(255,255,255,0.08);
      background: rgba(30, 41, 59, 0.95);
    }
    .voca-toast-progress { min-width: 120px; }
    .voca-toast.voca-show { opacity: 1; transform: translateY(0); }
    .voca-toast-success { background: rgba(21, 128, 61, 0.95); }
    .voca-toast-error { background: rgba(185, 28, 28, 0.95); }
    .voca-toast-icon {
      width: 20px; height: 20px; border-radius: 50%; background: rgba(255,255,255,0.2);
      display: flex; align-items: center; justify-content: center; font-weight: 800; font-size: 11px;
    }
    .voca-toast-content { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
    .voca-toast-title { font-weight: 700; font-size: 13px; }
    .voca-toast-text { font-weight: 500; font-size: 12px; opacity: 0.9; }
    .voca-spinner {
      width: 14px; height: 14px; border: 2px solid rgba(255,255,255,0.3);
      border-top-color: #fff; border-radius: 50%; animation: vocaSpin 0.8s linear infinite;
    }
    @keyframes vocaSpin { to { transform: rotate(360deg); } }
  `;
  document.documentElement.appendChild(style);
}

const progressToasts = new Map();

function layoutVocaToasts() {
  const gap = 12;
  let offset = 20;
  for (const toast of document.querySelectorAll('.voca-toast.voca-show')) {
    toast.style.bottom = `${offset}px`;
    offset += toast.getBoundingClientRect().height + gap;
  }
}

function createJobId() {
  return `voca-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function showVocaProgressToast(jobId, word) {
  ensureVocaToastStyles();
  const toast = document.createElement('div');
  toast.className = 'voca-toast voca-toast-progress';
  toast.dataset.vocaJobId = jobId;
  toast.innerHTML = `
    <span class="voca-spinner"></span>
    <span class="voca-toast-title">${escapeHtml(word)}</span>`;
  document.documentElement.appendChild(toast);
  progressToasts.set(jobId, toast);
  requestAnimationFrame(() => toast.classList.add('voca-show'));
  layoutVocaToasts();
}

function removeVocaProgressToast(jobId) {
  const toast = progressToasts.get(jobId);
  if (!toast) return;
  toast.classList.remove('voca-show');
  progressToasts.delete(jobId);
  setTimeout(() => {
    toast.remove();
    layoutVocaToasts();
  }, 300);
}

export function showVocaError(message) {
  showVocaToast(message, { error: true });
}

function showVocaToast(message, { error = false, success = false } = {}) {
  ensureVocaToastStyles();
  const toast = document.createElement('div');
  toast.className = `voca-toast ${error ? 'voca-toast-error' : 'voca-toast-success'}`;
  toast.innerHTML = `
    <span class="voca-toast-icon">${error ? '!' : '✓'}</span>
    <span class="voca-toast-text">${escapeHtml(message)}</span>`;
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

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

export function removeVocaLookupPanel(doc) {
  doc?.querySelectorAll('.voca-lookup-panel').forEach((el) => el.remove());
}

export function showVocaLookupResults(doc, anchorRect, query, result) {
  const cards = Array.isArray(result?.cards) && result.cards.length
    ? result.cards
    : result?.card
      ? [result.card]
      : [];
  if (cards.length === 0) {
    showVocaNotFoundPanel(doc, anchorRect, query);
    return;
  }
  if (cards.length === 1) {
    showVocaLookupPanel(doc, anchorRect, cards[0]);
    return;
  }
  showVocaLookupMultiPanel(doc, anchorRect, query, cards);
}

export function showVocaLookupPanel(doc, anchorRect, card) {
  removeVocaLookupPanel(doc);
  removeReaderVocaLookupClass(doc);

  const panel = doc.createElement('div');
  panel.className = 'voca-lookup-panel';
  const ipa = card.ipa || card.pronunciation || '';
  panel.style.left = `${anchorRect.left + anchorRect.width / 2}px`;
  panel.style.top = `${anchorRect.top - 8}px`;

  const head = doc.createElement('div');
  head.className = 'voca-lookup-panel__head';
  const wordEl = doc.createElement('span');
  wordEl.className = 'voca-lookup-panel__word';
  wordEl.textContent = card.word;
  const voiceBtn = doc.createElement('button');
  voiceBtn.type = 'button';
  voiceBtn.className = 'voca-lookup-panel__voice';
  voiceBtn.title = 'Play pronunciation';
  voiceBtn.textContent = '🔊';
  voiceBtn.addEventListener('click', async (e) => {
    e.stopPropagation();
    voiceBtn.disabled = true;
    voiceBtn.textContent = '…';
    try {
      await playCardAudio(card);
    } catch (err) {
      showVocaToast(err instanceof Error ? err.message : 'Cannot play audio.', { error: true });
    } finally {
      voiceBtn.disabled = false;
      voiceBtn.textContent = '🔊';
    }
  });
  head.append(wordEl, voiceBtn);

  if (ipa) {
    const ipaEl = doc.createElement('div');
    ipaEl.className = 'voca-lookup-panel__ipa';
    ipaEl.textContent = ipa.startsWith('/') ? ipa : `/${ipa}/`;
    panel.appendChild(head);
    panel.appendChild(ipaEl);
  } else {
    panel.appendChild(head);
  }

  if (card.meaningVi) {
    const meaningEl = doc.createElement('div');
    meaningEl.className = 'voca-lookup-panel__meaning';
    meaningEl.textContent = card.meaningVi;
    panel.appendChild(meaningEl);
  }

  panel.addEventListener('mousedown', (e) => e.stopPropagation());
  panel.addEventListener('mouseup', (e) => e.stopPropagation());
  doc.body.appendChild(panel);
}

function showVocaLookupMultiPanel(doc, anchorRect, query, cards) {
  removeVocaLookupPanel(doc);
  removeReaderVocaLookupClass(doc);

  const panel = doc.createElement('div');
  panel.className = 'voca-lookup-panel voca-lookup-panel--multi';
  panel.style.left = `${anchorRect.left + anchorRect.width / 2}px`;
  panel.style.top = `${anchorRect.top - 8}px`;

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

    const wordEl = doc.createElement('span');
    wordEl.className = 'voca-lookup-panel__item-word';
    wordEl.textContent = card.word;

    const meaningEl = doc.createElement('span');
    meaningEl.className = 'voca-lookup-panel__item-meaning';
    meaningEl.textContent = card.meaningVi || '';

    item.append(wordEl, meaningEl);
    item.addEventListener('click', (e) => {
      e.stopPropagation();
      showVocaLookupPanel(doc, anchorRect, card);
    });
    list.appendChild(item);
  });

  panel.append(queryEl, hintEl, list);
  panel.addEventListener('mousedown', (e) => e.stopPropagation());
  panel.addEventListener('mouseup', (e) => e.stopPropagation());
  doc.body.appendChild(panel);
}

export function showVocaNotFoundPanel(doc, anchorRect, word) {
  removeVocaLookupPanel(doc);
  const panel = doc.createElement('div');
  panel.className = 'voca-lookup-panel voca-lookup-panel--empty';
  panel.style.left = `${anchorRect.left + anchorRect.width / 2}px`;
  panel.style.top = `${anchorRect.top - 8}px`;

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
      if (result.found) {
        showVocaLookupResults(doc, anchorRect, word, result);
      }
    } catch {
      showVocaNotFoundPanel(doc, anchorRect, word);
    }
  });

  panel.append(wordEl, hintEl, addBtn);
  panel.addEventListener('mousedown', (e) => e.stopPropagation());
  panel.addEventListener('mouseup', (e) => e.stopPropagation());
  doc.body.appendChild(panel);
}

function removeReaderVocaLookupClass(doc) {
  // no-op placeholder for future highlight styling
}

export function getVocaLookupPanelCss() {
  return `
    .voca-lookup-panel {
      position: fixed;
      z-index: 2147483000;
      transform: translate(-50%, calc(-100% - 12px));
      min-width: 200px;
      max-width: min(300px, calc(100vw - 24px));
      padding: 10px 12px;
      border-radius: 10px;
      background: #ffffff;
      border: 1px solid rgba(15, 23, 42, 0.18);
      box-shadow: 0 18px 42px rgba(15, 23, 42, 0.28), 0 0 0 1px rgba(255, 255, 255, 0.9) inset;
      color: #0f172a;
      font-family: 'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, sans-serif;
      font-size: 13px;
      opacity: 1;
      isolation: isolate;
    }
    .voca-lookup-panel--empty { opacity: 1; }
    .voca-lookup-panel--multi { max-width: 320px; }
    .voca-lookup-panel__query {
      font-weight: 700; font-size: 13px; margin-bottom: 2px;
    }
    .voca-lookup-panel__list {
      margin-top: 8px; display: flex; flex-direction: column; gap: 6px;
      max-height: 220px; overflow-y: auto;
    }
    .voca-lookup-panel__item {
      width: 100%; text-align: left; border: 1px solid rgba(15, 23, 42, 0.1);
      border-radius: 8px; padding: 8px 10px; background: #f8fafc;
      cursor: pointer; font-family: inherit; color: inherit;
      display: flex; flex-direction: column; gap: 2px;
      transition: background 0.15s ease, border-color 0.15s ease;
    }
    .voca-lookup-panel__item:hover {
      background: #eff6ff; border-color: rgba(37, 99, 235, 0.25);
    }
    .voca-lookup-panel__item-word { font-weight: 700; font-size: 12px; line-height: 1.35; }
    .voca-lookup-panel__item-meaning {
      font-size: 11px; color: #475569; line-height: 1.35;
      display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden;
    }
    .voca-lookup-panel__head {
      display: flex; align-items: center; justify-content: space-between; gap: 8px;
    }
    .voca-lookup-panel__word { font-weight: 700; font-size: 14px; }
    .voca-lookup-panel__hint {
      margin-top: 4px; color: #64748b; font-size: 12px; line-height: 1.4;
    }
    .voca-lookup-panel__create {
      margin-top: 10px; width: 100%;
      border: 0; border-radius: 8px; padding: 8px 12px;
      background: #2563eb; color: #fff;
      font-family: inherit; font-size: 12px; font-weight: 700;
      cursor: pointer; transition: background 0.15s ease, opacity 0.15s ease;
    }
    .voca-lookup-panel__create:hover:not(:disabled) { background: #1d4ed8; }
    .voca-lookup-panel__create:disabled { opacity: 0.65; cursor: wait; }
    .voca-lookup-panel__voice {
      border: 1px solid rgba(2, 132, 199, 0.18); background: #e0f2fe; border-radius: 7px; width: 30px; height: 30px;
      cursor: pointer; font-size: 16px; line-height: 1; color: #075985;
      display: inline-flex; align-items: center; justify-content: center;
    }
    .voca-lookup-panel__voice:disabled { opacity: 0.5; cursor: wait; }
    .voca-lookup-panel__ipa { margin-top: 4px; color: #475569; font-size: 12px; }
    .voca-lookup-panel__meaning { margin-top: 6px; color: #1e293b; line-height: 1.45; }
  `;
}
