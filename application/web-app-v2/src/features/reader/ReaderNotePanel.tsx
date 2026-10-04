import { useState, useEffect, useRef, useCallback } from 'react';
import type { Book } from '@/types/api';
import {
  type BookNotebookStatus,
  type NotebookSummary,
  type NotebookPageData,
  fetchNotebooks,
  createNotebook,
  linkNotebookToBook,
  fetchNotebookPageDetail,
  saveNotebookPageDetail,
} from './notebookApi';
import { useToast } from '@/components/Toast';
import './ReaderNotePanel.css';

const TEMPLATE_OPTIONS: { id: NotebookPageData['template']; name: string; badge: string; icon: string }[] = [
  { id: 'cornell', name: 'Cornell Notes', badge: '✦ STUDY JOURNAL', icon: '📝' },
  { id: 'reading', name: 'Reading Notes', badge: '📖 READING NOTES', icon: '📖' },
  { id: 'ruled', name: 'Ruled Notebook', badge: '📑 SCHOLAR JOURNAL', icon: '📑' },
  { id: 'vocab', name: 'Vocabulary Lab', badge: '✦ VOCAB LAB', icon: '🔤' },
  { id: 'work', name: 'Work & Project Log', badge: '💼 PROJECT LOG', icon: '💼' },
  { id: 'blank', name: 'Freeform Blank', badge: '✦ FREEFORM', icon: '📄' },
];

