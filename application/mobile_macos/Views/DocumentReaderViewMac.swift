import SwiftUI
import AppKit
import PDFKit
import WebKit

// MARK: - Same-Origin Local Scheme Handler for Offline EPUB + foliate-js Runtime

final class LocalEpubSchemeHandlerMac: NSObject, WKURLSchemeHandler {
    private var epubFileURL: URL?

    func setEpubFileURL(_ url: URL?) {
        self.epubFileURL = url
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileURL: URL?
        let mimeType: String

        switch path {
        case "epub-reader.html":
            fileURL = Self.bundledResource(name: "epub-reader", ext: "html")
            mimeType = "text/html; charset=utf-8"
        case "epub-native-runtime.js":
            fileURL = Self.bundledResource(name: "epub-native-runtime", ext: "js")
            mimeType = "application/javascript; charset=utf-8"
        case "book.epub":
            fileURL = epubFileURL
            mimeType = "application/epub+zip"
        default:
            fileURL = nil
            mimeType = "application/octet-stream"
        }

        guard let target = fileURL, let data = try? Data(contentsOf: target) else {
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            urlSchemeTask.didReceive(resp)
            urlSchemeTask.didFinish()
            return
        }

        let headers = [
            "Content-Type": mimeType,
            "Content-Length": "\(data.count)",
            "Cache-Control": "no-cache",
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private static func bundledResource(name: String, ext: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources/EpubReader") {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "EpubReader") {
            return url
        }
        return Bundle.main.url(forResource: name, withExtension: ext)
    }
}

// MARK: - Shared Types for Native Document Reader

struct DocTocItemMac: Identifiable, Equatable {
    let id: String
    let label: String
    let level: Int
    let page: Int?
    let href: String?
}

struct DocSearchHitMac: Identifiable, Equatable {
    let id = UUID()
    let cfi: String
    let label: String
    let pre: String
    let match: String
    let post: String
}

enum PdfDisplayLayoutMac: String, CaseIterable {
    case single = "1 trang"
    case twoUp = "2 trang"
    case continuous = "Cuộn dọc"
}

enum PdfFilterModeMac: String, CaseIterable {
    case original = "Gốc"
    case warm = "Ấm"
    case dark = "Đêm"
}

// MARK: - Native PDFKit Wrapper (Apple Books PDF Engine)

struct NativePDFViewMac: NSViewRepresentable {
    let document: PDFDocument?
    let targetPage: Int
    let displayLayout: PdfDisplayLayoutMac
    let zoomTrigger: Int
    let zoomDelta: CGFloat
    let fitMode: String // "fit" | "width" | "custom"
    let highlights: [Highlight]
    let onPageChanged: (Int) -> Void
    let onSelectionChanged: (String, Int, [NormalizedPdfRect]) -> Void
    let onContextProviderReady: (@escaping () -> (pageText: String, selectedText: String)) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.1, blue: 0.14, alpha: 1.0)
        context.coordinator.attach(to: pdfView)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.parent = self

        if pdfView.document !== document {
            pdfView.document = document
            context.coordinator.lastSyncedPage = 0
            context.coordinator.lastAppliedHighlightsSignature = ""
        }

        switch displayLayout {
        case .single:
            if pdfView.displayMode != .singlePage { pdfView.displayMode = .singlePage }
        case .twoUp:
            if pdfView.displayMode != .twoUp { pdfView.displayMode = .twoUp }
        case .continuous:
            if pdfView.displayMode != .singlePageContinuous { pdfView.displayMode = .singlePageContinuous }
        }

        if let doc = document, targetPage >= 1, targetPage <= doc.pageCount,
           context.coordinator.lastSyncedPage != targetPage,
           let pageObj = doc.page(at: targetPage - 1) {
            let currentIdx = pdfView.currentPage.map { doc.index(for: $0) + 1 } ?? 0
            if currentIdx != targetPage {
                context.coordinator.isProgrammaticNav = true
                pdfView.go(to: pageObj)
                context.coordinator.isProgrammaticNav = false
            }
            context.coordinator.lastSyncedPage = targetPage
        }

        if context.coordinator.lastZoomTrigger != zoomTrigger {
            context.coordinator.lastZoomTrigger = zoomTrigger
            if fitMode == "fit" {
                pdfView.autoScales = true
            } else if zoomDelta != 0 {
                pdfView.autoScales = false
                let nextScale = max(0.4, min(4.0, pdfView.scaleFactor + zoomDelta))
                pdfView.scaleFactor = nextScale
            }
        }

