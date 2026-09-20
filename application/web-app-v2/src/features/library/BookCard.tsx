import { useNavigate } from 'react-router-dom';
import { getLocalProgress } from '@/features/reader/localProgress';
import type { Book, BookStatePatch } from '@/types/api';
import styles from './library.module.css';

/** A single library tile: cover (or gradient fallback), resume-progress bar,
 * title, and page/lang meta. Clicking opens the reader at the saved page. */
export function BookCard({
  book,
  index,
  onStateChange,
}: {
  book: Book;
  index: number;
  onStateChange: (patch: BookStatePatch) => void;
}) {
  const navigate = useNavigate();
  const progress = getLocalProgress(book.slug);
  const hasProgress = !!(progress && progress.page > 1 && book.pageCount);
  const progressPercent = hasProgress
    ? Math.min(100, Math.round((progress!.page / book.pageCount) * 100))
    : 0;

  // Resume route (no explicit page): the reader seeds from local progress
  // instantly, then reconciles with the backend copy. A page in the URL would
  // read as a deep link and pin the reader to the local page.
  const open = () => {
    navigate(`/read/${encodeURIComponent(book.slug)}`);
  };

  return (
    <div
      className={styles.card}
      style={{ animationDelay: `${index * 40}ms` }}
      onClick={open}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => {
        if (e.target !== e.currentTarget) return;
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          open();
        }
      }}
    >
      <div className={styles.coverWrapper}>
        <div className={styles.bookActions}>
          <button
            className={book.isPriority ? styles.bookActionActive : styles.bookAction}
            title={book.isPriority ? 'Bỏ ưu tiên' : 'Ưu tiên đọc'}
            aria-label={book.isPriority ? 'Bỏ ưu tiên' : 'Ưu tiên đọc'}
            onClick={(event) => {
              event.stopPropagation();
              onStateChange({ isPriority: !book.isPriority });
            }}
          >
            ★
          </button>
          <button
            className={book.onShelf ? styles.bookActionActive : styles.bookAction}
            title={book.onShelf ? 'Bỏ khỏi kệ' : 'Cho lên kệ'}
            aria-label={book.onShelf ? 'Bỏ khỏi kệ' : 'Cho lên kệ'}
            onClick={(event) => {
              event.stopPropagation();
              onStateChange({ onShelf: !book.onShelf });
            }}
          >
            ▣
          </button>
          <button
            className={book.isFinished ? styles.bookActionActive : styles.bookAction}
            title={book.isFinished ? 'Đánh dấu chưa đọc xong' : 'Đánh dấu đã đọc'}
            aria-label={book.isFinished ? 'Đánh dấu chưa đọc xong' : 'Đánh dấu đã đọc'}
            onClick={(event) => {
              event.stopPropagation();
              onStateChange({ isFinished: !book.isFinished });
            }}
          >
            ✓
          </button>
        </div>
        {book.cover ? (
          <img className={styles.coverImg} src={book.cover} alt={book.title} />
        ) : (
          <div className={styles.coverFallback}>
            <h4>{book.title}</h4>
            <p>{book.author}</p>
          </div>
        )}
        {hasProgress && (
          <div className={styles.progressTrack}>
            <div className={styles.progressFill} style={{ width: `${progressPercent}%` }} />
          </div>
        )}
      </div>
      <div className={styles.cardContent}>
        <h3 className={styles.cardTitle}>{book.title}</h3>
        <div className={styles.meta}>
          <span>
            {hasProgress
              ? `${progress!.page}/${book.pageCount} trang`
              : book.pageCount
                ? `${book.pageCount} trang`
                : ''}
          </span>
          <span className={styles.langs}>EN · VI</span>
        </div>
      </div>
    </div>
  );
}
