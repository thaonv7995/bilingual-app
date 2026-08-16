/**
 * Device speech synthesis (Web Speech API) — the offline fallback for word audio.
 *
 * Voca 2.0 removed the client's ability to supply its own TTS credential:
 * `POST /v1/audio/{slug}` takes only `{text?, voiceModel?}` and synthesis runs on
 * whatever provider the Voca SERVER has configured. When it has none, every
 * uncached word answers 503 `TTS_NOT_CONFIGURED` and there is nothing the client
 * can send to fix it. The device's own voice is free, offline and always there,
 * so that is what we speak with instead — it sounds worse than edge-tts, which is
 * why it stays a fallback and not the default.
 *
 * Two browser quirks shape this whole module:
 *  1. `getVoices()` is EMPTY on the first call in Chrome and Safari; the list
 *     arrives later with a `voiceschanged` event. So we warm it and cache it.
 *  2. Safari only starts speech from inside a user gesture, and the gesture is
 *     gone the moment the call stack yields. So `speakWithDevice` never awaits
 *     before `speak()` — it reads the warmed cache synchronously.
 */

/** How long to wait for `voiceschanged` before settling for whatever exists. */
const VOICES_TIMEOUT_MS = 1500;

let voiceCache: SpeechSynthesisVoice[] = [];
let voicesPromise: Promise<SpeechSynthesisVoice[]> | null = null;

/**
 * The engine, or null when this browser has no usable one. Older and embedded
 * WebViews ship no `speechSynthesis` at all, and a few ship the object without
 * the utterance constructor — both count as "unavailable", so nothing here may
 * assume `window.speechSynthesis` exists just because the DOM types say it does.
 */
function synth(): SpeechSynthesis | null {
  if (typeof window === 'undefined') return null;
  const engine: SpeechSynthesis | undefined = window.speechSynthesis;
  if (!engine || typeof engine.speak !== 'function') return null;
  if (typeof window.SpeechSynthesisUtterance !== 'function') return null;
  return engine;
}

export function deviceSpeechAvailable(): boolean {
  return synth() !== null;
}

/**
 * Resolve (and cache) the voice list. The first `getVoices()` is empty in Chrome
 * and Safari, so we wait for `voiceschanged` — but not every engine fires it, and
 * Safari can fire it before we subscribe, so the timeout is the real guarantee
 * that this always settles.
 */
function loadVoices(): Promise<SpeechSynthesisVoice[]> {
  const engine = synth();
  if (!engine) return Promise.resolve([]);
  if (voiceCache.length) return Promise.resolve(voiceCache);

  // A non-empty first read means the list is already there and nothing needs
  // waiting on — that is the second call in Chrome, and every call in Firefox.
  const immediate = engine.getVoices();
  if (immediate.length) {
    voiceCache = immediate;
    return Promise.resolve(immediate);
  }
  if (voicesPromise) return voicesPromise;

  const pending = new Promise<SpeechSynthesisVoice[]>((resolve) => {
    // Declared first so the listener and the timer below can both reach it,
    // while it in turn disposes of both — every reference here is read at call
    // time, long after this executor has finished initialising them.
    const settle = (voices: SpeechSynthesisVoice[]): void => {
      clearTimeout(timer);
      engine.removeEventListener?.('voiceschanged', onVoicesChanged);
      voiceCache = voices;
      // Empty means the engine never delivered: drop the memo so a later call
      // retries instead of caching "no voices" for the rest of the session.
      if (!voices.length) voicesPromise = null;
      resolve(voices);
    };
    const onVoicesChanged = () => {
      const voices = engine.getVoices();
      if (voices.length) settle(voices);
    };
    if (typeof engine.addEventListener === 'function') {
      engine.addEventListener('voiceschanged', onVoicesChanged);
    }
    const timer = setTimeout(() => settle(engine.getVoices()), VOICES_TIMEOUT_MS);
  });

  voicesPromise = pending;
  return pending;
}

