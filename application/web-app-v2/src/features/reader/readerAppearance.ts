import { readJSON, writeJSON } from '../../lib/storage.ts';
import type { Book } from '../../types/api.ts';

export type FontCategory = 'default' | 'serif' | 'sans' | 'handwriting' | 'mono';

export interface ReaderFontOption {
  id: string;
  label: string;
  sublabel: string;
  category: FontCategory;
  family: string;
  googleFontUrl?: string;
}

export interface ReaderThemeOption {
  id: string;
  label: string;
  sublabel: string;
  paper: string;
  ink: string;
  muted: string;
  accent: string;
  rule: string;
  codeBg: string;
  isDark: boolean;
  isBookDefault?: boolean;
}

export interface ReaderInkOption {
  id: string;
  label: string;
  color: string;
}

export type PaperTextureId =
  | 'default'
  | 'paper-grain'
  | 'vintage'
  | 'linen'
  | 'parchment'
  | 'dot-grid'
  | 'ruled';

export interface ReaderTextureOption {
  id: PaperTextureId;
  label: string;
}

export type PageMarginPreset = 'default' | 'compact' | 'normal' | 'wide';
export type LineHeightPreset = 'default' | '1.35' | '1.5' | '1.65' | '1.8';
export type InterlinearOpacityPreset = 35 | 55 | 80;

export interface ParsedThemeDescriptor {
  /** Preset theme ID ('default', 'paper-sepia', ...) or 'custom' when customPaperColor is set */
  themeId: string;
  /** Optional custom hex color (#rrggbb) when themeId === 'custom' */
  customPaperColor: string;
  /** 'auto' (follow paper theme) or hex color (#rrggbb) */
  inkColor: string;
  /** Paper texture overlay */
  textureId: PaperTextureId;
  /** Text font scale percentage (80 - 140, default 100) */
  fontScale: number;
  /** Line-height preset ('default' | '1.35' | '1.5' | '1.65' | '1.8') */
  lineHeight: LineHeightPreset;
  /** Horizontal page margin preset ('default' | 'compact' | 'normal' | 'wide') */
  pageMargin: PageMarginPreset;
  /** Single-page line-by-line bilingual interlinear mode */
  interlinear: boolean;
  /** Opacity percentage for the secondary translation subline (35 | 55 | 80) */
  interlinearOpacity: InterlinearOpacityPreset;
}

export const DEFAULT_THEME_DESCRIPTOR: ParsedThemeDescriptor = {
  themeId: 'default',
  customPaperColor: '',
  inkColor: 'auto',
  textureId: 'default',
  fontScale: 100,
  lineHeight: 'default',
  pageMargin: 'default',
  interlinear: false,
  interlinearOpacity: 55,
};

