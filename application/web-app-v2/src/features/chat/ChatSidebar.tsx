import { useEffect, useRef } from 'react';
import { useToast } from '@/components/Toast';
import type { Book, Highlight } from '@/types/api';
import { renderMessageContent } from './markdown';
import { useChat } from './useChat';
import './chat.css';

const MIN_WIDTH = 280;
const MAX_WIDTH = 800;

export function ChatSidebar({
  book,
  page,
  highlights,
  open,
  chatWidth,
  onClose,
  onWidthChange,
  onResizing,
}: {
  book: Book;
  page: number;
  highlights: Highlight[];
  open: boolean;
  chatWidth: number;
  onClose: () => void;
  onWidthChange: (width: number) => void;
  onResizing: () => void;
}) {
  const toast = useToast();
  const {
    messages,
    chatInput,
    setChatInput,
    chatPending,
    suggestedPrompts,
    isRecordingMic,
    sendMessage,
    cancel,
    clearChat,
    toggleSpeech,
  } = useChat({ book, page, highlights, open });

  const sidebarRef = useRef<HTMLDivElement>(null);
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const resizingRef = useRef(false);
  const rafRef = useRef<number | undefined>(undefined);

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'auto' });
  }, [messages, chatPending]);

  // Drag-resize the panel (ported from v1 app.js:1037-1085).
  useEffect(() => {
    const onMove = (e: MouseEvent) => {
      if (!resizingRef.current) return;
      const width = Math.min(MAX_WIDTH, Math.max(MIN_WIDTH, window.innerWidth - e.clientX));
      if (sidebarRef.current) sidebarRef.current.style.width = `${width}px`;
      if (rafRef.current) cancelAnimationFrame(rafRef.current);
      rafRef.current = requestAnimationFrame(onResizing);
    };
    const onUp = () => {
      if (!resizingRef.current) return;
      resizingRef.current = false;
      document.body.classList.remove('is-resizing');
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
      const finalWidth = parseInt(sidebarRef.current?.style.width || '', 10);
      if (!isNaN(finalWidth)) onWidthChange(finalWidth);
    };
    document.addEventListener('mousemove', onMove);
    document.addEventListener('mouseup', onUp);
    return () => {
      document.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseup', onUp);
    };
  }, [onResizing, onWidthChange]);

  const startResizing = (e: React.MouseEvent) => {
    e.preventDefault();
    resizingRef.current = true;
    document.body.classList.add('is-resizing');
    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';
  };

  return (
    <div
      ref={sidebarRef}
      className="chat-sidebar"
      style={open ? { width: `${chatWidth}px` } : { width: 0, borderLeft: 'none', overflow: 'hidden' }}
    >
      <div className="chat-resize-handle" onMouseDown={startResizing} />

      <div className="chat-header">
        <span className="chat-header__title">
          🤖 Companion Reader Agent
          <span className="chat-header__badge">Context Active</span>
        </span>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          <button
            className="nav-btn"
            onClick={() => toast.show('Voice Conversation sẽ có ở phase kế tiếp', 'info')}
            title="Voice Conversation"
          >
            <MicIcon />
          </button>
          {messages.length > 0 && (
            <button className="nav-btn" onClick={clearChat} title="Làm mới phiên chat">
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                <path d="M23 4v6h-6" />
                <path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10" />
              </svg>
            </button>
          )}
          <button className="nav-btn" onClick={onClose} aria-label="Đóng chat">
            ✕
          </button>
        </div>
      </div>

      <div className="chat-messages">
        {messages.map((msg, idx) => (
          <div
            key={idx}
            className={`chat-bubble ${msg.role === 'user' ? 'bubble-user' : 'bubble-assistant'} ${msg.pending ? 'pending' : ''}`}
          >
            {msg.pending ? (
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, color: 'var(--text-muted)' }}>
                <span>Đang trả lời</span>
                <div className="typing-indicator">
                  <span />
                  <span />
                  <span />
                </div>
              </div>
            ) : (
              renderMessageContent(msg.content)
            )}
          </div>
        ))}
        <div ref={messagesEndRef} />
      </div>

      <div className="chat-quick-actions">
        <button
          className="quick-prompt-btn"
          onClick={() => sendMessage('Tóm tắt trang này vừa đủ để mình nắm ý chính và đọc tiếp.')}
        >
          📝 Tóm tắt trang
        </button>
        {suggestedPrompts.map((item, idx) => (
          <button key={idx} className="quick-prompt-btn" onClick={() => sendMessage(item.prompt)}>
            {item.icon || '❓'} {item.title}
          </button>
        ))}
      </div>

      <div className="chat-composer">
        <div className="chat-composer-container">
          <textarea
            className="chat-input"
            placeholder="Hỏi về trang này hoặc toàn bộ sách..."
            value={chatInput}
            onChange={(e) => setChatInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault();
                sendMessage();
              }
            }}
          />
          <div className="chat-composer-actions">
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <span className="chat-char-counter">{chatInput.length} ký tự</span>
              <button
                className={`chat-mic-btn ${isRecordingMic ? 'recording' : ''}`}
                onClick={toggleSpeech}
                title="Nhập liệu bằng giọng nói"
                style={{ background: 'none', border: 'none', cursor: 'pointer', color: isRecordingMic ? '#ef4444' : '#64748b', display: 'flex', padding: 4, borderRadius: 4 }}
              >
                <MicIcon strokeWidth={2.2} />
              </button>
            </div>
            {chatPending ? (
              <button className="chat-send-btn chat-cancel-btn" onClick={cancel} title="Hủy phản hồi">
                <svg width="16" height="16" viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="16" rx="2" ry="2" fill="currentColor" /></svg>
              </button>
            ) : (
              <button className="chat-send-btn" disabled={!chatInput.trim()} onClick={() => sendMessage()}>
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                  <line x1="22" y1="2" x2="11" y2="13" />
                  <polygon points="22 2 15 22 11 13 2 9 22 2" />
                </svg>
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

function MicIcon({ strokeWidth = 2 }: { strokeWidth?: number }) {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={strokeWidth} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z" />
      <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
      <line x1="12" y1="19" x2="12" y2="23" />
      <line x1="8" y1="23" x2="16" y2="23" />
    </svg>
  );
}
