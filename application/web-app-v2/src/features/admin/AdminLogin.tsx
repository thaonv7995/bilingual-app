import { useState } from 'react';
import type { FormEvent } from 'react';
import { apiJson, setAccessToken } from '@/lib/api-client';
import { useToast } from '@/components/Toast';
import type { AuthResponse } from '@/types/api';
import styles from './admin.module.css';

/**
 * Admin sign-in. Credentials go in the JSON body (never the query string), and
 * we require `is_admin` before letting the caller in.
 */
export function AdminLogin({ onSuccess }: { onSuccess: () => void }) {
  const toast = useToast();
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [submitting, setSubmitting] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (submitting) return;
    setError('');
    setSubmitting(true);
    try {
      const data = await apiJson<AuthResponse>('/api/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password }),
      });
      if (!data.is_admin) {
        setError('Bạn không có quyền quản trị viên.');
        return;
      }
      setAccessToken(data.access_token);
      toast.show('Đăng nhập thành công', 'success');
      onSuccess();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Đăng nhập thất bại.');
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className={styles.loginContainer}>
      <div className={styles.loginBox}>
        <div className={styles.loginIcon}>
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 3c1.66 0 3 1.34 3 3s-1.34 3-3 3-3-1.34-3-3 1.34-3 3-3zm0 14.2c-2.5 0-4.71-1.28-6-3.22.03-1.99 4-3.08 6-3.08 1.99 0 5.97 1.09 6 3.08-1.29 1.94-3.5 3.22-6 3.22z" />
          </svg>
        </div>
        <h1 className={styles.loginTitle}>Đăng nhập Quản trị</h1>
        <form onSubmit={handleSubmit}>
          <div className={styles.formGroup}>
            <label className={styles.label} htmlFor="admin-username">
              Tài khoản
            </label>
            <input
              id="admin-username"
              className={styles.input}
              type="text"
              required
              autoComplete="username"
              placeholder="admin"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
            />
          </div>
          <div className={styles.formGroup}>
            <label className={styles.label} htmlFor="admin-password">
              Mật khẩu
            </label>
            <input
              id="admin-password"
              className={styles.input}
              type="password"
              required
              autoComplete="current-password"
              placeholder="••••••••"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
            />
          </div>
          {error && <div className={styles.loginError}>{error}</div>}
          <button type="submit" className={`${styles.btn} ${styles.blockBtn}`} disabled={submitting}>
            {submitting ? 'Đang đăng nhập…' : 'Đăng nhập'}
          </button>
        </form>
      </div>
    </div>
  );
}