export const READER_FONTS: ReaderFontOption[] = [
  {
    id: 'default',
    label: 'Mặc định sách',
    sublabel: 'Theo thiết kế gốc của sách',
    category: 'default',
    family: '',
  },
  // Serif
  {
    id: 'literata',
    label: 'Literata',
    sublabel: 'Serif đọc sách điện tử',
    category: 'serif',
    family: "'Literata', Georgia, 'Times New Roman', serif",
    googleFontUrl:
      'https://fonts.googleapis.com/css2?family=Literata:ital,opsz,wght@0,7..72,400..700;1,7..72,400..700&display=swap',
  },
  {
    id: 'merriweather',
    label: 'Merriweather',
    sublabel: 'Cổ điển, đậm nét',
    category: 'serif',
    family: "'Merriweather', Georgia, 'Times New Roman', serif",
    googleFontUrl:
      'https://fonts.googleapis.com/css2?family=Merriweather:ital,wght@0,400;0,700;1,400;1,700&display=swap',
  },
  {
    id: 'lora',
    label: 'Lora',
    sublabel: 'Văn học, thanh lịch',
    category: 'serif',
    family: "'Lora', Georgia, 'Times New Roman', serif",
    googleFontUrl:
      'https://fonts.googleapis.com/css2?family=Lora:ital,wght@0,400..700;1,400..700&display=swap',
  },
  {
    id: 'noto-serif',
    label: 'Noto Serif',
    sublabel: 'Học thuật, dấu tiếng Việt chuẩn',
    category: 'serif',
    family: "'Noto Serif', Georgia, 'Times New Roman', serif",
    googleFontUrl:
      'https://fonts.googleapis.com/css2?family=Noto+Serif:ital,wght@0,400..700;1,400..700&display=swap',
  },
  {
    id: 'playfair',
    label: 'Playfair Display',
    sublabel: 'Tiêu đề & văn chương cổ điển',
    category: 'serif',
    family: "'Playfair Display', Georgia, 'Times New Roman', serif",
    googleFontUrl:
      'https://fonts.googleapis.com/css2?family=Playfair+Display:ital,wght@0,400..700;1,400..700&display=swap',
  },
  {
    id: 'charter',
    label: 'Charter / Georgia',
    sublabel: 'Sách in truyền thống',
    category: 'serif',
    family: "Charter, 'Bitstream Charter', Georgia, 'Times New Roman', serif",
  },
  // Sans-serif
  {
    id: 'inter',
    label: 'Inter',
    sublabel: 'Sans hiện đại, sách kỹ thuật',
    category: 'sans',
    family: "'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
    googleFontUrl:
      'https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap',
  },
  {
    id: 'plus-jakarta',
    label: 'Plus Jakarta Sans',
    sublabel: 'Sans mềm mại, dễ đọc',
    category: 'sans',
    family: "'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, sans-serif",
    googleFontUrl:
      'https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:ital,wght@0,400..700;1,400..700&display=swap',
  },
  {
    id: 'be-vietnam',
    label: 'Be Vietnam Pro',
    sublabel: 'Sans tối ưu tiếng Việt',
    category: 'sans',
    family: "'Be Vietnam Pro', -apple-system, BlinkMacSystemFont, sans-serif",
    googleFontUrl:
      'https://fonts.googleapis.com/css2?family=Be+Vietnam+Pro:ital,wght@0,400;0,500;0,600;0,700;1,400&display=swap',
  },
  {
    id: 'system-sans',
    label: 'System Sans',
    sublabel: 'SF Pro / Segoe UI hệ thống',
    category: 'sans',
    family: "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif",
  },
  // Handwriting / Script (full Vietnamese support)
  {
    id: 'playpen-sans',
    label: 'Playpen Sans',
    sublabel: 'Viết tay hiện đại, rõ chữ',
    category: 'handwriting',
    family: "'Playpen Sans', cursive, sans-serif",
    googleFontUrl:
      'https://fonts.googleapis.com/css2?family=Playpen+Sans:wght@400;500;600;700&display=swap',
  },
  {
    id: 'patrick-hand',
    label: 'Patrick Hand',
    sublabel: 'Viết tay sổ tay gọn gàng',
    category: 'handwriting',
    family: "'Patrick Hand', cursive, sans-serif",
    googleFontUrl:
      'https://fonts.googleapis.com/css2?family=Patrick+Hand&subset=vietnamese&display=swap',
  },
  {
    id: 'caveat',
    label: 'Caveat',
    sublabel: 'Viết tay bút mực tự nhiên',
    category: 'handwriting',
    family: "'Caveat', cursive, sans-serif",
    googleFontUrl:
      'https://fonts.googleapis.com/css2?family=Caveat:wght@400..700&display=swap',
  },
  {
    id: 'mali',
    label: 'Mali',
    sublabel: 'Viết tay nét tròn mềm mại',
    category: 'handwriting',
    family: "'Mali', cursive, sans-serif",
    googleFontUrl:
      'https://fonts.googleapis.com/css2?family=Mali:ital,wght@0,400;0,500;0,600;1,400&display=swap',
  },
  {
    id: 'itim',
    label: 'Itim',
    sublabel: 'Viết tay bút bi thanh thoát',
    category: 'handwriting',
    family: "'Itim', cursive, sans-serif",
    googleFontUrl: 'https://fonts.googleapis.com/css2?family=Itim&display=swap',
  },
  {
    id: 'dancing-script',
    label: 'Dancing Script',
    sublabel: 'Chữ viết tay thư pháp',
    category: 'handwriting',
    family: "'Dancing Script', cursive, serif",
    googleFontUrl:
      'https://fonts.googleapis.com/css2?family=Dancing+Script:wght@400..700&display=swap',
  },
  {
    id: 'kalam',
    label: 'Kalam',
    sublabel: 'Nét bút mực tự nhiên',
    category: 'handwriting',
    family: "'Kalam', cursive, sans-serif",
    googleFontUrl:
      'https://fonts.googleapis.com/css2?family=Kalam:wght@300;400;700&display=swap',
  },
  // Monospace / Typewriter
  {
    id: 'jetbrains-mono',
    label: 'JetBrains Mono',
    sublabel: 'Máy đánh chữ / Kỹ thuật',
    category: 'mono',
    family: "'JetBrains Mono', 'Courier New', Courier, monospace",
    googleFontUrl:
      'https://fonts.googleapis.com/css2?family=JetBrains+Mono:ital,wght@0,400;0,600;1,400&display=swap',
  },
  {
    id: 'courier-prime',
    label: 'Courier Prime',
    sublabel: 'Phong cách máy đánh chữ cổ điển',
    category: 'mono',
    family: "'Courier Prime', 'Courier New', Courier, monospace",
    googleFontUrl:
      'https://fonts.googleapis.com/css2?family=Courier+Prime:ital,wght@0,400;0,700;1,400;1,700&display=swap',
  },
];

