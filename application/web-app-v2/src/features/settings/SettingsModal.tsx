import { useState } from 'react';
import { useToast } from '@/components/Toast';
import type { LayoutMode } from '@/features/reader/readerConstants';
import { useSettingsStore, type Settings } from './settingsStore';
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

const VOICES = ['alloy', 'ash', 'ballad', 'coral', 'echo', 'sage', 'shimmer', 'verse'];

const LAYOUTS: { mode: LayoutMode; title: string; dir: 'row' | 'col'; order: [string, string] }[] = [
  { mode: 'en-vi', title: 'EN · VI (Trái–Phải)', dir: 'row', order: ['EN', 'VI'] },
  { mode: 'vi-en', title: 'VI · EN (Trái–Phải)', dir: 'row', order: ['VI', 'EN'] },
  { mode: 'en-over-vi', title: 'EN / VI (Trên–Dưới)', dir: 'col', order: ['EN', 'VI'] },
  { mode: 'vi-over-en', title: 'VI / EN (Trên–Dưới)', dir: 'col', order: ['VI', 'EN'] },
];

export function SettingsModal({ onClose }: { onClose: () => void }) {
  const toast = useToast();
  const settings = useSettingsStore((s) => s.settings);
  const setSettings = useSettingsStore((s) => s.setSettings);
  const [form, setForm] = useState<Settings>(settings);

  const patch = (p: Partial<Settings>) => setForm((f) => ({ ...f, ...p }));

  const onProviderChange = (value: string) => {
    const p = PROVIDERS.find((x) => x.value === value);
    patch({
      provider: value,
      ...(p?.baseURL ? { baseURL: p.baseURL } : {}),
      ...(p?.model ? { model: p.model } : {}),
    });
  };

  const onSave = (e: React.FormEvent) => {
    e.preventDefault();
    setSettings({ ...form, useApiTts: true });
    toast.show('Đã lưu cấu hình', 'success');
    onClose();
  };

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
              <input className={styles.input} type="password" placeholder="Nhập API Key của bạn" value={form.apiKey} onChange={(e) => patch({ apiKey: e.target.value })} />
            </Field>
            <Field label="Model Name">
              <input className={styles.input} type="text" required value={form.model} onChange={(e) => patch({ model: e.target.value })} />
            </Field>
          </Section>

          <Section title="Companion Voice (Realtime)" hint="Cuộc gọi giọng nói trực tiếp (WebRTC).">
            <Field label="Realtime API Key" full>
              <input className={styles.input} type="password" placeholder="Mặc định dùng chung API Key chính" value={form.realtimeApiKey} onChange={(e) => patch({ realtimeApiKey: e.target.value })} />
            </Field>
            <Field label="Realtime Model">
              <input className={styles.input} type="text" placeholder="gpt-realtime-mini" value={form.realtimeModel} onChange={(e) => patch({ realtimeModel: e.target.value })} />
            </Field>
            <Field label="AI Voice">
              <select className={styles.input} value={form.realtimeVoice} onChange={(e) => patch({ realtimeVoice: e.target.value })}>
                {VOICES.map((v) => (
                  <option key={v} value={v}>
                    {v}
                  </option>
                ))}
              </select>
            </Field>
          </Section>

          <Section title="Voca / TTS" hint="Token bridge nằm ở server. Dùng API Key phía trên để tạo audio phát âm.">
            <Field label="TTS Endpoint (tùy chọn)" full>
              <input className={styles.input} type="url" placeholder="https://api.openai.com/v1/audio/speech" value={form.ttsEndpoint} onChange={(e) => patch({ ttsEndpoint: e.target.value })} />
            </Field>
            <Field label="TTS Voice Model" full>
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
                    <span className={styles.previewBadge}>{l.order[0]}</span>
                    <span className={styles.previewBadge}>{l.order[1]}</span>
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
