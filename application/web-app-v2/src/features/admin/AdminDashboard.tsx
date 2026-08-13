import { useState } from 'react';
import type { ReactNode } from 'react';
import { BooksTab } from './BooksTab';
import { UsersTab } from './UsersTab';
import { ApiKeysTab } from './ApiKeysTab';
import { ChangePasswordTab } from './ChangePasswordTab';
import styles from './admin.module.css';

type TabId = 'books' | 'users' | 'apikeys' | 'password';

interface TabDef {
  id: TabId;
  navLabel: string;
  title: string;
  icon: ReactNode;
}

const TABS: TabDef[] = [
  {
    id: 'books',
    navLabel: 'Quản Lý Tủ Sách',
    title: 'Quản Lý Tủ Sách',
    icon: <path d="M12 2A10 10 0 0 0 2 12A10 10 0 0 0 12 22A10 10 0 0 0 22 12A10 10 0 0 0 12 2M19 13H13V19H11V13H5V11H11V5H13V11H19V13Z" />,
  },
  {
    id: 'users',
    navLabel: 'Người Dùng & Quyền',
    title: 'Người Dùng & Phân Quyền',
    icon: <path d="M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z" />,
  },
  {
    id: 'apikeys',
    navLabel: 'Quản Lý API Key',
    title: 'Quản Lý API Key',
    icon: <path d="M12.65 11C11.83 7.56 8.77 5 5 5c-4.42 0-8 3.58-8 8s3.58 8 8 8c3.77 0 6.83-2.56 7.65-6H17v3h4v-3h2v-4H12.65zM5 17c-2.21 0-4-1.79-4-4s1.79-4 4-4 4 1.79 4 4-1.79 4-4 4z" />,
  },
  {
    id: 'password',
    navLabel: 'Đổi Mật Khẩu',
    title: 'Đổi Mật Khẩu Admin',
    icon: <path d="M18 8h-1V6c0-2.76-2.24-5-5-5S7 3.24 7 6v2H6c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V10c0-1.1-.9-2-2-2zM12 17c-1.1 0-2-.9-2-2s.9-2 2-2 2 .9 2 2-.9 2-2 2zm3.1-9H8.9V6c0-1.71 1.39-3.1 3.1-3.1s3.1 1.39 3.1 3.1v2z" />,
  },
];

export function AdminDashboard({ onLogout }: { onLogout: () => void }) {
  const [active, setActive] = useState<TabId>('books');
  const activeTab = TABS.find((t) => t.id === active);
  const pageTitle = activeTab?.title ?? '';

  return (
    <div className={styles.layout}>
      <aside className={styles.sidebar}>
        <div className={styles.sidebarHeader}>
          <div className={styles.logo}>
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M19 2H5C3.89 2 3 2.9 3 4V20C3 21.1 3.9 22 5 22H19C20.11 22 21 21.1 21 20V4C21 2.9 20.11 2 19 2M19 20H5V4H19V20M12 9V11H17V9H12M12 13V15H17V13H12M8 9V11H10V9H8M8 13V15H10V13H8Z" />
            </svg>
            <span>Admin Portal</span>
          </div>
        </div>
        <nav className={styles.sidebarNav}>
          {TABS.map((tab) => (
            <button
              key={tab.id}
              type="button"
              className={`${styles.navItem} ${active === tab.id ? styles.navItemActive : ''}`}
              onClick={() => setActive(tab.id)}
            >
              <svg viewBox="0 0 24 24" aria-hidden="true">
                {tab.icon}
              </svg>
              <span>{tab.navLabel}</span>
            </button>
          ))}
        </nav>
      </aside>

      <div className={styles.mainWrapper}>
        <header className={styles.topbar}>
          <div className={styles.pageTitle}>{pageTitle}</div>
          <div className={styles.topbarActions}>
            <a href="/" target="_blank" rel="noreferrer">
              View Web App ↗
            </a>
            <button
              type="button"
              className={`${styles.btn} ${styles.btnSm} ${styles.btnOutlineDanger}`}
              onClick={onLogout}
            >
              Đăng xuất
            </button>
          </div>
        </header>

        <main className={styles.content}>
          {active === 'books' && <BooksTab />}
          {active === 'users' && <UsersTab />}
          {active === 'apikeys' && <ApiKeysTab />}
          {active === 'password' && <ChangePasswordTab onLogout={onLogout} />}
        </main>
      </div>
    </div>
  );
}
