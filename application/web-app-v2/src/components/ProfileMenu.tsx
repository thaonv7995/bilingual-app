import { useEffect, useRef, useState } from 'react';
import styles from './ProfileMenu.module.css';

const ICON = {
  admin: 'M3 3h7v9H3zM14 3h7v5h-7zM14 12h7v9h-7zM3 16h7v5H3z',
  settings:
    'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6m7.4-3a7.5 7.5 0 0 0-.1-1l2-1.6-2-3.4-2.4 1a7 7 0 0 0-1.7-1l-.4-2.5H9.2l-.4 2.5a7 7 0 0 0-1.7 1l-2.4-1-2 3.4 2 1.6a7.5 7.5 0 0 0 0 2l-2 1.6 2 3.4 2.4-1a7 7 0 0 0 1.7 1l.4 2.5h5.6l.4-2.5a7 7 0 0 0 1.7-1l2.4 1 2-3.4-2-1.6c.1-.3.1-.7.1-1',
  logout: 'M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9',
};

/**
 * User menu shared by the library header and the reader topbar (v1 duplicated
 * this markup in both). `variant` switches between the pill (dashboard) and the
 * compact reader button.
 */
export function ProfileMenu({
  username,
  isAdmin,
  variant = 'dashboard',
  onOpenSettings,
  onLogout,
}: {
  username: string;
  isAdmin: boolean;
  variant?: 'dashboard' | 'reader';
  onOpenSettings: () => void;
  onLogout: () => void;
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onDocClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener('click', onDocClick);
    return () => document.removeEventListener('click', onDocClick);
  }, [open]);

  const initials = username.slice(0, 2);

  return (
    <div
      ref={ref}
      className={`${styles.container} ${open ? styles.open : ''}`}
      data-variant={variant}
    >
      <button
        type="button"
        className={`${styles.trigger} ${variant === 'reader' ? styles.triggerReader : ''}`}
        onClick={(e) => {
          e.stopPropagation();
          setOpen((v) => !v);
        }}
        aria-haspopup="menu"
        aria-expanded={open}
      >
        <span className={styles.avatar}>{initials}</span>
        <span className={styles.name}>{username}</span>
        {variant === 'reader' && (
          <svg className={styles.arrow} width="14" height="14" viewBox="0 0 24 24" aria-hidden="true">
            <path d="m6 9 6 6 6-6" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" />
          </svg>
        )}
      </button>

      <div className={styles.menu} role="menu">
        {isAdmin && (
          <a className={styles.item} href="/admin" target="_blank" rel="noreferrer" role="menuitem">
            <Icon d={ICON.admin} />
            <span>Admin Site</span>
          </a>
        )}
        <button
          type="button"
          className={styles.item}
          role="menuitem"
          onClick={() => {
            setOpen(false);
            onOpenSettings();
          }}
        >
          <Icon d={ICON.settings} />
          <span>Cấu hình Companion Agent</span>
        </button>
        <div className={styles.divider} />
        <button
          type="button"
          className={`${styles.item} ${styles.logout}`}
          role="menuitem"
          onClick={() => {
            setOpen(false);
            onLogout();
          }}
        >
          <Icon d={ICON.logout} />
          <span>Đăng xuất</span>
        </button>
      </div>
    </div>
  );
}

function Icon({ d }: { d: string }) {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={d} />
    </svg>
  );
}