        context.coordinator.syncHighlightAnnotations(in: pdfView, highlights: highlights)
    }

    final class Coordinator: NSObject {
        var parent: NativePDFViewMac
        weak var pdfView: PDFView?
        var lastSyncedPage: Int = 0
        var lastZoomTrigger: Int = 0
        var isProgrammaticNav: Bool = false
        var lastAppliedHighlightsSignature: String = ""

        init(_ parent: NativePDFViewMac) {
            self.parent = parent
        }

        func attach(to view: PDFView) {
            self.pdfView = view
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handlePageChanged(_:)),
                name: .PDFViewPageChanged,
                object: view
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSelectionChanged(_:)),
                name: .PDFViewSelectionChanged,
                object: view
            )
            parent.onContextProviderReady { [weak self] in
                guard let self, let pv = self.pdfView else { return ("", "") }
                let pageText = pv.currentPage?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let selText = pv.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (pageText, selText)
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func handlePageChanged(_ note: Notification) {
            guard !isProgrammaticNav,
                  let pv = pdfView,
                  let doc = pv.document,
                  let page = pv.currentPage else { return }
            let num = doc.index(for: page) + 1
            if num != lastSyncedPage {
                lastSyncedPage = num
                DispatchQueue.main.async {
                    self.parent.onPageChanged(num)
                }
            }
        }

        @objc private func handleSelectionChanged(_ note: Notification) {
            guard let pv = pdfView, let doc = pv.document else { return }
            guard let sel = pv.currentSelection,
                  let rawText = sel.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawText.isEmpty,
                  let firstPage = sel.pages.first else {
                DispatchQueue.main.async {
                    self.parent.onSelectionChanged("", self.lastSyncedPage, [])
                }
                return
            }

            let pageNum = doc.index(for: firstPage) + 1
            let pageBounds = firstPage.bounds(for: .cropBox)
            let lineSelections = sel.selectionsByLine()
            var rects: [NormalizedPdfRect] = []
            for line in lineSelections {
                let b = line.bounds(for: firstPage)
                guard b.width > 0.5, b.height > 0.5, pageBounds.width > 0, pageBounds.height > 0 else { continue }
                let nx = max(0, min(1, Double((b.minX - pageBounds.minX) / pageBounds.width)))
                let ny = max(0, min(1, Double(1.0 - (b.maxY - pageBounds.minY) / pageBounds.height)))
                let nw = max(0, min(1, Double(b.width / pageBounds.width)))
                let nh = max(0, min(1, Double(b.height / pageBounds.height)))
                rects.append(NormalizedPdfRect(x: nx, y: ny, w: nw, h: nh))
            }

            DispatchQueue.main.async {
                self.parent.onSelectionChanged(rawText, pageNum, rects)
            }
        }

        func syncHighlightAnnotations(in pv: PDFView, highlights: [Highlight]) {
            guard let doc = pv.document else { return }
            let sig = highlights.map { "\($0.id):\($0.color):\($0.page):\($0.anchorJson ?? "")" }.joined(separator: "|")
            guard sig != lastAppliedHighlightsSignature else { return }
            lastAppliedHighlightsSignature = sig

            for pIdx in 0..<doc.pageCount {
                guard let page = doc.page(at: pIdx) else { continue }
                let existing = page.annotations.filter { $0.userName == "bilingual_reader_hl" }
                for ann in existing {
                    page.removeAnnotation(ann)
                }
            }

            for hl in highlights {
                guard hl.page >= 1, hl.page <= doc.pageCount,
                      let page = doc.page(at: hl.page - 1),
                      let anchor = DocumentHighlightAnchor.parse(hl.anchorJson),
                      anchor.kind == "pdf",
                      let rects = anchor.rects else { continue }

                let pageBounds = page.bounds(for: .cropBox)
                let nsColor = nsColorFromHex(hl.color).withAlphaComponent(0.38)
                for r in rects {
                    let x = pageBounds.minX + CGFloat(r.x) * pageBounds.width
                    let w = CGFloat(r.w) * pageBounds.width
                    let h = CGFloat(r.h) * pageBounds.height
                    let y = pageBounds.minY + CGFloat(1.0 - r.y - r.h) * pageBounds.height
                    let ann = PDFAnnotation(bounds: CGRect(x: x, y: y, width: w, height: h), forType: .highlight, withProperties: nil)
                    ann.color = nsColor
                    ann.contents = hl.note
                    ann.userName = "bilingual_reader_hl"
                    page.addAnnotation(ann)
                }
            }
        }

        private func nsColorFromHex(_ hex: String) -> NSColor {
            let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            var int: UInt64 = 0
            Scanner(string: cleaned).scanHexInt64(&int)
            let r = CGFloat((int >> 16) & 0xFF) / 255.0
            let g = CGFloat((int >> 8) & 0xFF) / 255.0
            let b = CGFloat(int & 0xFF) / 255.0
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
        }
    }
}

// MARK: - Native WKWebView Wrapper for Offline foliate-js EPUB Engine

