import { useEffect, useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { useToast } from '@/components/Toast';
import type { LayoutMode } from '@/features/reader/readerConstants';
import { apiJson } from '@/lib/api-client';
import { deviceSpeechAvailable } from '@/lib/speech';
import { playSentenceAudio } from '@/features/audiobook/audiobookService';
import { syncVocaCards } from '@/lib/vocaCards';
import { checkVocaHealth } from '@/lib/vocaClient';
import { useSettingsStore, type AudioSource, type Settings } from './settingsStore';
import {
  saveServerSettings,
  USER_SETTINGS_KEY,
  type ServerSettings,
} from './serverSecrets';
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
  const replaceSettings = useSettingsStore((s) => s.replaceSettings);
  const [form, setForm] = useState<Settings>(settings);
  // Some embedded WebViews ship no Web Speech API at all — say so here instead of
  // letting the fallback fail silently on the first word.
  const deviceVoiceReady = deviceSpeechAvailable();

  // Secrets (LLM key and Voca API key) live server-side and never come
  // back to the browser — the modal only learns whether each is set, and inputs
  // are write-only (blank = keep existing). Loaded from /api/user/settings on open.
  const [llmKey, setLlmKey] = useState('');
  const [llmDirty, setLlmDirty] = useState(false);
  const [hasLlmKey, setHasLlmKey] = useState(false);
  const [vocaOrigin, setVocaOrigin] = useState('');
  const [vocaOriginDirty, setVocaOriginDirty] = useState(false);
  const [vocaToken, setVocaToken] = useState('');
  const [hasVocaToken, setHasVocaToken] = useState(false);
  const [vocaTokenDirty, setVocaTokenDirty] = useState(false);
  // Audio Provider Settings (server-side)
  const [audioProvider, setAudioProvider] = useState('device');
  const [audioVoice, setAudioVoice] = useState('');
  const [audioVoiceEn, setAudioVoiceEn] = useState('');
  const [audioVoiceVi, setAudioVoiceVi] = useState('');
  const [speechSpeed, setSpeechSpeed] = useState('1.0');
  const [azureApiKey, setAzureApiKey] = useState('');
  const [azureDirty, setAzureDirty] = useState(false);
  const [hasAzureKey, setHasAzureKey] = useState(false);
  const [elevenLabsApiKey, setElevenLabsApiKey] = useState('');
  const [elevenLabsDirty, setElevenLabsDirty] = useState(false);
  const [hasElevenLabsKey, setHasElevenLabsKey] = useState(false);
  const [audioTesting, setAudioTesting] = useState(false);
  // The non-secret Voca origin is the one field we READ back, so a failed load
  // must not let a save write the empty box over it (that wiped the origin).
  const [secretsLoaded, setSecretsLoaded] = useState(false);
  const [vocaTesting, setVocaTesting] = useState(false);
  const [vocaTestResult, setVocaTestResult] = useState('');

  useEffect(() => {
    let cancelled = false;
    apiJson<ServerSettings>('/api/user/settings')
      .then((s) => {
        if (cancelled) return;
        setHasLlmKey(s.hasLlmKey);
        setVocaOrigin(s.vocaOrigin || '');
        setHasVocaToken(s.hasVocaToken);
        setAudioProvider(s.audioProvider || 'device');
        setAudioVoice(s.audioVoice || '');
        setAudioVoiceEn(s.audioVoiceEn || s.audioVoice || '');
        setAudioVoiceVi(s.audioVoiceVi || '');
        setSpeechSpeed(s.speechSpeed || '1.0');
        setHasAzureKey(!!s.hasAzureKey);
        setHasElevenLabsKey(!!s.hasElevenLabsKey);
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

  const onTestAudio = async (lang: 'en' | 'vi') => {
    setAudioTesting(true);
    try {
      const isVi = lang === 'vi';
      const voice = isVi
        ? (audioVoiceVi.trim() || audioVoice.trim())
        : (audioVoiceEn.trim() || audioVoice.trim());
      const testText = isVi
        ? 'Xin chào, đây là âm thanh đọc thử sách bằng tiếng Việt.'
        : 'Hello, this is a preview of your audiobook reading voice.';
      await playSentenceAudio({
        text: testText,
        provider: audioProvider,
        voice,
        speed: speechSpeed,
        lang: isVi ? 'vi-VN' : 'en-US',
      });
      toast.show(`Phát âm thử (${lang.toUpperCase()}) thành công!`, 'success');
    } catch (err: any) {
      toast.show(`Lỗi phát âm: ${err.message}`, 'danger');
    } finally {
      setAudioTesting(false);
    }
  };

  const onSave = async (e: React.FormEvent) => {
    e.preventDefault();
    if (vocaTokenError) {
      toast.show(vocaTokenError, 'danger');
      return;
    }
    try {
      const saved = await saveServerSettings({
        provider: form.provider,
        baseURL: form.baseURL.trim(),
        model: form.model.trim(),
        ttsModel: form.ttsModel.trim(),
        audioSource: form.audioSource,
        layoutMode: form.layoutMode,
        hideFinishedBooks: form.hideFinishedBooks,
        ...(secretsLoaded || vocaOriginDirty ? { vocaOrigin: normalizeVocaOrigin(vocaOrigin) } : {}),
        ...(llmDirty ? { llmApiKey: llmKey.trim() } : {}),
        ...(vocaTokenDirty ? { vocaToken: vocaToken.trim() } : {}),
        audioProvider,
        audioVoice: audioVoiceEn.trim() || audioVoice.trim(),
        audioVoiceEn: audioVoiceEn.trim(),
        audioVoiceVi: audioVoiceVi.trim(),
        speechSpeed: speechSpeed.trim() || '1.0',
        ...(azureDirty ? { azureApiKey: azureApiKey.trim() } : {}),
        ...(elevenLabsDirty ? { elevenLabsApiKey: elevenLabsApiKey.trim() } : {}),
      });

      replaceSettings(saved);
      queryClient.setQueryData<ServerSettings>(USER_SETTINGS_KEY, saved);
      toast.show('Đã lưu và đồng bộ cài đặt trên server', 'success');
      onClose();
    } catch (error) {
      toast.show(
        error instanceof Error
          ? `Không thể lưu cài đặt: ${error.message}`
          : 'Không thể lưu cài đặt lên server.',
        'danger',
      );
    }
  };

  const savedPlaceholder = '•••••••••••• (đã lưu ở server — để trống nếu giữ nguyên)';

  return (
    <div className={styles.backdrop} onMouseDown={onClose}>
      <form className={styles.panel} onMouseDown={(e) => e.stopPropagation()} onSubmit={onSave}>
        <div className={styles.header}>
          <div>
            <h3>Cài đặt</h3>
            <p className={styles.sectionHint}>
              Mọi thay đổi được lưu trên server và đồng bộ giữa Web và Mobile.
            </p>
          </div>
          <button type="button" className={styles.close} onClick={onClose} aria-label="Đóng">
            ✕
          </button>
        </div>

        <div className={styles.body}>
          <Section title="Cấu hình">
            <Field label="API Provider">
              <select className={styles.input} value={form.provider} onChange={(e) => onProviderChange(e.target.value)}>
                {PROVIDERS.map((p) => (
                  <option key={p.value} value={p.value}>
                    {p.label}
                  </option>
                ))}
              </select>
            </Field>
            <Field label="API Base URL">
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

          <Section
            title="Audiobook &amp; Voice"
            hint="Cấu hình giọng đọc, đồng bộ giữa Web và iOS."
          >
            <Field label="Nguồn phát Audio">
              <select
                className={styles.input}
                value={audioProvider}
                onChange={(e) => setAudioProvider(e.target.value)}
              >
                <option value="device">Trình duyệt / Thiết bị Offline (Miễn phí)</option>
                <option value="openai">OpenAI TTS (Dùng API Key của Companion)</option>
                <option value="azure">Azure Speech (Neural TTS chất lượng cao)</option>
                <option value="elevenlabs">ElevenLabs (Giọng đọc biểu cảm cao cấp)</option>
              </select>
            </Field>

            {audioProvider !== 'device' && (
              <>
                <Field label="Voice Tiếng Anh (English Voice ID)">
                  <input
                    className={styles.input}
                    type="text"
                    placeholder={
                      audioProvider === 'azure'
                        ? 'en-US-JennyNeural'
                        : audioProvider === 'elevenlabs'
                          ? '21m00Tcm4TlvDq8ikWAM (Rachel)'
                          : 'alloy, echo, nova...'
                    }
                    value={audioVoiceEn}
                    onChange={(e) => setAudioVoiceEn(e.target.value)}
                  />
                </Field>

                <Field label="Voice Tiếng Việt (Vietnamese Voice ID)">
                  <input
                    className={styles.input}
                    type="text"
                    placeholder={
                      audioProvider === 'azure'
                        ? 'vi-VN-HoaiMyNeural hoặc vi-VN-NamMinhNeural'
                        : audioProvider === 'elevenlabs'
                          ? 'Voice ID tiếng Việt'
                          : 'alloy, shimmer...'
                    }
                    value={audioVoiceVi}
                    onChange={(e) => setAudioVoiceVi(e.target.value)}
                  />
                </Field>

                <Field label="Tốc độ đọc mặc định">
                  <input
                    className={styles.input}
                    type="text"
                    placeholder="1.0"
                    value={speechSpeed}
                    onChange={(e) => setSpeechSpeed(e.target.value)}
                  />
                </Field>
              </>
            )}

            {audioProvider === 'azure' && (
              <Field label="Azure Speech Key" full>
                <input
                  className={styles.input}
                  type="password"
                  placeholder={hasAzureKey ? savedPlaceholder : 'Nhập Azure Speech Key (hoặc key@region)'}
                  value={azureApiKey}
                  onChange={(e) => {
                    setAzureApiKey(e.target.value);
                    setAzureDirty(true);
                  }}
                />
              </Field>
            )}

            {audioProvider === 'elevenlabs' && (
              <Field label="ElevenLabs Key" full>
                <input
                  className={styles.input}
                  type="password"
                  placeholder={hasElevenLabsKey ? savedPlaceholder : 'Nhập ElevenLabs API Key'}
                  value={elevenLabsApiKey}
                  onChange={(e) => {
                    setElevenLabsApiKey(e.target.value);
                    setElevenLabsDirty(true);
                  }}
                />
              </Field>
            )}

            <div className={`${styles.group} ${styles.voiceTestRow}`}>
              <button
                type="button"
                className={`${styles.btnGhost} ${styles.voiceTestButton}`}
                onClick={() => onTestAudio('en')}
                disabled={audioTesting}
                title="Nghe thử giọng tiếng Anh"
              >
                <span aria-hidden="true">▶</span>
                <span>{audioTesting ? 'Đang đọc…' : 'English'}</span>
              </button>
              <button
                type="button"
                className={`${styles.btnGhost} ${styles.voiceTestButton}`}
                onClick={() => onTestAudio('vi')}
                disabled={audioTesting}
                title="Nghe thử giọng tiếng Việt"
              >
                <span aria-hidden="true">▶</span>
                <span>{audioTesting ? 'Đang đọc…' : 'Tiếng Việt'}</span>
              </button>
            </div>
          </Section>

          <Section title="Voca API" hint="API key được lưu an toàn trên server và chỉ dùng cho Voca.">
            <Field label="Voca API URL">
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
            <Field label="Voca API Key">
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
            <Field label="Nguồn phát âm">
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
                  ? 'Giọng thiết bị miễn phí và dùng ngoại tuyến.'
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

          <Section title="Thư viện">
            <label className={styles.checkboxRow}>
              <input
                type="checkbox"
                checked={form.hideFinishedBooks}
                onChange={(e) => patch({ hideFinishedBooks: e.target.checked })}
              />
              <span>
                <strong>Ẩn sách đã đọc</strong>
                <small>Sách đã hoàn thành chỉ hiện khi chọn bộ lọc “Đã đọc”.</small>
              </span>
            </label>
          </Section>
        </div>

        <div className={styles.footer}>
          <button type="button" className={styles.btnGhost} onClick={onClose}>
            Hủy
          </button>
          <button type="submit" className={styles.btnPrimary}>
            Lưu &amp; Đồng Bộ
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