export const READER_THEMES: ReaderThemeOption[] = [
  {
    id: 'default',
    label: 'Gốc',
    sublabel: 'Màu giấy gốc theo sách',
    paper: '#f4f1ea',
    ink: '#111111',
    muted: '#57534e',
    accent: '#1e4088',
    rule: '#d6d3d1',
    codeBg: '#ebe6dc',
    isDark: false,
    isBookDefault: true,
  },
  {
    id: 'paper-white',
    label: 'Trắng',
    sublabel: 'Pure White',
    paper: '#ffffff',
    ink: '#18181b',
    muted: '#52525b',
    accent: '#1d4ed8',
    rule: '#e4e4e7',
    codeBg: '#f4f4f5',
    isDark: false,
  },
  {
    id: 'paper-cream',
    label: 'Kem ấm',
    sublabel: 'Warm Cream',
    paper: '#fdf9f0',
    ink: '#26211c',
    muted: '#6b5e51',
    accent: '#1e4088',
    rule: '#e5dec9',
    codeBg: '#f4eee1',
    isDark: false,
  },
  {
    id: 'paper-sepia',
    label: 'Sepia',
    sublabel: 'Vintage Sepia',
    paper: '#f2e7cf',
    ink: '#3b2e22',
    muted: '#6e5a47',
    accent: '#854d0e',
    rule: '#d9c8ad',
    codeBg: '#e8d9bc',
    isDark: false,
  },
  {
    id: 'paper-oat',
    label: 'Giấy lụa',
    sublabel: 'Soft Oat',
    paper: '#eae4d7',
    ink: '#272421',
    muted: '#57534e',
    accent: '#1e3a8a',
    rule: '#d1c9b8',
    codeBg: '#e0d8c7',
    isDark: false,
  },
  {
    id: 'paper-rose',
    label: 'Hồng phấn',
    sublabel: 'Soft Rose',
    paper: '#fbf0f2',
    ink: '#2d1c22',
    muted: '#6e4f58',
    accent: '#9d174d',
    rule: '#e8d0d6',
    codeBg: '#f3e2e6',
    isDark: false,
  },
  {
    id: 'paper-sage',
    label: 'Xanh dịu',
    sublabel: 'Soft Sage',
    paper: '#e6efe7',
    ink: '#1b2b21',
    muted: '#4a6352',
    accent: '#166534',
    rule: '#c5d9c8',
    codeBg: '#dae6dc',
    isDark: false,
  },
  {
    id: 'paper-mist',
    label: 'Xanh sương',
    sublabel: 'Nordic Mist',
    paper: '#edf2f7',
    ink: '#1e293b',
    muted: '#475569',
    accent: '#0369a1',
    rule: '#cbd5e1',
    codeBg: '#e2e8f0',
    isDark: false,
  },
  {
    id: 'paper-dark',
    label: 'Tối dịu',
    sublabel: 'Dark Slate',
    paper: '#1a202c',
    ink: '#e2e8f0',
    muted: '#94a3b8',
    accent: '#60a5fa',
    rule: '#334155',
    codeBg: '#111621',
    isDark: true,
  },
  {
    id: 'paper-oled',
    label: 'Đen đêm',
    sublabel: 'AMOLED Night',
    paper: '#101216',
    ink: '#d4d4d8',
    muted: '#8e8e93',
    accent: '#38bdf8',
    rule: '#27272a',
    codeBg: '#181b22',
    isDark: true,
  },
];

