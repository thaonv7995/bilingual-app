import { useEffect } from 'react';
import { QueryClientProvider } from '@tanstack/react-query';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { ToastProvider } from '@/components/Toast';
import { ConfirmProvider } from '@/components/Modal';
import { LoginView } from '@/features/auth/LoginView';
import { LibraryView } from '@/features/library/LibraryView';
import { ReaderView } from '@/features/reader/ReaderView';
import { useAuthStore } from '@/features/auth/authStore';
import { queryClient } from './queryClient';

/**
 * Reader SPA shell: providers + routes.
 *
 * Routes mirror v1's hash routes but use browser history (SPA fallback is added
 * on the backend at cutover):
 *   /                          → library
 *   /read/:slug                → reader (resume saved page)
 *   /read/:slug/page/:page     → reader at a specific page
 *
 * Views are filled in per phase; placeholders keep the scaffold building.
 */
export function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <ToastProvider>
        <ConfirmProvider>
          <BrowserRouter>
            <AuthGate />
          </BrowserRouter>
        </ConfirmProvider>
      </ToastProvider>
    </QueryClientProvider>
  );
}

function AuthGate() {
  const status = useAuthStore((s) => s.status);
  const bootstrap = useAuthStore((s) => s.bootstrap);

  useEffect(() => {
    void bootstrap();
  }, [bootstrap]);

  if (status === 'loading') return <SplashScreen />;
  if (status !== 'authenticated') return <LoginView />;

  return (
    <Routes>
      <Route path="/" element={<LibraryView />} />
      <Route path="/read/:slug" element={<ReaderView />} />
      <Route path="/read/:slug/page/:page" element={<ReaderView />} />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}

function SplashScreen() {
  return (
    <div style={{ display: 'grid', placeItems: 'center', height: '100%' }}>
      <p style={{ color: 'var(--text-muted)' }}>Đang tải…</p>
    </div>
  );
}
