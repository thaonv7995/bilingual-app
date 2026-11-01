import { useEffect, useRef } from 'react';
import {
  INTERLINEAR_OPACITY_OPTIONS,
  LINE_HEIGHT_OPTIONS,
  PAGE_MARGIN_OPTIONS,
  READER_FONTS,
  READER_INK_COLORS,
  READER_TEXTURES,
  READER_THEMES,
  getReaderFont,
  getReaderTheme,
  parseThemeDescriptor,
  preloadReaderFontsInAppDocument,
  serializeThemeDescriptor,
  type InterlinearOpacityPreset,
  type LineHeightPreset,
  type PageMarginPreset,
  type PaperTextureId,
  type ParsedThemeDescriptor,
} from './readerAppearance';

export interface ReaderAppearancePopoverProps {
  bookTitle: string;
  effectiveFontId: string;
  effectiveThemeId: string;
  bookDefaultFontId: string;
  bookDefaultThemeId: string;
  hasUserOverride: boolean;
  isSavingDefault?: boolean;
  appliedFontScale?: number;
  clampedByA4?: boolean;
  atMaxA4Scale?: boolean;
  onSelectFont: (fontId: string) => void;
  onSelectTheme: (themeDescriptor: string) => void;
  onResetToBookDefault: () => void;
  onSaveAsBookDefault: () => void;
  onClose: () => void;
}

const FONT_GROUPS: { category: string; label: string }[] = [
  { category: 'default', label: 'Mặc định' },
  { category: 'serif', label: 'Serif — Sách in có chân' },
  { category: 'sans', label: 'Sans-serif — Hiện đại' },
  { category: 'handwriting', label: 'Handwriting — Chữ viết tay' },
  { category: 'mono', label: 'Monospace — Máy đánh chữ' },
];