/**
 * Pick a voice for `lang`: exact match (local voices first — a fallback that
 * needs the network defeats the point), then en-US, then the same language
 * family, then any English one. Null means "let the engine choose its default",
 * which beats forcing a wrong-language voice onto the word.
 */
function pickVoice(voices: SpeechSynthesisVoice[], lang: string): SpeechSynthesisVoice | null {
  if (!voices.length) return null;
  const wanted = lang.toLowerCase();
  const family = wanted.split('-')[0] ?? wanted;
  const tag = (v: SpeechSynthesisVoice) => String(v.lang || '').toLowerCase().replace(/_/g, '-');
  return (
    voices.find((v) => tag(v) === wanted && v.localService) ??
    voices.find((v) => tag(v) === wanted) ??
    voices.find((v) => tag(v) === 'en-us') ??
    voices.find((v) => tag(v) === family || tag(v).startsWith(`${family}-`)) ??
    voices.find((v) => tag(v).startsWith('en')) ??
    null
  );
}

/** Ceiling for one utterance, scaled by length — a single word needs seconds. */
function hungTimeoutMs(text: string): number {
  return Math.min(30_000, 5_000 + text.length * 150);
}

/**
 * Speak `text` and resolve when the utterance ends (rejects if the engine
 * reports an error). Call it DIRECTLY from the click handler: see the
 * gesture note below.
 */
export async function speakWithDevice(text: string, lang = 'en-US'): Promise<void> {
  const engine = synth();
  if (!engine) throw new Error('Trình duyệt này không hỗ trợ đọc bằng giọng thiết bị.');
  const value = String(text || '').trim();
  if (!value) throw new Error('Không có nội dung để đọc.');

  // GESTURE-CRITICAL: nothing may await between the caller's click and
  // `engine.speak()`. Safari starts speech only from inside a user gesture and
  // drops the request as soon as the stack yields, so the voice list is read
  // synchronously from the cache `loadVoices()` warmed at import — never awaited
  // here. This function is `async` for its return type only; its body runs
  // synchronously all the way to `speak()`.
  const voices = voiceCache.length ? voiceCache : engine.getVoices();
  if (!voices.length) void loadVoices(); // nothing to pick from now; warm for next time
  const voice = pickVoice(voices, lang);

  const utterance = new window.SpeechSynthesisUtterance(value);
  utterance.lang = voice?.lang || lang;
  if (voice) utterance.voice = voice;
  utterance.rate = 0.95; // a hair under 1: isolated words are clearer slowed down

  // A second tap must replace the queued word, not stack another one behind it.
  engine.cancel();

  return new Promise<void>((resolve, reject) => {
    let settled = false;
    function finish(err?: Error): void {
      if (settled) return;
      settled = true;
      clearTimeout(watchdog);
      if (err) reject(err);
      else resolve();
    }

    utterance.addEventListener('end', () => finish(), { once: true });
    utterance.addEventListener(
      'error',
      (event) => {
        // Our own `cancel()` (a newer tap) surfaces here as canceled/interrupted.
        // That is this module doing its job, not a failure worth reporting.
        if (event.error === 'canceled' || event.error === 'interrupted') finish();
        else finish(new Error(`Giọng thiết bị gặp lỗi (${event.error}).`));
      },
      { once: true },
    );

    // Some engines never deliver `end` at all (a long-standing Chrome bug). By
    // the time this fires the word has almost certainly been spoken, and
    // rejecting long after the click would only produce a confusing error — so
    // clear the stuck queue and report success. The point is that no caller can
    // await forever. Armed before `speak()`, so even a synchronous `error` from
    // it finds `watchdog` initialised.
    const watchdog = setTimeout(() => {
      engine.cancel();
      finish();
    }, hungTimeoutMs(value));

    engine.speak(utterance);
  });
}

// Warm the list at import: `speakWithDevice` cannot await for it, so it has to
// already be there by the time the user taps a speaker button.
void loadVoices();
