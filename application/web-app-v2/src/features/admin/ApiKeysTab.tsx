import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { apiJson } from '@/lib/api-client';
import { useToast } from '@/components/Toast';
import { useConfirm } from '@/components/Modal';
import { ADMIN_QUERY_KEY, useApiKeys } from './adminApi';
import type { CreateApiKeyResponse } from './adminApi';
import styles from './admin.module.css';

export function ApiKeysTab() {
  const toast = useToast();
  const confirm = useConfirm();
  const queryClient = useQueryClient();
  const { data: keys = [] } = useApiKeys();

  const [showCreate, setShowCreate] = useState(false);
  const [name, setName] = useState('');
  const [creating, setCreating] = useState(false);
  const [revealedKey, setRevealedKey] = useState('');
  const [revokingId, setRevokingId] = useState<number | null>(null);

  const refreshAll = () => queryClient.invalidateQueries({ queryKey: ADMIN_QUERY_KEY });

  function toggleCreate() {
    setShowCreate((v) => !v);
    setRevealedKey('');
    setName('');
  }

  async function handleCreate() {
    // Guard against double-submit so a second click can't mint (and lose) a key.
    if (creating) return;
    const trimmed = name.trim();
    if (!trimmed) {
      toast.show('Vui lòng nhập tên nhận diện cho Key', 'warning');
      return;
    }
    setCreating(true);
    try {
      const res = await apiJson<CreateApiKeyResponse>(
        `/api/admin/apikeys?name=${encodeURIComponent(trimmed)}`,
        { method: 'POST' },
      );
      setRevealedKey(res.key_value);
      toast.show('Đã khởi tạo API Key mới', 'success');
      void refreshAll();
    } catch (err) {
      toast.show('Tạo API Key thất bại: ' + (err instanceof Error ? err.message : ''), 'danger');
    } finally {
      setCreating(false);
    }
  }

  async function handleRevoke(id: number) {
    if (revokingId) return;
    const ok = await confirm({
      title: 'Vô hiệu hóa Key',
      danger: true,
      confirmLabel: 'Vô hiệu hóa',
      message: 'Xác nhận vô hiệu hóa API Key này? Mọi tác vụ dùng key này sẽ thất bại lập tức.',
    });
    if (!ok) return;

    setRevokingId(id);
    try {
      await apiJson(`/api/admin/apikeys/${id}`, { method: 'DELETE' });
      toast.show('API Key đã bị vô hiệu hóa', 'success');
      void refreshAll();
    } catch (err) {
      toast.show('Lỗi vô hiệu hóa Key: ' + (err instanceof Error ? err.message : ''), 'danger');
    } finally {
      setRevokingId(null);
    }
  }

  return (
    <div className={styles.tabPanel}>
      <section className={styles.card}>
        <div className={styles.cardHeader}>
          <h2>Quản Lý API Keys</h2>
          <button type="button" className={`${styles.btn} ${styles.btnSm}`} onClick={toggleCreate}>
            {showCreate ? 'Hủy thao tác' : 'Tạo API Key'}
          </button>
        </div>

        {showCreate && (
          <div className={styles.creationBox}>
            <h3>Đăng ký API Key mới</h3>
            <div className={styles.formGroup}>
              <label className={styles.label} htmlFor="apikey-name">
                Tên nhãn (Ví dụ: Dịch thuật CLI, Backend Sync)
              </label>
              <input
                id="apikey-name"
                className={styles.input}
                type="text"
                placeholder="Tên gợi nhớ cho Key này"
                value={name}
                onChange={(e) => setName(e.target.value)}
              />
            </div>
            <div className={styles.formActions} style={{ marginTop: 0 }}>
              <button type="button" className={`${styles.btn} ${styles.btnSm}`} onClick={handleCreate} disabled={creating}>
                {creating ? 'Đang khởi tạo…' : 'Khởi tạo Key'}
              </button>
              <button
                type="button"
                className={`${styles.btn} ${styles.btnSecondary} ${styles.btnSm}`}
                onClick={() => setShowCreate(false)}
              >
                Hủy
              </button>
            </div>

            {revealedKey && (
              <div className={styles.keyReveal}>
                <p>Lưu lại API Key này (nó sẽ không hiển thị lại nữa):</p>
                <code className={styles.keyRevealValue}>{revealedKey}</code>
              </div>
            )}
          </div>
        )}

        <div className={styles.tableContainer}>
          <table className={styles.table}>
            <thead>
              <tr>
                <th>Tên Nhãn Key</th>
                <th>Key Prefix</th>
                <th>Trạng Thái</th>
                <th className={styles.thAction}>Hành Động</th>
              </tr>
            </thead>
            <tbody>
              {keys.length === 0 ? (
                <tr>
                  <td colSpan={4} className={styles.emptyRow}>
                    Chưa có API Key nào trong hệ thống.
                  </td>
                </tr>
              ) : (
                keys.map((k) => (
                  <tr key={k.id}>
                    <td className={styles.cellStrong}>{k.name}</td>
                    <td className={styles.cellMono}>{k.key_value.slice(0, 15)}...</td>
                    <td>
                      <span className={`${styles.badge} ${k.is_active ? styles.badgeSuccess : styles.badgeDanger}`}>
                        {k.is_active ? 'Hoạt động' : 'Đã thu hồi'}
                      </span>
                    </td>
                    <td>
                      <div className={styles.actionsRight}>
                        {k.is_active ? (
                          <button
                            type="button"
                            className={`${styles.btn} ${styles.btnOutlineDanger} ${styles.btnSm}`}
                            onClick={() => void handleRevoke(k.id)}
                            disabled={revokingId === k.id}
                          >
                            {revokingId === k.id ? 'Đang xử lý…' : 'Vô hiệu hóa'}
                          </button>
                        ) : (
                          <span className={styles.dash}>—</span>
                        )}
                      </div>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}
