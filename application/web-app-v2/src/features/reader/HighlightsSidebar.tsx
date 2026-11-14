import { useMemo, useState } from 'react';
import type { Highlight } from '@/types/api';
import { filterAndSortHighlights } from './highlightsList';
import './highlights.css';

export function HighlightsSidebar({
  open,
  currentPage,
  highlights,
  activePreviewId,
  onOpenReference,
  onDeleteHighlight,
  onClose,
}: {
  open: boolean;
  currentPage: number;
  highlights: Highlight[];
  activePreviewId?: string | null;
  onOpenReference: (highlight: Highlight) => void;
  onDeleteHighlight: (id: string) => void;
  onClose: () => void;
}) {
  const [onlyCurrentPage, setOnlyCurrentPage] = useState(false);

  const displayed = useMemo(
    () => filterAndSortHighlights(highlights, { currentPage, onlyCurrentPage }),
    [highlights, currentPage, onlyCurrentPage],
  );
  const currentPageCount = useMemo(
    () => highlights.filter((h) => h.page === currentPage).length,
    [highlights, currentPage],
  );

  return (
    <aside
      className={`highlights-sidebar ${open ? 'is-open' : ''}`}
      style={open ? { width: '320px' } : { width: 0, borderLeft: 'none' }}
      aria-label="Ghi chú và đánh dấu"
      aria-hidden={!open}
    >
      <div className="highlights-sidebar__header">
        <span className="highlights-sidebar__title">
          <span>Ghi chú & Đánh dấu</span>
          <span className="highlights-sidebar__count">{highlights.length}</span>
        </span>
        <button className="nav-btn" onClick={onClose} title="Đóng bảng ghi chú" aria-label="Đóng">
          ✕
        </button>
      </div>

      <div className="highlights-sidebar__filter" role="tablist" aria-label="Lọc đánh dấu">
        <button
          type="button"
          className={`highlights-filter-btn ${!onlyCurrentPage ? 'is-active' : ''}`}
          onClick={() => setOnlyCurrentPage(false)}
        >
          Tất cả ({highlights.length})
        </button>
        <button
          type="button"
          className={`highlights-filter-btn ${onlyCurrentPage ? 'is-active' : ''}`}
          onClick={() => setOnlyCurrentPage(true)}
        >
          Trang này ({currentPageCount})
        </button>
      </div>

      {displayed.length === 0 ? (
        <div className="highlights-sidebar__empty">
          <strong>Chưa có highlight nào</strong>
          <span>Bôi đen đoạn văn bản bất kỳ để đánh dấu hoặc thêm ghi chú.</span>
        </div>
      ) : (
        <div className="highlights-sidebar__list">
          {displayed.map((hl) => {
            const trimmedNote = hl.note?.trim();
            return (
              <div
                key={hl.id}
                role="button"
                tabIndex={open ? 0 : -1}
                className={`highlight-card ${activePreviewId === hl.id ? 'is-previewed' : ''}`}
                style={{ borderColor: `${hl.color}55` }}
                onClick={() => onOpenReference(hl)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    onOpenReference(hl);
                  }
                }}
              >
                <div className="highlight-card__meta">
                  <span className="highlight-card__badge">
                    <span className="highlight-card__dot" style={{ backgroundColor: hl.color }} />
                    Trang {hl.page} • {hl.lang.toUpperCase()}
                  </span>
                  <button
                    type="button"
                    className="highlight-card__delete"
                    title="Xoá đánh dấu"
                    aria-label="Xoá đánh dấu"
                    onClick={(e) => {
                      e.stopPropagation();
                      onDeleteHighlight(hl.id);
                    }}
                  >
                    <TrashIcon />
                  </button>
                </div>

                <div className="highlight-card__quote">“{hl.text}”</div>

                {trimmedNote && <div className="highlight-card__note">{trimmedNote}</div>}

                <div className="highlight-card__hint">
                  <span>↗ Mở trang {hl.page} ở cửa sổ xem riêng (giữ nguyên trang {currentPage})</span>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </aside>
  );
}

function TrashIcon() {
  return (
    <svg
      width="13"
      height="13"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M3 6h18" />
      <path d="M8 6V4h8v2" />
      <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6" />
    </svg>
  );
}

