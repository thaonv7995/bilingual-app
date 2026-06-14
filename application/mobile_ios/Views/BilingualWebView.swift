import SwiftUI
import WebKit

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

class NoSelectionMenuWebView: WKWebView {
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        return false
    }
}

struct BilingualWebView: UIViewRepresentable {
    let urlString: String
    let lang: String
    let page: Int
    let activeSentenceId: String?
    @ObservedObject var api = APIService.shared
    let onScroll: (CGFloat) -> Void
    let onHighlightMessage: (HighlightMessage) -> Void
    let onSentenceClicked: (String?) -> Void
    
    func makeUIView(context: Context) -> WKWebView {
        let preferences = WKPreferences()
        
        let configuration = WKWebViewConfiguration()
        configuration.preferences = preferences
        
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "iosListener")
        
        let isEnglish = lang == "en"
        let highlightColor = isEnglish ? "rgba(56, 189, 248, 0.22)" : "rgba(250, 204, 21, 0.24)"
        let hoverColor = isEnglish ? "rgba(56, 189, 248, 0.08)" : "rgba(250, 204, 21, 0.08)"
        
        // Inject highlighting core script
        let jsSource = """
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
                html, body, main, article, .book-page, .sheet-flow, .prose-page {
                    margin: 0 !important;
                    padding: 0 !important;
                    width: 100% !important;
                    max-width: 100% !important;
                    box-sizing: border-box !important;
                    overflow-x: hidden !important;
                    background-color: #F9F7F1 !important;
                    color: #333333 !important;
                    font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif !important;
                }
                div, p, h1, h2, h3, h4, h5, h6, ul, ol, li {
                    background-color: transparent !important;
                    color: inherit !important;
                }
                body {
                    padding: 24px 24px 40px 24px !important;
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
            `;
            document.head.appendChild(style);
        }

        const PARAGRAPH_SELECTOR = 'p, li, blockquote, pre, h1, h2, h3, h4, h5, h6';

        window.getParagraphs = function() {
            return Array.from(document.body.querySelectorAll(PARAGRAPH_SELECTOR));
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

        function handleSelectionEnd(e) {
            setTimeout(() => {
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
            const paragraphs = article.querySelectorAll('p, .chapter-start, .no-indent, h1, h2, h3, li');
            paragraphs.forEach((p, idx) => {
                if (!p.querySelector('.sentence-node')) {
                    segmentParagraph(p, idx);
                }
            });
        }

        // Run sentence segmentation on current document
        try {
            segmentDocSentences(document);
        } catch(e) {
            console.error("Failed to segment sentences: ", e);
        }
        """
        let userScript = WKUserScript(source: jsSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        contentController.addUserScript(userScript)
        
        configuration.userContentController = contentController
        
        let webView = NoSelectionMenuWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.isOpaque = true
        webView.backgroundColor = UIColor(red: 249/255, green: 247/255, blue: 241/255, alpha: 1.0)
        webView.scrollView.backgroundColor = UIColor(red: 249/255, green: 247/255, blue: 241/255, alpha: 1.0)
        
        // Register observer for programmatical scrolling
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(context.coordinator.handleScrollTo(_:)),
            name: NSNotification.Name("ScrollTo_\(lang)"),
            object: nil
        )
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedUrlString != urlString {
            context.coordinator.loadedUrlString = urlString
            if let url = URL(string: urlString) {
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
    

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: BilingualWebView
        weak var webView: WKWebView?
        var lastReceivedScrollTop: CGFloat = 0
        var isUpdatingScroll = false
        var loadedUrlString: String?
        var lastAppliedHighlights: [Highlight] = []
        var lastAppliedSentenceId: String? = nil
        
        init(_ parent: BilingualWebView) {
            self.parent = parent
        }
        
        @objc func handleScrollTo(_ notification: Notification) {
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
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
                                
                                var rect: CGRect? = nil
                                if let rectDict = selectionData["rect"] as? [String: Any],
                                   let rx = rectDict["x"] as? CGFloat,
                                   let ry = rectDict["y"] as? CGFloat,
                                   let rw = rectDict["width"] as? CGFloat,
                                   let rh = rectDict["height"] as? CGFloat {
                                    rect = CGRect(x: rx, y: ry, width: rw, height: rh)
                                }
                                
                                let info = SelectionInfo(paragraphIndex: pIndex, startOffset: start, endOffset: end, text: text, rect: rect)
                                parent.onHighlightMessage(.textSelected(selectionInfo: info))
                            }
                        } else if type == "highlightClicked" {
                            if let id = json["id"] as? String {
                                var rect: CGRect? = nil
                                if let rectDict = json["rect"] as? [String: Any],
                                   let rx = rectDict["x"] as? CGFloat,
                                   let ry = rectDict["y"] as? CGFloat,
                                   let rw = rectDict["width"] as? CGFloat,
                                   let rh = rectDict["height"] as? CGFloat {
                                    rect = CGRect(x: rx, y: ry, width: rw, height: rh)
                                }
                                parent.onHighlightMessage(.highlightClicked(id: id, rect: rect))
                            }
                        } else if type == "sentenceClicked" {
                            if let sId = json["sentenceId"] as? String {
                                parent.onSentenceClicked(sId)
                            }
                        } else if type == "clearSelection" {
                            parent.onHighlightMessage(.clearSelection)
                            parent.onSentenceClicked(nil)
                        }
                    }
                }
            }
        }
    }
}
