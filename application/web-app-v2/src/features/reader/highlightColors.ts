/** Highlight palette + toolbar icons — ported from v1 (app.js:34-64, 261-276). */

export interface HighlightColorDef {
  id: string;
  value: string; // CSS hex actually stored on the highlight
  label: string;
}

export const HIGHLIGHT_COLORS: HighlightColorDef[] = [
  { id: 'yellow', value: '#fde68a', label: 'Vàng' },
  { id: 'blue', value: '#93c5fd', label: 'Xanh' },
  { id: 'pink', value: '#f9a8d4', label: 'Hồng' },
  { id: 'green', value: '#86efac', label: 'Xanh lá' },
];

/** Named color -> hex, for the AI `highlight_text` tool which passes names. */
export const colorMap: Record<string, string> = {
  yellow: '#fde68a',
  blue: '#93c5fd',
  pink: '#f9a8d4',
  green: '#86efac',
};

const TOOLBAR_ICONS: Record<'note' | 'book' | 'trash', string> = {
  note: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 20h9"></path><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"></path></svg>',
  book: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H21"></path><path d="M4 4.5A2.5 2.5 0 0 1 6.5 2H21v20H6.5A2.5 2.5 0 0 1 4 19.5Z"></path><path d="M8 6h8"></path><path d="M8 10h6"></path></svg>',
  trash: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h18"></path><path d="M8 6V4h8v2"></path><path d="m19 6-1 14H6L5 6"></path><path d="M10 11v5"></path><path d="M14 11v5"></path></svg>',
};

export function setToolbarIcon(button: HTMLElement, icon: keyof typeof TOOLBAR_ICONS): void {
  button.innerHTML = TOOLBAR_ICONS[icon] || '';
}
