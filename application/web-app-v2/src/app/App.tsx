import { useEffect } from 'react';
import { QueryClientProvider } from '@tanstack/react-query';
import { BrowserRouter, Navigate, Route, Routes } from 'react-router-dom';
import { ToastProvider } from '@/components/Toast';
import { ConfirmProvider } from '@/components/Modal';
import { LoginView } from '@/features/auth/LoginView';
import { LibraryView } from '@/features/library/LibraryView';
import { ReaderView } from '@/features/reader/ReaderView';
import { useAuthStore } from '@/features/auth/authStore';
import {
  getServerSettings,
  migrateLegacySecrets,
  saveServerSettings,
  USER_SETTINGS_KEY,
} from '@/features/settings/serverSecrets';
import {
  LEGACY_PUBLIC_SETTINGS,
  useSettingsStore,
} from '@/features/settings/settingsStore';
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
  const settingsHydrated = useSettingsStore((s) => s.hydrated);

  useEffect(() => {
    void bootstrap();
  }, [bootstrap]);

  // The server is the single source of truth. After authentication:
  // 1. migrate legacy secrets and public preferences once;
  // 2. fetch the canonical server state;
  // 3. hydrate the synchronous runtime store used by feature modules.
  useEffect(() => {
    if (status !== 'authenticated') return;

    let cancelled = false;

    const hydrateSettings = async () => {
      try {
        const migratedSecrets = await migrateLegacySecrets();

        const hasLegacyPublicSettings =
          Object.keys(LEGACY_PUBLIC_SETTINGS).length > 0;

        if (hasLegacyPublicSettings) {
          await saveServerSettings(LEGACY_PUBLIC_SETTINGS);
        }

        if (migratedSecrets || hasLegacyPublicSettings) {
          await queryClient.invalidateQueries({
            queryKey: USER_SETTINGS_KEY,
          });
        }

        const serverSettings = await queryClient.fetchQuery({
          queryKey: USER_SETTINGS_KEY,
          queryFn: getServerSettings,
        });

        if (!cancelled) {
          useSettingsStore.getState().replaceSettings(serverSettings);
        }
      } catch (error) {
        console.error('[settings] failed to hydrate from server', error);

        // Do not silently switch back to local persistence. Defaults remain in
        // memory and the next authenticated load will retry the server.
        if (!cancelled) {
          useSettingsStore.getState().replaceSettings(
            useSettingsStore.getState().settings,
          );
        }
      }
    };

    void hydrateSettings();

    return () => {
      cancelled = true;
    };
  }, [status]);

  if (status === 'loading') return <SplashScreen />;
  if (status !== 'authenticated') return <LoginView />;
  if (!settingsHydrated) return <SettingsSplashScreen />;

  return (
    <Routes>
      <Route path="/" element={<LibraryView />} />
      <Route path="/read/:slug" element={<ReaderView />} />
      <Route path="/read/:slug/page/:page" element={<ReaderView />} />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}

function SettingsSplashScreen() {
  return (
    <div style={{ display: 'grid', placeItems: 'center', height: '100%' }}>
      <p style={{ color: 'var(--text-muted)' }}>
        Đang đồng bộ cài đặt từ server…
      </p>
    </div>
  );
}

function SplashScreen() {
  return (
    <div style={{ display: 'grid', placeItems: 'center', height: '100%' }}>
      <p style={{ color: 'var(--text-muted)' }}>Đang tải…</p>
    </div>
  );
}
