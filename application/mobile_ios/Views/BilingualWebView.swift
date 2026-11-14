import SwiftUI
import WebKit
import PencilKit

class BilingualCanvasView: PKCanvasView {
    private let localUndoManager = UndoManager()
    
    override var undoManager: UndoManager? {
        return localUndoManager
    }
    
    override var canBecomeFirstResponder: Bool {
        return true
    }
    
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(undo(_:)) {
            return localUndoManager.canUndo
        }
        if action == #selector(redo(_:)) {
            return localUndoManager.canRedo
        }
        return super.canPerformAction(action, withSender: sender)
    }
    
    @objc func undo(_ sender: Any?) {
        if localUndoManager.canUndo {
            localUndoManager.undo()
        }
    }
    
    @objc func redo(_ sender: Any?) {
        if localUndoManager.canRedo {
            localUndoManager.redo()
        }
    }
}

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
    case toggleFullScreen
}

enum VocaWebAction {
    case addWord(String)
    /// Audio is keyed by the card slug, never the numeric Voca id.
    case playAudio(slug: String)
    case selectCard(VocaCard)
    case dismiss
}

private func selectionRect(from dict: [String: Any]?) -> CGRect? {
    guard let dict else { return nil }
    func number(_ key: String) -> CGFloat? {
        if let value = dict[key] as? CGFloat { return value }
        if let value = dict[key] as? Double { return CGFloat(value) }
        if let value = dict[key] as? Int { return CGFloat(value) }
        if let value = dict[key] as? NSNumber { return CGFloat(value.doubleValue) }
        return nil
    }
    guard let x = number("x"), let y = number("y"), let width = number("width"), let height = number("height") else {
        return nil
    }
    return CGRect(x: x, y: y, width: width, height: height)
}

class NoSelectionMenuWebView: WKWebView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        return false
    }
}

struct BilingualWebView: UIViewRepresentable {
    // Share a single WKProcessPool across all WebViews for better performance
    private static let sharedProcessPool = WKProcessPool()
    
    let bookSlug: String
    let urlString: String
    let lang: String
    let page: Int
    let viewMode: String
    let activeSentenceId: String?
    let isPencilModeActive: Bool
    // Extra top padding on iPhone so full-screen mode clears the notch /
    // Dynamic Island. Applied via CSS variable `--bkb-top-inset` so fullscreen
    // toggling never alters typography rules.
    var topOverlayInset: CGFloat = 0
    var effectiveFontId: String = "default"
    var effectiveThemeId: String = "default"
    @ObservedObject var api = APIService.shared
    let onScroll: (CGFloat) -> Void
    let onHighlightMessage: (HighlightMessage) -> Void
    let onSentenceClicked: (String?) -> Void
    let onVocaAction: (VocaWebAction) -> Void
    var onOpenExternalURL: ((URL) -> Void)? = nil
    var onWebViewReady: ((WKWebView, String, Int) -> Void)? = nil
    var onWebViewDismantled: ((WKWebView, String, Int) -> Void)? = nil
    var onAppearanceMeasured: ((ReaderA4Status) -> Void)? = nil

    func makeUIView(context: Context) -> WKWebView {
        let preferences = WKPreferences()
        
        let configuration = WKWebViewConfiguration()
        configuration.preferences = preferences
        configuration.processPool = Self.sharedProcessPool
        
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "iosListener")
        
        let isEnglish = lang == "en"
        let highlightColor = isEnglish ? "rgba(56, 189, 248, 0.22)" : "rgba(250, 204, 21, 0.24)"
        let hoverColor = isEnglish ? "rgba(56, 189, 248, 0.08)" : "rgba(250, 204, 21, 0.08)"
        
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone
        let paddingCss: String
        if isPhone {
            // Extra bottom padding keeps the last lines clear of the home
            // indicator; top uses `--bkb-top-inset` for Dynamic Island / notch.
            let baseTop = viewMode == "split" ? 12 : 18
            let hPad = viewMode == "split" ? 14 : 16
            let bottom = viewMode == "split" ? 28 : 36
            paddingCss = "padding: calc(\(baseTop)px + var(--bkb-top-inset, \(Int(topOverlayInset))px)) \(hPad)px \(bottom)px !important;"
        } else {
            paddingCss = viewMode == "split" ? "padding: 16px 20px !important;" : "padding: 24px 32px !important;"
        }
        // Title pages draw their decorative frame at absolute mm coordinates
        // sized for a 210mm sheet (the title CONTENT is nested inside that
        // frame, so it must never be display:none'd) — restyle it into a
        // static, centered cover frame on phone instead.
        let phoneCss = isPhone ? """
                        p, li, blockquote, .prose-page, .sheet-flow {
                            -webkit-hyphens: auto;
                            hyphens: auto;
                        }
                        .title-page-container {
                            height: auto !important;
                        }
                        .title-page-border {
                            position: static !important;
                            width: auto !important;
                            height: auto !important;
                            min-height: 70vh !important;
                            margin: 24px 8px !important;
                            padding: 32px 16px !important;
                            border-width: 1px !important;
                            display: flex !important;
                            align-items: center !important;
                            justify-content: center !important;
                        }
                        .title-book {
                            font-size: 24pt !important;
                        }
        """ : ""

        // Force consistent viewport across ALL books on both iPhone and iPad.
        // Older-generation book pages omit <meta name="viewport">, causing
        // WKWebView to lay them out at 980px and shrink text to 22-49% scale.
        // Also disable user pinch/double-tap browser zoom so fullscreen toggle
        // never triggers native WebKit zoom rescaling.
        let viewportJs = """
            const forceViewport = () => {
                if (!document.head) { return; }
                const metas = Array.from(document.querySelectorAll('meta[name="viewport"]'));
                let vp = metas[0];
                for (let i = 1; i < metas.length; i++) {
                    metas[i].remove();
                }
                if (!vp) {
                    vp = document.createElement('meta');
                    vp.setAttribute('name', 'viewport');
                    document.head.appendChild(vp);
                }
                const targetContent = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no';
                if (vp.getAttribute('content') !== targetContent) {
                    vp.setAttribute('content', targetContent);
                }
            };
            forceViewport();
            document.documentElement.style.setProperty('--bkb-top-inset', '\(Int(topOverlayInset))px');
        """

