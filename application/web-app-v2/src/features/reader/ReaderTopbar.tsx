import { ProfileMenu } from '@/components/ProfileMenu';
import type { Book, ViewMode } from '@/types/api';
import { formatReaderZoom, type ZoomMode } from './readerConstants';

const VIEW_MODES: { mode: ViewMode; label: string; title: string; icon: 'book' | 'split' }[] = [
  { mode: 'en', label: 'EN', title: 'Tiếng Anh (Bản gốc)', icon: 'book' },
  { mode: 'vi', label: 'VI', title: 'Tiếng Việt (Bản dịch)', icon: 'book' },
  { mode: 'split', label: 'Song Ngữ', title: 'Song ngữ song song', icon: 'split' },
];

export function ReaderTopbar({
  book,
  page,
  viewMode,
  zoomMode,
  zoomLevel,
  chatOpen,
  username,
  isAdmin,
  onHome,
  onGoToPage,
  onStep,
  onSetViewMode,
  onSelectZoomMode,
  onAdjustZoom,
  onToggleChat,
  onOpenSettings,
  onLogout,
}: {
  book: Book;
  page: number;
  viewMode: ViewMode;
  zoomMode: ZoomMode;
  zoomLevel: number;
  chatOpen: boolean;
  username: string;
  isAdmin: boolean;
  onHome: () => void;
  onGoToPage: (page: number) => void;
  onStep: (delta: number) => void;
  onSetViewMode: (mode: ViewMode) => void;
  onSelectZoomMode: (mode: ZoomMode) => void;
  onAdjustZoom: (direction: number) => void;
  onToggleChat: () => void;
  onOpenSettings: () => void;
  onLogout: () => void;
}) {
  return (
    <div className="reader-topbar">
      <div className="reader-topbar__left">
        <button className="btn-action" onClick={onHome}>
          🏠 Library
        </button>
        <span className="reader-topbar__title">{book.title}</span>
      </div>

      <div className="reader-topbar__center">
        <div className="reader-nav">
          <button
            className="nav-btn page-nav__arrow"
            disabled={page <= 1}
            onClick={() => onStep(-1)}
            aria-label="Trang trước"
          >
            <Chevron dir="left" />
          </button>
          <span className="page-indicator">
            Trang
            <input
              className="page-input"
              type="number"
              min={1}
              max={book.pageCount}
              value={page}
              onChange={(e) => {
                let val = parseInt(e.target.value, 10);
                if (isNaN(val) || val < 1) val = 1;
                if (val > book.pageCount) val = book.pageCount;
                onGoToPage(val);
              }}
            />
            / {book.pageCount}
          </span>
          <button
            className="nav-btn page-nav__arrow"
            disabled={page >= book.pageCount}
            onClick={() => onStep(1)}
            aria-label="Trang sau"
          >
            <Chevron dir="right" />
          </button>
        </div>

        <div className="reader-zoom-toolbar" role="group" aria-label="Điều chỉnh thu phóng">
          <button className="zoom-step-btn" onClick={() => onAdjustZoom(-1)} aria-label="Thu nhỏ">
            −
          </button>
          <span className="zoom-level" aria-live="polite">
            {formatReaderZoom(zoomLevel)}
          </span>
          <button className="zoom-step-btn" onClick={() => onAdjustZoom(1)} aria-label="Phóng to">
            +
          </button>
          <span className="zoom-toolbar-divider" aria-hidden="true" />
          <button
            className={`zoom-fit-btn ${zoomMode === 'fit-page' ? 'active' : ''}`}
            onClick={() => onSelectZoomMode('fit-page')}
            title="Vừa trang (Shift+P)"
          >
            Fit Page
          </button>
          <button
            className={`zoom-fit-btn ${zoomMode === 'fit-width' ? 'active' : ''}`}
            onClick={() => onSelectZoomMode('fit-width')}
            title="Vừa chiều rộng (Shift+W)"
          >
            Fit Width
          </button>
        </div>
      </div>

      <div className="reader-topbar__right">
        <div className="view-modes">
          {VIEW_MODES.map((v) => (
            <button
              key={v.mode}
              className={`mode-btn ${viewMode === v.mode ? 'active' : ''}`}
              onClick={() => onSetViewMode(v.mode)}
              title={v.title}
            >
              {v.icon === 'split' ? <SplitIcon /> : <BookIcon />}
              <span>{v.label}</span>
            </button>
          ))}
        </div>

        <button
          className={`btn-icon ${chatOpen ? 'active' : ''}`}
          onClick={onToggleChat}
          title="Companion Reader Agent"
        >
          <ChatIcon />
        </button>

        <ProfileMenu
          variant="reader"
          username={username}
          isAdmin={isAdmin}
          onOpenSettings={onOpenSettings}
          onLogout={onLogout}
        />
      </div>
    </div>
  );
}

function Chevron({ dir }: { dir: 'left' | 'right' }) {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d={dir === 'left' ? 'm15 18-6-6 6-6' : 'm9 18 6-6-6-6'} />
    </svg>
  );
}

function BookIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20" />
      <path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z" />
    </svg>
  );
}

function SplitIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <rect x="3" y="3" width="18" height="18" rx="2" ry="2" />
      <line x1="12" y1="3" x2="12" y2="21" />
    </svg>
  );
}

function ChatIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
      <circle cx="9" cy="10" r="1" />
      <circle cx="15" cy="10" r="1" />
      <path d="M9 15h6" />
    </svg>
  );
}
