import type { ReactNode } from 'react';

/** Inline markdown: bold (**), italic (*), inline code (`). Ported from v1
 * parseInlineFormatting (app.js:2853-2868). React auto-escapes the text. */
function parseInline(text: string): ReactNode[] {
  const regex = /(\*\*.*?\*\*|\*.*?\*|`.*?`)/g;
  return text.split(regex).map((part, idx) => {
    if (part.startsWith('**') && part.endsWith('**')) return <strong key={idx}>{part.slice(2, -2)}</strong>;
    if (part.startsWith('*') && part.endsWith('*')) return <em key={idx}>{part.slice(1, -1)}</em>;
    if (part.startsWith('`') && part.endsWith('`'))
      return (
        <code className="inline-code" key={idx}>
          {part.slice(1, -1)}
        </code>
      );
    return part;
  });
}

/** Block-level mini-markdown: headers, ordered/unordered lists, fenced code,
 * paragraphs. Ported from v1 renderMessageContent (app.js:2871-2965). */
export function renderMessageContent(content: string): ReactNode[] {
  const lines = content.split('\n');
  const elements: ReactNode[] = [];
  let key = 0;
  let inCode = false;
  let codeLines: string[] = [];
  let listItems: string[] = [];
  let listType: 'ul' | 'ol' | null = null;

  const flushList = () => {
    if (listItems.length === 0) return;
    const items = listItems.map((item, idx) => <li key={idx}>{parseInline(item)}</li>);
    elements.push(listType === 'ol' ? <ol key={key++}>{items}</ol> : <ul key={key++}>{items}</ul>);
    listItems = [];
    listType = null;
  };

  for (const line of lines) {
    if (line.trim().startsWith('```')) {
      flushList();
      if (inCode) {
        elements.push(
          <pre key={key++}>
            <code>{codeLines.join('\n')}</code>
          </pre>,
        );
        codeLines = [];
        inCode = false;
      } else {
        inCode = true;
      }
      continue;
    }
    if (inCode) {
      codeLines.push(line);
      continue;
    }

    const trimmed = line.trim();
    if (!trimmed) {
      flushList();
      continue;
    }
    if (trimmed.startsWith('### ')) {
      flushList();
      elements.push(<h4 key={key++}>{parseInline(trimmed.slice(4))}</h4>);
      continue;
    }
    if (trimmed.startsWith('## ')) {
      flushList();
      elements.push(<h3 key={key++}>{parseInline(trimmed.slice(3))}</h3>);
      continue;
    }

    const ulMatch = line.match(/^(\s*)([*+-])\s+(.*)$/);
    if (ulMatch) {
      if (listType !== 'ul') {
        flushList();
        listType = 'ul';
      }
      listItems.push(ulMatch[3]!);
      continue;
    }
    const olMatch = line.match(/^(\s*)(\d+)\.\s+(.*)$/);
    if (olMatch) {
      if (listType !== 'ol') {
        flushList();
        listType = 'ol';
      }
      listItems.push(olMatch[3]!);
      continue;
    }

    flushList();
    elements.push(<p key={key++}>{parseInline(line)}</p>);
  }

  flushList();
  if (inCode && codeLines.length > 0) {
    elements.push(
      <pre key={key++}>
        <code>{codeLines.join('\n')}</code>
      </pre>,
    );
  }
  return elements;
}
