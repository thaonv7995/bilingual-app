import { useState } from 'react';
import type { FormEvent } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { apiJson } from '@/lib/api-client';
import { useToast } from '@/components/Toast';
import { useConfirm } from '@/components/Modal';
import { ADMIN_QUERY_KEY, useAdminBooks, useAdminUsers, usePermissions } from './adminApi';
import styles from './admin.module.css';

export function UsersTab() {
  const toast = useToast();
  const confirm = useConfirm();
  const queryClient = useQueryClient();

  const { data: users = [] } = useAdminUsers();
  const { data: books = [] } = useAdminBooks();
  const { data: permissions = [] } = usePermissions();

  const [showCreate, setShowCreate] = useState(false);
  const [newUsername, setNewUsername] = useState('');
  const [newPassword, setNewPassword] = useState('');
  const [creating, setCreating] = useState(false);

  const [selectedUser, setSelectedUser] = useState('');
  const [selectedBook, setSelectedBook] = useState('');
  const [granting, setGranting] = useState(false);
  const [revokingId, setRevokingId] = useState<number | null>(null);

  const readers = users.filter((u) => !u.is_admin);
  const refreshAll = () => queryClient.invalidateQueries({ queryKey: ADMIN_QUERY_KEY });

  async function handleCreateUser(e: FormEvent) {
    e.preventDefault();
    if (creating) return;
    const username = newUsername.trim();
    const password = newPassword.trim();
    if (!username || !password) return;

    setCreating(true);
    try {
      await apiJson('/api/auth/register', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password }),
      });
      toast.show(`Đã tạo tài khoản "${username}" thành công.`, 'success');
      setShowCreate(false);
      setNewUsername('');
      setNewPassword('');
      void refreshAll();
    } catch (err) {
      toast.show('Lỗi tạo tài khoản: ' + (err instanceof Error ? err.message : ''), 'danger');
    } finally {
      setCreating(false);
    }
  }

  async function handleGrant() {
    if (granting) return;
    if (!selectedUser || !selectedBook) {
      toast.show('Vui lòng chọn thông tin hợp lệ', 'warning');
      return;
    }
    setGranting(true);
    try {
      await apiJson(
        `/api/admin/permissions?user_id=${encodeURIComponent(selectedUser)}&book_slug=${encodeURIComponent(selectedBook)}`,
        { method: 'POST' },
      );
      toast.show('Cấp quyền thành công', 'success');
      void refreshAll();
    } catch (err) {
      toast.show('Lỗi cấp quyền: ' + (err instanceof Error ? err.message : ''), 'danger');
    } finally {
      setGranting(false);
    }
  }

  async function handleRevoke(id: number) {
    if (revokingId) return;
    const ok = await confirm({
      title: 'Thu hồi quyền',
      danger: true,
      confirmLabel: 'Thu hồi',
      message: 'Xác nhận thu hồi quyền truy cập này?',
    });
    if (!ok) return;

    setRevokingId(id);
    try {
      await apiJson(`/api/admin/permissions/${id}`, { method: 'DELETE' });
      toast.show('Thu hồi quyền thành công', 'success');
      void refreshAll();
    } catch (err) {
      toast.show('Lỗi thu hồi quyền: ' + (err instanceof Error ? err.message : ''), 'danger');
    } finally {
      setRevokingId(null);
    }
  }

  return (
    <div className={styles.tabPanel}>
      <section className={styles.card}>
        <div className={styles.cardHeader}>
          <h2>Tài Khoản Độc Giả</h2>
          <button
            type="button"
            className={`${styles.btn} ${styles.btnSm} ${styles.btnSecondary}`}
            onClick={() => {
              setShowCreate((v) => !v);
              setNewUsername('');
              setNewPassword('');
            }}
          >
            {showCreate ? 'Đóng Form' : 'Thêm Độc Giả'}
          </button>
        </div>

        {showCreate && (
          <div className={styles.creationBox}>
            <form onSubmit={handleCreateUser}>
              <div className={styles.formRow}>
                <div className={styles.formGroupTight}>
                  <label className={styles.label} htmlFor="new-username">
                    Tài khoản (Username)
                  </label>
                  <input
                    id="new-username"
                    className={styles.input}
                    type="text"
                    required
                    autoComplete="off"
                    placeholder="Nhập tên đăng nhập"
                    value={newUsername}
                    onChange={(e) => setNewUsername(e.target.value)}
                  />
                </div>
                <div className={styles.formGroupTight}>
                  <label className={styles.label} htmlFor="new-password">
                    Mật khẩu
                  </label>
                  <input
                    id="new-password"
                    className={styles.input}
                    type="password"
                    required
                    autoComplete="new-password"
                    placeholder="Nhập mật khẩu"
                    value={newPassword}
                    onChange={(e) => setNewPassword(e.target.value)}
                  />
                </div>
              </div>
              <div className={styles.formActions}>
                <button type="submit" className={`${styles.btn} ${styles.btnSm}`} disabled={creating}>
                  {creating ? 'Đang tạo…' : 'Tạo Tài Khoản'}
                </button>
                <button
                  type="button"
                  className={`${styles.btn} ${styles.btnSecondary} ${styles.btnSm}`}
                  onClick={() => setShowCreate(false)}
                >
                  Hủy
                </button>
              </div>
            </form>
          </div>
        )}

        <div style={{ marginTop: '1.5rem' }}>
          <h3 className={styles.sectionTitle}>Cấp Quyền Đọc Sách</h3>
          <div className={`${styles.formRow} ${styles.formRowEnd}`}>
            <div className={styles.formGroupTight}>
              <label className={styles.label} htmlFor="select-user">
                Chọn Độc Giả
              </label>
              <select
                id="select-user"
                className={styles.select}
                value={selectedUser}
                onChange={(e) => setSelectedUser(e.target.value)}
              >
                {readers.length === 0 ? (
                  <option value="" disabled>
                    -- Chưa có độc giả nào --
                  </option>
                ) : (
                  <>
                    <option value="" disabled>
                      -- Chọn độc giả --
                    </option>
                    {readers.map((u) => (
                      <option key={u.id} value={String(u.id)}>
                        {u.username}
                      </option>
                    ))}
                  </>
                )}
              </select>
            </div>
            <div className={styles.formGroupTight}>
              <label className={styles.label} htmlFor="select-book">
                Chọn Sách
              </label>
              <select
                id="select-book"
                className={styles.select}
                value={selectedBook}
                onChange={(e) => setSelectedBook(e.target.value)}
              >
                {books.length === 0 ? (
                  <option value="" disabled>
                    -- Thư viện trống --
                  </option>
                ) : (
                  <>
                    <option value="" disabled>
                      -- Chọn sách --
                    </option>
                    {books.map((b) => (
                      <option key={b.slug} value={b.slug}>
                        {b.title}
                      </option>
                    ))}
                  </>
                )}
              </select>
            </div>
            <button type="button" className={styles.btn} onClick={handleGrant} disabled={granting}>
              {granting ? 'Đang cấp…' : 'Cấp Quyền'}
            </button>
          </div>
        </div>
      </section>

      <section className={styles.card}>
        <div className={styles.cardHeader}>
          <h2>Danh Sách Phân Quyền</h2>
        </div>
        <div className={styles.tableContainer}>
          <table className={styles.table}>
            <thead>
              <tr>
                <th>Tài Khoản</th>
                <th>Sách Được Truy Cập</th>
                <th className={styles.thAction}>Hành Động</th>
              </tr>
            </thead>
            <tbody>
              {permissions.length === 0 ? (
                <tr>
                  <td colSpan={3} className={styles.emptyRow}>
                    Chưa có quyền đọc nào được cấp phát.
                  </td>
                </tr>
              ) : (
                permissions.map((p) => {
                  const user = users.find((u) => u.id === p.user_id);
                  const book = books.find((b) => b.slug === p.book_slug);
                  return (
                    <tr key={p.id}>
                      <td className={styles.cellStrong}>{user ? user.username : `User ID ${p.user_id}`}</td>
                      <td>{book ? book.title : p.book_slug}</td>
                      <td>
                        <div className={styles.actionsRight}>
                          <button
                            type="button"
                            className={`${styles.btn} ${styles.btnOutlineDanger} ${styles.btnSm}`}
                            onClick={() => void handleRevoke(p.id)}
                            disabled={revokingId === p.id}
                          >
                            {revokingId === p.id ? 'Đang thu hồi…' : 'Thu hồi'}
                          </button>
                        </div>
                      </td>
                    </tr>
                  );
                })
              )}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}
