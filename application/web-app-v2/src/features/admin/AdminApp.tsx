import { useEffect, useState } from 'react';
import { QueryClientProvider } from '@tanstack/react-query';
import { queryClient } from '@/app/queryClient';
import { ToastProvider } from '@/components/Toast';
import { ConfirmProvider } from '@/components/Modal';
import { apiJson, clearAccessToken, ensureFreshAccessToken } from '@/lib/api-client';
import type { User } from '@/types/api';
import { AdminLogin } from './AdminLogin';
import { AdminDashboard } from './AdminDashboard';
import styles from './admin.module.css';

/**
 * Admin entry (separate Vite bundle from the reader SPA).
 *
 * All dynamic data is rendered via escaped JSX — never `innerHTML` — closing the
 * stored-XSS holes v1 had in book titles, usernames, API-key names, and server
 * error strings. Credentials travel in JSON bodies and downloads use blob URLs,
 * so no secret ever lands in a URL.
 */
export function AdminApp() {
  return (
    <QueryClientProvider client={queryClient}>
      <ToastProvider>
        <ConfirmProvider>
          <AdminGate />
        </ConfirmProvider>
      </ToastProvider>
    </QueryClientProvider>
  );
}

type Status = 'loading' | 'anonymous' | 'authenticated';

function AdminGate() {
  const [status, setStatus] = useState<Status>('loading');

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        // Mint an access token from the HttpOnly refresh cookie, then confirm
        // this session is actually an admin before showing the dashboard.
        await ensureFreshAccessToken();
        const me = await apiJson<User>('/api/auth/me');
        if (cancelled) return;
        if (me.is_admin) {
          setStatus('authenticated');
        } else {
          clearAccessToken();
          setStatus('anonymous');
        }
      } catch {
        if (cancelled) return;
        clearAccessToken();
        setStatus('anonymous');
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  async function handleLogout() {
    clearAccessToken();
    try {
      await apiJson('/api/auth/logout', { method: 'POST' });
    } catch {
      /* best-effort; the local token is already cleared */
    }
    setStatus('anonymous');
  }

  if (status === 'loading') {
    return (
      <div className={styles.loginContainer}>
        <p style={{ color: 'var(--text-muted)' }}>Đang tải…</p>
      </div>
    );
  }

  if (status !== 'authenticated') {
    return <AdminLogin onSuccess={() => setStatus('authenticated')} />;
  }

  return <AdminDashboard onLogout={() => void handleLogout()} />;
}
