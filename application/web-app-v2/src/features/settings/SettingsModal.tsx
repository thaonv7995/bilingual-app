import { useEffect, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useToast } from '@/components/Toast';
import type { LayoutMode } from '@/features/reader/readerConstants';
import { apiJson } from '@/lib/api-client';
import { useSettingsStore, type Settings } from './settingsStore';
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

const LAYOUTS: { mode: LayoutMode; title: string; dir: 'row' | 'col'; order: [string, string] }[] = [
  { mode: 'en-vi', title: 'EN · VI (Trái–Phải)', dir: 'row', order: ['EN', 'VI'] },
  { mode: 'vi-en', title: 'VI · EN (Trái–Phải)', dir: 'row', order: ['VI', 'EN'] },
  { mode: 'en-over-vi', title: 'EN / VI (Trên–Dưới)', dir: 'col', order: ['EN', 'VI'] },
  { mode: 'vi-over-en', title: 'VI / EN (Trên–Dưới)', dir: 'col', order: ['VI', 'EN'] },
];

export function SettingsModal({ onClose }: { onClose: () => void }) {
  const toast = useToast();
  const queryClient = useQueryClient();
  const settings = useSettingsStore((s) => s.settings);
  const setSettings = useSettingsStore((s) => s.setSettings);
  const [form, setForm] = useState<Settings>(settings);

  // Secrets (LLM key, realtime key, voca token) live server-side and never come
  // back to the browser — the modal only learns whether each is set, and inputs
  // are write-only (blank = keep existing). Loaded from /api/user/settings on open.
  const [llmKey, setLlmKey] = useState('');
  const [llmDirty, setLlmDirty] = useState(false);
  const [hasLlmKey, setHasLlmKey] = useState(false);
  const [realtimeKey, setRealtimeKey] = useState('');
  const [realtimeDirty, setRealtimeDirty] = useState(false);
  const [hasRealtimeKey, setHasRealtimeKey] = useState(false);
  const [vocaOrigin, setVocaOrigin] = useState('');
  const [vocaToken, setVocaToken] = useState('');
  const [hasVocaToken, setHasVocaToken] = useState(false);
  const [vocaTokenDirty, setVocaTokenDirty] = useState(false);

  useEffect(() => {
    let cancelled = false;
    apiJson<ServerSecrets>('/api/user/settings')
      .then((s) => {
        if (cancelled) return;
        setHasLlmKey(s.hasLlmKey);
        setHasRealtimeKey(s.hasRealtimeKey);
        setVocaOrigin(s.vocaOrigin || '');
        setHasVocaToken(s.hasVocaToken);
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

  const onSave = async (e: React.FormEvent) => {
    e.preventDefault();
    setSettings({ ...form, useApiTts: true });
    // Persist secrets/config to the backend. Only send a secret field when the
    // user actually typed one, so a blank field keeps the existing server value.
    try {
      await saveServerSecrets({
        vocaOrigin: vocaOrigin.trim(),
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

          <Section title="Voca Dictionary Bridge" hint="Token nhập ở đây được lưu an toàn phía server (không lưu trên trình duyệt). Dùng chung API Key / Model phía trên để tạo thẻ từ vựng và TTS phát âm.">
            <Field label="Voca Bridge URL" full>
              <input className={styles.input} type="url" placeholder="https://voca-bridge.thaonv.online" value={vocaOrigin} onChange={(e) => setVocaOrigin(e.target.value)} />
            </Field>
            <Field label="Voca API Token" full>
              <input
                className={styles.input}
                type="password"
                placeholder={hasVocaToken ? savedPlaceholder : 'Bearer token'}
                value={vocaToken}
                onChange={(e) => {
                  setVocaToken(e.target.value);
                  setVocaTokenDirty(true);
                }}
              />
            </Field>
            <Field label="TTS Endpoint (tùy chọn)">
              <input className={styles.input} type="url" placeholder="https://api.openai.com/v1/audio/speech" value={form.ttsEndpoint} onChange={(e) => patch({ ttsEndpoint: e.target.value })} />
            </Field>
            <Field label="TTS Voice Model">
              <input className={styles.input} type="text" value={form.ttsModel} onChange={(e) => patch({ ttsModel: e.target.value })} />
            </Field>
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