export function ReaderNotePanel({
  isOpen,
  onClose,
  book,
  currentPage,
  onGoToPage,
  status,
  onRefreshStatus,
}: {
  isOpen: boolean;
  onClose: () => void;
  book: Book;
  currentPage: number;
  onGoToPage: (page: number) => void;
  status: BookNotebookStatus | null;
  onRefreshStatus: () => Promise<void>;
}) {
  const toast = useToast();
  const [notebooks, setNotebooks] = useState<NotebookSummary[]>([]);
  const [selectedNotebookId, setSelectedNotebookId] = useState<string>('');
  const [isCreatingNb, setIsCreatingNb] = useState(false);
  const [isWide, setIsWide] = useState(false);
  const [paperTheme, setPaperTheme] = useState<'cream' | 'dark' | 'white'>('cream');
  const [activeTab, setActiveTab] = useState<'editor' | 'all'>('editor');

  // Page template data
  const [pageData, setPageData] = useState<NotebookPageData | null>(null);
  const [isLoadingPage, setIsLoadingPage] = useState(false);
  const [saveStatus, setSaveStatus] = useState<'idle' | 'saving' | 'saved'>('idle');

  // Editable refs to sync contenteditable
  const cuesRef = useRef<HTMLDivElement>(null);
  const notesRef = useRef<HTMLDivElement>(null);
  const summaryRef = useRef<HTMLDivElement>(null);
  const topicRef = useRef<HTMLInputElement>(null);
  const saveTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Load notebooks on mount / open
  useEffect(() => {
    if (isOpen) {
      void fetchNotebooks().then((list) => {
        setNotebooks(list);
        if (status?.linkedNotebook?.id) {
          setSelectedNotebookId(status.linkedNotebook.id);
        } else if (list.length > 0 && !selectedNotebookId) {
          const match = list.find((nb) => nb.bookSlug === book.slug);
          if (match) setSelectedNotebookId(match.id);
          else setSelectedNotebookId(list[0]!.id);
        }
      });
    }
  }, [isOpen, status?.linkedNotebook?.id, book.slug]);

  // Sync selected notebook ID with status
  useEffect(() => {
    if (status?.linkedNotebook?.id) {
      setSelectedNotebookId(status.linkedNotebook.id);
    }
  }, [status?.linkedNotebook?.id]);

  // Track specific page being viewed in the notebook
  const [activePageId, setActivePageId] = useState<string | null>(null);
  const lastSyncedKeyRef = useRef<string>('');

  // When book page changes in reader, reset activePageId to sync with reading page
  useEffect(() => {
    setActivePageId(null);
  }, [currentPage]);

  // Fetch page template data from Notebook Studio API
  const loadPageDetail = useCallback(
    async (targetPageId?: string | null, targetPageNum?: number) => {
      if (!selectedNotebookId) return;
      if (saveTimeoutRef.current) {
        clearTimeout(saveTimeoutRef.current);
        saveTimeoutRef.current = null;
      }
      setIsLoadingPage(true);
      lastSyncedKeyRef.current = '';
      try {
        const pid = targetPageId ? targetPageId : undefined;
        const pnum = targetPageNum !== undefined ? targetPageNum : (!pid ? currentPage : undefined);
        const res = await fetchNotebookPageDetail(selectedNotebookId, book.slug, pnum, book.title, pid);
        if (res.ok && res.page) {
          setPageData(res.page);
          setActivePageId(res.page.id);
        }
      } finally {
        setIsLoadingPage(false);
      }
    },
    [selectedNotebookId, book.slug, book.title, currentPage]
  );

  const currentTemplate = pageData?.template || 'cornell';

  const handleReloadPage = async () => {
    if (!selectedNotebookId) return;
    if (saveTimeoutRef.current) {
      clearTimeout(saveTimeoutRef.current);
      saveTimeoutRef.current = null;
    }
    lastSyncedKeyRef.current = '';
    setIsLoadingPage(true);
    try {
      await Promise.all([
        loadPageDetail(activePageId || pageData?.id, pageData?.bookPage || currentPage),
        onRefreshStatus(),
      ]);
      toast.success(`Đã cập nhật nội dung từ Notebook Studio`);
    } catch {
      toast.error('Không thể tải lại từ Sổ tay');
    } finally {
      setIsLoadingPage(false);
    }
  };

  useEffect(() => {
    if (isOpen && selectedNotebookId) {
      if (pageData?.bookPage === currentPage) return;
      void loadPageDetail(undefined, currentPage);
    }
  }, [isOpen, selectedNotebookId, currentPage, loadPageDetail, pageData?.bookPage]);

  useEffect(() => {
    if (activeTab === 'all') {
      lastSyncedKeyRef.current = '';
    }
  }, [activeTab]);

  // Sync pageData to DOM ONLY when switching pages or templates or opening editor,
  // NEVER while typing or saving on the active page!
  useEffect(() => {
    if (!pageData || isLoadingPage || activeTab !== 'editor') return;
    const pageKey = `${pageData.id}-${pageData.bookPage || currentPage}-${currentTemplate}`;
    if (lastSyncedKeyRef.current !== pageKey) {
      lastSyncedKeyRef.current = pageKey;
      if (cuesRef.current) cuesRef.current.innerHTML = pageData.cues || '';
      if (notesRef.current) notesRef.current.innerHTML = pageData.notes || pageData.content || '';
      if (summaryRef.current) summaryRef.current.innerHTML = pageData.summary || '';
      if (topicRef.current) topicRef.current.value = pageData.topic || book.title || '';
    }
  }, [pageData, currentTemplate, currentPage, isLoadingPage, book.title, activeTab]);

  const handleOpenPage = (pageId: string, bookPageNum?: number | null) => {
    setActivePageId(pageId);
    setActiveTab('editor');
    if (bookPageNum && bookPageNum !== currentPage) {
      onGoToPage(bookPageNum);
    }
    void loadPageDetail(pageId, bookPageNum || undefined);
  };

  const handleSelectNotebook = async (id: string) => {
    setSelectedNotebookId(id);
    setActivePageId(null);
    if (id) {
      const ok = await linkNotebookToBook(book.slug, id);
      if (ok) {
        toast.success('Đã liên kết sổ tay');
        await onRefreshStatus();
      }
    }
  };

  const handleCreateNewNotebook = async () => {
    setIsCreatingNb(true);
    try {
      const newNb = await createNotebook({
        title: `[Ghi chép] ${book.title}`,
        bookSlug: book.slug,
        bookTitle: book.title,
        category: 'Sách song ngữ',
      });
      if (newNb) {
        setNotebooks((prev) => [newNb, ...prev]);
        setSelectedNotebookId(newNb.id);
        await linkNotebookToBook(book.slug, newNb.id);
        toast.success(`Đã tạo sổ mới: "${newNb.title}"`);
        await onRefreshStatus();
      } else {
        toast.error('Không thể tạo sổ mới');
      }
    } finally {
      setIsCreatingNb(false);
    }
  };

  // Save changes to Notebook Studio API
  const handleSavePage = useCallback(
    async (silent = false) => {
      if (!selectedNotebookId || !pageData || isLoadingPage) return;
      if (!notesRef.current) return;
      if (saveTimeoutRef.current) {
        clearTimeout(saveTimeoutRef.current);
        saveTimeoutRef.current = null;
      }
      const notesHtml = notesRef.current.innerHTML;
      const cuesHtml = cuesRef.current ? cuesRef.current.innerHTML : pageData.cues || '';
      const summaryHtml = summaryRef.current ? summaryRef.current.innerHTML : pageData.summary || '';
      const topicVal = topicRef.current ? topicRef.current.value : pageData.topic || book.title;

      setSaveStatus('saving');
      try {
        const payload = {
          pageId: pageData.id,
          bookSlug: book.slug,
          bookTitle: book.title,
          page: pageData.bookPage || currentPage,
          template: pageData.template || 'cornell',
          topic: topicVal,
          title: pageData.title || `${book.title} — Trang ${pageData.bookPage || currentPage}`,
          status: pageData.status || 'WIP',
          date: pageData.date || new Date().toLocaleDateString('vi-VN'),
          no: pageData.no || String(pageData.bookPage || currentPage).padStart(2, '0'),
          cues: cuesHtml,
          notes: notesHtml,
          content: notesHtml,
          summary: summaryHtml,
        };

        const res = await saveNotebookPageDetail(selectedNotebookId, payload);
        if (res.ok && res.page) {
          const pageKey = `${res.page.id}-${res.page.bookPage || currentPage}-${res.page.template || currentTemplate}`;
          lastSyncedKeyRef.current = pageKey;
          setPageData(res.page);
          setActivePageId(res.page.id);
          setSaveStatus('saved');
          if (!silent) toast.success(`Đã lưu trang vào Sổ tay`);
          void onRefreshStatus();
          setTimeout(() => setSaveStatus('idle'), 3000);
        } else {
          setSaveStatus('idle');
          if (!silent) toast.error(res.message || 'Lỗi lưu trang');
        }
      } catch {
        setSaveStatus('idle');
        if (!silent) toast.error('Không thể kết nối tới Sổ tay');
      }
    },
    [selectedNotebookId, pageData, isLoadingPage, currentTemplate, book.slug, book.title, currentPage, onRefreshStatus, toast],
  );

  // Debounced auto-save on content changes
  const triggerAutoSave = () => {
    if (saveTimeoutRef.current) clearTimeout(saveTimeoutRef.current);
    saveTimeoutRef.current = setTimeout(() => {
      void handleSavePage(true);
    }, 2000);
  };

  // Rich formatting actions
  const applyFormat = (command: string, value: string | undefined = undefined) => {
    document.execCommand(command, false, value);
    triggerAutoSave();
  };



  const handleChangeTemplate = (newTemplate: NotebookPageData['template']) => {
    if (!pageData) return;
    setPageData((prev) => (prev ? { ...prev, template: newTemplate } : null));
    triggerAutoSave();
  };

  const notes = status?.notes || [];
  const notebookBaseUrl = (localStorage.getItem('bilingual.notebookUrl') || 'http://localhost:27972').replace(/\/+$/, '');

  return (
    <div
      className={`reader-note-panel ${isOpen ? 'reader-note-panel--open' : ''} ${isWide ? 'reader-note-panel--wide' : ''} theme-${paperTheme}`}
      aria-label="Ghi chép sổ tay"
    >
      {/* 1. Header Toolbar */}
      <div className="reader-note-panel__header">
        <div className="reader-note-panel__title-box">
          <span className="reader-note-panel__title-icon">📓</span>
          <span className="reader-note-panel__title-text">Ghi chép & Sổ tay</span>
          <div
            className={`reader-note-panel__status-dot ${status?.offline ? 'offline' : ''}`}
            title={status?.offline ? 'Chưa kết nối Notebook Studio' : 'Đã kết nối Notebook Studio'}
          />
        </div>

        <div className="reader-note-panel__header-actions">
          {selectedNotebookId && (
            <button
              className="reader-note-panel__btn-tool"
              onClick={() => void handleReloadPage()}
              disabled={isLoadingPage}
              title="Tải lại nội dung trang từ Notebook Studio"
            >
              <ReloadIcon spinning={isLoadingPage} />
            </button>
          )}
          {selectedNotebookId && (
            <a
              href={`${notebookBaseUrl}/?book=${encodeURIComponent(selectedNotebookId)}&refBook=${encodeURIComponent(book.slug)}&bookPage=${pageData?.bookPage || currentPage}`}
              target="_blank"
              rel="noreferrer"
              className="reader-note-panel__btn-tool"
              title="Mở toàn màn hình bên Notebook Studio"
            >
              <ExternalLinkIcon />
            </a>
          )}
          <button
            className="reader-note-panel__btn-tool"
            onClick={() => setIsWide((w) => !w)}
            title={isWide ? 'Thu gọn panel' : 'Mở rộng panel'}
          >
            {isWide ? '⇤' : '⇥'}
          </button>
          <button className="reader-note-panel__btn-tool" onClick={onClose} title="Đóng panel (N / Esc)">
            ✕
          </button>
        </div>
      </div>

      {/* 2. Notebook Selector & Formatting Bar */}
      <div className="reader-note-panel__meta-bar">
        <div className="reader-note-panel__notebook-row">
          <label className="reader-note-panel__meta-label">Sổ:</label>
          <select
            className="reader-note-panel__select"
            value={selectedNotebookId}
            onChange={(e) => void handleSelectNotebook(e.target.value)}
          >
            {notebooks.map((nb) => (
              <option key={nb.id} value={nb.id}>
                {nb.title} ({nb.pageCount} trang)
              </option>
            ))}
          </select>
          <button
            className="reader-note-panel__btn-add-nb"
            onClick={handleCreateNewNotebook}
            disabled={isCreatingNb}
            title="Tạo sổ tay mới cho cuốn sách này"
          >
            {isCreatingNb ? '…' : '+ Sổ mới'}
          </button>
        </div>

        {/* Unified Compact Quick Note Bar */}
        <div className="reader-note-panel__quick-bar">
          <div className="reader-note-panel__tabs">
            <button
              className={`reader-note-panel__tab ${activeTab === 'editor' ? 'active' : ''}`}
              onClick={() => setActiveTab('editor')}
            >
              {pageData?.bookPage ? `Trang ${pageData.bookPage}` : pageData?.no ? `Trang #${pageData.no}` : `Trang ${currentPage}`}
            </button>
            <button
              className={`reader-note-panel__tab ${activeTab === 'all' ? 'active' : ''}`}
              onClick={() => setActiveTab('all')}
            >
              Tất cả ({notes.length})
            </button>
          </div>

          <div className="reader-note-panel__quick-tools">
            {activeTab === 'editor' && (
              <>
                <select
                  className="template-select-compact"
                  value={currentTemplate}
                  onChange={(e) => handleChangeTemplate(e.target.value as NotebookPageData['template'])}
                  title="Chọn mẫu ghi chú"
                >
                  {TEMPLATE_OPTIONS.map((t) => (
                    <option key={t.id} value={t.id}>
                      {t.icon} {t.name}
                    </option>
                  ))}
                </select>

                <div className="format-tools-compact">
                  <button
                    type="button"
                    className="format-btn-compact"
                    onMouseDown={(e) => {
                      e.preventDefault();
                      applyFormat('bold');
                    }}
                    title="Đậm (Ctrl+B)"
                  >
                    <strong>B</strong>
                  </button>
                  <button
                    type="button"
                    className="format-btn-compact"
                    onMouseDown={(e) => {
                      e.preventDefault();
                      applyFormat('italic');
                    }}
                    title="Nghiêng (Ctrl+I)"
                  >
                    <em>I</em>
                  </button>
                  <button
                    type="button"
                    className="format-btn-compact"
                    onMouseDown={(e) => {
                      e.preventDefault();
                      applyFormat('insertUnorderedList');
                    }}
                    title="Danh sách gạch đầu dòng"
                  >
                    •
                  </button>
                  <button
                    type="button"
                    className="format-btn-compact"
                    onClick={() => void handleReloadPage()}
                    disabled={isLoadingPage}
                    title="Tải lại trang từ Notebook Studio (Reload)"
                  >
                    <ReloadIcon spinning={isLoadingPage} />
                  </button>
                </div>

                <button
                  className={`btn-save-compact ${saveStatus === 'saving' ? 'saving' : ''} ${saveStatus === 'saved' ? 'saved' : ''}`}
                  onClick={() => void handleSavePage(false)}
                  title="Lưu trang ghi chú"
                >
                  {saveStatus === 'saving' ? 'Đang lưu…' : saveStatus === 'saved' ? '✓ Đã lưu' : 'Lưu'}
                </button>
              </>
            )}

            <div className="reader-note-panel__theme-selector">
              <button
                className={`theme-dot theme-cream ${paperTheme === 'cream' ? 'active' : ''}`}
                onClick={() => setPaperTheme('cream')}
                title="Giấy kem"
              />
              <button
                className={`theme-dot theme-dark ${paperTheme === 'dark' ? 'active' : ''}`}
                onClick={() => setPaperTheme('dark')}
                title="Giấy tối"
              />
              <button
                className={`theme-dot theme-white ${paperTheme === 'white' ? 'active' : ''}`}
                onClick={() => setPaperTheme('white')}
                title="Giấy trắng"
              />
            </div>
          </div>
        </div>
      </div>

      {/* 3. Main Content Area */}
      <div className="reader-note-panel__content">
        {activeTab === 'all' ? (
          /* List of all notes in this book */
          <div className="all-notes-view">
            <div className="all-notes-header">
              <span>Tất cả ghi chú cho "{book.title}"</span>
              <span className="notes-badge">{notes.length} trang có ghi chú</span>
            </div>
            {notes.length === 0 ? (
              <div className="empty-notes-hint">Chưa có ghi chú nào trong cuốn sổ này.</div>
            ) : (
              <div className="all-notes-list">
                {notes.map((n) => {
                  const isActive = (activePageId && n.id === activePageId) || n.id === pageData?.id || (n.bookPage && n.bookPage === (pageData?.bookPage || currentPage));
                  return (
                    <div
                      key={n.id}
                      className={`note-summary-card ${isActive ? 'active' : ''}`}
                      onClick={() => handleOpenPage(n.id, n.bookPage)}
                    >
                      <div className="note-card-head">
                        <span className="note-page-tag">
                          {n.bookPage ? `Trang sách ${n.bookPage}` : n.no ? `Trang sổ #${n.no}` : 'Ghi chép'}
                        </span>
                        <span className="note-date">{n.date}</span>
                      </div>
                      <div className="note-card-title">{n.title || '(Chưa đặt tiêu đề)'}</div>
                      <div className="note-card-preview">{n.preview || 'Chưa có nội dung xem trước...'}</div>
                    </div>
                  );
                })}
              </div>
            )}
          </div>
        ) : isLoadingPage ? (
          <div className="template-loading-box">
            <span className="spinner" />
            <span>Đang tải trang sổ tay từ Notebook Studio…</span>
          </div>
        ) : (
          /* Authentic Notebook Page Canvas */
          <div
            key={`${pageData?.id || 'new'}-${pageData?.bookPage || currentPage}-${currentTemplate}`}
            className="notebook-page-canvas"
          >
            <div className={`a4-template-sheet ${currentTemplate}-template-sheet`}>
              {/* Punch Margin & Corners */}
              <div className="punch-margin-line" />
              <div className="corner-decor corner-tl" />
              <div className="corner-decor corner-tr" />
              <div className="corner-decor corner-bl" />
              <div className="corner-decor corner-br" />

              {/* Functional Header */}
              <div className="functional-header">
                <div className="header-top-meta">
                  <div className="header-purpose-badge">
                    {TEMPLATE_OPTIONS.find((t) => t.id === currentTemplate)?.badge || '✦ STUDY JOURNAL'}
                  </div>
                  <div className="status-pills">
                    {(['TODO', 'WIP', 'DONE'] as const).map((st) => (
                      <button
                        key={st}
                        type="button"
                        className={`status-pill-btn ${pageData?.status === st ? `active-${st.toLowerCase()}` : ''}`}
                        onClick={() => {
                          setPageData((p) => (p ? { ...p, status: st } : null));
                          triggerAutoSave();
                        }}
                      >
                        {st}
                      </button>
                    ))}
                  </div>
                </div>

                <div className="header-main-field">
                  <span className="field-label">CHỦ ĐỀ / TOPIC:</span>
                  <input
                    ref={topicRef}
                    type="text"
                    className="field-underline-input topic-input"
                    defaultValue={pageData?.topic || book.title}
                    placeholder="Chủ đề ghi chép..."
                    onInput={triggerAutoSave}
                  />
                </div>

                <div className="header-sub-fields">
                  <div className="sub-field-group">
                    <span style={{ fontWeight: 700 }}>NGÀY:</span>
                    <span className="sub-field-text">{pageData?.date || new Date().toLocaleDateString('vi-VN')}</span>
                  </div>
                  <div className="sub-field-group">
                    <span style={{ fontWeight: 700 }}>TRANG SÁCH:</span>
                    <span className="sub-field-badge">
                      {pageData?.bookPage ? `Trang ${pageData.bookPage}` : pageData?.no ? `Trang #${pageData.no}` : `Trang ${currentPage}`}
                    </span>
                  </div>
                </div>
              </div>

              {/* Template Body */}
              {currentTemplate === 'cornell' ? (
                /* Cornell Split Layout */
                <div className="cornell-container">
                  <div className="cornell-body-split">
                    <div className="cornell-cue-col">
                      <div className="col-guide-bar">
                        <span className="section-guide-badge">TỪ KHÓA & CÂU HỎI (CUES)</span>
                      </div>
                      <div
                        ref={cuesRef}
                        contentEditable
                        suppressContentEditableWarning
                        className="template-writing-area cornell-cues-text"
                        data-placeholder="Từ khóa, thuật ngữ gợi nhớ, câu hỏi tự vấn..."
                        onInput={triggerAutoSave}
                      />
                    </div>
                    <div className="cornell-notes-col">
                      <div className="col-guide-bar">
                        <span className="section-guide-badge">GHI CHÉP CHÍNH (NOTES)</span>
                      </div>
                      <div
                        ref={notesRef}
                        contentEditable
                        suppressContentEditableWarning
                        className="template-writing-area cornell-notes-text ruled-lines"
                        data-placeholder="Ghi chép chi tiết, ý chính, trích dẫn, ví dụ minh họa..."
                        onInput={triggerAutoSave}
                      />
                    </div>
                  </div>
                  <div className="cornell-summary-area">
                    <div className="col-guide-bar">
                      <span className="section-guide-badge">TÓM TẮT & BÀI HỌC (SUMMARY)</span>
                    </div>
                    <div
                      ref={summaryRef}
                      contentEditable
                      suppressContentEditableWarning
                      className="template-writing-area cornell-summary-text"
                      data-placeholder="Đúc kết 1-2 câu cốt lõi của trang này..."
                      onInput={triggerAutoSave}
                    />
                  </div>
                </div>
              ) : currentTemplate === 'reading' ? (
                /* Reading Notes Layout */
                <div className="reading-container">
                  <div className="reading-body-split">
                    <div className="reading-ideas-col">
                      <div className="col-guide-bar">
                        <span className="section-guide-badge">Ý TƯỞNG & ĐÚC KẾT (KEY IDEAS)</span>
                      </div>
                      <div
                        ref={cuesRef}
                        contentEditable
                        suppressContentEditableWarning
                        className="template-writing-area reading-ideas-text"
                        data-placeholder="Luận điểm chính của tác giả..."
                        onInput={triggerAutoSave}
                      />
                    </div>
                    <div className="reading-quotes-col">
                      <div className="col-guide-bar">
                        <span className="section-guide-badge">TRÍCH DẪN & HIGHLIGHTS</span>
                      </div>
                      <div
                        ref={notesRef}
                        contentEditable
                        suppressContentEditableWarning
                        className="template-writing-area reading-quotes-text ruled-lines"
                        data-placeholder="Các câu trích dẫn tâm đắc hoặc thẻ từ vựng..."
                        onInput={triggerAutoSave}
                      />
                    </div>
                  </div>
                  <div className="reading-summary-area">
                    <div className="col-guide-bar">
                      <span className="section-guide-badge">CẢM NHẬN & LIÊN HỆ THỰC TẾ</span>
                    </div>
                    <div
                      ref={summaryRef}
                      contentEditable
                      suppressContentEditableWarning
                      className="template-writing-area reading-summary-text"
                      data-placeholder="Bài học áp dụng vào công việc / cuộc sống..."
                      onInput={triggerAutoSave}
                    />
                  </div>
                </div>
              ) : (
                /* Ruled & Freeform Layout */
                <div className="ruled-container">
                  <div className="col-guide-bar">
                    <span className="section-guide-badge">GHI CHÉP TỰ DO (NOTES)</span>
                  </div>
                  <div
                    ref={notesRef}
                    contentEditable
                    suppressContentEditableWarning
                    className="template-writing-area ruled-full-text ruled-lines"
                    data-placeholder="Bắt đầu ghi chép suy nghĩ, từ vựng hoặc trích dẫn tại đây..."
                    onInput={triggerAutoSave}
                  />
                </div>
              )}

              {/* Scholar Footer */}
              <div className="scholar-footer">
                <span className="footer-left-tag">
                  {currentTemplate.toUpperCase()} · NOTEBOOK STUDIO
                </span>
                <div className="footer-page-box">
                  <span>TRANG</span>
                  <span className="footer-page-line">
                    {pageData?.bookPage ? pageData.bookPage : pageData?.no ? `#${pageData.no}` : currentPage}
                  </span>
                </div>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

function ReloadIcon({ spinning = false }: { spinning?: boolean }) {
  return (
    <svg
      width="13"
      height="13"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={spinning ? 'spin-anim' : ''}
      aria-hidden="true"
    >
      <path d="M21 12a9 9 0 0 0-9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" />
      <path d="M3 3v5h5" />
      <path d="M3 12a9 9 0 0 0 9 9 9.75 9.75 0 0 0 6.74-2.74L21 16" />
      <path d="M16 21h5v-5" />
    </svg>
  );
}

function ExternalLinkIcon() {
  return (
    <svg
      width="13"
      height="13"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" />
      <polyline points="15 3 21 3 21 9" />
      <line x1="10" y1="14" x2="21" y2="3" />
    </svg>
  );
}
