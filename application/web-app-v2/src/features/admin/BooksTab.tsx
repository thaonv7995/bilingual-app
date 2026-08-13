import { useRef, useState } from 'react';
import type { DragEvent } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { apiFetch, apiJson, ensureFreshAccessToken, getAccessToken } from '@/lib/api-client';
import { useToast } from '@/components/Toast';
import { useConfirm } from '@/components/Modal';
import type { Book } from '@/types/api';
import { ADMIN_QUERY_KEY, useAdminBooks } from './adminApi';
import styles from './admin.module.css';

const API_BASE = import.meta.env.VITE_API_BASE ?? '';

interface UploadResult {
  status: number;
  responseText: string;
}

/**
 * Raw XHR upload — used instead of `fetch` purely for `upload.progress` events.
 * The bearer token is passed in (not read from a URL), so the caller can refresh
 * and retry with a fresh one on a 401.
 */
function xhrUpload(file: File, token: string, onProgress: (pct: number) => void): Promise<UploadResult> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open('POST', `${API_BASE}/api/books/upload`, true);
    xhr.withCredentials = true;
    if (token) xhr.setRequestHeader('Authorization', `Bearer ${token}`);
    xhr.upload.addEventListener('progress', (e) => {
      if (e.lengthComputable) onProgress(Math.round((e.loaded / e.total) * 100));
    });
    xhr.onload = () => resolve({ status: xhr.status, responseText: xhr.responseText });
    xhr.onerror = () => reject(new Error('network'));
    const fd = new FormData();
    fd.append('file', file);
    xhr.send(fd);
  });
}

function parseDetail(responseText: string, fallback: string): string {
  try {
    const json = JSON.parse(responseText) as { detail?: unknown };
    const d = json.detail;
    if (typeof d === 'string') return d;
    if (Array.isArray(d)) {
      const msg = d
        .map((item) => (item && typeof item === 'object' ? (item as { msg?: string }).msg : ''))
        .filter(Boolean)
        .join('; ');
      if (msg) return msg;
    }
  } catch {
    /* non-JSON body */
  }
  return fallback;
}

type Status = { kind: 'idle' } | { kind: 'muted' | 'success' | 'danger'; text: string };