struct NativeEpubWebViewMac: NSViewRepresentable {
    let epubFileURL: URL?
    let initialCfi: String?
    let estimatedTotalPages: Int
    let fontId: String
    let themeId: String
    let flowMode: String // "paginated" | "scrolled"
    let maxColumns: Int
    let highlights: [Highlight]
    let onWebViewReady: (WKWebView) -> Void
    let onReady: ([DocTocItemMac]) -> Void
    let onRelocate: (String, Double, Int, Int, String, String) -> Void
    let onTextSelected: (String, String, String, Int) -> Void
    let onHighlightClicked: (String) -> Void
    let onSelectionCleared: () -> Void
    let onSearchResults: ([DocSearchHitMac]) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: "bkb-epub")
        config.userContentController.add(context.coordinator, name: "epubBridge")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        onWebViewReady(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self

        if let fileURL = epubFileURL, context.coordinator.loadedFileURL != fileURL {
            context.coordinator.loadedFileURL = fileURL
            context.coordinator.schemeHandler.setEpubFileURL(fileURL)
            context.coordinator.didTriggerOpen = false
            if let pageURL = URL(string: "bkb-epub://app/epub-reader.html") {
                webView.load(URLRequest(url: pageURL))
            }
        }

        if context.coordinator.isRuntimeReady {
            context.coordinator.pushAppearance(fontId: fontId, themeId: themeId, flow: flowMode, maxColumns: maxColumns)
            context.coordinator.pushHighlights(highlights)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: NativeEpubWebViewMac
        let schemeHandler = LocalEpubSchemeHandlerMac()
        weak var webView: WKWebView?
        var loadedFileURL: URL?
        var didTriggerOpen = false
        var isRuntimeReady = false
        var lastAppearanceKey = ""
        var lastHighlightsKey = ""

        init(_ parent: NativeEpubWebViewMac) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didTriggerOpen, loadedFileURL != nil else { return }
            didTriggerOpen = true
            let loc = (parent.initialCfi ?? "").replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            let js = "window.BilingualEpub && window.BilingualEpub.openFromUrl('bkb-epub://app/book.epub', '', '\(loc)', \(max(1, parent.estimatedTotalPages)));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            DispatchQueue.main.async {
                switch type {
                case "ready":
                    self.isRuntimeReady = true
                    self.lastAppearanceKey = ""
                    self.lastHighlightsKey = ""
                    self.pushAppearance(
                        fontId: self.parent.fontId,
                        themeId: self.parent.themeId,
                        flow: self.parent.flowMode,
                        maxColumns: self.parent.maxColumns
                    )
                    self.pushHighlights(self.parent.highlights)
                    let rawToc = body["toc"] as? [[String: Any]] ?? []
                    let items: [DocTocItemMac] = rawToc.enumerated().map { idx, row in
                        DocTocItemMac(
                            id: "\(idx)-\(row["href"] as? String ?? "")",
                            label: row["label"] as? String ?? "Chương",
                            level: row["level"] as? Int ?? 0,
                            page: nil,
                            href: row["href"] as? String
                        )
                    }
                    self.parent.onReady(items)

                case "relocate":
                    let cfi = body["cfi"] as? String ?? ""
                    let fraction = body["fraction"] as? Double ?? 0
                    let page = body["page"] as? Int ?? 1
                    let total = body["totalPages"] as? Int ?? max(1, self.parent.estimatedTotalPages)
                    let chapter = body["chapterTitle"] as? String ?? ""
                    let visibleText = body["visibleText"] as? String ?? ""
                    self.parent.onRelocate(cfi, fraction, page, total, chapter, visibleText)

                case "textSelected":
                    let cfi = body["cfi"] as? String ?? ""
                    let text = body["text"] as? String ?? ""
                    let chapter = body["chapterTitle"] as? String ?? ""
                    let page = body["page"] as? Int ?? 1
                    self.parent.onTextSelected(cfi, text, chapter, page)

                case "highlightClicked":
                    if let id = body["id"] as? String {
                        self.parent.onHighlightClicked(id)
                    }

                case "selectionCleared":
                    self.parent.onSelectionCleared()

                case "searchResults":
                    let arr = body["results"] as? [[String: Any]] ?? []
                    let hits = arr.compactMap { row -> DocSearchHitMac? in
                        guard let cfi = row["cfi"] as? String else { return nil }
                        return DocSearchHitMac(
                            cfi: cfi,
                            label: row["label"] as? String ?? "",
                            pre: row["pre"] as? String ?? "",
                            match: row["match"] as? String ?? "",
                            post: row["post"] as? String ?? ""
                        )
                    }
                    self.parent.onSearchResults(hits)

                case "error":
                    self.parent.onError(body["message"] as? String ?? "Không thể hiển thị EPUB")

                default:
                    break
                }
            }
        }

        func pushAppearance(fontId: String, themeId: String, flow: String, maxColumns: Int) {
            let key = "\(fontId)|\(themeId)|\(flow)|\(maxColumns)"
            guard key != lastAppearanceKey, let webView else { return }
            lastAppearanceKey = key

            let font = ReaderAppearance.getFont(fontId)
            let theme = ReaderAppearance.getTheme(themeId)
            let desc = ReaderAppearance.parseThemeDescriptor(themeId)
            let hasCustomPaper = desc.themeId != "default"
            let paper = hasCustomPaper ? theme.paper : "#fcfbf7"
            let ink = (desc.inkColor != "auto" && !desc.inkColor.isEmpty) ? desc.inkColor : (hasCustomPaper ? theme.ink : "#1f2328")
            let family = font.id != "default" && !font.family.isEmpty
                ? font.family
                : "\"Iowan Old Style\", \"Palatino Linotype\", Georgia, serif"
            let marginPct = desc.pageMargin == "compact" ? "4%" : (desc.pageMargin == "wide" ? "9%" : "6%")
            let payload: [String: Any] = [
                "fontFamily": family,
                "googleFontUrl": font.googleFontUrl ?? "",
                "fontScale": desc.fontScale,
                "lineHeight": desc.lineHeight == "default" ? "1.68" : desc.lineHeight,
                "marginPct": marginPct,
                "paper": paper,
                "ink": ink,
                "isDark": theme.isDark,
                "flow": flow,
                "maxColumns": maxColumns,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                webView.evaluateJavaScript("window.BilingualEpub && window.BilingualEpub.setAppearance(\(json));", completionHandler: nil)
            }
        }

        func pushHighlights(_ highlights: [Highlight]) {
            let epubHls = highlights.compactMap { hl -> [String: String]? in
                guard let anchor = DocumentHighlightAnchor.parse(hl.anchorJson),
                      anchor.kind == "epub",
                      let cfi = anchor.cfi, !cfi.isEmpty else { return nil }
                return [
                    "id": hl.id,
                    "cfi": cfi,
                    "color": hl.color,
                    "text": hl.text,
                    "note": hl.note ?? "",
                ]
            }
            let key = epubHls.map { "\($0["id"] ?? ""):\($0["color"] ?? ""):\($0["cfi"] ?? "")" }.joined(separator: "|")
            guard key != lastHighlightsKey, let webView else { return }
            lastHighlightsKey = key
            if let data = try? JSONSerialization.data(withJSONObject: epubHls),
               let json = String(data: data, encoding: .utf8) {
                webView.evaluateJavaScript("window.BilingualEpub && window.BilingualEpub.setHighlights(\(json));", completionHandler: nil)
            }
        }
    }
}

// MARK: - Main Apple Books-style PDF & EPUB Reader View for macOS

struct DocumentReaderViewMac: View {
    let book: Book
    let onClose: () -> Void

    @ObservedObject private var api = APIService.shared
    @ObservedObject private var backup = BackupManager.shared

    private var isPdf: Bool { book.resolvedFormat == "pdf" }
    private var isEpub: Bool { book.resolvedFormat == "epub" }

    // Loading & Document State
    @State private var isLoading: Bool = true
    @State private var loadError: String?
    @State private var pdfDocument: PDFDocument?
    @State private var localEpubURL: URL?
    @State private var epubWebView: WKWebView?

    // Navigation & Progress
    @State private var currentPage: Int = 1
    @State private var totalPages: Int = 1
    @State private var progression: Double = 0
    @State private var currentCfi: String = ""
    @State private var initialCfi: String?
    @State private var currentChapterTitle: String = ""
    @State private var currentVisibleText: String = ""
    @State private var didUserNavigate: Bool = false

    // Apple Books Presentation Controls
    @State private var pdfLayout: PdfDisplayLayoutMac = .single
    @State private var pdfFilter: PdfFilterModeMac = .original
    @State private var pdfZoomTrigger: Int = 0
    @State private var pdfZoomDelta: CGFloat = 0
    @State private var pdfFitMode: String = "fit"

    @State private var epubFlow: String = "paginated"
    @State private var epubTwoColumn: Bool = true

    // Appearance (EPUB)
    @State private var selectedFontId: String = "default"
    @State private var selectedThemeId: String = "default"
    @State private var showAppearancePopover: Bool = false
    @State private var isSavingAppearanceDefault: Bool = false

    // Sidebars (TOC/Search, Highlights, AI Chat)
    @State private var showTocSidebar: Bool = false
    @State private var tocItems: [DocTocItemMac] = []
    @State private var tocTab: Int = 0 // 0: TOC, 1: Search (EPUB)
    @State private var searchQuery: String = ""
    @State private var searchResults: [DocSearchHitMac] = []
    @State private var showHighlightsSidebar: Bool = false
    @State private var showChatSidebar: Bool = false

