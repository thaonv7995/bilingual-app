declare module 'foliate-js/view.js' {
  export interface FoliateTocItem {
    label: string;
    href: string;
    subitems?: FoliateTocItem[];
  }

  export interface FoliateLocation {
    fraction?: number;
    cfi?: string;
    range?: Range;
    tocItem?: FoliateTocItem;
    pageItem?: { label?: string };
    section?: { current: number; total: number };
    location?: { current: number; next: number; total: number };
    index?: number;
  }

  export interface FoliateRenderer extends HTMLElement {
    setStyles?: (css: string) => void;
    getContents: () => Array<{ doc: Document; index: number; overlayer?: unknown }>;
    goTo: (target: unknown) => Promise<void>;
    prev: () => Promise<void>;
    next: () => Promise<void>;
    heads?: HTMLElement[];
    feet?: HTMLElement[];
  }

  export interface FoliateBook {
    toc?: FoliateTocItem[];
    metadata?: { title?: string; author?: unknown; language?: string };
    sections: Array<{ id: string; cfi?: string; linear?: string }>;
  }

  export interface FoliateViewElement extends HTMLElement {
    book?: FoliateBook;
    renderer?: FoliateRenderer;
    lastLocation?: FoliateLocation | null;
    open: (book: File | Blob | string) => Promise<void>;
    close: () => void;
    init: (opts: { lastLocation?: string; showTextStart?: boolean }) => Promise<void>;
    goTo: (target: string | number | { fraction: number }) => Promise<unknown>;
    goToFraction: (fraction: number) => Promise<void>;
    prev: (distance?: number) => Promise<void>;
    next: (distance?: number) => Promise<void>;
    getCFI: (index: number, range?: Range) => string;
    addAnnotation: (annotation: { value: string }, remove?: boolean) => Promise<unknown>;
    deleteAnnotation: (annotation: { value: string }) => Promise<unknown>;
    search: (opts: { query: string; wholeWords?: boolean }) => AsyncGenerator<{
      cfi?: string;
      excerpt?: { pre?: string; match?: string; post?: string };
      label?: string;
      subitems?: Array<{ cfi: string; excerpt?: { pre?: string; match?: string; post?: string } }>;
      progress?: number;
    }>;
    clearSearch: () => void;
  }

  export class View extends HTMLElement implements FoliateViewElement {
    book?: FoliateBook;
    renderer?: FoliateRenderer;
    lastLocation?: FoliateLocation | null;
    open(book: File | Blob | string): Promise<void>;
    close(): void;
    init(opts: { lastLocation?: string; showTextStart?: boolean }): Promise<void>;
    goTo(target: string | number | { fraction: number }): Promise<unknown>;
    goToFraction(fraction: number): Promise<void>;
    prev(distance?: number): Promise<void>;
    next(distance?: number): Promise<void>;
    getCFI(index: number, range?: Range): string;
    addAnnotation(annotation: { value: string }, remove?: boolean): Promise<unknown>;
    deleteAnnotation(annotation: { value: string }): Promise<unknown>;
    search(opts: { query: string; wholeWords?: boolean }): AsyncGenerator<{
      cfi?: string;
      excerpt?: { pre?: string; match?: string; post?: string };
      label?: string;
      subitems?: Array<{ cfi: string; excerpt?: { pre?: string; match?: string; post?: string } }>;
      progress?: number;
    }>;
    clearSearch(): void;
  }
}

declare module 'foliate-js/overlayer.js' {
  export class Overlayer {
    static highlight: (rects: DOMRect[], options?: { color?: string; padding?: number }) => SVGElement;
    static underline: (rects: DOMRect[], options?: { color?: string; width?: number }) => SVGElement;
    static outline: (rects: DOMRect[], options?: { color?: string; width?: number }) => SVGElement;
  }
}
