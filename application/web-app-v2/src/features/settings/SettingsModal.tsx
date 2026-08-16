import { useEffect, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useToast } from '@/components/Toast';
import type { LayoutMode } from '@/features/reader/readerConstants';
import { apiJson } from '@/lib/api-client';
import { deviceSpeechAvailable } from '@/lib/speech';
import { syncVocaCards } from '@/lib/vocaCards';
import { checkVocaHealth } from '@/lib/vocaClient';
import { useSettingsStore, type AudioSource, type Settings } from './settingsStore';
import { saveServerSecrets, USER_SETTINGS_KEY, type ServerSecrets } from './serverSecrets';
import styles from './settings.module.css';

const PROVIDERS: { value: string; label: string; baseURL?: string; model?: string }[] = [
  { value: 'openai', label: 'OpenAI (Official)', baseURL: 'https://api.openai.com/v1', model: 'gpt-4o-mini' },
  {
    value: 'gemini',
    label: 'Google Gemini (OpenAI compat)',
    baseURL: 'https://generativelanguage.googleapis.com/v1beta/openai',
    model: 'gemini-2.0-flash',
  },
  { value: 'custom', label: 'Custom (Ollama / Local)' },
];

const VOICES: { value: string; label: string }[] = [
  { value: 'alloy', label: 'Alloy (Mặc định)' },
  { value: 'ash', label: 'Ash' },
  { value: 'ballad', label: 'Ballad' },
  { value: 'coral', label: 'Coral' },
  { value: 'echo', label: 'Echo' },
  { value: 'sage', label: 'Sage' },
  { value: 'shimmer', label: 'Shimmer' },
  { value: 'verse', label: 'Verse' },
];

const AUDIO_SOURCES: { value: AudioSource; label: string }[] = [
  { value: 'auto', label: 'Tự động — Voca trước, lỗi thì dùng giọng thiết bị' },
  { value: 'voca', label: 'Chỉ Voca — báo lỗi nếu không tạo được audio' },
  { value: 'device', label: 'Chỉ giọng thiết bị — nhanh, chạy ngoại tuyến' },
];

const LAYOUTS: { mode: LayoutMode; title: string; dir: 'row' | 'col'; order: [string, string] }[] = [
  { mode: 'en-vi', title: 'EN · VI (Trái–Phải)', dir: 'row', order: ['EN', 'VI'] },
  { mode: 'vi-en', title: 'VI · EN (Trái–Phải)', dir: 'row', order: ['VI', 'EN'] },
  { mode: 'en-over-vi', title: 'EN / VI (Trên–Dưới)', dir: 'col', order: ['EN', 'VI'] },
  { mode: 'vi-over-en', title: 'VI / EN (Trên–Dưới)', dir: 'col', order: ['VI', 'EN'] },
];

/** Voca 2.0 keys are prefixed; catching a paste mistake here beats a 401 later. */
const VOCA_KEY_PREFIX = 'voca_';

/**
 * The Voca host answers on BOTH http and https with no redirect, so an http://
 * origin would ship the API key in cleartext — force https, except on a local
 * Voca where there's no certificate to speak of.
 */
