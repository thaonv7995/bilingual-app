/** A4 page geometry and zoom bounds — ported verbatim from v1 (app.js:41-54). */
export const READER_PAGE_WIDTH = 794;
export const READER_PAGE_HEIGHT = 1123;
export const READER_VIEWPORT_PADDING = 40;
export const READER_ZOOM_MIN = 0.5;
export const READER_ZOOM_MAX = 2;
export const READER_ZOOM_STEP = 0.1;

export type ZoomMode = 'fit-page' | 'fit-width' | 'custom';
export type LayoutMode = 'en-vi' | 'vi-en' | 'en-over-vi' | 'vi-over-en';

export function clampReaderZoom(scale: number, min: number = READER_ZOOM_MIN): number {
  return Math.min(READER_ZOOM_MAX, Math.max(min, scale));
}

export function formatReaderZoom(scale: number): string {
  return `${Math.round(scale * 100)}%`;
}

export function padPage(num: number): string {
  return String(num).padStart(4, '0');
}
