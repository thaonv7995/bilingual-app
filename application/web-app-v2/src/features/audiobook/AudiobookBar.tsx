import type { AudiobookLanguageMode } from './useAudiobook';
import styles from './AudiobookBar.module.css';

interface AudiobookBarProps {
  isPlaying: boolean;
  currentSentenceIndex: number;
  totalSentences: number;
  currentLang?: 'en' | 'vi' | null;
  mode: AudiobookLanguageMode;
  speed: string;
  provider: string;
  error: string | null;
  onPlay: () => void;
  onPause: () => void;
  onNext: () => void;
  onPrev: () => void;
  onModeChange: (mode: AudiobookLanguageMode) => void;
  onSpeedChange: (speed: string) => void;
  onClose: () => void;
}

export function AudiobookBar({
  isPlaying,
  currentSentenceIndex,
  totalSentences,
  currentLang,
  mode,
  speed,
  provider,
  error,
  onPlay,
  onPause,
  onNext,
  onPrev,
  onModeChange,
  onSpeedChange,
  onClose,
}: AudiobookBarProps) {
  return (
    <div className={styles.container} role="region" aria-label="Audiobook Player">
      {error && <div className={styles.errorBanner}>{error}</div>}

      <div className={styles.providerBadge} title={`Nguồn đọc: ${provider === 'device' ? 'Thiết bị (Offline)' : provider}`}>
        {isPlaying ? (
          <div className={styles.waveBox}>
            <span className={styles.waveBar} />
            <span className={styles.waveBar} />
            <span className={styles.waveBar} />
          </div>
        ) : (
          <span>🎧</span>
        )}
      </div>

      <div className={styles.controls}>
        <button
          className={styles.btnAction}
          onClick={onPrev}
          disabled={totalSentences === 0 || currentSentenceIndex === 0}
          title="Câu trước"
          aria-label="Câu trước"
        >
          <PrevIcon />
        </button>

        <button
          className={styles.btnPlay}
          onClick={isPlaying ? onPause : onPlay}
          title={isPlaying ? 'Tạm dừng' : 'Đọc trang sách'}
          aria-label={isPlaying ? 'Tạm dừng' : 'Đọc tiếp'}
        >
          {isPlaying ? <PauseIcon /> : <PlayIcon />}
        </button>

        <button
          className={styles.btnAction}
          onClick={onNext}
          disabled={totalSentences === 0 || currentSentenceIndex >= totalSentences - 1}
          title="Câu tiếp theo"
          aria-label="Câu tiếp theo"
        >
          <NextIcon />
        </button>
      </div>

      <span className={styles.progressText}>
        {totalSentences > 0 ? (
          <>
            {currentLang && <span className={styles.langBadge}>{currentLang}</span>}
            <span>{`${currentSentenceIndex + 1} / ${totalSentences}`}</span>
          </>
        ) : (
          '0 / 0'
        )}
      </span>

      <div className={styles.selectGroup}>
        <select
          className={styles.select}
          value={mode}
          onChange={(e) => onModeChange(e.target.value as AudiobookLanguageMode)}
          title="Chế độ đọc ngôn ngữ"
        >
          <option value="en">EN (Tiếng Anh)</option>
          <option value="vi">VI (Tiếng Việt)</option>
          <option value="bilingual">Song ngữ (EN · VI)</option>
        </select>

        <select
          className={styles.select}
          value={speed}
          onChange={(e) => onSpeedChange(e.target.value)}
          title="Tốc độ đọc"
        >
          <option value="0.8">0.8x</option>
          <option value="1.0">1.0x</option>
          <option value="1.25">1.25x</option>
          <option value="1.5">1.5x</option>
        </select>
      </div>

      <button className={styles.btnClose} onClick={onClose} title="Đóng Audiobook" aria-label="Đóng">
        ✕
      </button>
    </div>
  );
}

function PlayIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor">
      <path d="M5 3l14 9-14 9V3z" />
    </svg>
  );
}

function PauseIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor">
      <rect x="6" y="4" width="4" height="16" rx="1" />
      <rect x="14" y="4" width="4" height="16" rx="1" />
    </svg>
  );
}

function PrevIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor">
      <path d="M19 20L9 12l10-8v16zM5 19h2V5H5v14z" />
    </svg>
  );
}

function NextIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 24 24" fill="currentColor">
      <path d="M5 4l10 8-10 8V4zM19 5h-2v14h2V5z" />
    </svg>
  );
}