function normalizeVocaOrigin(value: string): string {
  const trimmed = value.trim().replace(/\/+$/, '');
  if (!/^http:\/\//i.test(trimmed)) return trimmed;
  if (/^http:\/\/(localhost|127\.0\.0\.1)([:/]|$)/i.test(trimmed)) return trimmed;
  return trimmed.replace(/^http:\/\//i, 'https://');
}

export function SettingsModal({ onClose }: { onClose: () => void }) {
  const toast = useToast();
  const queryClient = useQueryClient();
  const settings = useSettingsStore((s) => s.settings);
  const setSettings = useSettingsStore((s) => s.setSettings);
  const [form, setForm] = useState<Settings>(settings);
  // Some embedded WebViews ship no Web Speech API at all — say so here instead of
  // letting the fallback fail silently on the first word.
  const deviceVoiceReady = deviceSpeechAvailable();

  // Secrets (LLM key, realtime key, Voca API key) live server-side and never come
  // back to the browser — the modal only learns whether each is set, and inputs
  // are write-only (blank = keep existing). Loaded from /api/user/settings on open.
  const [llmKey, setLlmKey] = useState('');
  const [llmDirty, setLlmDirty] = useState(false);
  const [hasLlmKey, setHasLlmKey] = useState(false);
  const [realtimeKey, setRealtimeKey] = useState('');
  const [realtimeDirty, setRealtimeDirty] = useState(false);
  const [hasRealtimeKey, setHasRealtimeKey] = useState(false);
  const [vocaOrigin, setVocaOrigin] = useState('');
  const [vocaOriginDirty, setVocaOriginDirty] = useState(false);
  const [vocaToken, setVocaToken] = useState('');
  const [hasVocaToken, setHasVocaToken] = useState(false);
  const [vocaTokenDirty, setVocaTokenDirty] = useState(false);
  // The non-secret Voca origin is the one field we READ back, so a failed load
  // must not let a save write the empty box over it (that wiped the origin).
  const [secretsLoaded, setSecretsLoaded] = useState(false);
  const [vocaTesting, setVocaTesting] = useState(false);
  const [vocaTestResult, setVocaTestResult] = useState('');

  useEffect(() => {
    let cancelled = false;
    apiJson<ServerSecrets>('/api/user/settings')
      .then((s) => {
        if (cancelled) return;
        setHasLlmKey(s.hasLlmKey);
        setHasRealtimeKey(s.hasRealtimeKey);
        setVocaOrigin(s.vocaOrigin || '');
        setHasVocaToken(s.hasVocaToken);
        setSecretsLoaded(true);
      })
      .catch(() => {
        /* not configured yet / offline — leave fields empty */
      });
    return () => {
      cancelled = true;
    };
  }, []);

  const patch = (p: Partial<Settings>) => setForm((f) => ({ ...f, ...p }));

  const onProviderChange = (value: string) => {
    const p = PROVIDERS.find((x) => x.value === value);
    patch({
      provider: value,
      ...(p?.baseURL ? { baseURL: p.baseURL } : {}),
      ...(p?.model ? { model: p.model } : {}),
    });
  };

  const vocaTokenError =
    vocaTokenDirty && vocaToken.trim() && !vocaToken.trim().startsWith(VOCA_KEY_PREFIX)
      ? `API key Voca phải bắt đầu bằng "${VOCA_KEY_PREFIX}".`
      : '';

  // /health needs no key, so it only proves the URL is a live Voca; the card sync
  // right after is what actually exercises the saved API key (and warms the cache).
  const onTestVoca = async () => {
    setVocaTesting(true);
    setVocaTestResult('');
    try {
      const health = await checkVocaHealth();
      const cards = await syncVocaCards({ force: true });
      setVocaTestResult(
        `Kết nối OK — ${health.service || 'voca'} ${health.version || ''} · ${cards.cards.length} thẻ.`,
      );
    } catch (err) {
      setVocaTestResult(err instanceof Error ? err.message : 'Không kết nối được Voca.');
    } finally {
      setVocaTesting(false);
    }
  };

  const onSave = async (e: React.FormEvent) => {
    e.preventDefault();
    if (vocaTokenError) {
      toast.show(vocaTokenError, 'danger');
      return;
    }
    setSettings(form);
    // Persist secrets/config to the backend. Only send a secret field when the
    // user actually typed one, so a blank field keeps the existing server value —
    // and only send the origin once we know what the server currently holds.
    try {
      await saveServerSecrets({
        ...(secretsLoaded || vocaOriginDirty ? { vocaOrigin: normalizeVocaOrigin(vocaOrigin) } : {}),
        ...(llmDirty ? { llmApiKey: llmKey.trim() } : {}),
        ...(realtimeDirty ? { realtimeApiKey: realtimeKey.trim() } : {}),
        ...(vocaTokenDirty ? { vocaToken: vocaToken.trim() } : {}),
      });
      await queryClient.invalidateQueries({ queryKey: USER_SETTINGS_KEY });
    } catch {
      /* non-fatal: local (non-secret) settings are still saved */
    }
    toast.show('Đã lưu cấu hình', 'success');
    onClose();
  };

  const savedPlaceholder = '•••••••••••• (đã lưu ở server — để trống nếu giữ nguyên)';

  return (
    <div className={styles.backdrop} onMouseDown={onClose}>
      <form className={styles.panel} onMouseDown={(e) => e.stopPropagation()} onSubmit={onSave}>
        <div className={styles.header}>
          <h3>Cấu hình Companion Agent &amp; Voca</h3>
          <button type="button" className={styles.close} onClick={onClose} aria-label="Đóng">
            ✕
          </button>
        </div>

        <div className={styles.body}>
          <Section title="Companion Reader Agent">
            <Field label="API Provider" full>
              <select className={styles.input} value={form.provider} onChange={(e) => onProviderChange(e.target.value)}>
                {PROVIDERS.map((p) => (
                  <option key={p.value} value={p.value}>
                    {p.label}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="API Base URL" full>
              <input className={styles.input} type="text" required value={form.baseURL} onChange={(e) => patch({ baseURL: e.target.value })} />
            </Field>
            <Field label="API Key">
              <input
                className={styles.input}
                type="password"
                placeholder={hasLlmKey ? savedPlaceholder : 'Nhập API Key của bạn'}
                value={llmKey}
                onChange={(e) => {
                  setLlmKey(e.target.value);
                  setLlmDirty(true);
                }}
              />
            </Field>
            <Field label="Model Name">
              <input className={styles.input} type="text" required value={form.model} onChange={(e) => patch({ model: e.target.value })} />
            </Field>
          </Section>

          <Section title="Companion Voice (Realtime)" hint="Cấu hình cuộc gọi giọng nói trực tiếp (WebRTC).">
            <Field label="Realtime API Key" full>
              <input
                className={styles.input}
                type="password"
                placeholder={hasRealtimeKey ? savedPlaceholder : 'Mặc định dùng chung API Key chính ở trên'}
                value={realtimeKey}
                onChange={(e) => {
                  setRealtimeKey(e.target.value);
                  setRealtimeDirty(true);
                }}
              />
            </Field>
            <Field label="Realtime Model Name">
              <input className={styles.input} type="text" placeholder="gpt-realtime-mini" value={form.realtimeModel} onChange={(e) => patch({ realtimeModel: e.target.value })} />
            </Field>
            <Field label="AI Voice">
              <select className={styles.input} value={form.realtimeVoice} onChange={(e) => patch({ realtimeVoice: e.target.value })}>
                {VOICES.map((v) => (
                  <option key={v.value} value={v.value}>
                    {v.label}
                  </option>
                ))}
              </select>
            </Field>
          </Section>

          <Section title="Voca API" hint="API key nhập ở đây được lưu an toàn phía server (không lưu trên trình duyệt). Voca tự chạy LLM và TTS, nên phần này không dùng API Key phía trên.">
            <Field label="Voca API URL" full>
              <input
                className={styles.input}
                type="url"
                placeholder="https://voca.thaonv.online"
                value={vocaOrigin}
                onChange={(e) => {
                  setVocaOrigin(e.target.value);
                  setVocaOriginDirty(true);
                }}
              />
            </Field>
            <Field label="Voca API Key" full>
              <input
                className={styles.input}
                type="password"
                placeholder={hasVocaToken ? savedPlaceholder : 'voca_...'}
                value={vocaToken}
                onChange={(e) => {
                  setVocaToken(e.target.value);
                  setVocaTokenDirty(true);
                }}
              />
              {vocaTokenError && <p className={styles.sectionHint}>{vocaTokenError}</p>}
            </Field>
            <Field label="Nguồn phát âm" full>
              <select
                className={styles.input}
                value={form.audioSource}
                onChange={(e) => patch({ audioSource: e.target.value as AudioSource })}
              >
                {AUDIO_SOURCES.map((s) => (
                  <option key={s.value} value={s.value}>
                    {s.label}
                  </option>
                ))}
              </select>
              <p className={styles.sectionHint}>
                {deviceVoiceReady
                  ? 'Giọng thiết bị chất lượng thấp hơn Voca nhưng miễn phí, chạy ngoại tuyến và luôn dùng được.'
                  : 'Trình duyệt này không có giọng thiết bị — chỉ dùng được nguồn Voca.'}
              </p>
            </Field>
            <Field label="TTS Voice Model">
              <input className={styles.input} type="text" value={form.ttsModel} onChange={(e) => patch({ ttsModel: e.target.value })} />
            </Field>
            <div className={`${styles.group} ${styles.groupFull}`}>
              <button type="button" className={styles.btnGhost} onClick={onTestVoca} disabled={vocaTesting}>
                {vocaTesting ? 'Đang kiểm tra…' : 'Kiểm tra kết nối'}
              </button>
              <p className={styles.sectionHint}>
                {vocaTestResult || 'Kiểm tra dùng cấu hình đã lưu ở server — hãy lưu trước khi thử.'}
              </p>
            </div>
          </Section>

          <Section title="Bố cục song ngữ">
            <div className={styles.layoutGrid}>
              {LAYOUTS.map((l) => (
                <button
                  key={l.mode}
                  type="button"
                  className={`${styles.layoutCard} ${form.layoutMode === l.mode ? styles.layoutActive : ''}`}
                  onClick={() => patch({ layoutMode: l.mode })}
                  title={l.title}
                >
                  <div className={styles.layoutPreview} style={{ flexDirection: l.dir === 'row' ? 'row' : 'column' }}>
                    <span className={`${styles.previewBadge} ${l.order[0] === 'EN' ? styles.badgeEn : styles.badgeVi}`}>{l.order[0]}</span>
                    <span className={`${styles.previewBadge} ${l.order[1] === 'EN' ? styles.badgeEn : styles.badgeVi}`}>{l.order[1]}</span>
                  </div>
                </button>
              ))}
            </div>
          </Section>
        </div>

        <div className={styles.footer}>
          <button type="button" className={styles.btnGhost} onClick={onClose}>
            Hủy
          </button>
          <button type="submit" className={styles.btnPrimary}>
            Lưu Cấu Hình
          </button>
        </div>
      </form>
    </div>
  );
}

function Section({ title, hint, children }: { title: string; hint?: string; children: React.ReactNode }) {
  return (
    <section className={styles.section}>
      <h4 className={styles.sectionTitle}>{title}</h4>
      {hint && <p className={styles.sectionHint}>{hint}</p>}
      <div className={styles.grid}>{children}</div>
    </section>
  );
}

function Field({ label, full, children }: { label: string; full?: boolean; children: React.ReactNode }) {
  return (
    <div className={`${styles.group} ${full ? styles.groupFull : ''}`}>
      <label className={styles.label}>{label}</label>
      {children}
    </div>
  );
}
