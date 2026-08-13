import { createContext, useCallback, useContext, useEffect, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import styles from './Modal.module.css';

/** Presentational modal: a backdrop + centered panel. Closes on Esc / backdrop. */
export function Modal({
  open,
  onClose,
  title,
  children,
  labelledBy,
}: {
  open: boolean;
  onClose?: () => void;
  title?: ReactNode;
  children: ReactNode;
  labelledBy?: string;
}) {
  useEffect(() => {
    if (!open || !onClose) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div className={styles.backdrop} onMouseDown={onClose}>
      <div
        className={styles.panel}
        role="dialog"
        aria-modal="true"
        aria-labelledby={labelledBy}
        onMouseDown={(e) => e.stopPropagation()}
      >
        {title != null && <h2 className={styles.title}>{title}</h2>}
        {children}
      </div>
    </div>
  );
}

// -- promise-based confirm/alert ---------------------------------------------

interface ConfirmOptions {
  title?: string;
  message: ReactNode;
  confirmLabel?: string;
  cancelLabel?: string;
  danger?: boolean;
  /** true → alert (single OK button, no cancel). */
  alert?: boolean;
}

type ConfirmFn = (options: ConfirmOptions) => Promise<boolean>;

const ConfirmContext = createContext<ConfirmFn | null>(null);

/**
 * Promise-based confirm/alert, replacing v1's imperative `popupConfig` (app.js)
 * and the admin `showConfirm`. `await confirm({ message })` resolves to the
 * user's choice.
 */
export function ConfirmProvider({ children }: { children: ReactNode }) {
  const [options, setOptions] = useState<ConfirmOptions | null>(null);
  const resolver = useRef<((v: boolean) => void) | null>(null);

  const confirm = useCallback<ConfirmFn>((opts) => {
    setOptions(opts);
    return new Promise<boolean>((resolve) => {
      resolver.current = resolve;
    });
  }, []);

  const settle = useCallback((value: boolean) => {
    resolver.current?.(value);
    resolver.current = null;
    setOptions(null);
  }, []);

  return (
    <ConfirmContext.Provider value={confirm}>
      {children}
      <Modal open={options != null} onClose={() => settle(false)} title={options?.title}>
        <div className={styles.body}>{options?.message}</div>
        <div className={styles.actions}>
          {!options?.alert && (
            <button className={styles.btnGhost} onClick={() => settle(false)}>
              {options?.cancelLabel ?? 'Hủy'}
            </button>
          )}
          <button
            className={options?.danger ? styles.btnDanger : styles.btnPrimary}
            onClick={() => settle(true)}
            autoFocus
          >
            {options?.confirmLabel ?? 'Xác nhận'}
          </button>
        </div>
      </Modal>
    </ConfirmContext.Provider>
  );
}

export function useConfirm(): ConfirmFn {
  const ctx = useContext(ConfirmContext);
  if (!ctx) throw new Error('useConfirm must be used within <ConfirmProvider>');
  return ctx;
}
