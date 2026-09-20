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
        <button
          className={`${styles.priorityButton} ${book.isPriority ? styles.priorityButtonActive : ''}`}
          aria-label={book.isPriority ? 'Bỏ ưu tiên' : 'Ưu tiên đọc'}
          title={book.isPriority ? 'Bỏ ưu tiên' : 'Ưu tiên đọc'}
          onClick={(event) => {
            event.stopPropagation();
            onStateChange({ isPriority: !book.isPriority });
          }}
        >
          <StarIcon filled={book.isPriority} />
        </button>
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

function StarIcon({ filled }: { filled: boolean }) {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill={filled ? 'currentColor' : 'none'}
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2" />
    </svg>
  );
}
