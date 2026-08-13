import { create } from 'zustand';
import {
  apiJson,
  clearAccessToken,
  ensureFreshAccessToken,
  registerSessionExpiredHandler,
  setAccessToken,
} from '@/lib/api-client';
import type { AuthResponse, User } from '@/types/api';

type AuthStatus = 'loading' | 'authenticated' | 'anonymous';

interface AuthState {
  status: AuthStatus;
  user: User | null;
  loginError: string | null;
  /** Restore a session on app load using the HttpOnly refresh cookie. */
  bootstrap: () => Promise<void>;
  login: (username: string, password: string) => Promise<boolean>;
  logout: () => Promise<void>;
}

export const useAuthStore = create<AuthState>((set) => ({
  status: 'loading',
  user: null,
  loginError: null,

  bootstrap: async () => {
    try {
      // No access token in memory after a reload — mint one from the cookie.
      await ensureFreshAccessToken(true);
      const user = await apiJson<User>('/api/auth/me');
      set({ status: 'authenticated', user });
    } catch {
      clearAccessToken();
      set({ status: 'anonymous', user: null });
    }
  },

  login: async (username, password) => {
    set({ loginError: null });
    try {
      // v2 sends credentials in the JSON body, never the URL query string.
      const data = await apiJson<AuthResponse>('/api/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password }),
      });
      setAccessToken(data.access_token);
      set({
        status: 'authenticated',
        user: { username: data.username, is_admin: data.is_admin },
      });
      return true;
    } catch (err) {
      set({ loginError: err instanceof Error ? err.message : 'Đăng nhập thất bại' });
      return false;
    }
  },

  logout: async () => {
    try {
      await apiJson('/api/auth/logout', { method: 'POST' });
    } catch {
      /* best-effort; clear locally regardless */
    }
    clearAccessToken();
    set({ status: 'anonymous', user: null });
  },
}));

// A terminal refresh failure (expired/invalid refresh cookie) logs the user out.
registerSessionExpiredHandler(() => {
  clearAccessToken();
  useAuthStore.setState({ status: 'anonymous', user: null });
});