    // Highlights, Selection & Voca
    @State private var highlights: [Highlight] = []
    @State private var selectedText: String = ""
    @State private var selectedPage: Int = 1
    @State private var selectedPdfRects: [NormalizedPdfRect] = []
    @State private var selectedEpubCfi: String = ""
    @State private var editingHighlight: Highlight?
    @State private var showNotePopover: Bool = false
    @State private var noteDraft: String = ""
    @State private var noteDraftColor: String = "#fde68a"

    @State private var vocaLookupWord: String?
    @State private var vocaLookupResult: VocaLookupResult?
    @State private var vocaLookupError: String?
    @State private var isLookingUpVoca: Bool = false
    @State private var isCreatingVocaCard: Bool = false

    // AI Companion Chat
    @State private var chatMessages: [ChatMessage] = []
    @State private var chatInput: String = ""
    @State private var isSendingChat: Bool = false
    @State private var pdfContextGetter: (() -> (pageText: String, selectedText: String))?
    @State private var isBookFinished: Bool = false

    private let highlightColors: [(name: String, hex: String)] = [
        ("Vàng", "#fde68a"),
        ("Xanh dương", "#93c5fd"),
        ("Hồng", "#f9a8d4"),
        ("Xanh lá", "#86efac"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            readerHeader

            HStack(spacing: 0) {
                if showTocSidebar {
                    tocDrawer
                        .frame(width: 280)
                    Divider().background(Color.white.opacity(0.1))
                }

                // Main Reading Canvas
                ZStack(alignment: .bottom) {
                    readerCanvas

                    if !selectedText.isEmpty || editingHighlight != nil {
                        selectionActionBar
                            .padding(.bottom, 52)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if vocaLookupWord != nil {
                        vocaCardOverlay
                            .padding(.bottom, 54)
                            .transition(.scale(scale: 0.95).combined(with: .opacity))
                    }

                    if isLoading {
                        VStack(spacing: 12) {
                            ProgressView().tint(.white)
                            Text("Đang mở sách \(book.resolvedFormat.uppercased())…")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(hex: "0f172a").opacity(0.85))
                    } else if let loadError {
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title2)
                                .foregroundStyle(Color(hex: "f59e0b"))
                            Text("Không thể mở sách").font(.headline).foregroundStyle(.white)
                            Text(loadError).font(.caption).foregroundStyle(Color(hex: "94a3b8"))
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(hex: "0f172a"))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showHighlightsSidebar {
                    Divider().background(Color.white.opacity(0.1))
                    highlightsPanel
                        .frame(width: 300)
                }

                if showChatSidebar {
                    Divider().background(Color.white.opacity(0.1))
                    chatPanel
                        .frame(width: 350)
                }
            }

            bottomScrubberBar
        }
        .background(Color(hex: "0f172a"))
        .popover(isPresented: $showNotePopover, arrowEdge: .bottom) {
            noteEditorPopover
        }
        .task {
            await initializeDocument()
        }
    }

    // MARK: - Header

    private var readerHeader: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Label("Thư viện", systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.bordered)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showTocSidebar.toggle() }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.bordered)
            .help("Mục lục\(isEpub ? " & Tìm kiếm" : "")")

            VStack(alignment: .leading, spacing: 1) {
                Text(book.title)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(currentChapterTitle.isEmpty ? book.resolvedFormat.uppercased() : currentChapterTitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "94a3b8"))
                    .lineLimit(1)
            }

            Spacer()

            // Page / Navigation Controls
            HStack(spacing: 6) {
                Button { stepPage(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.bordered)
                Text(isEpub ? "\(Int(round(progression * 100)))%" : "\(currentPage) / \(totalPages)")
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(minWidth: 64)
                Button { stepPage(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.bordered)
            }

            if isPdf {
                Picker("", selection: $pdfLayout) {
                    ForEach(PdfDisplayLayoutMac.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)

                Picker("", selection: $pdfFilter) {
                    ForEach(PdfFilterModeMac.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 140)

                HStack(spacing: 4) {
                    Button {
                        pdfFitMode = "custom"; pdfZoomDelta = -0.15; pdfZoomTrigger += 1
                    } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.bordered)
                    Button {
                        pdfFitMode = "fit"; pdfZoomDelta = 0; pdfZoomTrigger += 1
                    } label: { Text("Fit").font(.caption.weight(.semibold)) }
                    .buttonStyle(.bordered)
                    Button {
                        pdfFitMode = "custom"; pdfZoomDelta = 0.15; pdfZoomTrigger += 1
                    } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.bordered)
                }
            } else if isEpub {
                Picker("", selection: $epubFlow) {
                    Text("Lật trang").tag("paginated")
                    Text("Cuộn dọc").tag("scrolled")
                }
                .pickerStyle(.segmented)
                .frame(width: 150)

                if epubFlow == "paginated" {
                    Button {
                        epubTwoColumn.toggle()
                    } label: {
                        Image(systemName: epubTwoColumn ? "book.fill" : "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .help(epubTwoColumn ? "2 trang mở" : "1 trang")
                }

                Button {
                    showAppearancePopover.toggle()
                } label: {
                    Text("Aa").font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(.bordered)
                .popover(isPresented: $showAppearancePopover, arrowEdge: .bottom) {
                    ReaderAppearancePopoverMac(
                        effectiveFontId: selectedFontId,
                        effectiveThemeId: selectedThemeId,
                        bookDefaultFontId: ReaderAppearance.getFont(book.defaultFont).id,
                        bookDefaultThemeId: ReaderAppearance.serializeThemeDescriptor(
                            ReaderAppearance.parseThemeDescriptor(book.defaultTheme)
                        ),
                        hasUserOverride: selectedFontId != (book.defaultFont ?? "default") || selectedThemeId != (book.defaultTheme ?? "default"),
                        isSavingDefault: isSavingAppearanceDefault,
                        onSelectFont: { fontId in
                            selectedFontId = fontId
                            persistAppearanceOverride()
                        },
                        onSelectTheme: { themeId in
                            selectedThemeId = themeId
                            persistAppearanceOverride()
                        },
                        onResetToBookDefault: {
                            selectedFontId = ReaderAppearance.getFont(book.defaultFont).id
                            selectedThemeId = ReaderAppearance.serializeThemeDescriptor(
                                ReaderAppearance.parseThemeDescriptor(book.defaultTheme)
                            )
                            Task {
                                await api.updateBookState(slug: book.slug, readerFont: "", readerTheme: "")
                            }
                        },
                        onSaveAsBookDefault: {
                            isSavingAppearanceDefault = true
                            Task {
                                _ = await api.updateBookAppearanceDefaults(
                                    slug: book.slug,
                                    defaultFont: selectedFontId,
                                    defaultTheme: selectedThemeId
                                )
                                await MainActor.run { isSavingAppearanceDefault = false }
                            }
                        },
                        onClose: { showAppearancePopover = false }
                    )
                }
            }

            Button {
                let next = !isBookFinished
                isBookFinished = next
                Task { await api.updateBookState(slug: book.slug, isFinished: next) }
            } label: {
                Image(systemName: isBookFinished ? "checkmark.circle.fill" : "checkmark.circle")
                    .foregroundStyle(isBookFinished ? Color(hex: "22c55e") : .white)
            }
            .buttonStyle(.bordered)
            .help(isBookFinished ? "Đã hoàn thành" : "Đánh dấu hoàn thành")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showHighlightsSidebar.toggle()
                    if showHighlightsSidebar { showChatSidebar = false }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "highlighter")
                    if !highlights.isEmpty {
                        Text("\(highlights.count)").font(.caption2.bold())
                    }
                }
            }
            .buttonStyle(.bordered)
            .help("Ghi chú & Đánh dấu")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showChatSidebar.toggle()
                    if showChatSidebar { showHighlightsSidebar = false }
                }
            } label: {
                Image(systemName: "bubble.left.and.text.bubble.right")
            }
            .buttonStyle(.bordered)
            .help("Hỏi AI theo ngữ cảnh trang")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(hex: "111827"))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.white.opacity(0.08)), alignment: .bottom)
    }

    // MARK: - Main Reader Canvas

    @ViewBuilder
    private var readerCanvas: some View {
        if isPdf {
            NativePDFViewMac(
                document: pdfDocument,
                targetPage: currentPage,
                displayLayout: pdfLayout,
                zoomTrigger: pdfZoomTrigger,
                zoomDelta: pdfZoomDelta,
                fitMode: pdfFitMode,
                highlights: highlights,
                onPageChanged: { newPage in
                    currentPage = newPage
                    progression = totalPages > 0 ? Double(newPage) / Double(totalPages) : 0
                    didUserNavigate = true
                    saveCurrentProgress()
                },
                onSelectionChanged: { text, pageNum, rects in
                    selectedText = text
                    selectedPage = pageNum
                    selectedPdfRects = rects
                    if !text.isEmpty { editingHighlight = nil }
                },
                onContextProviderReady: { getter in
                    self.pdfContextGetter = getter
                }
            )
            .colorMultiply(pdfFilter == .warm ? Color(red: 0.98, green: 0.94, blue: 0.85) : .white)
            .colorInvert(enabled: pdfFilter == .dark)
        } else {
            NativeEpubWebViewMac(
                epubFileURL: localEpubURL,
                initialCfi: initialCfi,
                estimatedTotalPages: max(1, book.pageCount ?? 1),
                fontId: selectedFontId,
                themeId: selectedThemeId,
                flowMode: epubFlow,
                maxColumns: epubTwoColumn && epubFlow == "paginated" ? 2 : 1,
                highlights: highlights,
                onWebViewReady: { wv in self.epubWebView = wv },
                onReady: { items in
                    self.tocItems = items
                    self.isLoading = false
                },
                onRelocate: { cfi, frac, page, total, chapter, visibleText in
                    self.currentCfi = cfi
                    self.progression = frac
                    self.currentPage = page
                    self.totalPages = total
                    if !chapter.isEmpty { self.currentChapterTitle = chapter }
                    if !visibleText.isEmpty { self.currentVisibleText = visibleText }
                    if didUserNavigate {
                        saveCurrentProgress()
                    } else {
                        didUserNavigate = true
                    }
                },
                onTextSelected: { cfi, text, chapter, page in
                    self.selectedEpubCfi = cfi
                    self.selectedText = text
                    self.selectedPage = page
                    if !chapter.isEmpty { self.currentChapterTitle = chapter }
                    self.editingHighlight = nil
                },
                onHighlightClicked: { hlId in
                    if let found = highlights.first(where: { $0.id == hlId }) {
                        self.editingHighlight = found
                        self.selectedText = found.text
                    }
                },
                onSelectionCleared: {
                    if editingHighlight == nil {
                        self.selectedText = ""
                        self.selectedEpubCfi = ""
                    }
                },
                onSearchResults: { hits in self.searchResults = hits },
                onError: { msg in
                    self.loadError = msg
                    self.isLoading = false
                }
            )
        }
    }

    // MARK: - Floating Selection / Highlight / Voca Action Bar

    private var selectionActionBar: some View {
        HStack(spacing: 10) {
            ForEach(highlightColors, id: \.hex) { c in
                Button {
                    applyHighlight(color: c.hex, note: editingHighlight?.note ?? "")
                } label: {
                    Circle()
                        .fill(Color(hex: c.hex))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Highlight màu \(c.name)")
            }

            Divider().frame(height: 18)

            Button {
                noteDraft = editingHighlight?.note ?? ""
                noteDraftColor = editingHighlight?.color ?? "#fde68a"
                showNotePopover = true
            } label: {
                Label("Ghi chú", systemImage: "square.and.pencil")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)

            Button {
                lookupSelectedWordInVoca()
            } label: {
                Label("Tra Voca", systemImage: "character.book.closed")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)

            Button {
                showChatSidebar = true
                showHighlightsSidebar = false
                chatInput = "Giải thích đoạn này giúp mình: \"\(selectedText.prefix(240))\""
            } label: {
                Label("Hỏi AI", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)

            if let editHl = editingHighlight {
                Button(role: .destructive) {
                    deleteHighlight(editHl)
                    editingHighlight = nil
                    selectedText = ""
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }

            Button {
                editingHighlight = nil
                selectedText = ""
                selectedEpubCfi = ""
                selectedPdfRects = []
                epubWebView?.evaluateJavaScript("window.BilingualEpub && window.BilingualEpub.clearSelection();", completionHandler: nil)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    private var noteEditorPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ghi chú đánh dấu").font(.headline)
            TextEditor(text: $noteDraft)
                .frame(width: 260, height: 110)
                .font(.body)
                .padding(6)
                .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Huỷ") { showNotePopover = false }
                Button("Lưu") {
                    applyHighlight(color: noteDraftColor, note: noteDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                    showNotePopover = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }

    // MARK: - Native Voca Lookup Overlay

    private var vocaCardOverlay: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(vocaLookupWord ?? "")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    vocaLookupWord = nil
                    vocaLookupResult = nil
                    vocaLookupError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isLookingUpVoca {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Đang tra từ điển Voca…").font(.caption).foregroundStyle(Color(hex: "94a3b8"))
                }
            } else if let err = vocaLookupError {
                Text(err).font(.caption).foregroundStyle(Color(hex: "f87171"))
            } else if let result = vocaLookupResult, let card = result.resolvedCards.first {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if !card.displayIpa.isEmpty {
                            Text(card.displayIpa).font(.caption.monospaced()).foregroundStyle(Color(hex: "38bdf8"))
                        }
                        if let pos = card.partOfSpeech, !pos.isEmpty {
                            Text(pos).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.white.opacity(0.1), in: Capsule())
                        }
                        Spacer()
                        Button {
                            Task { try? await VocaService.playAudio(slug: card.slug) }
                        } label: {
                            Image(systemName: "speaker.wave.2.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                    Text(card.displayMeaning)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                    if let ex = card.examples?.first, !ex.isEmpty {
                        Text("“\(ex)”")
                            .font(.caption)
                            .italic()
                            .foregroundStyle(Color(hex: "cbd5e1"))
                    }
                }
            } else if let word = vocaLookupWord {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Chưa có từ '\(word)' trong sổ Voca của bạn.")
                        .font(.caption)
                        .foregroundStyle(Color(hex: "cbd5e1"))
                    Button {
                        createVocaCard(word: word)
                    } label: {
                        if isCreatingVocaCard {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Tạo thẻ Voca mới", systemImage: "plus.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreatingVocaCard)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(Color(hex: "1e293b"), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    // MARK: - TOC / Search Drawer

    private var tocDrawer: some View {
        VStack(spacing: 0) {
            HStack {
                if isEpub {
                    Picker("", selection: $tocTab) {
                        Text("Mục lục").tag(0)
                        Text("Tìm kiếm").tag(1)
                    }
                    .pickerStyle(.segmented)
                } else {
                    Text("Mục lục PDF").font(.headline).foregroundStyle(.white)
                    Spacer()
                }
            }
            .padding(10)

            Divider().background(Color.white.opacity(0.08))

            if isEpub && tocTab == 1 {
                VStack(spacing: 8) {
                    HStack {
                        TextField("Tìm trong sách…", text: $searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { runEpubSearch() }
                        Button("Tìm") { runEpubSearch() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding([.horizontal, .top], 10)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(searchResults) { hit in
                                Button {
                                    jumpToEpubTarget(hit.cfi)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        if !hit.label.isEmpty {
                                            Text(hit.label).font(.caption2).foregroundStyle(Color(hex: "38bdf8"))
                                        }
                                        Text("\(hit.pre)\(hit.match)\(hit.post)")
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.9))
                                            .lineLimit(3)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(10)
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if tocItems.isEmpty {
                            Text("Tài liệu này chưa có mục lục.")
                                .font(.caption)
                                .foregroundStyle(Color(hex: "94a3b8"))
                                .padding(16)
                        } else {
                            ForEach(tocItems) { item in
                                Button {
                                    if let p = item.page {
                                        goToPdfPage(p)
                                    } else if let href = item.href {
                                        jumpToEpubTarget(href)
                                    }
                                } label: {
                                    HStack {
                                        Text(item.label)
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .lineLimit(2)
                                            .padding(.leading, CGFloat(min(item.level, 4) * 12))
                                        Spacer()
                                        if let p = item.page {
                                            Text("\(p)")
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(Color(hex: "94a3b8"))
                                        }
                                    }
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 8)
                                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color(hex: "111827"))
    }

    // MARK: - Highlights Sidebar

    private var highlightsPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ghi chú & Đánh dấu (\(highlights.count))")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Spacer()
                Button { showHighlightsSidebar = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider().background(Color.white.opacity(0.08))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if highlights.isEmpty {
                        Text("Bôi đen văn bản bất kỳ để highlight, ghi chú hoặc tra từ Voca.")
                            .font(.caption)
                            .foregroundStyle(Color(hex: "94a3b8"))
                            .padding(14)
                    } else {
                        ForEach(highlights.sorted { $0.page < $1.page }) { hl in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Circle().fill(Color(hex: hl.color)).frame(width: 10, height: 10)
                                    Text("Trang \(hl.page)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(Color(hex: "94a3b8"))
                                    Spacer()
                                    Button(role: .destructive) {
                                        deleteHighlight(hl)
                                    } label: {
                                        Image(systemName: "trash").font(.caption2)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Color(hex: "f87171"))
                                }
                                Text("“\(hl.text)”")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                                    .lineLimit(4)
                                if let note = hl.note, !note.isEmpty {
                                    Text(note)
                                        .font(.caption)
                                        .foregroundStyle(Color(hex: "fde68a"))
                                }
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                            .onTapGesture {
                                if isPdf {
                                    goToPdfPage(hl.page)
                                } else if let anchor = DocumentHighlightAnchor.parse(hl.anchorJson),
                                          let cfi = anchor.cfi {
                                    jumpToEpubTarget(cfi)
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Color(hex: "111827"))
    }

    // MARK: - AI Companion Chat Sidebar

    private var chatPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Companion AI", systemImage: "sparkles")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Spacer()
                if !chatMessages.isEmpty {
                    Button { chatMessages.removeAll() } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Button { showChatSidebar = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider().background(Color.white.opacity(0.08))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chatMessages.isEmpty {
                        Button("📝 Tóm tắt trang đang đọc") {
                            sendChatPrompt("Tóm tắt nội dung trang đang đọc một cách súc tích, dễ nhớ.")
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 8)
                    }
                    ForEach(chatMessages) { msg in
                        Text(msg.content)
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: msg.role == "user" ? .trailing : .leading)
                            .background(
                                msg.role == "user" ? Color(hex: "2563eb").opacity(0.55) : Color.white.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                    }
                    if isSendingChat {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("AI đang trả lời…").font(.caption).foregroundStyle(Color(hex: "94a3b8"))
                        }
                    }
                }
                .padding(12)
            }

            Divider().background(Color.white.opacity(0.08))

            HStack(spacing: 8) {
                TextField("Hỏi về trang này…", text: $chatInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { sendChatPrompt(chatInput) }
                Button {
                    sendChatPrompt(chatInput)
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSendingChat)
            }
            .padding(10)
        }
        .background(Color(hex: "111827"))
    }

    // MARK: - Bottom Scrubber Bar

    private var bottomScrubberBar: some View {
        HStack(spacing: 12) {
            Text(currentChapterTitle.isEmpty ? book.title : currentChapterTitle)
                .font(.caption)
                .foregroundStyle(Color(hex: "94a3b8"))
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)

            if isPdf {
                Slider(
                    value: Binding(
                        get: { Double(currentPage) },
                        set: { goToPdfPage(Int(round($0))) }
                    ),
                    in: 1...Double(max(1, totalPages))
                )
            } else {
                Slider(
                    value: Binding(
                        get: { progression },
                        set: { newFrac in
                            progression = newFrac
                            didUserNavigate = true
                            epubWebView?.evaluateJavaScript(
                                "window.BilingualEpub && window.BilingualEpub.goToFraction(\(newFrac));",
                                completionHandler: nil
                            )
                        }
                    ),
                    in: 0...1
                )
            }

            Text(isPdf ? "Trang \(currentPage)/\(totalPages)" : "\(Int(round(progression * 100)))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color(hex: "cbd5e1"))
                .frame(minWidth: 84, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(hex: "111827"))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.white.opacity(0.08)), alignment: .top)
    }

    // MARK: - Logic & Persistence

    private func initializeDocument() async {
        isLoading = true
        loadError = nil
        isBookFinished = book.isFinished == true
        totalPages = max(1, book.pageCount ?? 1)
        selectedFontId = (book.readerFont?.isEmpty == false ? book.readerFont! : book.defaultFont) ?? "default"
        selectedThemeId = (book.readerTheme?.isEmpty == false ? book.readerTheme! : book.defaultTheme) ?? "default"

        // 1. Resolve local vs server reading progress
        var resolvedProgress: ReadingProgress?
        if let localData = UserDefaults.standard.data(forKey: "progress_\(book.slug)"),
           let localProg = try? JSONDecoder().decode(ReadingProgress.self, from: localData) {
            resolvedProgress = localProg
        }
        if !api.isOfflineMode, let serverProg = await api.fetchReadingProgress(slug: book.slug) {
            let localTs = resolvedProgress?.lastRead ?? 0
            let serverTs = serverProg.lastRead ?? 0
            if serverTs >= localTs {
                resolvedProgress = serverProg
            }
        } else if let uname = api.currentUser?.username,
                  let offlineProg = backup.offlineProgress(forUsername: uname, slug: book.slug) {
            let localTs = resolvedProgress?.lastRead ?? 0
            if (offlineProg.lastRead ?? 0) >= localTs {
                resolvedProgress = offlineProg
            }
        }

        if let prog = resolvedProgress {
            currentPage = max(1, prog.page)
            progression = prog.progression ?? (Double(currentPage) / Double(max(1, totalPages)))
            if let loc = prog.locator, !loc.isEmpty {
                initialCfi = loc
                currentCfi = loc
            }
        }

        // 2. Load highlights (server or offline vault)
        if !api.isOfflineMode {
            await api.fetchHighlights(slug: book.slug)
            highlights = api.highlights
        } else if let uname = api.currentUser?.username {
            highlights = backup.offlineHighlights(forUsername: uname, slug: book.slug)
        }

        // 3. Locate or download source file (.pdf / .epub)
        let fmt = book.resolvedFormat
        let vaultFile = backup.localSourceURL(slug: book.slug, format: fmt)
        var resolvedFileURL: URL?

        if FileManager.default.fileExists(atPath: vaultFile.path) {
            resolvedFileURL = vaultFile
        } else if !api.isOfflineMode {
            do {
                let data = try await api.fetchBookSourceData(slug: book.slug)
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(book.slug).\(fmt)")
                try data.write(to: tmp, options: .atomic)
                resolvedFileURL = tmp
            } catch {
                loadError = "Không tải được tệp sách: \(error.localizedDescription)"
                isLoading = false
                return
            }
        } else {
            loadError = "Sách chưa được đồng bộ vào Mac Backup Vault để đọc ngoại tuyến."
            isLoading = false
            return
        }

        guard let fileURL = resolvedFileURL else {
            loadError = "Không tìm thấy tệp nguồn sách."
            isLoading = false
            return
        }

        if isPdf {
            if let doc = PDFDocument(url: fileURL) {
                pdfDocument = doc
                totalPages = max(1, doc.pageCount)
                currentPage = max(1, min(totalPages, currentPage))
                tocItems = extractPdfOutline(from: doc)
                isLoading = false
            } else {
                loadError = "Tệp PDF không hợp lệ hoặc bị hỏng."
                isLoading = false
            }
        } else {
            localEpubURL = fileURL
        }
    }

    private func extractPdfOutline(from doc: PDFDocument) -> [DocTocItemMac] {
        guard let root = doc.outlineRoot else { return [] }
        var out: [DocTocItemMac] = []
        func walk(_ node: PDFOutline, level: Int) {
            for i in 0..<node.numberOfChildren {
                guard out.count < 600, let child = node.child(at: i) else { break }
                let pageNum = child.destination?.page.map { doc.index(for: $0) + 1 }
                out.append(DocTocItemMac(
                    id: "\(out.count)-\(child.label ?? "")",
                    label: child.label ?? "Mục \(out.count + 1)",
                    level: level,
                    page: pageNum,
                    href: nil
                ))
                walk(child, level: level + 1)
            }
        }
        walk(root, level: 0)
        return out
    }

    private func stepPage(_ delta: Int) {
        didUserNavigate = true
        if isPdf {
            let step = pdfLayout == .twoUp ? delta * 2 : delta
            goToPdfPage(currentPage + step)
        } else {
            let fn = delta > 0 ? "next" : "prev"
            epubWebView?.evaluateJavaScript("window.BilingualEpub && window.BilingualEpub.\(fn)();", completionHandler: nil)
        }
    }

    private func goToPdfPage(_ target: Int) {
        let clamped = max(1, min(totalPages, target))
        didUserNavigate = true
        currentPage = clamped
        progression = totalPages > 0 ? Double(clamped) / Double(totalPages) : 0
        saveCurrentProgress()
    }

    private func jumpToEpubTarget(_ target: String) {
        didUserNavigate = true
        let escaped = target.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        epubWebView?.evaluateJavaScript("window.BilingualEpub && window.BilingualEpub.goTo('\(escaped)');", completionHandler: nil)
    }

    private func runEpubSearch() {
        let escaped = searchQuery.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        epubWebView?.evaluateJavaScript("window.BilingualEpub && window.BilingualEpub.search('\(escaped)');", completionHandler: nil)
    }

    private func saveCurrentProgress() {
        let now = Int(Date().timeIntervalSince1970)
        let slug = book.slug
        let p = currentPage
        let loc = isEpub ? currentCfi : nil
        let frac = progression
        Task {
            await api.saveReadingProgress(
                slug: slug,
                page: p,
                viewMode: "en",
                lastRead: now,
                locator: loc,
                progression: frac
            )
        }
    }

    private func persistAppearanceOverride() {
        let f = selectedFontId
        let t = selectedThemeId
        Task {
            await api.updateBookState(slug: book.slug, readerFont: f, readerTheme: t)
        }
    }

    private func applyHighlight(color: String, note: String) {
        if var existing = editingHighlight {
            existing.color = color
            existing.note = note
            if let idx = highlights.firstIndex(where: { $0.id == existing.id }) {
                highlights[idx] = existing
            }
            editingHighlight = nil
            selectedText = ""
            Task { await api.saveHighlight(slug: book.slug, highlight: existing) }
            return
        }

        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let anchorJson: String
        let lang: String
        if isPdf {
            guard !selectedPdfRects.isEmpty else { return }
            anchorJson = DocumentHighlightAnchor.encodePdf(rects: selectedPdfRects)
            lang = "pdf"
        } else {
            guard !selectedEpubCfi.isEmpty else { return }
            anchorJson = DocumentHighlightAnchor.encodeEpub(cfi: selectedEpubCfi, chapterTitle: currentChapterTitle)
            lang = "epub"
        }

        let newHl = Highlight(
            id: "hl-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))",
            page: selectedPage,
            lang: lang,
            color: color,
            text: trimmed,
            startOffset: 0,
            endOffset: trimmed.count,
            paragraphIndex: 0,
            anchorJson: anchorJson,
            note: note,
            createdAt: Int(Date().timeIntervalSince1970)
        )
        highlights.append(newHl)
        selectedText = ""
        selectedPdfRects = []
        selectedEpubCfi = ""
        epubWebView?.evaluateJavaScript("window.BilingualEpub && window.BilingualEpub.clearSelection();", completionHandler: nil)
        Task { await api.saveHighlight(slug: book.slug, highlight: newHl) }
    }

    private func deleteHighlight(_ hl: Highlight) {
        highlights.removeAll { $0.id == hl.id }
        Task { await api.deleteHighlight(slug: book.slug, id: hl.id) }
    }

    private func lookupSelectedWordInVoca() {
        let word = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        vocaLookupWord = word
        vocaLookupResult = nil
        vocaLookupError = nil
        isLookingUpVoca = true
        Task {
            do {
                let res = try await VocaService.lookupWord(word)
                await MainActor.run {
                    vocaLookupResult = res
                    isLookingUpVoca = false
                }
            } catch {
                await MainActor.run {
                    vocaLookupError = error.localizedDescription
                    isLookingUpVoca = false
                }
            }
        }
    }

    private func createVocaCard(word: String) {
        isCreatingVocaCard = true
        Task {
            do {
                let card = try await VocaService.addWordToVoca(word)
                await MainActor.run {
                    vocaLookupResult = VocaLookupResult(found: true, word: word, matchType: "exact", card: card, cards: [card])
                    isCreatingVocaCard = false
                }
            } catch {
                await MainActor.run {
                    vocaLookupError = error.localizedDescription
                    isCreatingVocaCard = false
                }
            }
        }
    }

    private func sendChatPrompt(_ rawPrompt: String) {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSendingChat else { return }
        chatInput = ""
        chatMessages.append(ChatMessage(role: "user", content: prompt))
        isSendingChat = true

        let pageContext: String
        let selContext: String
        if isPdf, let ctx = pdfContextGetter?() {
            pageContext = ctx.pageText
            selContext = ctx.selectedText.isEmpty ? selectedText : ctx.selectedText
        } else {
            pageContext = currentVisibleText
            selContext = selectedText
        }

        let sysPrompt = """
        You are Companion Reader Agent for the book "\(book.title)" by \(book.author ?? "Unknown") (\(book.resolvedFormat.uppercased())).
        Current location: \(isPdf ? "Page \(currentPage)/\(totalPages)" : "\(currentChapterTitle) (\(Int(round(progression * 100)))%)").

        SELECTED TEXT:
        \(selContext.isEmpty ? "None" : selContext)

        CURRENT PAGE CONTEXT:
        \(pageContext.isEmpty ? "Unavailable" : String(pageContext.prefix(4000)))

        Answer concisely in Vietnamese by default unless asked otherwise. Stay grounded in the page context.
        """

        var payload: [[String: String]] = [["role": "system", "content": sysPrompt]]
        for m in chatMessages.suffix(12) {
            payload.append(["role": m.role, "content": m.content])
        }

        let baseURL = UserDefaults.standard.string(forKey: "aiBaseUrl") ?? "https://api.openai.com/v1"
        let model = UserDefaults.standard.string(forKey: "aiModel") ?? "gpt-4o-mini"

        Task {
            do {
                let reply = try await api.sendChat(baseURL: baseURL, apiKey: "", model: model, messages: payload)
                await MainActor.run {
                    chatMessages.append(ChatMessage(role: "assistant", content: reply))
                    isSendingChat = false
                }
            } catch {
                await MainActor.run {
                    chatMessages.append(ChatMessage(role: "assistant", content: "Lỗi AI: \(error.localizedDescription)"))
                    isSendingChat = false
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func colorInvert(enabled: Bool) -> some View {
        if enabled {
            self.colorInvert()
        } else {
            self
        }
    }
}
