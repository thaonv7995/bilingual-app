import { translateColor } from '@/features/reader/highlightColors';
import type { useVoice } from './useVoice';
import './voice.css';

type Voice = ReturnType<typeof useVoice>;

function statusText(v: Voice): string {
  if (v.state === 'connecting') return 'Đang kết nối Realtime...';
  if (v.state === 'error') return `Lỗi: ${v.error || 'Không thể kết nối'}`;
  if (v.state !== 'live') return 'Đang ngoại tuyến';
  if (v.speakingState === 'ai-speaking') return '🔊 AI đang nói...';
  if (v.speakingState === 'user-speaking') return '🎤 Đang nghe bạn...';
  return v.micMuted ? '🔇 Mic tắt' : '🎙️ Đang lắng nghe';
}

function toolText(tc: NonNullable<Voice['toolCall']>): string {
  switch (tc.name) {
    case 'highlight_text':
      return `Đã highlight "${tc.text}" màu ${translateColor(tc.color || 'yellow')}`;
    case 'remove_highlight':
      return `Đã xóa highlight "${tc.text}"`;
    case 'lookup_word':
      return `Đang tra từ "${tc.text}"...`;
    case 'add_word_to_voca':
      return `Đã thêm "${tc.text}" vào Voca`;
    case 'go_to_page':
      return `Chuyển sang trang ${tc.text}`;
    case 'next_page':
      return 'Trang tiếp theo';
    case 'previous_page':
      return 'Trang trước';
    default:
      return `Thực thi ${tc.name}`;
  }
}

export function VoiceOverlay({ voice }: { voice: Voice }) {
  const { state, speakingState, micMuted, toolCall, caption, userTranscript } = voice;

  return (
    <div className="voice-overlay">
      <div className="voice-status">
        <span className={`status-dot ${state}`} />
        <span className="status-text">{statusText(voice)}</span>
      </div>

      <div className="voice-center">
        {state === 'error' ? (
          <div className="voice-error">
            <div className="voice-error-icon">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#ef4444" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <circle cx="12" cy="12" r="10" />
                <line x1="15" y1="9" x2="9" y2="15" />
                <line x1="9" y1="9" x2="15" y2="15" />
              </svg>
            </div>
            <div className="voice-error-text">{voice.error || 'Không thể kết nối với Voice Mode'}</div>
            <button className="voice-retry-btn" onClick={voice.retry}>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" style={{ marginRight: 6 }}>
                <path d="M23 4v6h-6" />
                <path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10" />
              </svg>
              Thử lại
            </button>
          </div>
        ) : (
          <div className="voice-visualizer">
            <div className={`voice-orb ${speakingState}`}>
              <div className={`voice-pulse-ring ${speakingState}`} />
              <div className={`voice-pulse-ring ring-2 ${speakingState}`} />
              <div className={`voice-icon-inner ${speakingState} ${micMuted && speakingState === 'listening' ? 'muted' : ''}`}>
                {speakingState === 'ai-speaking' ? <SpeakerIcon /> : micMuted ? <MicOffIcon /> : <MicIcon />}
              </div>
            </div>
            <div className={`voice-wave-bars ${speakingState}`}>
              {[0, 1, 2, 3, 4].map((i) => (
                <span key={i} className="bar" />
              ))}
            </div>
          </div>
        )}

        {toolCall && (
          <div className={`voice-tool-feedback ${toolCall.status}`}>
            <span className="tool-feedback-icon">
              {toolCall.status === 'executing' ? <span className="tool-spinner" /> : toolCall.status === 'success' ? '✅' : '❌'}
            </span>
            <span className="tool-feedback-text">{toolText(toolCall)}</span>
          </div>
        )}

        {caption && (
          <div className="voice-live-caption">
            <span className="caption-label" style={{ color: '#c084fc' }}>AI</span>
            <span className="caption-text">{caption}</span>
          </div>
        )}
        {userTranscript && (
          <div className="voice-live-caption user-caption">
            <span className="caption-label" style={{ color: '#818cf8' }}>Bạn</span>
            <span className="caption-text">{userTranscript}</span>
          </div>
        )}
      </div>

      <div className="voice-bottom-controls">
        <button
          className={`voice-mic-btn ${micMuted ? 'muted' : ''} ${speakingState === 'ai-speaking' ? 'disabled' : ''}`}
          onClick={voice.toggleMic}
          disabled={speakingState === 'ai-speaking'}
          title={micMuted ? 'Bật mic' : 'Tắt mic'}
        >
          {micMuted ? <MicOffIcon small /> : <MicIcon small />}
        </button>
        <button className="voice-end-btn" onClick={voice.stop}>
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" style={{ marginRight: 6 }}>
            <path d="M10.68 13.31a16 16 0 0 0 3.41 2.6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7 2 2 0 0 1 1.72 2v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91z" />
            <line x1="23" y1="1" x2="17" y2="7" />
            <line x1="17" y1="1" x2="23" y2="7" />
          </svg>
          Kết thúc
        </button>
      </div>
    </div>
  );
}

function MicIcon({ small }: { small?: boolean }) {
  const s = small ? 16 : 24;
  return (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z" />
      <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
    </svg>
  );
}
function MicOffIcon({ small }: { small?: boolean }) {
  const s = small ? 16 : 24;
  return (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <line x1="1" y1="1" x2="23" y2="23" />
      <path d="M9 9v3a3 3 0 0 0 5.12 2.12M15 9.34V4a3 3 0 0 0-5.94-.6" />
      <path d="M17 16.95A7 7 0 0 1 5 12v-2m14 0v2c0 .76-.13 1.49-.35 2.17" />
    </svg>
  );
}
function SpeakerIcon() {
  return (
    <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5" />
      <path d="M19.07 4.93a10 10 0 0 1 0 14.14M15.54 8.46a5 5 0 0 1 0 7.07" />
    </svg>
  );
}