export function BooksTab() {
  const toast = useToast();
  const confirm = useConfirm();
  const queryClient = useQueryClient();
  const { data: books = [], isLoading, isError } = useAdminBooks();

  const fileInputRef = useRef<HTMLInputElement>(null);
  const [dragging, setDragging] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [progress, setProgress] = useState(0);
  const [status, setStatus] = useState<Status>({ kind: 'idle' });
  const [deletingSlug, setDeletingSlug] = useState<string | null>(null);
  const [downloadingSlug, setDownloadingSlug] = useState<string | null>(null);

  const refreshBooks = () => queryClient.invalidateQueries({ queryKey: ADMIN_QUERY_KEY });

  async function handleUpload(file: File | null | undefined) {
    if (!file) return;
    // Guard against double-submit: ignore any file dropped while one is in flight.
    if (uploading) return;

    if (!file.name.endsWith('.bkb')) {
      toast.show('Định dạng file không hỗ trợ. Vui lòng chọn file .bkb', 'danger');
      resetFileInput();
      return;
    }

    setUploading(true);
    setProgress(0);
    setStatus({ kind: 'muted', text: 'Đang bắt đầu tải lên...' });

    try {
      let result = await xhrUpload(file, getAccessToken(), setProgress);
      if (result.status === 401) {
        // Access token expired mid-session — mint a fresh one and retry once.
        const fresh = await ensureFreshAccessToken(true);
        result = await xhrUpload(file, fresh, setProgress);
      }

      if (result.status === 200) {
        setProgress(100);
        setStatus({ kind: 'success', text: 'Hoàn tất tải lên!' });
        toast.show('Nạp sách thành công', 'success');
        void refreshBooks();
        window.setTimeout(() => setStatus({ kind: 'idle' }), 3000);
      } else {
        const detail = parseDetail(result.responseText, 'Lỗi hệ thống');
        setStatus({ kind: 'danger', text: detail });
        toast.show('Lỗi tải sách: ' + detail, 'danger');
      }
    } catch {
      setStatus({ kind: 'danger', text: 'Mất kết nối với máy chủ.' });
      toast.show('Lỗi kết nối', 'danger');
    } finally {
      setUploading(false);
      // Reset so re-selecting the same file re-fires the change event.
      resetFileInput();
    }
  }

  function resetFileInput() {
    if (fileInputRef.current) fileInputRef.current.value = '';
  }

  function onDrop(e: DragEvent<HTMLDivElement>) {
    e.preventDefault();
    setDragging(false);
    const file = e.dataTransfer.files?.[0];
    void handleUpload(file);
  }

  async function handleDownload(slug: string) {
    if (downloadingSlug) return;
    setDownloadingSlug(slug);
    try {
      const res = await apiFetch(`/api/books/${slug}/download`);
      if (!res.ok) {
        toast.show('Tải sách thất bại.', 'danger');
        return;
      }
      const blob = await res.blob();
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `${slug}.bkb`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
    } catch {
      toast.show('Lỗi kết nối khi tải sách.', 'danger');
    } finally {
      setDownloadingSlug(null);
    }
  }

  async function handleDelete(slug: string, title: string) {
    if (deletingSlug) return;
    const ok = await confirm({
      title: 'Xóa sách',
      danger: true,
      confirmLabel: 'Xóa vĩnh viễn',
      message: (
        <>
          Cảnh báo: Bạn có chắc muốn xóa cuốn sách <strong>"{title}"</strong>?
          <br />
          <br />
          File vật lý và tất cả highlight liên quan sẽ bị xóa vĩnh viễn khỏi hệ thống.
        </>
      ),
    });
    if (!ok) return;

    setDeletingSlug(slug);
    try {
      await apiJson(`/api/books/${slug}`, { method: 'DELETE' });
      toast.show(`Đã xóa "${title}" thành công.`, 'success');
      void refreshBooks();
    } catch (err) {
      toast.show('Xóa sách thất bại: ' + (err instanceof Error ? err.message : ''), 'danger');
    } finally {
      setDeletingSlug(null);
    }
  }

  // Newest first, matching v1.
  const ordered = [...books].reverse();

  return (
    <div className={styles.tabPanel}>
      <section className={styles.card}>
        <div className={styles.cardHeader}>
          <h2>Tải Sách Mới (.bkb Package)</h2>
        </div>
        <div
          className={`${styles.uploadZone} ${dragging ? styles.uploadZoneDrag : ''}`}
          onClick={() => fileInputRef.current?.click()}
          onDragEnter={(e) => {
            e.preventDefault();
            setDragging(true);
          }}
          onDragOver={(e) => {
            e.preventDefault();
            setDragging(true);
          }}
          onDragLeave={(e) => {
            e.preventDefault();
            setDragging(false);
          }}
          onDrop={onDrop}
        >
          <div className={styles.uploadIcon}>
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M9 16H15V10H19L12 3L5 10H9V16M5 20V18H19V20H5Z" />
            </svg>
          </div>
          <p>
            Nhấp hoặc kéo thả file <strong>.bkb</strong> vào đây
          </p>
          <span className={styles.uploadHint}>Kích thước khuyên dùng &lt; 50MB</span>
          <input
            ref={fileInputRef}
            type="file"
            className={styles.hiddenInput}
            accept=".bkb"
            onChange={(e) => void handleUpload(e.target.files?.[0])}
          />
          {(uploading || progress > 0) && (
            <div className={styles.progressContainer}>
              <div className={styles.progressBar} style={{ width: `${progress}%` }} />
            </div>
          )}
          {status.kind !== 'idle' && (
            <div
              className={`${styles.statusMsg} ${
                status.kind === 'success'
                  ? styles.statusSuccess
                  : status.kind === 'danger'
                    ? styles.statusDanger
                    : styles.statusMuted
              }`}
            >
              {status.text}
            </div>
          )}
        </div>
      </section>

      <section className={styles.card}>
        <div className={styles.cardHeader}>
          <h2>Tủ Sách Hiện Có</h2>
        </div>
        <div className={styles.booksGrid}>
          {isLoading ? (
            <div className={styles.booksEmpty}>Đang tải tủ sách…</div>
          ) : isError ? (
            <div className={styles.booksEmpty}>Không thể tải danh sách sách.</div>
          ) : ordered.length === 0 ? (
            <div className={styles.booksEmpty}>Chưa có cuốn sách nào trong thư viện.</div>
          ) : (
            ordered.map((book) => (
              <BookCard
                key={book.slug}
                book={book}
                downloading={downloadingSlug === book.slug}
                deleting={deletingSlug === book.slug}
                onDownload={() => void handleDownload(book.slug)}
                onDelete={() => void handleDelete(book.slug, book.title)}
              />
            ))
          )}
        </div>
      </section>
    </div>
  );
}

function BookCard({
  book,
  downloading,
  deleting,
  onDownload,
  onDelete,
}: {
  book: Book;
  downloading: boolean;
  deleting: boolean;
  onDownload: () => void;
  onDelete: () => void;
}) {
  return (
    <div className={styles.bookCard}>
      <div className={styles.bookCover}>
        {book.cover ? (
          <img src={book.cover} alt={book.title} />
        ) : (
          <div className={styles.coverFallback}>
            <h4>{book.title}</h4>
          </div>
        )}
        <div className={styles.actionsOverlay}>
          <button
            type="button"
            className={`${styles.btn} ${styles.btnSecondary} ${styles.btnSm}`}
            onClick={onDownload}
            disabled={downloading}
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M5 20H19V18H5V20M19 9H15V3H9V9H5L12 16L19 9Z" />
            </svg>
            {downloading ? 'Đang tải…' : 'Tải về .bkb'}
          </button>
          <button
            type="button"
            className={`${styles.btn} ${styles.btnDanger} ${styles.btnSm}`}
            onClick={onDelete}
            disabled={deleting}
          >
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M19,4H15.5L14.5,3H9.5L8.5,4H5V6H19M6,19A2,2 0 0,0 8,21H16A2,2 0 0,0 18,19V7H6V19Z" />
            </svg>
            {deleting ? 'Đang xóa…' : 'Xóa sách'}
          </button>
        </div>
      </div>
      <div className={styles.bookBody}>
        <div className={styles.bookTitle} title={book.title}>
          {book.title}
        </div>
        <div className={styles.bookAuthor}>{book.author || 'Không rõ tác giả'}</div>
        <div className={styles.bookMeta}>
          <span>{book.pageCount} trang</span>
          <span className={styles.bookSlug} title={book.slug}>
            {book.slug}
          </span>
        </div>
      </div>
    </div>
  );
}
