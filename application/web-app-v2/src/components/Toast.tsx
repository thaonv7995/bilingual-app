import { createContext, useCallback, useContext, useMemo, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import styles from './Toast.module.css';

export type ToastType = 'success' | 'danger' | 'info' | 'warning';

interface ToastItem {
  id: number;
  message: string;
  type: ToastType;
}

interface ToastApi {
  show: (message: string, type?: ToastType, durationMs?: number) => void;
}

const ToastContext = createContext<ToastApi | null>(null);

const ICONS: Record<ToastType, string> = {
  success: 'M9 16.2 4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4z',
  danger: 'M12 2 1 21h22zm0 6 7.5 13h-15zM11 10h2v5h-2zm0 6h2v2h-2z',
  info: 'M11 9h2V7h-2m1 13a8 8 0 1 1 0-16 8 8 0 0 1 0 16m-1-5h2v-4h-2z',
  warning: 'M1 21h22L12 2zm12-3h-2v-2h2zm0-4h-2v-4h2z',
};

/**
 * One notification system for the whole app (v1 had three: admin `showToast`,
 * the voca `.voca-toast` stack, and in-reader toasts). Stacks bottom-right,
 * auto-dismisses, and is theme-aware via design tokens.
 */
export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<ToastItem[]>([]);
  const nextId = useRef(1);

  const show = useCallback((message: string, type: ToastType = 'info', durationMs = 4000) => {
    const id = nextId.current++;
    setToasts((prev) => [...prev, { id, message, type }]);
    window.setTimeout(() => {
      setToasts((prev) => prev.filter((t) => t.id !== id));
    }, durationMs);
  }, []);

  const api = useMemo(() => ({ show }), [show]);

  return (
    <ToastContext.Provider value={api}>
      {children}
      <div className={styles.container} role="region" aria-live="polite" aria-label="Thông báo">
        {toasts.map((t) => (
          <div key={t.id} className={`${styles.toast} ${styles[t.type]}`} role="status">
            <svg className={styles.icon} viewBox="0 0 24 24" aria-hidden="true">
              <path d={ICONS[t.type]} />
            </svg>
            <span className={styles.message}>{t.message}</span>
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}

export function useToast(): ToastApi {
  const ctx = useContext(ToastContext);
  if (!ctx) throw new Error('useToast must be used within <ToastProvider>');
  return ctx;
}