        // 1. Inject reader behavior and responsive geometry at document start.
        let cssStyleSource = """
        (function() {
            \(viewportJs)

            const injectStyle = () => {
                const STYLE_ID = 'reader-highlight-style';
                if (!document.getElementById(STYLE_ID)) {
                    const style = document.createElement('style');
                    style.id = STYLE_ID;
                    style.innerHTML = `
                        .sentence-node {
                            transition: background-color 0.2s ease;
                            border-radius: 3px;
                            cursor: pointer;
                            display: inline;
                        }
                        .sentence-node:hover {
                            background-color: \(hoverColor);
                        }
                        .sentence-node.highlight-sync {
                            background-color: \(highlightColor) !important;
                        }
                        .page-nav {
                            display: none !important;
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
                            -webkit-text-size-adjust: none !important;
                            touch-action: manipulation;
                        }
                        body, body.book-standalone {
                            margin: 0 !important;
                            \(paddingCss)
                            width: 100% !important;
                            max-width: 100% !important;
                            height: auto !important;
                            min-height: 100vh !important;
                            box-sizing: border-box !important;
                            display: block !important;
                            overflow-x: hidden !important;
                            overflow-y: auto !important;
                            touch-action: manipulation;
                        }
                        main, article, .prose-page {
                            margin: 0 !important;
                            padding: 0 !important;
                            width: 100% !important;
                            max-width: 100% !important;
                            box-sizing: border-box !important;
                            background: transparent !important;
                            background-color: transparent !important;
                        }
                        .book-page, .book-page--sheet, .sheet-flow {
                            margin: 0 auto !important;
                            padding: 0 !important;
                            width: 100% !important;
                            max-width: 100% !important;
                            height: auto !important;
                            min-height: 0 !important;
                            max-height: none !important;
                            box-sizing: border-box !important;
                            overflow: visible !important;
                            background: transparent !important;
                            background-color: transparent !important;
                            box-shadow: none !important;
                        }
                        .book-page--sheet::after {
                            display: none !important;
                            content: none !important;
                        }
                        * {
                            box-sizing: border-box !important;
                            max-width: 100% !important;
                            word-wrap: break-word !important;
                        }
        \(phoneCss)
                        mark.reader-highlight {
                            border-radius: 3px;
                            padding: 0 1px;
                            cursor: pointer;
                            position: relative;
                            color: inherit;
                            box-decoration-break: clone;
                            -webkit-box-decoration-break: clone;
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
                        .prose-page p, .prose-page li, .prose-page blockquote,
                        .prose-page .section-title, .prose-page .action-header, .prose-page .action-title,
                        .prose-page h1, .prose-page h2, .prose-page h3, .prose-page h4, .prose-page h5, .prose-page h6,
                        .sentence-node {
                            -webkit-user-select: text;
                            user-select: text;
                        }
                        .voca-lookup-panel {
                            position: fixed;
                            z-index: 10000;
                            min-width: 200px;
                            max-width: min(280px, calc(100vw - 24px)) !important;
                            padding: 10px 12px;
                            border-radius: 10px;
                            background-color: #ffffff !important;
                            border: 1px solid rgba(15, 23, 42, 0.12);
                            box-shadow: 0 10px 30px rgba(15, 23, 42, 0.18);
                            color: #0f172a !important;
                            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                            font-size: 13px;
                            opacity: 1 !important;
                            isolation: isolate;
                        }
                        .voca-lookup-panel--multi { max-width: min(320px, calc(100vw - 24px)) !important; }
                        .voca-lookup-panel__head {
                            display: flex; align-items: center; justify-content: space-between; gap: 8px;
                            background-color: transparent !important;
                        }
                        .voca-lookup-panel__word {
                            font-weight: 700; font-size: 14px;
                            color: #0f172a !important;
                            background-color: transparent !important;
                        }
                        .voca-lookup-panel__hint {
                            margin-top: 4px; color: #64748b !important; font-size: 12px; line-height: 1.4;
                            background-color: transparent !important;
                        }
                        .voca-lookup-panel__create {
                            margin-top: 10px; width: 100%;
                            border: 0; border-radius: 8px; padding: 8px 12px;
                            background-color: #2563eb !important;
                            color: #ffffff !important;
                            font-family: inherit; font-size: 12px; font-weight: 700;
                            cursor: pointer;
                        }
                        .voca-lookup-panel__voice {
                            border: 0; background-color: #e0f2fe !important; border-radius: 6px; width: 28px; height: 28px;
                            cursor: pointer; font-size: 14px; line-height: 1;
                        }
                        .voca-lookup-panel__ipa {
                            margin-top: 4px; color: #475569 !important; font-size: 12px;
                            background-color: transparent !important;
                        }
                        .voca-lookup-panel__meaning {
                            margin-top: 6px; color: #1e293b !important; line-height: 1.45;
                            background-color: transparent !important;
                        }
                        .voca-lookup-panel__list {
                            margin-top: 8px; display: flex; flex-direction: column; gap: 6px;
                            max-height: 220px; overflow-y: auto;
                            background-color: transparent !important;
                        }
                        .voca-lookup-panel__item {
                            width: 100%; text-align: left; border: 1px solid rgba(15, 23, 42, 0.1);
                            border-radius: 8px; padding: 8px 10px;
                            background-color: #f8fafc !important;
                            cursor: pointer; font-family: inherit; color: inherit;
                            display: flex; flex-direction: column; gap: 2px;
                        }
                        .voca-lookup-panel__item-word {
                            font-weight: 700; font-size: 12px; line-height: 1.35;
                            color: #0f172a !important;
                            background-color: transparent !important;
                        }
                        .voca-lookup-panel__item-meaning {
                            font-size: 11px; color: #475569 !important; line-height: 1.35;
                            background-color: transparent !important;
                        }
                    `;
                    if (document.head) {
                        document.head.appendChild(style);
                    } else {
                        document.documentElement.appendChild(style);
                    }
                }
            };
            
            injectStyle();
            
            const observer = new MutationObserver((mutations, obs) => {
                if (document.head) {
                    forceViewport();
                    injectStyle();
                }
                if (document.body) {
                    forceViewport();
                    injectStyle();
                    obs.disconnect();
                }
            });
            observer.observe(document.documentElement, { childList: true, subtree: true });
        })();
        """
        let cssUserScript = WKUserScript(source: cssStyleSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        contentController.addUserScript(cssUserScript)
        
        // 2. Inject highlighting core JS logic at .atDocumentEnd (needs DOM elements)
        let jsSource = """
        const PARAGRAPH_SELECTOR = 'p, .chapter-start, .no-indent, h1, h2, h3, h4, h5, h6, li, blockquote, .section-title, .action-header, .action-title';

        window.getParagraphs = function() {
            const article = document.querySelector('article') || document.body;
            return Array.from(article.querySelectorAll(PARAGRAPH_SELECTOR));
        };

        window.wrapTextRange = function(paragraph, startOffset, endOffset, highlightData) {
            const doc = document;
            const walker = doc.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
            let charCount = 0;
            let startNode = null;
            let startNodeOffset = 0;
            let endNode = null;
            let endNodeOffset = 0;

            while (walker.nextNode()) {
                const node = walker.currentNode;
                const nodeLen = node.textContent.length;
                if (startNode === null && charCount + nodeLen > startOffset) {
                    startNode = node;
                    startNodeOffset = startOffset - charCount;
                }
                if (endNode === null && charCount + nodeLen >= endOffset) {
                    endNode = node;
                    endNodeOffset = endOffset - charCount;
                    break;
                }
                charCount += nodeLen;
            }

            if (!startNode || !endNode) return false;

            const range = doc.createRange();
            range.setStart(startNode, startNodeOffset);
            range.setEnd(endNode, endNodeOffset);

            const mark = doc.createElement('mark');
            mark.className = 'reader-highlight';
            mark.dataset.highlightId = highlightData.id;
            mark.style.backgroundColor = highlightData.color;
            if (highlightData.note) {
                mark.dataset.hasNote = 'true';
                mark.title = highlightData.note;
            }

            try {
                range.surroundContents(mark);
            } catch (e) {
                const contents = range.extractContents();
                mark.appendChild(contents);
                range.insertNode(mark);
            }
            return true;
        };

        window.applyStoredHighlights = function(highlights) {
            if (window.clearIOSInterlinear) {
                window.clearIOSInterlinear();
            }
            // Remove existing highlights first
            document.querySelectorAll('mark.reader-highlight').forEach(el => {
                const parent = el.parentNode;
                while (el.firstChild) parent.insertBefore(el.firstChild, el);
                parent.removeChild(el);
            });
            
            const paragraphs = window.getParagraphs();
            highlights.forEach(h => {
                const paragraph = paragraphs[h.paragraphIndex];
                if (!paragraph) return;
                window.wrapTextRange(paragraph, h.startOffset, h.endOffset, h);
            });
            if (window.reapplyIOSInterlinearIfNeeded) {
                window.reapplyIOSInterlinearIfNeeded();
            }
        };

        window.getSelectionInfo = function(selection) {
            if (!selection || selection.isCollapsed) return null;
            const text = selection.toString().trim();
            if (!text) return null;

            const range = selection.getRangeAt(0);
            let container = range.commonAncestorContainer;
            if (container.nodeType === 3) container = container.parentElement;
            const paragraph = container.closest(PARAGRAPH_SELECTOR);
            if (!paragraph) return null;

            const paragraphs = window.getParagraphs();
            const paragraphIndex = paragraphs.indexOf(paragraph);
            if (paragraphIndex === -1) return null;

            const preRange = document.createRange();
            preRange.selectNodeContents(paragraph);
            preRange.setEnd(range.startContainer, range.startOffset);
            const startOffset = preRange.toString().length;
            const endOffset = startOffset + range.toString().length;
            
            const rect = range.getBoundingClientRect();

            return { paragraphIndex, startOffset, endOffset, text: range.toString(), rect: {x: rect.x, y: rect.y, width: rect.width, height: rect.height} };
        };

        window.highlightSentence = function(sentenceId) {
            document.querySelectorAll('.sentence-node.highlight-sync').forEach(el => {
                el.classList.remove('highlight-sync');
            });
            if (sentenceId) {
                const targetNode = document.querySelector(`.sentence-node[data-sentence-id="${sentenceId}"]`);
                if (targetNode) {
                    targetNode.classList.add('highlight-sync');
                }
            }
        };

        document.addEventListener('mouseup', handleSelectionEnd);
        document.addEventListener('touchend', handleSelectionEnd);

        let lastTapTime = 0;
        let lastToggleTime = 0;
        function triggerFullScreenToggle() {
            const now = Date.now();
            if (now - lastToggleTime < 450) return;
            lastToggleTime = now;
            window.webkit.messageHandlers.iosListener.postMessage(JSON.stringify({
                type: 'toggleFullScreen'
            }));
        }
        function handleDoubleTap(e) {
            if (e.target && typeof e.target.closest === 'function' && e.target.closest('.voca-lookup-panel, a, button')) {
                return;
            }
            const currentTime = Date.now();
            const tapLength = currentTime - lastTapTime;
            if (tapLength < 400 && tapLength > 0) {
                // Double tap detected
                triggerFullScreenToggle();
                // Prevent default to stop zooming
                if (e.cancelable) e.preventDefault();
            }
            lastTapTime = currentTime;
        }

        document.addEventListener('touchstart', function(e) {
            if (e.touches.length === 1) {
                handleDoubleTap(e);
            }
        }, {passive: false});

        document.addEventListener('dblclick', function(e) {
            if (e.target && typeof e.target.closest === 'function' && e.target.closest('.voca-lookup-panel, a, button')) {
                return;
            }
            if (e.cancelable) e.preventDefault();
            triggerFullScreenToggle();
        }, {passive: false});

        function handleSelectionEnd(e) {
            setTimeout(() => {
                if (e.target && typeof e.target.closest === 'function' && e.target.closest('.voca-lookup-panel')) {
                    return;
                }
                const selection = window.getSelection();
                const selectedText = selection.toString().trim();
                const clickedMark = e.target.closest('mark.reader-highlight');

                if (clickedMark) {
                    const highlightId = clickedMark.dataset.highlightId;
                    const rect = clickedMark.getBoundingClientRect();
                    window.webkit.messageHandlers.iosListener.postMessage(JSON.stringify({
                        type: 'highlightClicked',
                        id: highlightId,
                        rect: {x: rect.x, y: rect.y, width: rect.width, height: rect.height}
                    }));
                    selection.removeAllRanges();
                    return;
                }

                if (selectedText.length > 2) {
                    const selectionInfo = window.getSelectionInfo(selection);
                    if (selectionInfo) {
                        window.webkit.messageHandlers.iosListener.postMessage(JSON.stringify({
                            type: 'textSelected',
                            selectionInfo: selectionInfo
                        }));
                    }
                    return;
                }

                // Sentence node tap detection
                let sentenceNode = null;
                if (selectedText.length > 0) {
                    const node = selection.anchorNode;
                    if (node) {
                        sentenceNode = node.parentElement.closest('.sentence-node');
                    }
                } else {
                    sentenceNode = e.target.closest('.sentence-node');
                }

                if (sentenceNode) {
                    const sentenceId = sentenceNode.dataset.sentenceId;
                    window.webkit.messageHandlers.iosListener.postMessage(JSON.stringify({
                        type: 'sentenceClicked',
                        sentenceId: sentenceId
                    }));
                } else {
                    window.webkit.messageHandlers.iosListener.postMessage(JSON.stringify({
                        type: 'clearSelection'
                    }));
                }
            }, 50);
        }

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
            const text = pElement.textContent;
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
            const sentenceSpans = sentences.map((sText, sIdx) => {
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
                    let nodeText = node.textContent;
                    while (nodeText.length > 0 && currentSentenceIdx < sentences.length) {
                        if (nodeText.length <= currentSentenceRemainingLen) {
                            const textNode = pElement.ownerDocument.createTextNode(nodeText);
                            sentenceSpans[currentSentenceIdx].appendChild(textNode);
                            currentSentenceRemainingLen -= nodeText.length;
                            nodeText = '';
                        } else {
                            const part = nodeText.substring(0, currentSentenceRemainingLen);
                            const textNode = pElement.ownerDocument.createTextNode(part);
                            sentenceSpans[currentSentenceIdx].appendChild(textNode);
                            nodeText = nodeText.substring(currentSentenceRemainingLen);
                            currentSentenceIdx++;
                            if (currentSentenceIdx < sentences.length) {
                                currentSentenceRemainingLen = sentences[currentSentenceIdx].length;
                            }
                        }
                    }
                } else if (node.nodeType === 1) {
                    sentenceSpans[currentSentenceIdx].appendChild(node);
                    currentSentenceRemainingLen -= node.textContent.length;
                    if (currentSentenceRemainingLen <= 0 && currentSentenceIdx < sentences.length - 1) {
                        currentSentenceIdx++;
                        currentSentenceRemainingLen = sentences[currentSentenceIdx].length;
                    }
                }
            });
            sentenceSpans.forEach(span => {
                if (span.textContent.length > 0) {
                    pElement.appendChild(span);
                }
            });
        }

        function segmentDocSentences(doc) {
            const article = doc.querySelector('article') || doc.body;
            if (!article) return;
            const paragraphs = article.querySelectorAll(PARAGRAPH_SELECTOR);
            paragraphs.forEach((p, idx) => {
                if (!p.querySelector('.sentence-node')) {
                    segmentParagraph(p, idx);
                }
            });
        }

        let iosVocaDismissHandler = null;

        function stopVocaPanelEvent(e) {
            e.stopPropagation();
        }

        function positionIOSVocaPanel(panel, rect) {
            const margin = 12;
            const gap = 12;
            const x = Number(rect.x) || 0;
            const y = Number(rect.y) || 0;
            const w = Number(rect.width) || 0;
            const h = Number(rect.height) || 0;
            const insetLeft = Number(rect.insetLeft) || margin;
            const insetRight = Number(rect.insetRight) || margin;
            const vw = window.innerWidth;
            const vh = window.innerHeight;

            panel.style.transform = 'none';
            panel.style.visibility = 'hidden';
            panel.style.left = '0px';
            panel.style.top = '0px';
            document.documentElement.appendChild(panel);

            const pw = panel.offsetWidth;
            const ph = panel.offsetHeight;
            const anchorCenterX = x + w / 2;

            let top = y - gap - ph;
            if (top < margin) {
                top = y + h + gap;
            }
            if (top + ph > vh - margin) {
                top = Math.max(margin, vh - margin - ph);
            }

            let left = anchorCenterX - pw / 2;
            const minLeft = insetLeft;
            const maxLeft = Math.max(minLeft, vw - insetRight - pw);
            left = Math.max(minLeft, Math.min(maxLeft, left));

            panel.style.left = left + 'px';
            panel.style.top = top + 'px';
            panel.style.visibility = 'visible';
        }

        function attachVocaPanelInteractionGuards(panel) {
            ['mousedown', 'mouseup', 'touchstart', 'touchend', 'pointerdown', 'pointerup'].forEach((eventName) => {
                panel.addEventListener(eventName, stopVocaPanelEvent);
            });
        }

        function postIOSVocaMessage(payload) {
            window.webkit.messageHandlers.iosListener.postMessage(JSON.stringify(payload));
        }

        window.removeIOSVocaPanel = function() {
            document.querySelectorAll('.voca-lookup-panel').forEach((el) => el.remove());
            if (iosVocaDismissHandler) {
                ['pointerdown', 'touchstart', 'mousedown'].forEach((eventName) => {
                    document.removeEventListener(eventName, iosVocaDismissHandler, true);
                });
                iosVocaDismissHandler = null;
            }
        };

        window.showIOSVocaPanel = function(payload) {
            window.removeIOSVocaPanel();
            const rect = payload.rect || {};
            const panel = document.createElement('div');
            panel.className = 'voca-lookup-panel';
            attachVocaPanelInteractionGuards(panel);

            if (payload.mode === 'single' && payload.card) {
                const card = payload.card;
                const head = document.createElement('div');
                head.className = 'voca-lookup-panel__head';
                const wordEl = document.createElement('span');
                wordEl.className = 'voca-lookup-panel__word';
                wordEl.textContent = card.word || '';
                const voiceBtn = document.createElement('button');
                voiceBtn.type = 'button';
                voiceBtn.className = 'voca-lookup-panel__voice';
                voiceBtn.textContent = '🔊';
                voiceBtn.addEventListener('click', (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    if (voiceBtn.disabled) return;
                    voiceBtn.disabled = true;
                    voiceBtn.textContent = '…';
                    postIOSVocaMessage({ type: 'vocaPlayAudio', slug: card.slug || '' });
                    setTimeout(() => {
                        voiceBtn.disabled = false;
                        voiceBtn.textContent = '🔊';
                    }, 1200);
                });
                head.append(wordEl, voiceBtn);
                panel.appendChild(head);
                const ipa = card.ipa || card.pronunciation || '';
                if (ipa) {
                    const ipaEl = document.createElement('div');
                    ipaEl.className = 'voca-lookup-panel__ipa';
                    ipaEl.textContent = ipa.startsWith('/') ? ipa : '/' + ipa + '/';
                    panel.appendChild(ipaEl);
                }
                if (card.meaningVi) {
                    const meaningEl = document.createElement('div');
                    meaningEl.className = 'voca-lookup-panel__meaning';
                    meaningEl.textContent = card.meaningVi;
                    panel.appendChild(meaningEl);
                }
            } else if (payload.mode === 'multi' && Array.isArray(payload.cards)) {
                panel.classList.add('voca-lookup-panel--multi');
                const queryEl = document.createElement('div');
                queryEl.className = 'voca-lookup-panel__word';
                queryEl.textContent = payload.query || '';
                panel.appendChild(queryEl);
                const hintEl = document.createElement('div');
                hintEl.className = 'voca-lookup-panel__hint';
                hintEl.textContent = payload.cards.length + ' kết quả trong từ điển';
                panel.appendChild(hintEl);
                const list = document.createElement('div');
                list.className = 'voca-lookup-panel__list';
                payload.cards.forEach((card) => {
                    const item = document.createElement('button');
                    item.type = 'button';
                    item.className = 'voca-lookup-panel__item';
                    const wordEl = document.createElement('span');
                    wordEl.className = 'voca-lookup-panel__item-word';
                    wordEl.textContent = card.word || '';
                    item.appendChild(wordEl);
                    if (card.meaningVi) {
                        const meaningEl = document.createElement('span');
                        meaningEl.className = 'voca-lookup-panel__item-meaning';
                        meaningEl.textContent = card.meaningVi;
                        item.appendChild(meaningEl);
                    }
                    item.addEventListener('click', (e) => {
                        e.stopPropagation();
                        postIOSVocaMessage({ type: 'vocaSelectCard', card: card });
                    });
                    list.appendChild(item);
                });
                panel.appendChild(list);
            } else {
                panel.classList.add('voca-lookup-panel--empty');
                const wordEl = document.createElement('div');
                wordEl.className = 'voca-lookup-panel__word';
                wordEl.textContent = payload.query || '';
                const hintEl = document.createElement('div');
                hintEl.className = 'voca-lookup-panel__hint';
                hintEl.textContent = 'Chưa có trong từ điển';
                const addBtn = document.createElement('button');
                addBtn.type = 'button';
                addBtn.className = 'voca-lookup-panel__create';
                addBtn.textContent = 'Thêm vào Voca';
                addBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    postIOSVocaMessage({ type: 'vocaAdd', word: payload.query || '' });
                });
                panel.append(wordEl, hintEl, addBtn);
            }

            positionIOSVocaPanel(panel, rect);
            iosVocaDismissHandler = (e) => {
                if (e.target.closest('.voca-lookup-panel')) return;
                window.removeIOSVocaPanel();
                postIOSVocaMessage({ type: 'vocaDismiss' });
            };
            ['pointerdown', 'touchstart', 'mousedown'].forEach((eventName) => {
                document.addEventListener(eventName, iosVocaDismissHandler, true);
            });
        };

        window.__iosInterlinearPayload = null;
        window.__iosOppositePageKey = null;
        window.__iosOppositeParagraphs = null;

        window.clearIOSInterlinear = function() {
            const sublines = document.querySelectorAll('.bilingual-subline');
            if (!sublines.length) return;
            const parents = new Set();
            sublines.forEach((el) => {
                if (el.parentNode) parents.add(el.parentNode);
                el.remove();
            });
            parents.forEach((p) => {
                try { p.normalize(); } catch (_) {}
            });
        };

        function distributeWordsByWeights(words, weights) {
            if (!weights.length) return [];
            if (!words.length) return weights.map(() => '');
            if (weights.length === 1) return [words.join(' ')];
            const safeWeights = weights.map((w) => Math.max(1, w));
            const totalWeight = safeWeights.reduce((a, b) => a + b, 0);
            const totalWords = words.length;
            const out = [];
            let cumWeight = 0;
            let prevIdx = 0;
            for (let i = 0; i < safeWeights.length; i++) {
                cumWeight += safeWeights[i];
                const nextIdx = i === safeWeights.length - 1
                    ? totalWords
                    : Math.max(prevIdx, Math.min(totalWords, Math.round((cumWeight / totalWeight) * totalWords)));
                out.push(words.slice(prevIdx, nextIdx).join(' '));
                prevIdx = nextIdx;
            }
            return out;
        }

        function allocateTargetToVisualLines(lines, targetSentences) {
            if (!lines.length) return [];
            const cleaned = (targetSentences || []).map((s) => String(s || '').replace(/\\s+/g, ' ').trim()).filter(Boolean);
            if (!cleaned.length) return lines.map(() => '');
            if (lines.length === 1) return [cleaned.join(' ')];

            let maxSentenceIdx = 0;
            lines.forEach((l) => {
                l.tokens.forEach((t) => {
                    if (t.sentenceIndex > maxSentenceIdx) maxSentenceIdx = t.sentenceIndex;
                });
            });
            const sourceSentenceCount = maxSentenceIdx + 1;

            if (sourceSentenceCount === cleaned.length) {
                const buckets = lines.map(() => []);
                for (let sIdx = 0; sIdx < sourceSentenceCount; sIdx++) {
                    const words = cleaned[sIdx].split(/\\s+/).filter(Boolean);
                    if (!words.length) continue;
                    const lineIndices = [];
                    const weights = [];
                    lines.forEach((line, lIdx) => {
                        let w = 0;
                        line.tokens.forEach((t) => {
                            if (t.sentenceIndex === sIdx) w += t.weight;
                        });
                        if (w > 0) {
                            lineIndices.push(lIdx);
                            weights.push(w);
                        }
                    });
                    if (!lineIndices.length) continue;
                    const slices = distributeWordsByWeights(words, weights);
                    lineIndices.forEach((lIdx, idx) => {
                        if (slices[idx]) buckets[lIdx].push(slices[idx]);
                    });
                }
                return buckets.map((parts) => parts.join(' ').trim());
            }

            const allWords = cleaned.join(' ').split(/\\s+/).filter(Boolean);
            return distributeWordsByWeights(allWords, lines.map((l) => Math.max(1, l.totalWeight)));
        }

        function getOppositeParagraphMap(html, pageKey) {
            if (window.__iosOppositePageKey === pageKey && window.__iosOppositeParagraphs) {
                return window.__iosOppositeParagraphs;
            }
            const parsedDoc = new DOMParser().parseFromString(html || '', 'text/html');
            segmentDocSentences(parsedDoc);
            const article = parsedDoc.querySelector('article') || parsedDoc.body;
            const paragraphs = new Map();
            if (article) {
                Array.from(article.querySelectorAll(PARAGRAPH_SELECTOR)).forEach((p, pIdx) => {
                    const nodes = Array.from(p.querySelectorAll('.sentence-node'));
                    const list = [];
                    nodes.forEach((node) => {
                        const text = (node.textContent || '').replace(/\\s+/g, ' ').trim();
                        if (text) list.push(text);
                    });
                    if (!list.length) {
                        const fallback = (p.textContent || '').replace(/\\s+/g, ' ').trim();
                        if (fallback) list.push(fallback);
                    }
                    if (list.length) paragraphs.set(pIdx, list);
                });
            }
            window.__iosOppositePageKey = pageKey;
            window.__iosOppositeParagraphs = paragraphs;
            return paragraphs;
        }

        function measureVisualLinesInParagraph(p) {
            if (p.closest('pre, code, .code-block, .ascii-figure, .math, .formula, .formula-display')) {
                return [];
            }
            const walker = document.createTreeWalker(p, NodeFilter.SHOW_TEXT);
            const wordTokens = [];
            while (walker.nextNode()) {
                const textNode = walker.currentNode;
                const parentEl = textNode.parentElement;
                if (!parentEl) continue;
                if (parentEl.closest('.bilingual-subline, pre, .code-block, .ascii-figure')) continue;
                const raw = textNode.nodeValue || '';
                if (!raw.trim()) continue;
                const span = parentEl.closest('.sentence-node');
                const mId = span && span.dataset.sentenceId ? /^p-\\d+-s-(\\d+)$/.exec(span.dataset.sentenceId) : null;
                const sIdx = mId ? parseInt(mId[1], 10) : 0;
                const wordRegex = /\\S+/g;
                let match;
                while ((match = wordRegex.exec(raw)) !== null) {
                    const start = match.index;
                    const end = start + match[0].length;
                    let trailingEnd = end;
                    while (trailingEnd < raw.length && (raw[trailingEnd] === ' ' || raw[trailingEnd] === '\\t')) {
                        trailingEnd++;
                    }
                    wordTokens.push({
                        node: textNode,
                        start,
                        end,
                        trailingEnd,
                        weight: Math.max(1, match[0].length),
                        sentenceIndex: sIdx
                    });
                }
            }
            if (!wordTokens.length) return [];
            const range = document.createRange();
            const lines = [];
            for (const token of wordTokens) {
                try {
                    range.setStart(token.node, token.start);
                    range.setEnd(token.node, token.end);
                    const rect = range.getBoundingClientRect();
                    if (rect.width === 0 && rect.height === 0) continue;
                    const currentLine = lines[lines.length - 1];
                    if (!currentLine || Math.abs(rect.top - currentLine.top) > 6) {
                        lines.push({
                            top: rect.top,
                            tokens: [{ sentenceIndex: token.sentenceIndex, weight: token.weight }],
                            totalWeight: token.weight,
                            lastToken: token
                        });
                    } else {
                        currentLine.tokens.push({ sentenceIndex: token.sentenceIndex, weight: token.weight });
                        currentLine.totalWeight += token.weight;
                        currentLine.lastToken = token;
                    }
                } catch (_) {}
            }
            return lines;
        }

        window.applyIOSInterlinear = function(payload) {
            window.clearIOSInterlinear();
            if (!payload || !payload.enabled) {
                window.__iosInterlinearPayload = null;
                return;
            }
            window.__iosInterlinearPayload = payload;
            const paragraphMap = getOppositeParagraphMap(payload.targetHtml || '', payload.pageKey || '');
            const paragraphs = window.getParagraphs ? window.getParagraphs() : [];
            paragraphs.forEach((p, pIdx) => {
                const targetSentences = paragraphMap.get(pIdx);
                if (!targetSentences || !targetSentences.length) return;
                const sourceFull = (p.textContent || '').replace(/\\s+/g, ' ').trim();
                const targetFull = targetSentences.join(' ').replace(/\\s+/g, ' ').trim();
                if (!sourceFull || !targetFull) return;
                if (sourceFull.toLowerCase() === targetFull.toLowerCase()) return;

                const lines = measureVisualLinesInParagraph(p);
                if (!lines.length) return;
                const subTexts = allocateTargetToVisualLines(lines, targetSentences);
                for (let i = lines.length - 1; i >= 0; i--) {
                    const subText = (subTexts[i] || '').trim();
                    if (!subText) continue;
                    const sub = document.createElement('span');
                    sub.className = 'bilingual-subline';
                    sub.setAttribute('data-bilingual-sub', '1');
                    sub.setAttribute('data-subtext', subText);
                    sub.setAttribute('aria-hidden', 'true');
                    if (i === lines.length - 1) {
                        p.appendChild(sub);
                    } else {
                        const lastToken = lines[i].lastToken;
                        try {
                            const insertRange = document.createRange();
                            const safeOffset = Math.min(lastToken.trailingEnd, (lastToken.node.nodeValue || '').length);
                            insertRange.setStart(lastToken.node, safeOffset);
                            insertRange.collapse(true);
                            insertRange.insertNode(sub);
                        } catch (_) {
                            p.appendChild(sub);
                        }
                    }
                }
            });
        };

        window.reapplyIOSInterlinearIfNeeded = function() {
            if (window.__iosInterlinearPayload && window.__iosInterlinearPayload.enabled) {
                window.applyIOSInterlinear(window.__iosInterlinearPayload);
            }
        };

        // Run sentence segmentation on current document deferred
        requestAnimationFrame(() => {
            setTimeout(() => {
                try {
                    segmentDocSentences(document);
                } catch(e) {
                    console.error("Failed to segment sentences: ", e);
                }
            }, 0);
        });
        """
        let userScript = WKUserScript(source: jsSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        contentController.addUserScript(userScript)
        
        configuration.userContentController = contentController
        
        let webView = NoSelectionMenuWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.lastTopOverlayInset = Int(topOverlayInset)
        webView.scrollView.delegate = context.coordinator
        webView.scrollView.minimumZoomScale = 1.0
        webView.scrollView.maximumZoomScale = 1.0
        webView.scrollView.bouncesZoom = false
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        // Start transparent, then adopt the loaded BKB's computed paper color
        // in didFinish. A fixed native paper color creates a visible seam for
        // books whose design tokens use a different paper shade.
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        
        // Register observer for programmatical scrolling
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(context.coordinator.handleScrollTo(_:)),
            name: NSNotification.Name("ScrollTo_\(lang)"),
            object: nil
        )

        // Register observer for native programmatical scrolling
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(context.coordinator.handleScrollToOffset(_:)),
            name: NSNotification.Name("ScrollToOffset_\(lang)"),
            object: nil
        )

