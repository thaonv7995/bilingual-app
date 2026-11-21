import SwiftUI
import WebKit
import AppKit

struct SelectionInfo: Codable {
    let paragraphIndex: Int
    let startOffset: Int
    let endOffset: Int
    let text: String
    let rect: CGRect?
}

enum HighlightMessage {
    case textSelected(selectionInfo: SelectionInfo)
    case highlightClicked(id: String, rect: CGRect?)
    case clearSelection
}

enum VocaWebAction {
    case addWord(String)
    case playAudio(slug: String)
    case selectCard(VocaCard)
    case dismiss
}

private func selectionRect(from dict: [String: Any]?) -> CGRect? {
    guard let dict else { return nil }
    func num(_ key: String) -> CGFloat? {
        if let v = dict[key] as? CGFloat { return v }
        if let v = dict[key] as? Double { return CGFloat(v) }
        if let v = dict[key] as? Int { return CGFloat(v) }
        if let v = dict[key] as? NSNumber { return CGFloat(v.doubleValue) }
        return nil
    }
    guard let x = num("x"), let y = num("y"), let w = num("width"), let h = num("height") else { return nil }
    return CGRect(x: x, y: y, width: w, height: h)
}

struct BilingualWebViewMac: NSViewRepresentable {
    let bookSlug: String
    let urlString: String
    let lang: String
    let page: Int
    let viewMode: String
    let containerMode: String
    var effectiveFontId: String = "default"
    var effectiveThemeId: String = "default"
    var activeSentenceId: String? = nil
    var scrollActiveSentenceIntoView: Bool = false
    var scrollSyncScope: String = "main"

