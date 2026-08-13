/**
 * HTML-escape a string for safe interpolation into raw markup.
 *
 * React auto-escapes JSX, so app UI does not need this. It's here for the few
 * places that build raw HTML strings injected into a book iframe's document
 * (voca lookup popups, highlight toolbars) — the sink that was unescaped in v1.
 */
export function escapeHtml(value: unknown): string {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}
