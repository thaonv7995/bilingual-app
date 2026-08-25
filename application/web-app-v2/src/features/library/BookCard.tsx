import { useNavigate } from 'react-router-dom';
import { getLocalProgress } from '@/features/reader/localProgress';
import type { Book } from '@/types/api';
import styles from './library.module.css';

/** A single library tile: cover (or gradient fallback), resume-progress bar,
 * title, and page/lang meta. Clicking opens the reader at the saved page. */
export function BookCard({ book, index }: { book: Book; index: number }) {
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
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault();
          open();
        }
      }}
    >
      <div className={styles.coverWrapper}>
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
