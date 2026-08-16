/**
 * Reader-control tools the realtime voice AI can invoke, plus their executor.
 * Ported from v1 (app.js:278-460 definitions, 1870-2139 execution).
 *
 * The executor takes a live `VoiceControls` object (the v2 fix for v1's stale
 * closures, review #7): ReaderView rebuilds it every render and useVoice reads
 * it through a ref, so tools always act on the CURRENT page/viewMode/highlights.
 */
import { VocaError, addWordToVoca, lookupWord, showVocaLookupResults } from '@/lib/voca';
import { colorMap } from '@/features/reader/highlightColors';
import { getParagraphs } from '@/features/reader/iframe/segmentation';
import type { SelectionInfo } from '@/features/reader/iframe/highlightDom';
import type { Book, Highlight, HighlightLang, ViewMode } from '@/types/api';

export interface VoiceControls {
  book: Book;
  page: number;
  viewMode: ViewMode;
  highlights: Highlight[];
  requestPageChange: (target: number | ((p: number) => number)) => Promise<void> | void;
  setViewMode: (mode: ViewMode) => void;
  createHighlight: (info: SelectionInfo, lang: HighlightLang, color: string) => void;
  deleteHighlight: (id: string) => void;
}

export interface ToolResult {
  success: boolean;
  [k: string]: unknown;
}

interface Occurrence extends SelectionInfo {
  lang: HighlightLang;
  context: string;
}

function findOccurrencesInDoc(doc: Document, searchText: string): Omit<Occurrence, 'lang'>[] {
  const paragraphs = getParagraphs(doc);
  const out: Omit<Occurrence, 'lang'>[] = [];
  const scan = (transform: (s: string) => string) => {
    const target = transform(searchText);
    paragraphs.forEach((p, i) => {
      const text = transform(p.textContent || '');
      let idx = text.indexOf(target);
      while (idx >= 0) {
        out.push({
          paragraphIndex: i,
          startOffset: idx,
          endOffset: idx + searchText.length,
          text: searchText,
          context: (p.textContent || '').trim(),
        });
        idx = text.indexOf(target, idx + 1);
      }
    });
  };
  scan((s) => s); // exact
  if (out.length === 0) scan((s) => s.toLowerCase()); // case-insensitive fallback
  return out;
}

/** Voca failures carry a machine-readable code — give the model both. */
function vocaToolError(err: unknown, fallback: string): ToolResult {
  if (err instanceof VocaError) return { success: false, error: err.code, message: err.message };
  return { success: false, error: err instanceof Error ? err.message : fallback };
}

