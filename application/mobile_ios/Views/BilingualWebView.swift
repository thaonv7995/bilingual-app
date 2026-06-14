import SwiftUI
import WebKit

struct SelectionInfo: Codable {
    let paragraphIndex: Int
    let startOffset: Int
    let endOffset: Int
    let text: String
}

enum HighlightMessage {
    case textSelected(selectionInfo: SelectionInfo)
    case highlightClicked(id: String)
    case clearSelection
}

struct BilingualWebView: UIViewRepresentable {
    let urlString: String
    let lang: String
    let page: Int
    @ObservedObject var api = APIService.shared
    let onScroll: (CGFloat) -> Void
    let onHighlightMessage: (HighlightMessage) -> Void
    
    func makeUIView(context: Context) -> WKWebView {
        let preferences = WKPreferences()
        
        let configuration = WKWebViewConfiguration()
        configuration.preferences = preferences
        
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "iosListener")
        
        // Inject highlighting core script
        let jsSource = """
        const STYLE_ID = 'reader-highlight-style';
        if (!document.getElementById(STYLE_ID)) {
            const style = document.createElement('style');
            style.id = STYLE_ID;
            style.innerHTML = `
                mark.reader-highlight {
                    background-color: #fef08a;
                    color: black !important;
                    cursor: pointer;
                    border-radius: 2px;
                    padding: 1px 0;
                    transition: background-color 0.2s;
                }
                mark.reader-highlight[data-has-note="true"] {
                    border-bottom: 2px dashed #3b82f6;
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

            return { paragraphIndex, startOffset, endOffset, text: range.toString() };
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
                    window.webkit.messageHandlers.iosListener.postMessage(JSON.stringify({
                        type: 'highlightClicked',
                        id: highlightId
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
                } else {
                    window.webkit.messageHandlers.iosListener.postMessage(JSON.stringify({
                        type: 'clearSelection'
                    }));
                }
            }, 50);
        }
        """
        let userScript = WKUserScript(source: jsSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        contentController.addUserScript(userScript)
        
        configuration.userContentController = contentController
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        
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
        if let url = URL(string: urlString) {
            let request = URLRequest(url: url)
            if uiView.url != url {
                uiView.load(request)
            } else {
                // Apply highlights dynamically when list changes
                let filtered = api.highlights.filter { $0.page == page && $0.lang == lang }
                if let data = try? JSONEncoder().encode(filtered),
                   let jsonStr = String(data: data, encoding: .utf8) {
                    let js = "window.applyStoredHighlights(\(jsonStr));"
                    uiView.evaluateJavaScript(js, completionHandler: nil)
                }
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: BilingualWebView
        var lastReceivedScrollTop: CGFloat = 0
        var isUpdatingScroll = false
        
        init(_ parent: BilingualWebView) {
            self.parent = parent
        }
        
        @objc func handleScrollTo(_ notification: Notification) {
            guard let userInfo = notification.userInfo,
                  let scrollTop = userInfo["scrollTop"] as? CGFloat,
                  let webView = notification.object as? WKWebView else { return }
            
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
            if let data = try? JSONEncoder().encode(filtered),
               let jsonStr = String(data: data, encoding: .utf8) {
                let js = "window.applyStoredHighlights(\(jsonStr));"
                webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "iosListener",
                  let bodyString = message.body as? String else { return }
            
            if let data = bodyString.data(using: .utf8) {
                if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    if let type = json["type"] as? String {
                        if type == "scroll" && !isUpdatingScroll {
                            if let scrollTop = json["scrollTop"] as? CGFloat {
                                parent.onScroll(scrollTop)
                            }
                        } else if type == "textSelected" {
                            if let selectionData = json["selectionInfo"] as? [String: Any],
                               let pIndex = selectionData["paragraphIndex"] as? Int,
                               let start = selectionData["startOffset"] as? Int,
                               let end = selectionData["endOffset"] as? Int,
                               let text = selectionData["text"] as? String {
                                let info = SelectionInfo(paragraphIndex: pIndex, startOffset: start, endOffset: end, text: text)
                                parent.onHighlightMessage(.textSelected(selectionInfo: info))
                            }
                        } else if type == "highlightClicked" {
                            if let id = json["id"] as? String {
                                parent.onHighlightMessage(.highlightClicked(id: id))
                            }
                        } else if type == "clearSelection" {
                            parent.onHighlightMessage(.clearSelection)
                        }
                    }
                }
            }
        }
    }
}
