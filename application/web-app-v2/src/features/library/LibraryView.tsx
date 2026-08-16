import { useEffect, useMemo, useState } from 'react';
import { ProfileMenu } from '@/components/ProfileMenu';
import { SettingsModal } from '@/features/settings/SettingsModal';
import { useAuthStore } from '@/features/auth/authStore';
import { getLocalProgress } from '@/features/reader/localProgress';
import { BookCard } from './BookCard';
import { sortBooks } from './bookOrder';
import { useBooks } from './useBooks';
import styles from './library.module.css';

const GRID_MAX_WIDTH = 1600; // .dashboard max-width
const GRID_H_PADDING = 80; // .dashboard padding: 0 40px

/** How many columns the responsive grid shows, so page size tracks the layout
 * (v1 used cols*3). Derived from the viewport width against the container model
 * and the CSS breakpoints in library.module.css (auto-fill minmax: 150px below
 * 600px, else 180px). Window-based so it never depends on mount/layout timing. */
function computeColumns(viewportWidth: number): number {
  const contentWidth = Math.min(viewportWidth, GRID_MAX_WIDTH) - GRID_H_PADDING;
  const narrow = viewportWidth < 600;
  const minTrack = narrow ? 150 : 180;
  const gap = narrow ? 18 : 24;
  return Math.max(1, Math.floor((contentWidth + gap) / (minTrack + gap)));
}

function useColumnCount(): number {
  const [cols, setCols] = useState(() =>
    computeColumns(typeof window !== 'undefined' ? window.innerWidth : 1200),
  );
  useEffect(() => {
    const onResize = () => setCols(computeColumns(window.innerWidth));
    onResize();
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, []);
  return cols;
}

export function LibraryView() {
  const user = useAuthStore((s) => s.user);
  const logout = useAuthStore((s) => s.logout);
  const { data: books = [], isLoading, isError } = useBooks();

  const [settingsOpen, setSettingsOpen] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const cols = useColumnCount();
  const pageSize = Math.max(1, cols * 3);

  // Shelf order FIRST — before search and before pagination, otherwise page 1
  // would show whichever books the filter happened to keep, not the top of the
  // shelf. The server already sorts, but we re-apply the same comparator with
  // the local progress cache folded in (effectiveLastRead), so a book the user
  // just finished jumps to position 1 immediately — no refetch, works offline.
  // Recomputed per mount, which is exactly when we come back from the reader.
  const ordered = useMemo(
    () => sortBooks(books, (b) => getLocalProgress(b.slug)?.lastRead),
    [books],
  );

  // Filtering preserves relative order, so the shelf order survives search.
  const filtered = useMemo(() => {
    const q = searchQuery.trim().toLowerCase();
    if (!q) return ordered;
    return ordered.filter(
      (b) => b.title.toLowerCase().includes(q) || (b.author ?? '').toLowerCase().includes(q),
    );
  }, [ordered, searchQuery]);

  const totalPages = Math.max(1, Math.ceil(filtered.length / pageSize));
  const clampedPage = Math.min(currentPage, totalPages);
  const paginated = useMemo(
    () => filtered.slice((clampedPage - 1) * pageSize, clampedPage * pageSize),
    [filtered, clampedPage, pageSize],
  );

  return (
    <div className={styles.appContainer}>
      <header className={styles.header}>
        <div className={styles.headerContainer}>
          <h1 className={styles.brand}>Bilingual Digital Library</h1>
          <div className={styles.search}>
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
              <circle cx="11" cy="11" r="8" />
              <line x1="21" y1="21" x2="16.65" y2="16.65" />
            </svg>
            <input
              type="search"
              placeholder={`Tìm trong ${books.length} cuốn sách...`}
              value={searchQuery}
              onChange={(e) => {
                setSearchQuery(e.target.value);
                setCurrentPage(1);
              }}
            />
          </div>
          {user && (
            <ProfileMenu
              username={user.username}
              isAdmin={user.is_admin}
              onOpenSettings={() => setSettingsOpen(true)}
              onLogout={logout}
            />
          )}
        </div>
      </header>

      <main className={styles.dashboard}>
        {isLoading ? (
          <div className={styles.noResults}>Đang tải thư viện…</div>
        ) : isError ? (
          <div className={styles.noResults}>Không tải được thư viện. Vui lòng thử lại.</div>
        ) : books.length === 0 ? (
          <EmptyLibrary />
        ) : (
          <>
            {filtered.length === 0 ? (
              <div className={styles.noResults}>
                Không tìm thấy sách nào khớp với "<strong>{searchQuery}</strong>"
              </div>
            ) : (
              <div className={styles.booksGrid}>
                {paginated.map((book, index) => (
                  <BookCard key={book.slug} book={book} index={index} />
                ))}
              </div>
            )}

            {totalPages > 1 && (
              <div className={styles.pagination}>
                <button
                  className={styles.paginationArrow}
                  disabled={clampedPage <= 1}
                  onClick={() => setCurrentPage((p) => Math.max(1, p - 1))}
                  aria-label="Trang trước"
                >
                  ◀
                </button>
                <span className={styles.paginationInfo}>
                  Trang {clampedPage} / {totalPages}
                </span>
                <button
                  className={styles.paginationArrow}
                  disabled={clampedPage >= totalPages}
                  onClick={() => setCurrentPage((p) => Math.min(totalPages, p + 1))}
                  aria-label="Trang sau"
                >
                  ▶
                </button>
              </div>
            )}
          </>
        )}
      </main>

      <footer className={styles.footer}>
        <p>© 2026 Bilingual Book Reader. Digital restoration crafted with ♥ by @thaonv795.</p>
      </footer>

      {settingsOpen && <SettingsModal onClose={() => setSettingsOpen(false)} />}
    </div>
  );
}

function EmptyLibrary() {
  return (
    <div className={styles.emptyState}>
      <div className={styles.emptyIcon}>📚</div>
      <h3>Thư viện song ngữ trống</h3>
      <p>
        Hệ thống vừa được reset dữ liệu sạch sẽ. Vui lòng nhấn nút{' '}
        <strong>Admin Site</strong> phía trên thanh công cụ để truy cập trang quản trị và tải lên
        tệp sách <code>.bkb</code> của bạn!
      </p>
    </div>
  );
}