export async function executeWebTool(
  name: string,
  args: Record<string, unknown>,
  ctx: VoiceControls,
): Promise<ToolResult> {
  const iframeDoc = (lang: HighlightLang): Document | null =>
    document.querySelector<HTMLIFrameElement>(lang === 'en' ? '.en-pane-iframe' : '.vi-pane-iframe')
      ?.contentDocument ?? null;

  switch (name) {
    case 'highlight_text': {
      const text = String(args.text ?? '');
      const colorHex = colorMap[String(args.color ?? 'yellow')] || '#fde68a';
      const occurrenceIndex = args.occurrenceIndex != null ? Number(args.occurrenceIndex) : null;
      const highlightAll = Boolean(args.highlightAll);
      const langs: HighlightLang[] = ctx.viewMode === 'split' ? ['en', 'vi'] : [ctx.viewMode as HighlightLang];

      const all: Occurrence[] = [];
      for (const lang of langs) {
        const doc = iframeDoc(lang);
        if (!doc) continue;
        for (const o of findOccurrencesInDoc(doc, text)) all.push({ ...o, lang });
      }
      if (all.length === 0) return { success: false, error: 'text_not_found' };
      if (all.length > 1 && occurrenceIndex === null && !highlightAll) {
        return { success: false, error: 'multiple_occurrences', message: `Found ${all.length} occurrences.`, occurrences: all };
      }
      let targets: Occurrence[];
      if (highlightAll) targets = all;
      else if (occurrenceIndex !== null) {
        if (occurrenceIndex < 0 || occurrenceIndex >= all.length) return { success: false, error: 'invalid_occurrence_index' };
        targets = [all[occurrenceIndex]!];
      } else targets = [all[0]!];

      for (const occ of targets) {
        ctx.createHighlight(
          { paragraphIndex: occ.paragraphIndex, startOffset: occ.startOffset, endOffset: occ.endOffset, text },
          occ.lang,
          colorHex,
        );
      }
      return { success: true, message: `Highlighted ${targets.length} occurrence(s).` };
    }

    case 'remove_highlight': {
      const text = String(args.text ?? '').toLowerCase();
      const existing = ctx.highlights.find((h) => h.text.toLowerCase() === text && h.page === ctx.page);
      if (existing) {
        ctx.deleteHighlight(existing.id);
        return { success: true };
      }
      return { success: false, error: 'highlight_not_found' };
    }

    case 'lookup_word': {
      try {
        const result = await lookupWord(String(args.word ?? ''));
        if (result.found) {
          const doc = iframeDoc('en');
          if (doc) showVocaLookupResults(doc, { left: 150, top: 150, width: 0, height: 0 } as DOMRect, String(args.word), result);
          // Voca 2.0 tells us when the hit is exact — hand the model that one
          // rich card rather than the ambiguous list.
          return { success: true, matchType: result.matchType, definition: result.card ?? result.cards };
        }
        return { success: false, error: 'word_not_found_in_dictionary' };
      } catch (err) {
        return vocaToolError(err, 'lookup_failed');
      }
    }

    case 'add_word_to_voca': {
      try {
        // 2.0 returns the finished card, so the model can read it straight back.
        const card = await addWordToVoca(String(args.word ?? ''));
        return { success: true, word: card.word, meaningVi: card.meaningVi, meaningEn: card.meaningEn };
      } catch (err) {
        return vocaToolError(err, 'add_failed');
      }
    }

    case 'go_to_page': {
      const target = Number(args.page);
      if (target >= 1 && target <= ctx.book.pageCount) {
        await ctx.requestPageChange(target);
        return { success: true };
      }
      return { success: false, error: 'page_out_of_bounds' };
    }
    case 'next_page': {
      if (ctx.page < ctx.book.pageCount) {
        await ctx.requestPageChange((p) => p + 1);
        return { success: true };
      }
      return { success: false, error: 'already_at_last_page' };
    }
    case 'previous_page': {
      if (ctx.page > 1) {
        await ctx.requestPageChange((p) => p - 1);
        return { success: true };
      }
      return { success: false, error: 'already_at_first_page' };
    }

    case 'get_page_content': {
      const lang = args.lang as HighlightLang | undefined;
      let content = '';
      if (!lang || lang === 'en') {
        const doc = iframeDoc('en');
        if (doc) content += `[English Page ${ctx.page}]:\n${doc.body.innerText}\n`;
      }
      if (!lang || lang === 'vi') {
        const doc = iframeDoc('vi');
        if (doc) content += `[Vietnamese Page ${ctx.page}]:\n${doc.body.innerText}\n`;
      }
      return { success: true, content: content.trim() };
    }

    case 'get_current_context':
      return {
        success: true,
        page: ctx.page,
        totalPages: ctx.book.pageCount,
        viewMode: ctx.viewMode,
        bookTitle: ctx.book.title,
        bookAuthor: ctx.book.author || 'Unknown',
      };

    case 'switch_view_mode': {
      const mode = String(args.mode);
      if (mode === 'en' || mode === 'vi' || mode === 'split') {
        ctx.setViewMode(mode);
        return { success: true };
      }
      return { success: false, error: 'invalid_mode' };
    }

    case 'list_highlights':
      return {
        success: true,
        highlights: ctx.highlights
          .filter((h) => h.page === ctx.page)
          .map((h) => ({ text: h.text, color: h.color, lang: h.lang, note: h.note })),
      };

    default:
      return { success: false, error: `Unknown tool: ${name}` };
  }
}

/** Tool schemas sent to the OpenAI realtime session (app.js:278-460). */
export const WEB_TOOL_DEFINITIONS = [
  {
    name: 'highlight_text',
    description: 'Highlight a word or phrase on the current page with a color.',
    parameters: {
      type: 'object',
      properties: {
        text: { type: 'string', description: 'The exact word or phrase to highlight' },
        color: { type: 'string', enum: ['yellow', 'blue', 'pink', 'green'] },
        occurrenceIndex: { type: 'integer', description: '0-based index if multiple occurrences' },
        highlightAll: { type: 'boolean', description: 'Highlight all occurrences' },
      },
      required: ['text'],
    },
  },
  { name: 'remove_highlight', description: 'Remove a highlight from the current page.', parameters: { type: 'object', properties: { text: { type: 'string' } }, required: ['text'] } },
  { name: 'lookup_word', description: 'Look up an English word in the Voca dictionary and show its panel.', parameters: { type: 'object', properties: { word: { type: 'string' } }, required: ['word'] } },
  { name: 'add_word_to_voca', description: "Add an English word to the user's Voca collection.", parameters: { type: 'object', properties: { word: { type: 'string' } }, required: ['word'] } },
  { name: 'go_to_page', description: 'Navigate to a specific page number.', parameters: { type: 'object', properties: { page: { type: 'integer' } }, required: ['page'] } },
  { name: 'next_page', description: 'Go to the next page.', parameters: { type: 'object', properties: {} } },
  { name: 'previous_page', description: 'Go to the previous page.', parameters: { type: 'object', properties: {} } },
  { name: 'get_page_content', description: 'Get the text of the current page.', parameters: { type: 'object', properties: { page: { type: 'integer' }, lang: { type: 'string', enum: ['en', 'vi'] } } } },
  { name: 'get_current_context', description: 'Get current page number, view mode, and book info.', parameters: { type: 'object', properties: {} } },
  { name: 'switch_view_mode', description: 'Switch reader view: en, vi, or split.', parameters: { type: 'object', properties: { mode: { type: 'string', enum: ['en', 'vi', 'split'] } }, required: ['mode'] } },
  { name: 'list_highlights', description: 'List all highlights on the current page.', parameters: { type: 'object', properties: {} } },
] as const;
