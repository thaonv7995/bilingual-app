import { useState } from 'react';
import type { FormEvent } from 'react';
import { apiJson } from '@/lib/api-client';
import { useToast } from '@/components/Toast';
import styles from './admin.module.css';

/** Change the current admin's password, then force a re-login (the old session's
 * tokens are no longer valid). */
export function ChangePasswordTab({ onLogout }: { onLogout: () => void }) {
  const toast = useToast();
  const [current, setCurrent] = useState('');
  const [next, setNext] = useState('');
  const [confirmPw, setConfirmPw] = useState('');
  const [error, setError] = useState('');
  const [submitting, setSubmitting] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (submitting) return;
    setError('');

    if (next.length < 4) {
      setError('Mật khẩu mới phải có ít nhất 4 ký tự.');
      return;
    }
    if (next !== confirmPw) {
      setError('Mật khẩu mới và xác nhận mật khẩu không khớp.');
      return;
    }
    if (current === next) {
      setError('Mật khẩu mới phải khác mật khẩu hiện tại.');
      return;
    }

    setSubmitting(true);
    try {
      await apiJson('/api/auth/change-password', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ current_password: current, new_password: next }),
      });
      toast.show('Đổi mật khẩu thành công! Vui lòng đăng nhập lại.', 'success');
      setCurrent('');
      setNext('');
      setConfirmPw('');
      window.setTimeout(() => onLogout(), 1500);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Đổi mật khẩu thất bại.');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className={styles.tabPanel}>
      <section className={styles.card} style={{ maxWidth: 520 }}>
        <div className={styles.cardHeader}>
          <h2>Đổi Mật Khẩu Quản Trị</h2>
        </div>
        <p className={styles.mutedNote}>
          Cập nhật mật khẩu đăng nhập cho tài khoản admin hiện tại. Sau khi đổi, bạn sẽ cần đăng nhập lại.
        </p>
        <form onSubmit={handleSubmit}>
          <div className={styles.formGroup}>
            <label className={styles.label} htmlFor="current-password">
              Mật khẩu hiện tại
            </label>
            <input
              id="current-password"
              className={styles.input}
              type="password"
              required
              autoComplete="current-password"
              placeholder="Nhập mật khẩu hiện tại"
              value={current}
              onChange={(e) => setCurrent(e.target.value)}
            />
          </div>
          <div className={styles.formGroup}>
            <label className={styles.label} htmlFor="new-password-input">
              Mật khẩu mới
            </label>
            <input
              id="new-password-input"
              className={styles.input}
              type="password"
              required
              minLength={4}
              autoComplete="new-password"
              placeholder="Nhập mật khẩu mới (tối thiểu 4 ký tự)"
              value={next}
              onChange={(e) => setNext(e.target.value)}
            />
          </div>
          <div className={styles.formGroup}>
            <label className={styles.label} htmlFor="confirm-password">
              Xác nhận mật khẩu mới
            </label>
            <input
              id="confirm-password"
              className={styles.input}
              type="password"
              required
              autoComplete="new-password"
              placeholder="Nhập lại mật khẩu mới"
              value={confirmPw}
              onChange={(e) => setConfirmPw(e.target.value)}
            />
          </div>
          {error && <div className={styles.errorText}>{error}</div>}
          <button type="submit" className={styles.btn} disabled={submitting}>
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zM12 17c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1s3.1 1.39 3.1 3.1v2z" />
            </svg>
            {submitting ? 'Đang cập nhật…' : 'Cập Nhật Mật Khẩu'}
          </button>
        </form>
      </section>
    </div>
  );
}