export function ReaderAppearancePopover({
  bookTitle,
  effectiveFontId,
  effectiveThemeId,
  bookDefaultFontId,
  bookDefaultThemeId,
  hasUserOverride,
  isSavingDefault = false,
  appliedFontScale,
  clampedByA4 = false,
  atMaxA4Scale = false,
  onSelectFont,
  onSelectTheme,
  onResetToBookDefault,
  onSaveAsBookDefault,
  onClose,
}: ReaderAppearancePopoverProps) {
  const panelRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    preloadReaderFontsInAppDocument();
  }, []);

  useEffect(() => {
    const onMouseDown = (e: MouseEvent) => {
      const target = e.target as Element | null;
      if (!target) return;
      if (panelRef.current?.contains(target)) return;
      if (target.closest('.btn-reader-appearance')) return;
      onClose();
    };
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('mousedown', onMouseDown);
    window.addEventListener('keydown', onKeyDown);
    return () => {
      window.removeEventListener('mousedown', onMouseDown);
      window.removeEventListener('keydown', onKeyDown);
    };
  }, [onClose]);

  const desc = parseThemeDescriptor(effectiveThemeId);
  const currentFont = getReaderFont(effectiveFontId);
  const currentTheme = getReaderTheme(effectiveThemeId);
  const defaultFontMeta = getReaderFont(bookDefaultFontId);
  const defaultThemeMeta = getReaderTheme(bookDefaultThemeId);

  const matchesBookDefault =
    effectiveFontId === bookDefaultFontId && effectiveThemeId === bookDefaultThemeId;

  const updateDescriptor = (patch: Partial<ParsedThemeDescriptor>) => {
    const next = serializeThemeDescriptor({ ...desc, ...patch });
    onSelectTheme(next);
  };

  const isCustomInk =
    desc.inkColor !== 'auto' && !READER_INK_COLORS.some((c) => c.id === desc.inkColor);

  return (
    <div
      ref={panelRef}
      className="reader-appearance-popover"
      role="dialog"
      aria-label="Cài đặt hiển thị sách"
    >
      {/* Compact Header */}
      <div className="reader-appearance-popover__header">
        <div className="reader-appearance-popover__header-main">
          <span className="reader-appearance-popover__title">Hiển thị sách</span>
          <span
            className="reader-appearance-popover__badge"
            title={`Mặc định sách (${bookTitle}): ${defaultFontMeta.label} · ${defaultThemeMeta.label}`}
          >
            {matchesBookDefault && !hasUserOverride ? 'Mặc định' : 'Tuỳ chỉnh'}
          </span>
        </div>
        <button
          type="button"
          className="reader-appearance-popover__close"
          onClick={onClose}
          aria-label="Đóng"
        >
          ✕
        </button>
      </div>

      {/* Compact Settings List */}
      <div className="reader-appearance-list">
        {/* 1. Subline Opacity for Single-Page Interlinear Mode */}
        <div className="reader-setting-row">
          <span className="reader-setting-row__label">Độ đậm dòng dịch</span>
          <div className="reader-setting-row__control">
            <div className="reader-segmented reader-segmented--full">
              {INTERLINEAR_OPACITY_OPTIONS.map((opt) => (
                <button
                  key={opt.id}
                  type="button"
                  className={`reader-segmented__btn ${
                    (desc.interlinearOpacity || 55) === opt.id ? 'is-active' : ''
                  }`}
                  onClick={() =>
                    updateDescriptor({ interlinearOpacity: opt.id as InterlinearOpacityPreset })
                  }
                >
                  {opt.label}
                </button>
              ))}
            </div>
          </div>
        </div>

        {/* 2. Page Margin */}
        <div className="reader-setting-row">
          <span className="reader-setting-row__label">Lề trang</span>
          <div className="reader-setting-row__control">
            <div className="reader-segmented reader-segmented--full">
              {PAGE_MARGIN_OPTIONS.map((m) => (
                <button
                  key={m.id}
                  type="button"
                  className={`reader-segmented__btn ${desc.pageMargin === m.id ? 'is-active' : ''}`}
                  onClick={() => updateDescriptor({ pageMargin: m.id as PageMarginPreset })}
                >
                  {m.label}
                </button>
              ))}
            </div>
          </div>
        </div>

        {/* 2. Font Size (Text Scale) */}
        <div className="reader-setting-row">
          <span className="reader-setting-row__label">
            Cỡ chữ
            {(atMaxA4Scale || clampedByA4) && (
              <span
                className="reader-setting-row__a4-tag"
                title="Đã đạt cỡ chữ tối đa vừa khít khổ trang A4 (tăng thêm sẽ bị tràn trang)"
              >
                Max A4
              </span>
            )}
          </span>
          <div className="reader-setting-row__control reader-setting-row__control--inline">
            <div className="reader-stepper reader-stepper--wide">
              <button
                type="button"
                className="reader-stepper__btn"
                disabled={(appliedFontScale ?? desc.fontScale) <= 80}
                onClick={() => {
                  const base = appliedFontScale ?? desc.fontScale;
                  updateDescriptor({ fontScale: Math.max(80, base - 5) });
                }}
                title="Giảm cỡ chữ"
              >
                A−
              </button>
              <button
                type="button"
                className="reader-stepper__val-btn"
                onClick={() => updateDescriptor({ fontScale: 100 })}
                title="Nhấp để đặt lại 100% (Mặc định)"
              >
                {appliedFontScale ?? desc.fontScale}%
              </button>
              <button
                type="button"
                className="reader-stepper__btn"
                disabled={atMaxA4Scale || desc.fontScale >= 140}
                onClick={() => {
                  const base = appliedFontScale ?? desc.fontScale;
                  updateDescriptor({ fontScale: Math.min(140, base + 5) });
                }}
                title={
                  atMaxA4Scale
                    ? 'Không thể tăng thêm — chữ sẽ tràn khỏi khổ trang A4'
                    : 'Tăng cỡ chữ'
                }
              >
                A+
              </button>
            </div>
          </div>
        </div>

        {/* 4. Line Spacing */}
        <div className="reader-setting-row">
          <span className="reader-setting-row__label">Giãn dòng</span>
          <div className="reader-setting-row__control">
            <div className="reader-segmented reader-segmented--full">
              {LINE_HEIGHT_OPTIONS.map((lh) => (
                <button
                  key={lh.id}
                  type="button"
                  className={`reader-segmented__btn ${desc.lineHeight === lh.id ? 'is-active' : ''}`}
                  onClick={() => updateDescriptor({ lineHeight: lh.id as LineHeightPreset })}
                >
                  {lh.label}
                </button>
              ))}
            </div>
          </div>
        </div>

        {/* 5. Font Family (including Serif, Sans, Handwriting, Mono) */}
        <div className="reader-setting-row">
          <span className="reader-setting-row__label">Phông chữ</span>
          <div className="reader-setting-row__control">
            <select
              className="reader-compact-select"
              value={effectiveFontId}
              style={currentFont.family ? { fontFamily: currentFont.family } : undefined}
              onChange={(e) => onSelectFont(e.target.value)}
              aria-label="Chọn phông chữ"
            >
              {FONT_GROUPS.map((grp) => {
                const fonts = READER_FONTS.filter((f) => f.category === grp.category);
                if (!fonts.length) return null;
                return (
                  <optgroup key={grp.category} label={grp.label}>
                    {fonts.map((f) => (
                      <option key={f.id} value={f.id}>
                        {f.label} — {f.sublabel}
                      </option>
                    ))}
                  </optgroup>
                );
              })}
            </select>
          </div>
        </div>

        {/* 6. Text / Ink Color */}
        <div className="reader-setting-row reader-setting-row--stacked">
          <div className="reader-setting-row__top">
            <span className="reader-setting-row__label">Màu chữ</span>
            <span className="reader-setting-row__hint">
              {desc.inkColor === 'auto'
                ? 'Theo màu giấy'
                : READER_INK_COLORS.find((c) => c.id === desc.inkColor)?.label ||
                  desc.inkColor.toUpperCase()}
            </span>
          </div>
          <div className="reader-color-dots">
            {READER_INK_COLORS.map((ink) => {
              const active = desc.inkColor === ink.id;
              return (
                <button
                  key={ink.id}
                  type="button"
                  className={`reader-color-dot ${active ? 'is-active' : ''} ${
                    ink.id === 'auto' ? 'reader-color-dot--auto' : ''
                  }`}
                  style={ink.id !== 'auto' ? { backgroundColor: ink.color } : undefined}
                  onClick={() => updateDescriptor({ inkColor: ink.id })}
                  title={ink.label}
                >
                  {ink.id === 'auto' && <span>A</span>}
                </button>
              );
            })}
            <label
              className={`reader-color-dot reader-color-dot--picker ${isCustomInk ? 'is-active' : ''}`}
              title="Tuỳ chọn màu chữ bất kỳ"
              style={isCustomInk ? { backgroundColor: desc.inkColor } : undefined}
            >
              <span>+</span>
              <input
                type="color"
                value={desc.inkColor !== 'auto' ? desc.inkColor : currentTheme.ink}
                onChange={(e) => updateDescriptor({ inkColor: e.target.value })}
              />
            </label>
          </div>
        </div>

        {/* 7. Paper Color */}
        <div className="reader-setting-row reader-setting-row--stacked">
          <div className="reader-setting-row__top">
            <span className="reader-setting-row__label">Màu giấy</span>
            <span className="reader-setting-row__hint">
              {desc.themeId === 'custom'
                ? `Tuỳ chọn (${desc.customPaperColor.toUpperCase()})`
                : currentTheme.label}
            </span>
          </div>
          <div className="reader-color-dots">
            {READER_THEMES.map((theme) => {
              const active = desc.themeId === theme.id;
              return (
                <button
                  key={theme.id}
                  type="button"
                  className={`reader-color-dot ${active ? 'is-active' : ''}`}
                  style={{
                    backgroundColor: theme.paper,
                    color: theme.ink,
                  }}
                  onClick={() =>
                    updateDescriptor({
                      themeId: theme.id,
                      customPaperColor: '',
                    })
                  }
                  title={`${theme.label} — ${theme.sublabel}`}
                >
                  {theme.id === 'default' && <span className="reader-color-dot__tag">Gốc</span>}
                </button>
              );
            })}
            <label
              className={`reader-color-dot reader-color-dot--picker ${
                desc.themeId === 'custom' ? 'is-active' : ''
              }`}
              title="Tuỳ chọn màu giấy bất kỳ"
              style={
                desc.themeId === 'custom' && desc.customPaperColor
                  ? { backgroundColor: desc.customPaperColor }
                  : undefined
              }
            >
              <span>+</span>
              <input
                type="color"
                value={desc.customPaperColor || currentTheme.paper}
                onChange={(e) =>
                  updateDescriptor({
                    themeId: 'custom',
                    customPaperColor: e.target.value,
                  })
                }
              />
            </label>
          </div>
        </div>

        {/* 8. Paper Texture */}
        <div className="reader-setting-row">
          <span className="reader-setting-row__label">Chất giấy</span>
          <div className="reader-setting-row__control">
            <select
              className="reader-compact-select"
              value={desc.textureId}
              onChange={(e) => updateDescriptor({ textureId: e.target.value as PaperTextureId })}
              aria-label="Chọn chất liệu giấy"
            >
              {READER_TEXTURES.map((tex) => (
                <option key={tex.id} value={tex.id}>
                  {tex.label}
                </option>
              ))}
            </select>
          </div>
        </div>
      </div>

      {/* Compact Footer */}
      <div className="reader-appearance-popover__footer">
        <button
          type="button"
          className="reader-appearance-btn reader-appearance-btn--ghost"
          disabled={!hasUserOverride && matchesBookDefault}
          onClick={onResetToBookDefault}
          title="Khôi phục về mặc định của sách"
        >
          ↺ Mặc định
        </button>
        <button
          type="button"
          className="reader-appearance-btn reader-appearance-btn--primary"
          disabled={isSavingDefault || (matchesBookDefault && !hasUserOverride)}
          onClick={onSaveAsBookDefault}
          title="Lưu toàn bộ cấu hình đang chọn làm mặc định cho cuốn sách này"
        >
          {isSavingDefault ? 'Đang lưu…' : 'Lưu mặc định sách'}
        </button>
      </div>
    </div>
  );
}
