import { useEffect, useRef, useState } from 'react';
import { getVocaLookupPanelCss, removeVocaLookupPanel } from '@/lib/voca';
import { HIGHLIGHT_COLORS } from './highlightColors';
import { handleReaderVocaLookup } from './iframe/pageFrameUtils';

const HOST_VOCA_STYLE_ID = 'bilingual-host-voca-style';

export function ensureHostVocaStyles(): void {
  if (typeof document === 'undefined') return;
  if (document.getElementById(HOST_VOCA_STYLE_ID)) return;
  const style = document.createElement('style');
  style.id = HOST_VOCA_STYLE_ID;
  style.textContent = getVocaLookupPanelCss();
  document.head.appendChild(style);
}

export interface SelectionPopoverState {
  mode: 'create' | 'edit';
  text: string;
  rect: DOMRect;
  highlightId?: string;
  color?: string;
  note?: string;
}

export function DocumentSelectionPopover({
  state,
  onSelectColor,
  onSaveNote,
  onDelete,
  onAskAi,
  onClose,
}: {
  state: SelectionPopoverState;
  onSelectColor: (color: string) => void;
  onSaveNote: (color: string, note: string) => void;
  onDelete?: () => void;
  onAskAi?: (text: string) => void;
  onClose: () => void;
}) {
  const [noteOpen, setNoteOpen] = useState(Boolean(state.mode === 'edit' && state.note));
  const [noteText, setNoteText] = useState(state.note ?? '');
  const [activeColor, setActiveColor] = useState(state.color || HIGHLIGHT_COLORS[0]!.value);
  const rootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    ensureHostVocaStyles();
  }, []);

  useEffect(() => {
    setNoteText(state.note ?? '');
    setNoteOpen(Boolean(state.mode === 'edit' && state.note));
    setActiveColor(state.color || HIGHLIGHT_COLORS[0]!.value);
  }, [state]);

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        removeVocaLookupPanel(document);
        onClose();
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [onClose]);

  const vw = typeof window !== 'undefined' ? window.innerWidth : 1200;
  const vh = typeof window !== 'undefined' ? window.innerHeight : 800;
  const centerX = state.rect.left + state.rect.width / 2;
  const left = Math.max(140, Math.min(vw - 140, centerX));
  const showBelow = state.rect.top < 76;
  const top = showBelow
    ? Math.min(vh - 70, state.rect.bottom + 10)
    : Math.max(58, state.rect.top - 10);

  return (
    <div
      ref={rootRef}
      className={`doc-selection-popover ${showBelow ? 'is-below' : ''}`}
      style={{ left: `${left}px`, top: `${top}px` }}
      onMouseDown={(e) => e.stopPropagation()}
      onMouseUp={(e) => e.stopPropagation()}
      onClick={(e) => e.stopPropagation()}
    >
      <div className="doc-selection-toolbar">
        <div className="doc-selection-toolbar__colors">
          {HIGHLIGHT_COLORS.map((c) => (
            <button
              key={c.value}
              type="button"
              className={`doc-selection-toolbar__color ${activeColor === c.value ? 'is-active' : ''}`}
              style={{ backgroundColor: c.value }}
              title={c.label}
              aria-label={`Highlight ${c.label}`}
              onClick={() => {
                setActiveColor(c.value);
                onSelectColor(c.value);
              }}
            />
          ))}
        </div>

        <span className="doc-selection-toolbar__divider" aria-hidden="true" />

        <button
          type="button"
          className={`doc-selection-toolbar__btn ${noteOpen ? 'is-active' : ''}`}
          title="Thêm / sửa ghi chú"
          aria-label="Ghi chú"
          onClick={() => setNoteOpen((v) => !v)}
        >
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M12 20h9" />
            <path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z" />
          </svg>
        </button>

        {state.text.trim().length > 0 && (
          <button
            type="button"
            className="doc-selection-toolbar__btn"
            title="Tra cứu từ điển Voca"
            aria-label="Tra cứu Voca"
            onClick={() => {
              const targetRect = state.rect;
              const word = state.text;
              onClose();
              void handleReaderVocaLookup(word, document, targetRect);
            }}
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20" />
              <path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z" />
            </svg>
          </button>
        )}

        {onAskAi && state.text.trim().length > 0 && (
          <button
            type="button"
            className="doc-selection-toolbar__btn"
            title="Hỏi AI về đoạn này"
            aria-label="Hỏi AI"
            onClick={() => {
              onAskAi(state.text);
              onClose();
            }}
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
            </svg>
          </button>
        )}

        {state.mode === 'edit' && onDelete && (
          <button
            type="button"
            className="doc-selection-toolbar__btn is-danger"
            title="Xóa highlight"
            aria-label="Xóa highlight"
            onClick={onDelete}
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M3 6h18" />
              <path d="M8 6V4h8v2" />
              <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6" />
            </svg>
          </button>
        )}
      </div>

      {noteOpen && (
        <div className="doc-selection-note">
          <textarea
            className="doc-selection-note__input"
            placeholder="Nhập ghi chú..."
            value={noteText}
            autoFocus
            onChange={(e) => setNoteText(e.target.value)}
            onKeyDown={(e) => {
              e.stopPropagation();
              if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
                e.preventDefault();
                onSaveNote(activeColor, noteText.trim());
              }
            }}
          />
          <div className="doc-selection-note__footer">
            <button
              type="button"
              className="doc-selection-note__btn"
              onClick={() => setNoteOpen(false)}
            >
              Huỷ
            </button>
            <button
              type="button"
              className="doc-selection-note__btn is-primary"
              onClick={() => onSaveNote(activeColor, noteText.trim())}
            >
              Lưu
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
