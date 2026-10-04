import { apiFetch } from '@/lib/api-client';

export interface NotebookSummary {
  id: string;
  title: string;
  category: string;
  bookSlug?: string;
  coverGradient?: string;
  pageCount: number;
  updatedAt: string;
}

export interface BookNotebookStatus {
  ok: boolean;
  linkedNotebook: {
    id: string;
    title: string;
    coverGradient?: string;
  } | null;
  pagesWithNotes: number[];
  notes: {
    id: string;
    no?: string;
    bookPage: number | null;
    title: string;
    date: string;
    preview: string;
    template: string;
  }[];
  offline?: boolean;
}

export interface SyncNotePayload {
  notebookId: string;
  bookSlug: string;
  bookTitle: string;
  page: number;
  type: 'quote' | 'vocab' | 'note';
  text?: string;
  note?: string;
  vocab?: {
    word: string;
    ipa?: string;
    meaningVi?: string;
    meaningEn?: string;
    example?: string;
  };
}

const getHeaders = () => {
  const customUrl = localStorage.getItem('bilingual.notebookUrl') || '';
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };
  if (customUrl) {
    headers['X-Notebook-Base-URL'] = customUrl;
  }
  return headers;
};

export async function fetchNotebooks(): Promise<NotebookSummary[]> {
  try {
    const res = await apiFetch('/api/notebook/notebooks', {
      headers: getHeaders(),
    });
    if (!res.ok) return [];
    const data = await res.json();
    return Array.isArray(data.notebooks) ? data.notebooks : [];
  } catch (err) {
    console.warn('[NotebookApi] Failed to fetch notebooks:', err);
    return [];
  }
}

export async function createNotebook(payload: {
  title?: string;
  bookSlug?: string;
  bookTitle?: string;
  category?: string;
}): Promise<NotebookSummary | null> {
  try {
    const res = await apiFetch('/api/notebook/notebooks', {
      method: 'POST',
      headers: getHeaders(),
      body: JSON.stringify(payload),
    });
    if (!res.ok) return null;
    const data = await res.json();
    return data.notebook || null;
  } catch (err) {
    console.warn('[NotebookApi] Failed to create notebook:', err);
    return null;
  }
}

export async function linkNotebookToBook(bookSlug: string, notebookId: string): Promise<boolean> {
  try {
    const res = await apiFetch(`/api/notebook/books/${encodeURIComponent(bookSlug)}/link`, {
      method: 'POST',
      headers: getHeaders(),
      body: JSON.stringify({ notebookId }),
    });
    return res.ok;
  } catch (err) {
    console.warn('[NotebookApi] Failed to link notebook:', err);
    return false;
  }
}

export async function fetchBookNotebookStatus(bookSlug: string): Promise<BookNotebookStatus> {
  try {
    const res = await apiFetch(`/api/notebook/books/${encodeURIComponent(bookSlug)}/status`, {
      headers: getHeaders(),
    });
    if (!res.ok) {
      return { ok: false, linkedNotebook: null, pagesWithNotes: [], notes: [] };
    }
    return await res.json();
  } catch (err) {
    return { ok: false, linkedNotebook: null, pagesWithNotes: [], notes: [], offline: true };
  }
}

export async function syncNoteToNotebook(payload: SyncNotePayload): Promise<{ ok: boolean; message?: string }> {
  try {
    const res = await apiFetch('/api/notebook/sync', {
      method: 'POST',
      headers: getHeaders(),
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      return { ok: false, message: err.detail || 'Lỗi lưu ghi chú' };
    }
    return await res.json();
  } catch (err) {
    return { ok: false, message: err instanceof Error ? err.message : 'Lỗi kết nối' };
  }
}

export interface NotebookPageData {
  id: string;
  template: 'cornell' | 'reading' | 'ruled' | 'vocab' | 'work' | 'blank';
  title?: string;
  topic?: string;
  date?: string;
  no?: string;
  bookPage?: number;
  project?: string;
  status?: 'TODO' | 'WIP' | 'DONE';
  cues?: string;
  notes?: string;
  summary?: string;
  content?: string;
  isNew?: boolean;
}

export interface TemplateOption {
  id: string;
  name: string;
  badge: string;
}

export async function fetchNotebookPageDetail(
  notebookId: string,
  bookSlug: string,
  page?: number,
  bookTitle: string = '',
  pageId?: string
): Promise<{ ok: boolean; page?: NotebookPageData; availableTemplates?: TemplateOption[]; error?: string }> {
  try {
    const query = new URLSearchParams();
    if (bookSlug) query.set('bookSlug', bookSlug);
    if (page !== undefined && page !== null) query.set('page', String(page));
    if (pageId) query.set('pageId', pageId);
    if (bookTitle) query.set('bookTitle', bookTitle);

    const res = await apiFetch(
      `/api/notebook/notebooks/${encodeURIComponent(notebookId)}/page-detail?${query.toString()}`,
      { headers: getHeaders() }
    );
    if (!res.ok) return { ok: false, error: 'Không thể tải trang' };
    return await res.json();
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : 'Lỗi kết nối' };
  }
}

export async function saveNotebookPageDetail(
  notebookId: string,
  payload: Partial<NotebookPageData> & { bookSlug: string; bookTitle: string; page: number }
): Promise<{ ok: boolean; page?: NotebookPageData; message?: string }> {
  try {
    const res = await apiFetch(`/api/notebook/notebooks/${encodeURIComponent(notebookId)}/page-detail`, {
      method: 'PUT',
      headers: getHeaders(),
      body: JSON.stringify(payload),
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      return { ok: false, message: err.detail || 'Lỗi lưu trang' };
    }
    return await res.json();
  } catch (err) {
    return { ok: false, message: err instanceof Error ? err.message : 'Lỗi kết nối' };
  }
}