export const READER_INK_COLORS: ReaderInkOption[] = [
  { id: 'auto', label: 'Tự động theo giấy', color: 'auto' },
  { id: '#111111', label: 'Đen mực (Classic)', color: '#111111' },
  { id: '#334155', label: 'Than chì (Slate)', color: '#334155' },
  { id: '#3b2818', label: 'Nâu trầm (Espresso)', color: '#3b2818' },
  { id: '#172554', label: 'Xanh mực (Navy)', color: '#172554' },
  { id: '#143323', label: 'Xanh rêu (Forest)', color: '#143323' },
  { id: '#e2e8f0', label: 'Trắng dịu (Light)', color: '#e2e8f0' },
  { id: '#fde68a', label: 'Hổ phách (Amber)', color: '#fde68a' },
];

export const READER_TEXTURES: ReaderTextureOption[] = [
  { id: 'default', label: 'Trơn (Mặc định)' },
  { id: 'paper-grain', label: 'Giấy in sách (Grain)' },
  { id: 'vintage', label: 'Giấy cổ điển (Vintage)' },
  { id: 'linen', label: 'Vân vải lanh (Linen)' },
  { id: 'parchment', label: 'Giấy da cừu (Parchment)' },
  { id: 'dot-grid', label: 'Sổ chấm bi (Dot Grid)' },
  { id: 'ruled', label: 'Sổ kẻ ngang (Ruled)' },
];

export const PAGE_MARGIN_OPTIONS: { id: PageMarginPreset; label: string; mm?: string }[] = [
  { id: 'default', label: 'Gốc' },
  { id: 'compact', label: 'Hẹp', mm: '12mm' },
  { id: 'normal', label: 'Vừa', mm: '20mm' },
  { id: 'wide', label: 'Rộng', mm: '28mm' },
];

export const LINE_HEIGHT_OPTIONS: { id: LineHeightPreset; label: string }[] = [
  { id: 'default', label: 'Gốc' },
  { id: '1.35', label: '1.35' },
  { id: '1.5', label: '1.5' },
  { id: '1.65', label: '1.65' },
  { id: '1.8', label: '1.8' },
];

export const INTERLINEAR_OPACITY_OPTIONS: { id: InterlinearOpacityPreset; label: string }[] = [
  { id: 35, label: 'Mờ 35%' },
  { id: 55, label: 'Dịu 55%' },
  { id: 80, label: 'Rõ 80%' },
];

export function getReaderFont(fontId?: string | null): ReaderFontOption {
  if (!fontId) return READER_FONTS[0]!;
  return READER_FONTS.find((f) => f.id === fontId) ?? READER_FONTS[0]!;
}

export function getReaderTheme(themeId?: string | null): ReaderThemeOption {
  if (!themeId) return READER_THEMES[0]!;
  const parsed = parseThemeDescriptor(themeId);
  if (parsed.themeId === 'custom' && parsed.customPaperColor) {
    return buildCustomPaperTheme(parsed.customPaperColor);
  }
  return READER_THEMES.find((t) => t.id === parsed.themeId) ?? READER_THEMES[0]!;
}

/** Compute luminance of a #rrggbb hex string to infer whether a custom paper color is dark. */
export function isHexColorDark(hex: string): boolean {
  const clean = hex.replace('#', '').trim();
  if (clean.length !== 6) return false;
  const r = parseInt(clean.slice(0, 2), 16) || 0;
  const g = parseInt(clean.slice(2, 4), 16) || 0;
  const b = parseInt(clean.slice(4, 6), 16) || 0;
  const lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  return lum < 0.45;
}

export function buildCustomPaperTheme(hexPaper: string): ReaderThemeOption {
  const dark = isHexColorDark(hexPaper);
  return {
    id: 'custom',
    label: 'Tuỳ chọn',
    sublabel: hexPaper.toUpperCase(),
    paper: hexPaper,
    ink: dark ? '#e2e8f0' : '#18181b',
    muted: dark ? '#94a3b8' : '#52525b',
    accent: dark ? '#60a5fa' : '#1d4ed8',
    rule: dark ? '#334155' : '#d4d4d8',
    codeBg: dark ? '#111621' : '#f4f4f5',
    isDark: dark,
  };
}

const VALID_TEXTURES = new Set<PaperTextureId>([
  'default',
  'paper-grain',
  'vintage',
  'linen',
  'parchment',
  'dot-grid',
  'ruled',
]);
const VALID_MARGINS = new Set<PageMarginPreset>(['default', 'compact', 'normal', 'wide']);
const VALID_LINE_HEIGHTS = new Set<LineHeightPreset>(['default', '1.35', '1.5', '1.65', '1.8']);