    @ObservedObject var api = APIService.shared
    let highlights: [Highlight]
    let onHighlightMessage: (HighlightMessage) -> Void
    var onSentenceClicked: ((String?) -> Void)? = nil
    let onVocaAction: (VocaWebAction) -> Void
    var onOpenExternalURL: ((URL) -> Void)? = nil
    var onWebViewReady: ((WKWebView, String, Int) -> Void)? = nil
    var onWebViewDismantled: ((WKWebView, String, Int) -> Void)? = nil
    var onPageDidFinish: ((WKWebView, String, Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "macListener")

        let isEnglish = lang == "en"
        let highlightColor = isEnglish ? "rgba(56, 189, 248, 0.22)" : "rgba(250, 204, 21, 0.24)"
        let hoverColor = isEnglish ? "rgba(56, 189, 248, 0.08)" : "rgba(250, 204, 21, 0.08)"

        let baseStyleSource = """
        (function() {
            const STYLE_ID = 'mac-reader-base-style';
            const APPEARANCE_ID = 'bkb-appearance-style';
            const CSS_TEXT = `
                .page-nav { display: none !important; }
                @keyframes macPaperReveal {
                    from { opacity: 0.72; }
                    to { opacity: 1; }
                }
                @keyframes readerHighlightPulse {
                    0%, 100% { box-shadow: 0 0 0 0 rgba(56, 189, 248, 0); }
                    50% { box-shadow: 0 0 0 5px rgba(56, 189, 248, 0.42); }
                }
                @keyframes vocaPopIn {
                    from { opacity: 0; transform: translateY(4px) scale(0.96); }
                    to { opacity: 1; transform: translateY(0) scale(1); }
                }
                body {
                    animation: macPaperReveal 0.18s cubic-bezier(0.22, 1, 0.36, 1);
                }
                .sentence-node {
                    transition: background-color 0.2s ease, box-shadow 0.2s ease;
                    border-radius: 4px;
                    cursor: pointer;
                    display: inline;
                    -webkit-user-select: text;
                    user-select: text;
                }
                .sentence-node:hover {
                    background-color: \(hoverColor);
                }
                .sentence-node.highlight-sync {
                    background-color: \(highlightColor) !important;
                    box-decoration-break: clone;
                    -webkit-box-decoration-break: clone;
                }
                html {
                    margin: 0 !important;
                    padding: 0 !important;
                    width: 100% !important;
                    max-width: 100% !important;
                    height: auto !important;
                    min-height: 100vh !important;
                    box-sizing: border-box !important;
                    overflow-x: hidden !important;
                    overflow-y: auto !important;
                }
                html body, html body.book-standalone {
                    display: block !important;
                    margin: 0 !important;
                    padding: \(viewMode == "split" ? "20px 26px 40px" : "28px 40px 48px") !important;
                    width: 100% !important;
                    max-width: 100% !important;
                    min-width: 0 !important;
                    height: auto !important;
                    min-height: 100vh !important;
                    box-sizing: border-box !important;
                    overflow-x: hidden !important;
                    overflow-y: visible !important;
                }
                html body :is(main, article, .prose-page, .prose-content, .toc-page, .toc-columns-container, .copy-content, .unit-page, .exercises-page, .book-page, .book-page.book-page--sheet, .book-page--sheet, .sheet-flow) {
                    margin: 0 auto !important;
                    padding: 0 !important;
                    width: 100% !important;
                    max-width: min(780px, 100%) !important;
                    min-width: 0 !important;
                    flex-shrink: 1 !important;
                    height: auto !important;
                    min-height: 0 !important;
                    max-height: none !important;
                    overflow: visible !important;
                    overflow-x: visible !important;
                    overflow-y: visible !important;
                    box-sizing: border-box !important;
                    background: transparent !important;
                    background-color: transparent !important;
                    box-shadow: none !important;
                }
                html body .book-page--sheet::after,
                html body .book-page::after {
                    display: none !important;
                    content: none !important;
                }
                html body :is(.page-folio, .preface-folio, .toc-folio) {
                    position: static !important;
                    margin-top: 16px !important;
                    text-align: center !important;
                }
                html body *:not(.voca-lookup-panel):not(.voca-lookup-panel *) {
                    max-width: 100% !important;
                    box-sizing: border-box !important;
                }
                html body :is(p, li, blockquote, dd, dt, td, th, span, div, h1, h2, h3, h4, h5, h6) {
                    overflow-wrap: break-word !important;
                }
                html body :is(pre, .code-block, .ascii-figure) {
                    white-space: pre-wrap !important;
                    overflow-wrap: anywhere !important;
                }
                html body :is(img, svg, object, canvas, video, figure) {
                    max-width: 100% !important;
                    height: auto !important;
                }
                mark.reader-highlight {
                    border-radius: 3px;
                    padding: 0 1px;
                    cursor: pointer;
                    position: relative;
                    color: inherit;
                    box-decoration-break: clone;
                    -webkit-box-decoration-break: clone;
                    transition: filter 0.15s ease;
                }
                mark.reader-highlight:hover {
                    filter: brightness(0.96);
                }
                mark.reader-highlight--pulse {
                    animation: readerHighlightPulse 1.2s ease;
                }
                mark.reader-highlight[data-has-note="true"]::after {
                    content: '';
                    position: absolute;
                    top: -3px;
                    right: -3px;
                    width: 6px;
                    height: 6px;
                    border-radius: 50%;
                    background: #2563eb;
                    border: 1px solid #fff;
                }
                .voca-lookup-panel {
                    position: fixed;
                    z-index: 10000;
                    min-width: 220px;
                    max-width: min(320px, calc(100vw - 24px)) !important;
                    padding: 12px 14px;
                    border-radius: 10px;
                    background-color: #ffffff !important;
                    border: 1px solid rgba(15, 23, 42, 0.14);
                    box-shadow: 0 12px 32px rgba(15, 23, 42, 0.20);
                    color: #0f172a !important;
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                    font-size: 13px;
                    animation: vocaPopIn 0.16s cubic-bezier(0.22, 1, 0.36, 1);
                }
                .voca-lookup-panel__head { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
                .voca-lookup-panel__word { font-weight: 700; font-size: 14px; color: #0f172a !important; }
                .voca-lookup-panel__voice { border: 0; background-color: #e0f2fe !important; border-radius: 7px; width: 32px; height: 32px; display: inline-flex; align-items: center; justify-content: center; cursor: pointer; font-size: 14px; transition: background-color 0.12s ease, transform 0.1s ease; }
                .voca-lookup-panel__voice:hover { background-color: #bae6fd !important; }
                .voca-lookup-panel__voice:active { transform: scale(0.94); }
                .voca-lookup-panel__ipa { margin-top: 4px; color: #475569 !important; font-size: 12px; }
                .voca-lookup-panel__meaning { margin-top: 6px; color: #1e293b !important; line-height: 1.45; }
                .voca-lookup-panel__hint { margin-top: 4px; color: #64748b !important; font-size: 12px; }
                .voca-lookup-panel__create { margin-top: 10px; width: 100%; border: 0; border-radius: 8px; padding: 9px 12px; background-color: #2563eb !important; color: #fff !important; font-size: 12px; font-weight: 700; cursor: pointer; transition: filter 0.12s ease, transform 0.1s ease; }
                .voca-lookup-panel__create:hover { filter: brightness(1.08); }
                .voca-lookup-panel__create:active { transform: scale(0.98); }
                .voca-lookup-panel__list { margin-top: 8px; display: flex; flex-direction: column; gap: 6px; max-height: 220px; overflow-y: auto; }
                .voca-lookup-panel__item { width: 100%; text-align: left; border: 1px solid rgba(15, 23, 42, 0.1); border-radius: 8px; padding: 9px 10px; background-color: #f8fafc !important; cursor: pointer; display: flex; flex-direction: column; gap: 2px; transition: background-color 0.12s ease; }
                .voca-lookup-panel__item:hover { background-color: #eff6ff !important; border-color: rgba(37, 99, 235, 0.3); }
                .voca-lookup-panel__item-word { font-weight: 700; font-size: 12px; color: #0f172a !important; }
                .voca-lookup-panel__item-meaning { font-size: 11px; color: #475569 !important; }
            `;
            let isSyncing = false;
            const ensureAfterAuthorStyles = () => {
                if (isSyncing) return;
                const parent = document.head || document.documentElement;
                if (!parent) return;
                isSyncing = true;
                try {
                    let style = document.getElementById(STYLE_ID);
                    if (!style) {
                        style = document.createElement('style');
                        style.id = STYLE_ID;
                        style.textContent = CSS_TEXT;
                    }
                    const appearanceEl = document.getElementById(APPEARANCE_ID);
                    if (appearanceEl && appearanceEl.parentNode === parent) {
                        if (style.parentNode !== parent || style.nextElementSibling !== appearanceEl) {
                            parent.insertBefore(style, appearanceEl);
                        }
                    } else if (style.parentNode !== parent || style.nextElementSibling !== null) {
                        parent.appendChild(style);
                    }
                } finally {
                    isSyncing = false;
                }
            };
            ensureAfterAuthorStyles();
            const obs = new MutationObserver(() => { ensureAfterAuthorStyles(); });
            obs.observe(document.documentElement, { childList: true, subtree: true });
            document.addEventListener('DOMContentLoaded', () => { ensureAfterAuthorStyles(); });
            window.addEventListener('load', () => {
                ensureAfterAuthorStyles();
                obs.disconnect();
            });
        })();
        """

        let bridgeScript = """
        (function() {
            const PARAGRAPH_SELECTOR = 'p, .chapter-start, .no-indent, h1, h2, h3, h4, h5, h6, li, blockquote, .section-title, .action-header, .action-title';

            window.getParagraphs = function() {
                const container = document.querySelector('article') || document.querySelector('.prose-page') || document.body;
                if (!container) return [];
                return Array.from(container.querySelectorAll(PARAGRAPH_SELECTOR)).filter(el => !el.closest('.bilingual-subline'));
            };

            function splitIntoSentences(text) {
                if (!text) return [];
                const sentences = [];
                let currentStart = 0;
                const boundaryRegex = /([.!?])(\\s+|$)/g;
                let match;
                const abbrevs = [
                    'mr', 'mrs', 'dr', 'ms', 'prof', 'sr', 'jr', 'vs', 'etc', 'eg', 'ie', 'al',
                    'st', 'av', 'rd', 'capt', 'gen', 'col', 'lt', 'sgt', 'rep', 'sen', 'oct', 'nov', 'dec',
                    'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'tp', 'ts', 'ths', 'gs', 'hcm'
                ];
                while ((match = boundaryRegex.exec(text)) !== null) {
                    const boundaryIdx = match.index;
                    const precedingText = text.substring(currentStart, boundaryIdx);
                    const lastWordMatch = precedingText.match(/(\\b\\w+)$/);
                    const lastWord = lastWordMatch ? lastWordMatch[1].toLowerCase() : '';
                    if (abbrevs.includes(lastWord)) {
                        continue;
                    }
                    const sentenceEnd = boundaryIdx + 1 + match[2].length;
                    const sentenceText = text.substring(currentStart, sentenceEnd);
                    if (sentenceText.length > 0) {
                        sentences.push(sentenceText);
                    }
                    currentStart = sentenceEnd;
                }
                if (currentStart < text.length) {
                    const remaining = text.substring(currentStart);
                    if (remaining.length > 0) {
                        sentences.push(remaining);
                    }
                }
                return sentences;
            }

            function segmentParagraph(pElement, pIdx) {
                const text = pElement.textContent || '';
                if (!text.trim()) return;
                const sentences = splitIntoSentences(text);
                if (sentences.length <= 1) {
                    const span = pElement.ownerDocument.createElement('span');
                    span.className = 'sentence-node';
                    span.dataset.sentenceId = `p-${pIdx}-s-0`;
                    while (pElement.firstChild) {
                        span.appendChild(pElement.firstChild);
                    }
                    pElement.appendChild(span);
                    return;
                }
                const sentenceSpans = sentences.map((_, sIdx) => {
                    const span = pElement.ownerDocument.createElement('span');
                    span.className = 'sentence-node';
                    span.dataset.sentenceId = `p-${pIdx}-s-${sIdx}`;
                    return span;
                });
                let currentSentenceIdx = 0;
                let currentSentenceRemainingLen = sentences[0].length;
                const childNodes = Array.from(pElement.childNodes);
                pElement.innerHTML = '';
                childNodes.forEach(node => {
                    if (node.nodeType === 3) {
                        let nodeText = node.textContent || '';
                        while (nodeText.length > 0 && currentSentenceIdx < sentences.length) {
                            if (nodeText.length <= currentSentenceRemainingLen) {
                                sentenceSpans[currentSentenceIdx].appendChild(pElement.ownerDocument.createTextNode(nodeText));
                                currentSentenceRemainingLen -= nodeText.length;
                                nodeText = '';
                            } else {
                                const part = nodeText.substring(0, currentSentenceRemainingLen);
                                sentenceSpans[currentSentenceIdx].appendChild(pElement.ownerDocument.createTextNode(part));
                                nodeText = nodeText.substring(currentSentenceRemainingLen);
                                currentSentenceIdx++;
                                if (currentSentenceIdx < sentences.length) {
                                    currentSentenceRemainingLen = sentences[currentSentenceIdx].length;
                                }
                            }
                        }
                    } else if (node.nodeType === 1) {
                        if (currentSentenceIdx < sentenceSpans.length) {
                            sentenceSpans[currentSentenceIdx].appendChild(node);
                            currentSentenceRemainingLen -= (node.textContent || '').length;
                            if (currentSentenceRemainingLen <= 0 && currentSentenceIdx < sentences.length - 1) {
                                currentSentenceIdx++;
                                currentSentenceRemainingLen = sentences[currentSentenceIdx].length;
                            }
                        }
                    }
                });
                sentenceSpans.forEach(span => {
                    if (span.textContent.length > 0) {
                        pElement.appendChild(span);
                    }
                });
            }

            window.ensureSentencesSegmented = function() {
                const paragraphs = window.getParagraphs();
                paragraphs.forEach((p, idx) => {
                    if (!p.querySelector('.sentence-node')) {
                        segmentParagraph(p, idx);
                    }
                });
            };

            window.highlightSentence = function(sentenceId, scrollIfOffscreen) {
                window.ensureSentencesSegmented();
                document.querySelectorAll('.sentence-node.highlight-sync').forEach(el => {
                    el.classList.remove('highlight-sync');
                });
                if (!sentenceId) return;
                const nodes = document.querySelectorAll('.sentence-node');
                let targetNode = null;
                for (let i = 0; i < nodes.length; i++) {
                    if (nodes[i].dataset.sentenceId === sentenceId) {
                        targetNode = nodes[i];
                        break;
                    }
                }
                if (targetNode) {
                    targetNode.classList.add('highlight-sync');
                    if (scrollIfOffscreen) {
                        const rect = targetNode.getBoundingClientRect();
                        if (rect.top < 16 || rect.bottom > window.innerHeight - 16) {
                            window.__macIgnoreScroll = true;
                            targetNode.scrollIntoView({ behavior: 'smooth', block: 'center' });
                            setTimeout(() => { window.__macIgnoreScroll = false; }, 450);
                        }
                    }
                }
            };

            window.scrollToAndPulseHighlight = function(highlightId) {
                const marks = Array.from(document.querySelectorAll('mark.reader-highlight')).filter(m => m.dataset.highlightId === highlightId);
                if (marks.length === 0) return;
                window.__macIgnoreScroll = true;
                marks[0].scrollIntoView({ behavior: 'smooth', block: 'center' });
                setTimeout(() => { window.__macIgnoreScroll = false; }, 450);
                marks.forEach(m => {
                    m.classList.remove('reader-highlight--pulse');
                    void m.offsetWidth;
                    m.classList.add('reader-highlight--pulse');
                    setTimeout(() => m.classList.remove('reader-highlight--pulse'), 1300);
                });
            };

            window.wrapTextRange = function(paragraph, startOffset, endOffset, highlightData) {
                const walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT, null, false);
                let currentOffset = 0;
                const nodesToWrap = [];
                while (walker.nextNode()) {
                    const node = walker.currentNode;
                    if (node.parentElement && node.parentElement.closest('.bilingual-subline')) continue;
                    const len = node.nodeValue.length;
                    const nodeStart = currentOffset;
                    const nodeEnd = nodeStart + len;
                    if (nodeEnd > startOffset && nodeStart < endOffset) {
                        nodesToWrap.push({
                            node,
                            start: Math.max(0, startOffset - nodeStart),
                            end: Math.min(len, endOffset - nodeStart)
                        });
                    }
                    currentOffset = nodeEnd;
                }
                for (let i = nodesToWrap.length - 1; i >= 0; i--) {
                    const item = nodesToWrap[i];
                    try {
                        const range = document.createRange();
                        range.setStart(item.node, item.start);
                        range.setEnd(item.node, item.end);
                        const mark = document.createElement('mark');
                        mark.className = 'reader-highlight';
                        mark.dataset.highlightId = highlightData.id;
                        mark.dataset.hasNote = (highlightData.note && highlightData.note.trim().length > 0) ? 'true' : 'false';
                        mark.style.backgroundColor = highlightData.color;
                        range.surroundContents(mark);
                    } catch (e) {}
                }
            };

            window.applyStoredHighlights = function(highlights) {
                if (window.clearIOSInterlinear) window.clearIOSInterlinear();
                window.ensureSentencesSegmented();
                document.querySelectorAll('mark.reader-highlight').forEach(el => {
                    const parent = el.parentNode;
                    while (el.firstChild) parent.insertBefore(el.firstChild, el);
                    parent.removeChild(el);
                    parent.normalize();
                });
                const paragraphs = window.getParagraphs();
                highlights.forEach(h => {
                    const p = paragraphs[h.paragraphIndex];
                    if (p) window.wrapTextRange(p, h.startOffset, h.endOffset, h);
                });
                if (window.reapplyIOSInterlinearIfNeeded) window.reapplyIOSInterlinearIfNeeded();
            };

            window.getSelectionInfo = function(selection) {
                if (!selection || selection.rangeCount === 0) return null;
                const range = selection.getRangeAt(0);
                const text = selection.toString().trim();
                if (!text) return null;
                const paragraphs = window.getParagraphs();
                let targetP = range.commonAncestorContainer;
                if (targetP.nodeType === 3) targetP = targetP.parentNode;
                const pEl = targetP.closest(PARAGRAPH_SELECTOR);
                if (!pEl) return null;
                const pIndex = paragraphs.indexOf(pEl);
                if (pIndex === -1) return null;
                const preRange = range.cloneRange();
                preRange.selectNodeContents(pEl);
                preRange.setEnd(range.startContainer, range.startOffset);
                const startOffset = preRange.toString().length;
                const rect = range.getBoundingClientRect();
                return {
                    paragraphIndex: pIndex,
                    startOffset: startOffset,
                    endOffset: startOffset + range.toString().length,
                    text: text,
                    rect: rect ? { x: rect.left, y: rect.top, width: rect.width, height: rect.height } : null
                };
            };

            // Scroll Sync (Mac AppKit trackpad / wheel driven without feedback loops)
            window.__macUserInputUntil = 0;
            window.__macIgnoreScroll = false;
            const markUserScroll = () => { window.__macUserInputUntil = performance.now() + 350; };
            window.addEventListener('wheel', markUserScroll, { passive: true });
            window.addEventListener('mousedown', markUserScroll, { passive: true });
            window.addEventListener('keydown', markUserScroll, { passive: true });

            window.macSetScrollProgress = function(progress) {
                if (performance.now() < window.__macUserInputUntil) return;
                const maxScroll = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
                if (maxScroll <= 1) return;
                const targetY = Math.round(Math.min(1, Math.max(0, progress)) * maxScroll);
                if (Math.abs(window.scrollY - targetY) < 1.5) return;
                window.__macIgnoreScroll = true;
                window.scrollTo({ top: targetY, behavior: 'instant' });
                requestAnimationFrame(() => { window.__macIgnoreScroll = false; });
            };

            window.addEventListener('scroll', () => {
                if (window.__macIgnoreScroll) return;
                if (performance.now() > window.__macUserInputUntil) return;
                const maxScroll = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
                if (maxScroll <= 1) return;
                const progress = Math.min(1, Math.max(0, window.scrollY / maxScroll));
                window.webkit.messageHandlers.macListener.postMessage(JSON.stringify({
                    type: 'scrollProgress',
                    progress: progress
                }));
            }, { passive: true });

            document.addEventListener('mouseup', (e) => {
                setTimeout(() => {
                    if (e.target && typeof e.target.closest === 'function' && e.target.closest('.voca-lookup-panel, a, button')) {
                        return;
                    }
                    const sel = window.getSelection();
                    const txt = sel ? sel.toString().trim() : '';
                    const clickedMark = e.target && typeof e.target.closest === 'function' ? e.target.closest('mark.reader-highlight') : null;

                    if (clickedMark && txt.length < 2) {
                        const hlId = clickedMark.dataset.highlightId;
                        if (hlId) {
                            const rect = clickedMark.getBoundingClientRect();
                            window.webkit.messageHandlers.macListener.postMessage(JSON.stringify({
                                type: 'highlightClicked',
                                id: hlId,
                                rect: { x: rect.left, y: rect.top, width: rect.width, height: rect.height }
                            }));
                            if (sel) sel.removeAllRanges();
                            return;
                        }
                    }

                    if (txt.length >= 2) {
                        const info = window.getSelectionInfo(sel);
                        if (info) {
                            window.webkit.messageHandlers.macListener.postMessage(JSON.stringify({
                                type: 'textSelected',
                                selectionInfo: info
                            }));
                        }
                        return;
                    }

                    window.ensureSentencesSegmented();
                    let sentenceNode = null;
                    if (txt.length > 0 && sel && sel.anchorNode && sel.anchorNode.parentElement) {
                        sentenceNode = sel.anchorNode.parentElement.closest('.sentence-node');
                    } else if (e.target && typeof e.target.closest === 'function') {
                        sentenceNode = e.target.closest('.sentence-node');
                    }

                    if (sentenceNode && sentenceNode.dataset.sentenceId) {
                        window.webkit.messageHandlers.macListener.postMessage(JSON.stringify({
                            type: 'sentenceClicked',
                            sentenceId: sentenceNode.dataset.sentenceId
                        }));
                    } else {
                        window.webkit.messageHandlers.macListener.postMessage(JSON.stringify({ type: 'clearSelection' }));
                    }
                }, 25);
            });

            document.addEventListener('click', (e) => {
                const panel = document.querySelector('.voca-lookup-panel');
                if (panel && !panel.contains(e.target)) {
                    window.removeIOSVocaPanel && window.removeIOSVocaPanel();
                    window.webkit.messageHandlers.macListener.postMessage(JSON.stringify({ type: 'vocaDismiss' }));
                }
            });

            // Interlinear & Voca Popup compatibility
            window.__iosInterlinearPayload = null;
            window.clearIOSInterlinear = function() {
                document.querySelectorAll('.bilingual-subline').forEach(el => el.remove());
            };
            window.applyIOSInterlinear = function(payload) {
                window.clearIOSInterlinear();
                if (!payload || !payload.enabled || !payload.oppositeHtml) {
                    window.__iosInterlinearPayload = null;
                    return;
                }
                window.__iosInterlinearPayload = payload;
                const parser = new DOMParser();
                const oppDoc = parser.parseFromString(payload.oppositeHtml, 'text/html');
                const oppContainer = oppDoc.querySelector('article') || oppDoc.querySelector('.prose-page') || oppDoc.body;
                const oppParas = oppContainer ? Array.from(oppContainer.querySelectorAll(PARAGRAPH_SELECTOR)).map(el => (el.textContent || '').trim()) : [];
                const paras = window.getParagraphs();
                const count = Math.min(paras.length, oppParas.length);
                for (let i = 0; i < count; i++) {
                    const p = paras[i];
                    const oppText = oppParas[i];
                    if (!oppText || p.closest('.bilingual-subline')) continue;
                    const sub = document.createElement('span');
                    sub.className = 'bilingual-subline';
                    sub.setAttribute('data-subtext', oppText);
                    p.parentNode.insertBefore(sub, p.nextSibling);
                }
            };
            requestAnimationFrame(() => {
                try { window.ensureSentencesSegmented(); } catch (e) {}
            });
            window.reapplyIOSInterlinearIfNeeded = function() {
                if (window.__iosInterlinearPayload && window.__iosInterlinearPayload.enabled) {
                    window.applyIOSInterlinear(window.__iosInterlinearPayload);
                }
            };

            window.removeIOSVocaPanel = function() {
                const el = document.querySelector('.voca-lookup-panel');
                if (el) el.remove();
            };

            window.getPageTextForAI = function() {
                const cloned = (document.querySelector('.prose-page') || document.body).cloneNode(true);
                cloned.querySelectorAll('.bilingual-subline, .voca-lookup-panel, script, style').forEach(el => el.remove());
                return (cloned.innerText || cloned.textContent || '').replace(/\\s+/g, ' ').trim();
            };

            window.showIOSVocaPanel = function(payload) {
                window.removeIOSVocaPanel();
                const el = document.createElement('div');
                el.className = 'voca-lookup-panel';
                if (payload.mode === 'single' && payload.card) {
                    const card = payload.card;
                    const head = document.createElement('div');
                    head.className = 'voca-lookup-panel__head';
                    const w = document.createElement('div');
                    w.className = 'voca-lookup-panel__word';
                    w.textContent = card.word || '';
                    head.appendChild(w);
                    if (card.slug) {
                        const btn = document.createElement('button');
                        btn.className = 'voca-lookup-panel__voice';
                        btn.textContent = '🔊';
                        btn.onclick = (e) => {
                            e.stopPropagation();
                            window.webkit.messageHandlers.macListener.postMessage(JSON.stringify({ type: 'vocaPlayAudio', slug: card.slug }));
                        };
                        head.appendChild(btn);
                    }
                    el.appendChild(head);
                    if (card.ipa) {
                        const ipa = document.createElement('div');
                        ipa.className = 'voca-lookup-panel__ipa';
                        ipa.textContent = card.ipa;
                        el.appendChild(ipa);
                    }
                    const meaning = document.createElement('div');
                    meaning.className = 'voca-lookup-panel__meaning';
                    meaning.textContent = card.meaning || '';
                    el.appendChild(meaning);
                } else if (payload.mode === 'multi' && payload.cards) {
                    el.classList.add('voca-lookup-panel--multi');
                    const hint = document.createElement('div');
                    hint.className = 'voca-lookup-panel__word';
                    hint.textContent = 'Chọn từ phù hợp';
                    el.appendChild(hint);
                    const list = document.createElement('div');
                    list.className = 'voca-lookup-panel__list';
                    payload.cards.forEach(card => {
                        const item = document.createElement('button');
                        item.className = 'voca-lookup-panel__item';
                        const w = document.createElement('span');
                        w.className = 'voca-lookup-panel__item-word';
                        w.textContent = card.word || '';
                        const m = document.createElement('span');
                        m.className = 'voca-lookup-panel__item-meaning';
                        m.textContent = card.meaning || '';
                        item.appendChild(w);
                        item.appendChild(m);
                        item.onclick = (e) => {
                            e.stopPropagation();
                            window.webkit.messageHandlers.macListener.postMessage(JSON.stringify({ type: 'vocaSelectCard', card }));
                        };
                        list.appendChild(item);
                    });
                    el.appendChild(list);
                } else {
                    const w = document.createElement('div');
                    w.className = 'voca-lookup-panel__word';
                    w.textContent = payload.query || '';
                    const hint = document.createElement('div');
                    hint.className = 'voca-lookup-panel__hint';
                    hint.textContent = 'Từ chưa có trong Voca.';
                    const addBtn = document.createElement('button');
                    addBtn.className = 'voca-lookup-panel__create';
                    addBtn.textContent = '+ Thêm vào Voca';
                    addBtn.onclick = (e) => {
                        e.stopPropagation();
                        window.webkit.messageHandlers.macListener.postMessage(JSON.stringify({ type: 'vocaAddWord', word: payload.query || '' }));
                    };
                    el.appendChild(w);
                    el.appendChild(hint);
                    el.appendChild(addBtn);
                }
                const rect = payload.rect || { x: 40, y: 40, width: 80, height: 24 };
                el.style.left = Math.min(window.innerWidth - 330, Math.max(16, rect.x)) + 'px';
                el.style.top = Math.min(window.innerHeight - 180, Math.max(16, rect.y + rect.height + 10)) + 'px';
                document.body.appendChild(el);
            };
        })();
        """

        contentController.addUserScript(WKUserScript(source: baseStyleSource, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        contentController.addUserScript(WKUserScript(source: bridgeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        config.userContentController = contentController
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleScrollSync(_:)),
            name: NSNotification.Name("MacScrollToOffset_\(scrollSyncScope)_\(lang)"),
            object: nil
        )

        DispatchQueue.main.async {
            onWebViewReady?(webView, lang, page)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.webView = webView

        let appearanceKey = "\(effectiveFontId)|\(effectiveThemeId)|\(viewMode)"
        if context.coordinator.lastAppearanceKey != appearanceKey && context.coordinator.loadedTarget != nil {
            context.coordinator.lastAppearanceKey = appearanceKey
            context.coordinator.applyAppearance(in: webView)
        }

        let target: String
        let localFileURL = BackupManager.shared.localPageURL(slug: bookSlug, lang: lang, page: page)
        if let localFileURL {
            target = localFileURL.absoluteString
        } else {
            target = urlString
        }

        if context.coordinator.loadedTarget != target {
            context.coordinator.loadedTarget = target
            context.coordinator.lastAppliedSentenceId = nil
            context.coordinator.lastAppliedHighlights = []
            if let localFileURL {
                let outputDir = BackupManager.shared.localOutputDir(slug: bookSlug)
                webView.loadFileURL(localFileURL, allowingReadAccessTo: outputDir)
            } else if let url = URL(string: urlString) {
                context.coordinator.loadRemotePage(
                    url,
                    target: target,
                    token: api.token,
                    serverURL: URL(string: api.normalizedServerUrl),
                    in: webView
                )
            }
        } else {
            context.coordinator.syncHighlightsIfNeeded(in: webView)
            if activeSentenceId != context.coordinator.lastAppliedSentenceId {
                context.coordinator.applySentenceHighlight(in: webView)
            }
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "macListener")
        coordinator.parent.onWebViewDismantled?(nsView, coordinator.parent.lang, coordinator.parent.page)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: BilingualWebViewMac
        weak var webView: WKWebView?
        var loadedTarget: String?
        var lastAppearanceKey: String = ""
        var lastAppliedHighlights: [Highlight] = []
        var lastAppliedSentenceId: String? = nil
        private var installedCookieToken: String?
        private var cookieInstallToken: String?
        private static var oppositeCache: [String: String] = [:]

        init(_ parent: BilingualWebViewMac) {
            self.parent = parent
        }

        func loadRemotePage(
            _ url: URL,
            target: String,
            token: String,
            serverURL: URL?,
            in webView: WKWebView
        ) {
            let loadIfCurrent = { [weak self, weak webView] in
                guard let self,
                      let webView,
                      self.loadedTarget == target else {
                    return
                }
                var request = URLRequest(url: url)
                request.cachePolicy = .returnCacheDataElseLoad
                request.timeoutInterval = 20
                if !token.isEmpty {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                webView.load(request)
            }

            // The main HTML request already carries the Bearer token, so start it
            // immediately instead of leaving the reader blank while WebKit commits
            // the cookie asynchronously. The cookie is installed in parallel for
            // CSS, images, fonts and other protected subresources.
            loadIfCurrent()

            guard !token.isEmpty,
                  installedCookieToken != token,
                  let serverURL,
                  let host = serverURL.host else {
                return
            }

            guard cookieInstallToken != token else {
                return
            }
            cookieInstallToken = token

            let properties: [HTTPCookiePropertyKey: Any] = [
                .domain: host,
                .path: "/",
                .name: "jwt_token",
                .value: token,
                .secure: serverURL.scheme == "https" ? "TRUE" : "FALSE",
                .expires: Date(timeIntervalSinceNow: 86400 * 30),
            ]
            guard let cookie = HTTPCookie(properties: properties) else {
                cookieInstallToken = nil
                return
            }

            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak self] in
                guard let self else { return }
                self.installedCookieToken = token
                self.cookieInstallToken = nil
            }
        }

        func syncHighlightsIfNeeded(in webView: WKWebView, force: Bool = false) {
            let pageHighlights = parent.highlights.filter { $0.page == parent.page && $0.lang == parent.lang }
            guard force || pageHighlights != lastAppliedHighlights else { return }
            lastAppliedHighlights = pageHighlights
            if let data = try? JSONEncoder().encode(pageHighlights),
               let json = String(data: data, encoding: .utf8) {
                webView.evaluateJavaScript("window.applyStoredHighlights && window.applyStoredHighlights(\(json));", completionHandler: nil)
            }
        }

        func applySentenceHighlight(in webView: WKWebView) {
            lastAppliedSentenceId = parent.activeSentenceId
            let encodedId = String(
                data: (try? JSONSerialization.data(withJSONObject: [parent.activeSentenceId ?? ""])) ?? Data("[\"\"]".utf8),
                encoding: .utf8
            ) ?? "[\"\"]"
            let scrollFlag = parent.scrollActiveSentenceIntoView ? "true" : "false"
            webView.evaluateJavaScript("if (window.highlightSentence) { window.highlightSentence(\(encodedId)[0], \(scrollFlag)); }", completionHandler: nil)
        }

        @objc func handleScrollSync(_ notification: Notification) {
            guard parent.containerMode == "split", parent.viewMode == "split",
                  let info = notification.userInfo,
                  let progress = info["progress"] as? Double,
                  let nPage = info["page"] as? Int, nPage == parent.page,
                  let nSlug = info["bookSlug"] as? String, nSlug == parent.bookSlug,
                  let webView else {
                return
            }
            webView.evaluateJavaScript("window.macSetScrollProgress && window.macSetScrollProgress(\(progress));", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            parent.onWebViewReady?(webView, parent.lang, parent.page)
            lastAppearanceKey = "\(parent.effectiveFontId)|\(parent.effectiveThemeId)|\(parent.viewMode)"
            applyAppearance(in: webView)

            webView.evaluateJavaScript("window.ensureSentencesSegmented && window.ensureSentencesSegmented();", completionHandler: nil)
            syncHighlightsIfNeeded(in: webView, force: true)
            applySentenceHighlight(in: webView)
            parent.onPageDidFinish?(webView, parent.lang, parent.page)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.targetFrame?.isMainFrame != false,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.isFileURL || url.absoluteString.contains("/books/\(parent.bookSlug)/") {
                decisionHandler(.allow)
                return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }

        func applyAppearance(in webView: WKWebView) {
            let desc = ReaderAppearance.parseThemeDescriptor(parent.effectiveThemeId)
            let js = ReaderAppearance.buildApplyAppearanceJS(
                fontId: parent.effectiveFontId,
                themeId: parent.effectiveThemeId,
                viewMode: parent.viewMode
            )
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self else { return }
                if let dict = result as? [String: Any],
                   let rgba = dict["rgba"] as? [NSNumber], rgba.count == 4 {
                    let bgColor = NSColor(
                        srgbRed: CGFloat(truncating: rgba[0]) / 255,
                        green: CGFloat(truncating: rgba[1]) / 255,
                        blue: CGFloat(truncating: rgba[2]) / 255,
                        alpha: CGFloat(truncating: rgba[3])
                    )
                    DispatchQueue.main.async {
                        webView.underPageBackgroundColor = bgColor
                    }
                }
                self.syncInterlinear(in: webView, enabled: desc.interlinear)
            }
        }

        private func syncInterlinear(in webView: WKWebView, enabled: Bool) {
            if !enabled {
                webView.evaluateJavaScript("window.clearIOSInterlinear && window.clearIOSInterlinear();", completionHandler: nil)
                return
            }
            let oppLang = parent.lang == "en" ? "vi" : "en"
            let slug = parent.bookSlug
            let page = parent.page
            let cacheKey = "\(slug):\(page):\(oppLang)"

            if let cached = Self.oppositeCache[cacheKey] {
                sendInterlinearPayload(webView: webView, oppositeHtml: cached)
                return
            }
            if let localURL = BackupManager.shared.localPageURL(slug: slug, lang: oppLang, page: page),
               let html = try? String(contentsOf: localURL, encoding: .utf8), !html.isEmpty {
                Self.oppositeCache[cacheKey] = html
                sendInterlinearPayload(webView: webView, oppositeHtml: html)
                return
            }
            let pageStr = String(format: "%04d", page)
            guard let url = URL(string: "\(parent.api.normalizedServerUrl)/books/\(slug)/output/\(oppLang)/page_\(pageStr).html") else { return }
            var req = URLRequest(url: url)
            if !parent.api.token.isEmpty {
                req.setValue("Bearer \(parent.api.token)", forHTTPHeaderField: "Authorization")
            }
            URLSession.shared.dataTask(with: req) { data, response, _ in
                guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                      let html = String(data: data, encoding: .utf8), !html.isEmpty else { return }
                Self.oppositeCache[cacheKey] = html
                DispatchQueue.main.async {
                    self.sendInterlinearPayload(webView: webView, oppositeHtml: html)
                }
            }.resume()
        }

        private func sendInterlinearPayload(webView: WKWebView, oppositeHtml: String) {
            let payload: [String: Any] = ["enabled": true, "oppositeHtml": oppositeHtml]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.applyIOSInterlinear && window.applyIOSInterlinear(\(json));", completionHandler: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let str = message.body as? String,
                  let data = str.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch type {
                case "scrollProgress":
                    if let progress = json["progress"] as? Double {
                        let otherLang = self.parent.lang == "en" ? "vi" : "en"
                        NotificationCenter.default.post(
                            name: NSNotification.Name("MacScrollToOffset_\(self.parent.scrollSyncScope)_\(otherLang)"),
                            object: nil,
                            userInfo: [
                                "progress": progress,
                                "page": self.parent.page,
                                "bookSlug": self.parent.bookSlug,
                            ]
                        )
                    }
                case "textSelected":
                    if let infoDict = json["selectionInfo"] as? [String: Any],
                       let pIdx = infoDict["paragraphIndex"] as? Int,
                       let start = infoDict["startOffset"] as? Int,
                       let end = infoDict["endOffset"] as? Int,
                       let text = infoDict["text"] as? String {
                        let info = SelectionInfo(
                            paragraphIndex: pIdx,
                            startOffset: start,
                            endOffset: end,
                            text: text,
                            rect: selectionRect(from: infoDict["rect"] as? [String: Any])
                        )
                        self.parent.onHighlightMessage(.textSelected(selectionInfo: info))
                    }
                case "highlightClicked":
                    if let id = json["id"] as? String {
                        self.parent.onHighlightMessage(.highlightClicked(id: id, rect: selectionRect(from: json["rect"] as? [String: Any])))
                    }
                case "sentenceClicked":
                    if let sentenceId = json["sentenceId"] as? String, !sentenceId.isEmpty {
                        self.parent.onSentenceClicked?(sentenceId)
                    }
                case "clearSelection":
                    self.parent.onHighlightMessage(.clearSelection)
                    self.parent.onSentenceClicked?(nil)
                case "vocaAddWord":
                    if let word = json["word"] as? String {
                        self.parent.onVocaAction(.addWord(word))
                    }
                case "vocaPlayAudio":
                    if let slug = json["slug"] as? String {
                        self.parent.onVocaAction(.playAudio(slug: slug))
                    }
                case "vocaSelectCard":
                    if let cardDict = json["card"] as? [String: Any],
                       let card = VocaCard.fromWebPayload(cardDict) {
                        self.parent.onVocaAction(.selectCard(card))
                    }
                case "vocaDismiss":
                    self.parent.onVocaAction(.dismiss)
                default:
                    break
                }
            }
        }
    }
}

extension WKWebView {
    func evaluateShowVocaPanel(json: String) {
        evaluateJavaScript("window.showIOSVocaPanel && window.showIOSVocaPanel(\(json));", completionHandler: nil)
    }

    func evaluateDismissVocaPanel() {
        evaluateJavaScript("window.removeIOSVocaPanel && window.removeIOSVocaPanel();", completionHandler: nil)
    }

    func evaluateScrollAndPulseHighlight(id: String) {
        let encoded = String(
            data: (try? JSONSerialization.data(withJSONObject: [id])) ?? Data("[\"\"]".utf8),
            encoding: .utf8
        ) ?? "[\"\"]"
        evaluateJavaScript(
            "window.scrollToAndPulseHighlight && window.scrollToAndPulseHighlight(\(encoded)[0]);",
            completionHandler: nil
        )
    }
}