        DispatchQueue.main.async {
            onWebViewReady?(webView, lang, page)
        }

        return webView
    }

    private func registerWebView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.webView = webView
        if coordinator.registeredWebView === webView { return }
        coordinator.registeredWebView = webView
        onWebViewReady?(webView, lang, page)
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
        registerWebView(uiView, coordinator: context.coordinator)
        uiView.scrollView.delegate = context.coordinator

        // Update only the top notch inset CSS custom property on full-screen toggle
        // so fullscreen transitions never inject competing typography styles.
        if UIDevice.current.userInterfaceIdiom == .phone {
            let currentInset = Int(topOverlayInset)
            if context.coordinator.lastTopOverlayInset != currentInset {
                context.coordinator.lastTopOverlayInset = currentInset
                uiView.evaluateJavaScript(
                    "document.documentElement.style.setProperty('--bkb-top-inset', '\(currentInset)px');",
                    completionHandler: nil
                )
            }
        }

        let appearanceKey = "\(effectiveFontId)|\(effectiveThemeId)|\(viewMode)"
        if context.coordinator.lastAppearanceKey != appearanceKey && context.coordinator.loadedUrlString != nil {
            context.coordinator.lastAppearanceKey = appearanceKey
            context.coordinator.applyBookAppearance(in: uiView)
        }
        
        context.coordinator.updatePencilCanvas(
            isPencilModeActive: isPencilModeActive,
            bookSlug: bookSlug,
            page: page,
            lang: lang
        )
        
        // Inject jwt_token cookie to authorize remote subresources (like images)
        if !api.token.isEmpty,
           let serverURL = URL(string: api.serverUrl),
           let host = serverURL.host {
            let cookieProperties: [HTTPCookiePropertyKey: Any] = [
                .domain: host,
                .path: "/",
                .name: "jwt_token",
                .value: api.token,
                .secure: serverURL.scheme == "https" ? "TRUE" : "FALSE",
                .expires: Date(timeIntervalSinceNow: 86400 * 30) // 30 days
            ]
            if let cookie = HTTPCookie(properties: cookieProperties) {
                uiView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
            }
        }
        
        let targetUrlStr: String
        let isLocal: Bool
        
        if let localURL = BookCacheManager.shared.localPageURL(slug: bookSlug, lang: lang, page: page) {
            targetUrlStr = localURL.absoluteString
            isLocal = true
        } else {
            targetUrlStr = urlString
            isLocal = false
        }
        
        if context.coordinator.loadedUrlString != targetUrlStr {
            context.coordinator.loadedUrlString = targetUrlStr
            if isLocal, let localURL = BookCacheManager.shared.localPageURL(slug: bookSlug, lang: lang, page: page) {
                let outputDir = BookCacheManager.shared.localOutputDir(slug: bookSlug)
                uiView.loadFileURL(localURL, allowingReadAccessTo: outputDir)
            } else if let url = URL(string: urlString) {
                let request = URLRequest(url: url)
                uiView.load(request)
            }
        } else {
            // Apply highlights dynamically when list changes
            let filtered = api.highlights.filter { $0.page == page && $0.lang == lang }
            if filtered != context.coordinator.lastAppliedHighlights {
                context.coordinator.lastAppliedHighlights = filtered
                if let data = try? JSONEncoder().encode(filtered),
                   let jsonStr = String(data: data, encoding: .utf8) {
                    let js = "window.applyStoredHighlights(\(jsonStr));"
                    uiView.evaluateJavaScript(js, completionHandler: nil)
                }
            }
            
            // Highlight active sentence dynamically
            if activeSentenceId != context.coordinator.lastAppliedSentenceId {
                context.coordinator.lastAppliedSentenceId = activeSentenceId
                let sentenceId = activeSentenceId ?? ""
                let activeJs = "if (window.highlightSentence) { window.highlightSentence('\(sentenceId)'); }"
                uiView.evaluateJavaScript(activeJs, completionHandler: nil)
            }
        }
    }
    
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        uiView.scrollView.delegate = nil
        uiView.configuration.userContentController.removeAllScriptMessageHandlers()
        coordinator.registeredWebView = nil
        
        if let canvas = coordinator.canvasView {
            canvas.resignFirstResponder()
            canvas.drawingGestureRecognizer.isEnabled = false
            if let window = uiView.window ?? coordinator.getActiveWindow(),
               let toolPicker = PKToolPicker.shared(for: window) {
                toolPicker.setVisible(false, forFirstResponder: canvas)
                toolPicker.removeObserver(canvas)
            }
            canvas.removeFromSuperview()
        }
        coordinator.contentSizeObserver = nil
        coordinator.canvasView = nil
        
        coordinator.parent.onWebViewDismantled?(uiView, coordinator.parent.lang, coordinator.parent.page)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, UIScrollViewDelegate, PKCanvasViewDelegate {
        var parent: BilingualWebView
        weak var webView: WKWebView?
        var lastReceivedScrollTop: CGFloat = 0
        var isUpdatingScroll = false
        var loadedUrlString: String?
        var lastAppliedHighlights: [Highlight] = []
        var lastAppliedSentenceId: String? = nil
        var lastTopOverlayInset: Int = 0
        var lastAppearanceKey: String? = nil
        weak var registeredWebView: WKWebView?
        
        var canvasView: BilingualCanvasView?
        var contentSizeObserver: NSKeyValueObservation?
        var lastLoadedPageKey: String?
        var isDrawingLoading = false
        static var oppositeHtmlCache: [String: String] = [:]
        
        init(_ parent: BilingualWebView) {
            self.parent = parent
        }
        
        @objc func handleScrollTo(_ notification: Notification) {
            guard parent.viewMode == "split" else { return }
            
            guard let userInfo = notification.userInfo,
                  let scrollTop = userInfo["scrollTop"] as? CGFloat,
                  let webView = self.webView else { return }
            
            if abs(lastReceivedScrollTop - scrollTop) > 1 {
                lastReceivedScrollTop = scrollTop
                isUpdatingScroll = true
                
                let js = "window.scrollTo(0, \(scrollTop));"
                webView.evaluateJavaScript(js) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.isUpdatingScroll = false
                    }
                }
            }
        }

        @objc func handleScrollToOffset(_ notification: Notification) {
            guard parent.viewMode == "split" else { return }
            
            guard let userInfo = notification.userInfo,
                  let offset = userInfo["contentOffset"] as? CGPoint,
                  let webView = self.webView else { return }
            
            let otherScrollView = webView.scrollView
            if abs(otherScrollView.contentOffset.y - offset.y) > 0.5 {
                isUpdatingScroll = true
                otherScrollView.setContentOffset(offset, animated: false)
                isUpdatingScroll = false
            }
        }
        
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if !isUpdatingScroll {
                // Clear selection when scrolling
                parent.onHighlightMessage(.clearSelection)
                
                if parent.viewMode == "split" {
                    // Only synchronize scroll if the scroll is actively driven by a user gesture
                    // (either dragging, tracking, or decelerating after a drag).
                    guard scrollView.isDragging || scrollView.isDecelerating || scrollView.isTracking else {
                        return
                    }
                    
                    let otherLang = parent.lang == "en" ? "vi" : "en"
                    let contentOffset = scrollView.contentOffset
                    
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ScrollToOffset_\(otherLang)"),
                        object: nil,
                        userInfo: ["contentOffset": contentOffset]
                    )
                }
            }
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

            if isBookContentURL(url) {
                // Links with target="_blank" do not have a target frame. Keep
                // book-local links in the current reader WebView instead of
                // creating a second, unmanaged WebView.
                if navigationAction.targetFrame == nil {
                    webView.load(navigationAction.request)
                    decisionHandler(.cancel)
                } else {
                    decisionHandler(.allow)
                }
                return
            }

            guard isSupportedExternalURL(url) else {
                decisionHandler(.cancel)
                return
            }

            openExternalURL(url)
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url else {
                return nil
            }

            if isBookContentURL(url) {
                webView.load(navigationAction.request)
            } else if isSupportedExternalURL(url) {
                openExternalURL(url)
            }
            return nil
        }

        private func isBookContentURL(_ url: URL) -> Bool {
            if url.scheme?.lowercased() == "about" {
                return true
            }

            if url.isFileURL {
                let outputDirectory = BookCacheManager.shared
                    .localOutputDir(slug: parent.bookSlug)
                    .standardizedFileURL
                let candidate = url.standardizedFileURL
                return candidate.path == outputDirectory.path
                    || candidate.path.hasPrefix(outputDirectory.path + "/")
            }

            guard let sourceURL = URL(string: parent.urlString),
                  let sourceScheme = sourceURL.scheme?.lowercased(),
                  let candidateScheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(candidateScheme),
                  sourceScheme == candidateScheme,
                  sourceURL.host?.lowercased() == url.host?.lowercased(),
                  sourceURL.port == url.port,
                  let outputRange = sourceURL.path.range(of: "/output/") else {
                return false
            }

            let bookOutputPath = String(sourceURL.path[..<outputRange.upperBound])
            return url.path.hasPrefix(bookOutputPath)
        }

        private func isSupportedExternalURL(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return ["http", "https", "mailto", "tel"].contains(scheme)
        }

        private func openExternalURL(_ url: URL) {
            DispatchQueue.main.async { [weak self] in
                self?.parent.onOpenExternalURL?(url)
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            self.registeredWebView = nil
            parent.onWebViewReady?(webView, parent.lang, parent.page)

            if webView.scrollView.zoomScale != 1.0 {
                webView.scrollView.setZoomScale(1.0, animated: false)
            }
            self.lastTopOverlayInset = Int(parent.topOverlayInset)
            self.lastAppearanceKey = "\(parent.effectiveFontId)|\(parent.effectiveThemeId)|\(parent.viewMode)"
            applyBookAppearance(in: webView)

            let scrollScript = """
                (function() {
                    var isScrolling = false;
                    window.addEventListener('scroll', function() {
                        var scrollPos = window.pageYOffset || document.documentElement.scrollTop;
                        window.webkit.messageHandlers.iosListener.postMessage(JSON.stringify({
                            type: 'scroll',
                            scrollTop: scrollPos
                        }));
                    });
                })();
            """
            webView.evaluateJavaScript(scrollScript, completionHandler: nil)
            
            // Reapply highlights immediately after finish loading
            let filtered = parent.api.highlights.filter { $0.page == parent.page && $0.lang == parent.lang }
            self.lastAppliedHighlights = filtered
            if let data = try? JSONEncoder().encode(filtered),
               let jsonStr = String(data: data, encoding: .utf8) {
                let js = "window.applyStoredHighlights(\(jsonStr));"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
            
            // Highlight active sentence on finish loading
            if let activeId = parent.activeSentenceId {
                self.lastAppliedSentenceId = activeId
                let activeJs = "if (window.highlightSentence) { window.highlightSentence('\(activeId)'); }"
                webView.evaluateJavaScript(activeJs, completionHandler: nil)
            } else {
                self.lastAppliedSentenceId = nil
            }
        }

        func applyBookAppearance(in webView: WKWebView) {
            let isPhone = UIDevice.current.userInterfaceIdiom == .phone
            let desc = ReaderAppearance.parseThemeDescriptor(parent.effectiveThemeId)
            webView.evaluateJavaScript("if (window.clearIOSInterlinear) { window.clearIOSInterlinear(); }", completionHandler: nil)
            let js = ReaderAppearance.buildApplyAppearanceJS(
                fontId: parent.effectiveFontId,
                themeId: parent.effectiveThemeId,
                isPhone: isPhone,
                viewMode: parent.viewMode,
                topOverlayInset: parent.topOverlayInset
            )
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self = self else { return }
                Self.syncInterlinear(
                    in: webView,
                    slug: self.parent.bookSlug,
                    page: self.parent.page,
                    sourceLang: self.parent.lang,
                    enabled: desc.interlinear,
                    serverUrl: self.parent.api.serverUrl,
                    token: self.parent.api.token
                )
                if let dict = result as? [String: Any] {
                    if let components = dict["rgba"] as? [NSNumber], components.count == 4 {
                        let color = UIColor(
                            red: CGFloat(truncating: components[0]) / 255,
                            green: CGFloat(truncating: components[1]) / 255,
                            blue: CGFloat(truncating: components[2]) / 255,
                            alpha: CGFloat(truncating: components[3])
                        )
                        DispatchQueue.main.async {
                            webView.backgroundColor = color
                            webView.scrollView.backgroundColor = color
                        }
                    } else {
                        self.syncBookBackground(in: webView)
                    }
                    let appliedScale = (dict["appliedFontScale"] as? Int)
                        ?? (dict["appliedFontScale"] as? NSNumber)?.intValue
                        ?? ReaderAppearance.parseThemeDescriptor(self.parent.effectiveThemeId).fontScale
                    let clampedByA4 = (dict["clampedByA4"] as? Bool) ?? false
                    let atMaxA4Scale = (dict["atMaxA4Scale"] as? Bool) ?? (appliedScale >= 140)
                    DispatchQueue.main.async {
                        self.parent.onAppearanceMeasured?(
                            ReaderA4Status(
                                appliedFontScale: appliedScale,
                                clampedByA4: clampedByA4,
                                atMaxA4Scale: atMaxA4Scale
                            )
                        )
                    }
                } else {
                    self.syncBookBackground(in: webView)
                }
            }
        }

        static func fetchOppositePageHtml(slug: String, page: Int, targetLang: String, serverUrl: String, token: String, completion: @escaping (String?) -> Void) {
            let cacheKey = "\(slug):\(page):\(targetLang)"
            if let cached = Self.oppositeHtmlCache[cacheKey] {
                completion(cached)
                return
            }

            if let localURL = BookCacheManager.shared.localPageURL(slug: slug, lang: targetLang, page: page),
               let html = try? String(contentsOf: localURL, encoding: .utf8), !html.isEmpty {
                if Self.oppositeHtmlCache.count > 40 {
                    Self.oppositeHtmlCache.removeAll()
                }
                Self.oppositeHtmlCache[cacheKey] = html
                completion(html)
                return
            }

            let padPage = String(format: "%04d", max(1, page))
            let urlStr = "\(serverUrl)/books/\(slug)/output/\(targetLang)/page_\(padPage).html?token=\(token)"
            guard let url = URL(string: urlStr) else {
                completion(nil)
                return
            }

            URLSession.shared.dataTask(with: url) { data, response, _ in
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let data = data,
                      let html = String(data: data, encoding: .utf8), !html.isEmpty else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                DispatchQueue.main.async {
                    if Self.oppositeHtmlCache.count > 40 {
                        Self.oppositeHtmlCache.removeAll()
                    }
                    Self.oppositeHtmlCache[cacheKey] = html
                    completion(html)
                }
            }.resume()
        }

        static func syncInterlinear(
            in webView: WKWebView,
            slug: String,
            page: Int,
            sourceLang: String,
            enabled: Bool,
            serverUrl: String,
            token: String
        ) {
            guard enabled else {
                webView.evaluateJavaScript("if (window.clearIOSInterlinear) { window.clearIOSInterlinear(); }", completionHandler: nil)
                return
            }
            let targetLang = sourceLang == "en" ? "vi" : "en"
            let pageKey = "\(slug):\(page):\(targetLang)"

            fetchOppositePageHtml(slug: slug, page: page, targetLang: targetLang, serverUrl: serverUrl, token: token) { [weak webView] html in
                guard let webView = webView, let html = html else { return }
                let payload: [String: Any] = [
                    "enabled": true,
                    "pageKey": pageKey,
                    "targetHtml": html
                ]
                guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                      let jsonStr = String(data: data, encoding: .utf8) else { return }
                let js = "if (window.applyIOSInterlinear) { window.applyIOSInterlinear(\(jsonStr)); }"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }

        /// Extend the BKB page's own paper color through the reader padding and
        /// native WebView/scroll bounce area. The sheet is authoritative: the
        /// BKB body may intentionally use a separate browser-canvas color which
        /// would otherwise remain visible as a frame around the page on iOS.
        private func syncBookBackground(in webView: WKWebView) {
            let script = """
                (function() {
                    const candidates = [
                        document.querySelector('.book-page'),
                        document.querySelector('article'),
                        document.body,
                        document.documentElement
                    ];
                    for (const element of candidates) {
                        if (!element) continue;
                        const value = getComputedStyle(element).backgroundColor;
                        const match = value && value.match(/^rgba?\\(\\s*([\\d.]+)[, ]+\\s*([\\d.]+)[, ]+\\s*([\\d.]+)(?:\\s*[,/]\\s*([\\d.]+))?\\s*\\)$/i);
                        if (!match) continue;
                        const alpha = match[4] == null ? 1 : Number(match[4]);
                        if (alpha <= 0) continue;

                        // Only extend the selected paper color into the reader's
                        // outer canvas. Element-level BKB colors remain untouched.
                        document.documentElement.style.setProperty('background-color', value, 'important');
                        if (document.body) {
                            document.body.style.setProperty('background-color', value, 'important');
                        }
                        return [Number(match[1]), Number(match[2]), Number(match[3]), alpha];
                    }
                    return null;
                })();
            """

            webView.evaluateJavaScript(script) { result, _ in
                guard let components = result as? [NSNumber], components.count == 4 else { return }
                let color = UIColor(
                    red: CGFloat(truncating: components[0]) / 255,
                    green: CGFloat(truncating: components[1]) / 255,
                    blue: CGFloat(truncating: components[2]) / 255,
                    alpha: CGFloat(truncating: components[3])
                )
                DispatchQueue.main.async {
                    webView.backgroundColor = color
                    webView.scrollView.backgroundColor = color
                }
            }
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "iosListener",
                  let bodyString = message.body as? String else { return }
            
            if let data = bodyString.data(using: .utf8) {
                if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    if let type = json["type"] as? String {
                        if type == "scroll" && !isUpdatingScroll {
                            parent.onHighlightMessage(.clearSelection)
                            if let scrollTop = json["scrollTop"] as? CGFloat {
                                parent.onScroll(scrollTop)
                            }
                        } else if type == "textSelected" {
                            if let selectionData = json["selectionInfo"] as? [String: Any],
                               let pIndex = selectionData["paragraphIndex"] as? Int,
                               let start = selectionData["startOffset"] as? Int,
                               let end = selectionData["endOffset"] as? Int,
                               let text = selectionData["text"] as? String {
                                
                                var rect: CGRect? = selectionRect(from: selectionData["rect"] as? [String: Any])
                                
                                let info = SelectionInfo(paragraphIndex: pIndex, startOffset: start, endOffset: end, text: text, rect: rect)
                                parent.onHighlightMessage(.textSelected(selectionInfo: info))
                            }
                        } else if type == "highlightClicked" {
                            if let id = json["id"] as? String {
                                let rect = selectionRect(from: json["rect"] as? [String: Any])
                                parent.onHighlightMessage(.highlightClicked(id: id, rect: rect))
                            }
                        } else if type == "vocaAdd" {
                            if let word = json["word"] as? String {
                                parent.onVocaAction(.addWord(word))
                            }
                        } else if type == "vocaPlayAudio" {
                            if let slug = json["slug"] as? String, !slug.isEmpty {
                                parent.onVocaAction(.playAudio(slug: slug))
                            }
                        } else if type == "vocaSelectCard" {
                            if let cardDict = json["card"] as? [String: Any],
                               let card = VocaCard(webPayload: cardDict) {
                                parent.onVocaAction(.selectCard(card))
                            }
                        } else if type == "vocaDismiss" {
                            parent.onVocaAction(.dismiss)
                        } else if type == "sentenceClicked" {
                            if let sId = json["sentenceId"] as? String {
                                parent.onSentenceClicked(sId)
                            }
                        } else if type == "toggleFullScreen" {
                            parent.onHighlightMessage(.toggleFullScreen)
                        } else if type == "clearSelection" {
                            parent.onHighlightMessage(.clearSelection)
                            parent.onSentenceClicked(nil)
                        }
                    }
                }
            }
        }
        
        func updatePencilCanvas(isPencilModeActive: Bool, bookSlug: String, page: Int, lang: String) {
            guard let webView = self.webView else { return }
            
            let canvas: BilingualCanvasView
            if let existing = self.canvasView {
                canvas = existing
            } else {
                canvas = BilingualCanvasView()
                canvas.backgroundColor = .clear
                canvas.isOpaque = false
                canvas.delegate = self
                canvas.drawingPolicy = .anyInput
                
                webView.scrollView.addSubview(canvas)
                self.canvasView = canvas
                
                contentSizeObserver = webView.scrollView.observe(\.contentSize, options: [.initial, .new]) { [weak canvas] scrollView, _ in
                    guard let canvas = canvas else { return }
                    let newFrame = CGRect(origin: .zero, size: scrollView.contentSize)
                    if canvas.frame != newFrame {
                        canvas.frame = newFrame
                    }
                }
            }
            
            canvas.isUserInteractionEnabled = isPencilModeActive
            canvas.drawingGestureRecognizer.isEnabled = isPencilModeActive
            webView.scrollView.bringSubviewToFront(canvas)
            
            let pageKey = "\(bookSlug)_\(page)_\(lang)"
            if lastLoadedPageKey != pageKey {
                lastLoadedPageKey = pageKey
                isDrawingLoading = true
                loadDrawing(canvasView: canvas, slug: bookSlug, page: page, lang: lang)
                isDrawingLoading = false
            }
            
            if let window = webView.window ?? getActiveWindow(),
               let toolPicker = PKToolPicker.shared(for: window) {
                if isPencilModeActive {
                    toolPicker.addObserver(canvas)
                    toolPicker.setVisible(true, forFirstResponder: canvas)
                    canvas.becomeFirstResponder()
                } else {
                    toolPicker.setVisible(false, forFirstResponder: canvas)
                    toolPicker.removeObserver(canvas)
                    canvas.resignFirstResponder()
                }
            }
        }
        
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isDrawingLoading else { return }
            saveDrawing(canvasView: canvasView, slug: parent.bookSlug, page: parent.page, lang: parent.lang)
        }
        
        private func saveDrawing(canvasView: PKCanvasView, slug: String, page: Int, lang: String) {
            let drawing = canvasView.drawing
            let fileManager = FileManager.default
            let drawingsDir = BookCacheManager.shared.localBookDir(slug: slug).appendingPathComponent("drawings", isDirectory: true)
            let fileURL = drawingsDir.appendingPathComponent("page_\(page)_\(lang).bin")
            
            if drawing.bounds.isEmpty {
                if fileManager.fileExists(atPath: fileURL.path) {
                    try? fileManager.removeItem(at: fileURL)
                }
                return
            }
            
            do {
                try fileManager.createDirectory(at: drawingsDir, withIntermediateDirectories: true, attributes: nil)
                let data = drawing.dataRepresentation()
                try data.write(to: fileURL)
            } catch {
                print("Failed to save drawing: \(error)")
            }
        }
        
        private func loadDrawing(canvasView: PKCanvasView, slug: String, page: Int, lang: String) {
            let fileURL = BookCacheManager.shared.localBookDir(slug: slug)
                .appendingPathComponent("drawings", isDirectory: true)
                .appendingPathComponent("page_\(page)_\(lang).bin")
            
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    let data = try Data(contentsOf: fileURL)
                    let drawing = try PKDrawing(data: data)
                    canvasView.drawing = drawing
                } catch {
                    print("Failed to load drawing: \(error)")
                }
            } else {
                canvasView.drawing = PKDrawing()
            }
        }
        
        func getActiveWindow() -> UIWindow? {
            return UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
        }
    }
}