/**
 * Parse a theme descriptor string.
 * Supports plain IDs ("default", "paper-sepia") as well as compound strings:
 * "paper-sepia;tex=vintage;ink=#3b2818;scale=110;lh=1.5;margin=compact"
 * or "custom;paper=#f5ebd6;tex=linen".
 */
export function parseThemeDescriptor(raw?: string | null): ParsedThemeDescriptor {
  if (!raw || !raw.trim()) {
    return { ...DEFAULT_THEME_DESCRIPTOR };
  }
  const parts = raw
    .trim()
    .split(';')
    .map((p) => p.trim())
    .filter(Boolean);
  const first = parts[0] || 'default';
  const out: ParsedThemeDescriptor = {
    ...DEFAULT_THEME_DESCRIPTOR,
    themeId:
      first === 'custom' || READER_THEMES.some((t) => t.id === first) ? first : 'default',
  };

  for (let i = 1; i < parts.length; i++) {
    const seg = parts[i]!;
    const eqIdx = seg.indexOf('=');
    if (eqIdx <= 0) continue;
    const key = seg.slice(0, eqIdx).trim();
    const val = seg.slice(eqIdx + 1).trim();
    if (!val) continue;

    if (key === 'paper' && /^#[0-9a-fA-F]{6}$/.test(val)) {
      out.themeId = 'custom';
      out.customPaperColor = val.toLowerCase();
    } else if (key === 'ink' && (val === 'auto' || /^#[0-9a-fA-F]{6}$/.test(val))) {
      out.inkColor = val.toLowerCase();
    } else if (key === 'tex' && VALID_TEXTURES.has(val as PaperTextureId)) {
      out.textureId = val as PaperTextureId;
    } else if (key === 'scale') {
      const n = parseInt(val, 10);
      if (!isNaN(n)) out.fontScale = Math.max(80, Math.min(140, n));
    } else if (key === 'lh' && VALID_LINE_HEIGHTS.has(val as LineHeightPreset)) {
      out.lineHeight = val as LineHeightPreset;
    } else if (key === 'margin' && VALID_MARGINS.has(val as PageMarginPreset)) {
      out.pageMargin = val as PageMarginPreset;
    } else if (key === 'il') {
      out.interlinear = val === '1' || val === 'true';
    } else if (key === 'ilop') {
      const n = parseInt(val, 10);
      if (n === 35 || n === 55 || n === 80) {
        out.interlinearOpacity = n;
      }
    }
  }

  if (out.themeId === 'custom' && !out.customPaperColor) {
    out.themeId = 'default';
  }
  return out;
}

/**
 * Serialize a `ParsedThemeDescriptor` back into a compact string.
 * When all extra fields are at default, returns the plain `themeId` (e.g. "paper-sepia" or "default")
 * so existing callers and tests stay 100% compatible.
 */
export function serializeThemeDescriptor(desc: Partial<ParsedThemeDescriptor>): string {
  const merged: ParsedThemeDescriptor = {
    ...DEFAULT_THEME_DESCRIPTOR,
    ...desc,
  };
  const base =
    merged.themeId === 'custom' && merged.customPaperColor ? 'custom' : merged.themeId || 'default';
  const segments: string[] = [base];

  if (base === 'custom' && /^#[0-9a-fA-F]{6}$/.test(merged.customPaperColor)) {
    segments.push(`paper=${merged.customPaperColor.toLowerCase()}`);
  }
  if (merged.inkColor && merged.inkColor !== 'auto' && /^#[0-9a-fA-F]{6}$/.test(merged.inkColor)) {
    segments.push(`ink=${merged.inkColor.toLowerCase()}`);
  }
  if (merged.textureId && merged.textureId !== 'default') {
    segments.push(`tex=${merged.textureId}`);
  }
  if (merged.fontScale && merged.fontScale !== 100) {
    segments.push(`scale=${Math.max(80, Math.min(140, Math.round(merged.fontScale)))}`);
  }
  if (merged.lineHeight && merged.lineHeight !== 'default') {
    segments.push(`lh=${merged.lineHeight}`);
  }
  if (merged.pageMargin && merged.pageMargin !== 'default') {
    segments.push(`margin=${merged.pageMargin}`);
  }
  if (merged.interlinear) {
    segments.push('il=1');
  }
  if (merged.interlinearOpacity && merged.interlinearOpacity !== 55) {
    segments.push(`ilop=${merged.interlinearOpacity}`);
  }

  return segments.join(';');
}

export function isThemeDescriptorDefault(raw?: string | null): boolean {
  return serializeThemeDescriptor(parseThemeDescriptor(raw)) === 'default';
}

export interface LocalBookAppearance {
  readerFont?: string;
  readerTheme?: string;
}

const LOCAL_APPEARANCE_PREFIX = 'bilingual.bookAppearance.';

export function getLocalBookAppearance(slug: string): LocalBookAppearance {
  return readJSON<LocalBookAppearance>(`${LOCAL_APPEARANCE_PREFIX}${slug}`, {});
}

export function saveLocalBookAppearance(slug: string, appearance: LocalBookAppearance): void {
  writeJSON(`${LOCAL_APPEARANCE_PREFIX}${slug}`, appearance);
}

/**
 * Resolves the effective font & theme descriptor for a book:
 * 1. User's per-book override (local cache or server `book.readerFont` / `book.readerTheme`)
 * 2. Book's configured default (`book.defaultFont` / `book.defaultTheme`)
 * 3. `'default'` (original book stylesheet)
 */
export function resolveEffectiveBookAppearance(
  book: Pick<Book, 'slug' | 'defaultFont' | 'defaultTheme' | 'readerFont' | 'readerTheme'>,
  override?: LocalBookAppearance,
): {
  effectiveFontId: string;
  effectiveThemeId: string;
  effectiveDescriptor: ParsedThemeDescriptor;
  bookDefaultFontId: string;
  bookDefaultThemeId: string;
  bookDefaultDescriptor: ParsedThemeDescriptor;
  hasUserFontOverride: boolean;
  hasUserThemeOverride: boolean;
} {
  const bookDefaultFontId = getReaderFont(book.defaultFont || 'default').id;
  const bookDefaultDescriptor = parseThemeDescriptor(book.defaultTheme || 'default');
  const bookDefaultThemeId = serializeThemeDescriptor(bookDefaultDescriptor);

  const userFontRaw =
    override?.readerFont !== undefined ? override.readerFont : (book.readerFont ?? '');
  const userThemeRaw =
    override?.readerTheme !== undefined ? override.readerTheme : (book.readerTheme ?? '');

  const hasUserFontOverride = Boolean(userFontRaw && userFontRaw !== '');
  const hasUserThemeOverride = Boolean(userThemeRaw && userThemeRaw !== '');

  const effectiveFontId = hasUserFontOverride
    ? getReaderFont(userFontRaw).id
    : bookDefaultFontId;
  const effectiveDescriptor = hasUserThemeOverride
    ? parseThemeDescriptor(userThemeRaw)
    : bookDefaultDescriptor;
  const effectiveThemeId = serializeThemeDescriptor(effectiveDescriptor);

  return {
    effectiveFontId,
    effectiveThemeId,
    effectiveDescriptor,
    bookDefaultFontId,
    bookDefaultThemeId,
    bookDefaultDescriptor,
    hasUserFontOverride,
    hasUserThemeOverride,
  };
}

let previewFontsPreloaded = false;
/** Load a single Google Font into the parent document so browser font cache stays warm across iframe page turns. */
export function preloadSingleReaderFont(fontId: string): void {
  if (typeof document === 'undefined' || !fontId || fontId === 'default') return;
  const font = getReaderFont(fontId);
  if (!font.googleFontUrl) return;
  const linkId = `bilingual-preview-font-${font.id}`;
  if (document.getElementById(linkId)) return;
  const link = document.createElement('link');
  link.id = linkId;
  link.rel = 'stylesheet';
  link.href = font.googleFontUrl;
  document.head.appendChild(link);
}

/** Load Google Fonts into the parent document once so font picker previews render accurately. */
export function preloadReaderFontsInAppDocument(): void {
  if (previewFontsPreloaded || typeof document === 'undefined') return;
  previewFontsPreloaded = true;
  for (const font of READER_FONTS) {
    if (!font.googleFontUrl) continue;
    const linkId = `bilingual-preview-font-${font.id}`;
    if (document.getElementById(linkId)) continue;
    const link = document.createElement('link');
    link.id = linkId;
    link.rel = 'stylesheet';
    link.href = font.googleFontUrl;
    document.head.appendChild(link);
  }
}
