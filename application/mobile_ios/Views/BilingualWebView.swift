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
    case playAudio(cardId: String)
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
    @ObservedObject var api = APIService.shared
    let onScroll: (CGFloat) -> Void
    let onHighlightMessage: (HighlightMessage) -> Void
    let onSentenceClicked: (String?) -> Void
    let onVocaAction: (VocaWebAction) -> Void
    var onWebViewReady: ((WKWebView, String, Int) -> Void)? = nil
    var onWebViewDismantled: ((WKWebView, String, Int) -> Void)? = nil
    
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
        
        // 1. Set background color of root html tag immediately at .atDocumentStart to prevent white flash
        let cssStyleSource = """
        (function() {
            document.documentElement.style.backgroundColor = '#F9F7F1';
            document.documentElement.style.color = '#333333';
            
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
                            min-height: 100% !important;
                            box-sizing: border-box !important;
                            overflow-x: hidden !important;
                            overflow-y: auto !important;
                            background-color: #F9F7F1 !important;
                        }
                        body, body.book-standalone {
                            margin: 0 !important;
                            padding: 0 !important;
                            width: 100% !important;
                            max-width: 100% !important;
                            height: auto !important;
                            min-height: 100% !important;
                            box-sizing: border-box !important;
                            display: block !important;
                            overflow-x: hidden !important;
                            overflow-y: auto !important;
                            background-color: #F9F7F1 !important;
                            color: #333333 !important;
                            font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif !important;
                        }
                        main, article, .prose-page {
                            margin: 0 !important;
                            padding: 0 !important;
                            width: 100% !important;
                            max-width: 100% !important;
                            box-sizing: border-box !important;
                            background-color: transparent !important;
                            color: inherit !important;
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
                        }
                        div, p, h1, h2, h3, h4, h5, h6, ul, ol, li {
                            background-color: transparent !important;
                            color: inherit !important;
                        }
                        * {
                            box-sizing: border-box !important;
                            max-width: 100% !important;
                            word-wrap: break-word !important;
                        }
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
                if (document.head || document.body) {
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
        function handleDoubleTap(e) {
            if (e.target && typeof e.target.closest === 'function' && e.target.closest('.voca-lookup-panel')) {
                return;
            }
            const currentTime = new Date().getTime();
            const tapLength = currentTime - lastTapTime;
            if (tapLength < 400 && tapLength > 0) {
                // Double tap detected
                window.webkit.messageHandlers.iosListener.postMessage(JSON.stringify({
                    type: 'toggleFullScreen'
                }));
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
                    postIOSVocaMessage({ type: 'vocaPlayAudio', cardId: card.id || '' });
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
        context.coordinator.webView = webView
        webView.scrollView.delegate = context.coordinator
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.isOpaque = true
        webView.backgroundColor = UIColor(red: 249/255, green: 247/255, blue: 241/255, alpha: 1.0)
        webView.scrollView.backgroundColor = UIColor(red: 249/255, green: 247/255, blue: 241/255, alpha: 1.0)
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
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UIScrollViewDelegate, PKCanvasViewDelegate {
        var parent: BilingualWebView
        weak var webView: WKWebView?
        var lastReceivedScrollTop: CGFloat = 0
        var isUpdatingScroll = false
        var loadedUrlString: String?
        var lastAppliedHighlights: [Highlight] = []
        var lastAppliedSentenceId: String? = nil
        weak var registeredWebView: WKWebView?
        
        var canvasView: BilingualCanvasView?
        var contentSizeObserver: NSKeyValueObservation?
        var lastLoadedPageKey: String?
        var isDrawingLoading = false
        
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
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            self.registeredWebView = nil
            parent.onWebViewReady?(webView, parent.lang, parent.page)

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
                            if let cardId = json["cardId"] as? String, !cardId.isEmpty {
                                parent.onVocaAction(.playAudio(cardId: cardId))
                            }
                        } else if type == "vocaSelectCard" {
                            if let cardDict = json["card"] as? [String: Any],
                               let id = cardDict["id"] as? String,
                               let word = cardDict["word"] as? String {
                                let card = VocaCard(
                                    id: id,
                                    word: word,
                                    meaningVi: cardDict["meaningVi"] as? String ?? "",
                                    ipa: cardDict["ipa"] as? String,
                                    pronunciation: cardDict["pronunciation"] as? String,
                                    audioUrl: cardDict["audioUrl"] as? String,
                                    level: cardDict["level"] as? String
                                )
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



