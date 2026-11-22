import SwiftUI
import UIKit
import PDFKit
import WebKit

// MARK: - Same-Origin Local Scheme Handler for Offline EPUB + foliate-js Runtime (iOS/iPadOS)

final class LocalEpubSchemeHandlerIOS: NSObject, WKURLSchemeHandler {
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

// MARK: - Shared Types for iOS Document Reader

private struct DocTocItemIOS: Identifiable, Equatable {
    let id: String
    let label: String
    let level: Int
    let page: Int?
    let href: String?
}

private struct DocSearchHitIOS: Identifiable, Equatable {
    let id = UUID()
    let cfi: String
    let label: String
    let pre: String
    let match: String
    let post: String
}

private struct DocChatMessageIOS: Identifiable, Equatable {
    let id = UUID()
    let role: String
    let content: String
}

private enum PdfModeIOS: String, CaseIterable {
    case paged = "Lật trang"
    case scroll = "Cuộn dọc"
    case twoUp = "2 trang"
}

private enum PdfFilterIOS: String, CaseIterable {
    case original = "Gốc"
    case warm = "Ấm"
    case dark = "Đêm"
}

// MARK: - Native PDFKit Wrapper (Apple Books PDF Engine on iOS/iPadOS)

private struct NativePDFViewIOS: UIViewRepresentable {
    let document: PDFDocument?
    let targetPage: Int
    let mode: PdfModeIOS
    let highlights: [Highlight]
    let onPageChanged: (Int) -> Void
    let onSelectionChanged: (String, Int, [NormalizedPdfRect]) -> Void
    let onTapCenter: () -> Void
    let onContextProviderReady: (@escaping () -> (pageText: String, selectedText: String)) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = UIColor(red: 0.08, green: 0.1, blue: 0.14, alpha: 1.0)
        context.coordinator.attach(to: pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.parent = self

        if pdfView.document !== document {
            pdfView.document = document
            context.coordinator.lastSyncedPage = 0
            context.coordinator.lastAppliedHighlightsSig = ""
        }

        if context.coordinator.lastAppliedMode != mode {
            context.coordinator.lastAppliedMode = mode
            switch mode {
            case .paged:
                pdfView.displayDirection = .horizontal
                pdfView.displayMode = .singlePage
                pdfView.usePageViewController(true, withViewOptions: nil)
            case .scroll:
                pdfView.usePageViewController(false, withViewOptions: nil)
                pdfView.displayDirection = .vertical
                pdfView.displayMode = .singlePageContinuous
            case .twoUp:
                pdfView.usePageViewController(false, withViewOptions: nil)
                pdfView.displayDirection = .horizontal
                pdfView.displayMode = .twoUp
            }
            pdfView.autoScales = true
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

        context.coordinator.syncHighlights(in: pdfView, highlights: highlights)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: NativePDFViewIOS
        weak var pdfView: PDFView?
        var lastSyncedPage: Int = 0
        var lastAppliedMode: PdfModeIOS?
        var isProgrammaticNav = false
        var lastAppliedHighlightsSig = ""

        init(_ parent: NativePDFViewIOS) {
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

            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = self
            tap.cancelsTouchesInView = false
            view.addGestureRecognizer(tap)

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

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc private func handleTap(_ gr: UITapGestureRecognizer) {
            guard let pv = pdfView else { return }
            if let sel = pv.currentSelection, !(sel.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
                return
            }
            let loc = gr.location(in: pv)
            let ratio = loc.x / max(pv.bounds.width, 1)
            if ratio > 0.25 && ratio < 0.75 {
                DispatchQueue.main.async {
                    self.parent.onTapCenter()
                }
            }
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
            var rects: [NormalizedPdfRect] = []
            for line in sel.selectionsByLine() {
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

        func syncHighlights(in pv: PDFView, highlights: [Highlight]) {
            guard let doc = pv.document else { return }
            let sig = highlights.map { "\($0.id):\($0.color):\($0.page):\($0.anchorJson ?? "")" }.joined(separator: "|")
            guard sig != lastAppliedHighlightsSig else { return }
            lastAppliedHighlightsSig = sig

            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                for ann in page.annotations where ann.userName == "bilingual_reader_hl" {
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
                let color = uiColorFromHex(hl.color).withAlphaComponent(0.38)
                for r in rects {
                    let x = pageBounds.minX + CGFloat(r.x) * pageBounds.width
                    let w = CGFloat(r.w) * pageBounds.width
                    let h = CGFloat(r.h) * pageBounds.height
                    let y = pageBounds.minY + CGFloat(1.0 - r.y - r.h) * pageBounds.height
                    let ann = PDFAnnotation(bounds: CGRect(x: x, y: y, width: w, height: h), forType: .highlight, withProperties: nil)
                    ann.color = color
                    ann.contents = hl.note
                    ann.userName = "bilingual_reader_hl"
                    page.addAnnotation(ann)
                }
            }
        }

        private func uiColorFromHex(_ hex: String) -> UIColor {
            let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            var int: UInt64 = 0
            Scanner(string: cleaned).scanHexInt64(&int)
            let r = CGFloat((int >> 16) & 0xFF) / 255.0
            let g = CGFloat((int >> 8) & 0xFF) / 255.0
            let b = CGFloat(int & 0xFF) / 255.0
            return UIColor(red: r, green: g, blue: b, alpha: 1.0)
        }
    }
}

// MARK: - Native WKWebView Wrapper for Offline foliate-js EPUB Engine (iOS/iPadOS)

private struct NativeEpubWebViewIOS: UIViewRepresentable {
    let epubFileURL: URL?
    let initialCfi: String?
    let estimatedTotalPages: Int
    let fontId: String
    let themeId: String
    let flowMode: String
    let maxColumns: Int
    let highlights: [Highlight]
    let onWebViewReady: (WKWebView) -> Void
    let onReady: ([DocTocItemIOS]) -> Void
    let onRelocate: (String, Double, Int, Int, String, String) -> Void
    let onTextSelected: (String, String, String, Int) -> Void
    let onHighlightClicked: (String) -> Void
    let onSelectionCleared: () -> Void
    let onTapCenter: () -> Void
    let onSearchResults: ([DocSearchHitIOS]) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: "bkb-epub")
        config.userContentController.add(context.coordinator, name: "epubBridge")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.bounces = false
        context.coordinator.webView = webView
        onWebViewReady(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
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
        var parent: NativeEpubWebViewIOS
        let schemeHandler = LocalEpubSchemeHandlerIOS()
        weak var webView: WKWebView?
        var loadedFileURL: URL?
        var didTriggerOpen = false
        var isRuntimeReady = false
        var lastAppearanceKey = ""
        var lastHighlightsKey = ""

        init(_ parent: NativeEpubWebViewIOS) {
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
                    let items: [DocTocItemIOS] = rawToc.enumerated().map { idx, row in
                        DocTocItemIOS(
                            id: "\(idx)-\(row["href"] as? String ?? "")",
                            label: row["label"] as? String ?? "Chương",
                            level: row["level"] as? Int ?? 0,
                            page: nil,
                            href: row["href"] as? String
                        )
                    }
                    self.parent.onReady(items)

                case "relocate":
                    self.parent.onRelocate(
                        body["cfi"] as? String ?? "",
                        body["fraction"] as? Double ?? 0,
                        body["page"] as? Int ?? 1,
                        body["totalPages"] as? Int ?? max(1, self.parent.estimatedTotalPages),
                        body["chapterTitle"] as? String ?? "",
                        body["visibleText"] as? String ?? ""
                    )

                case "textSelected":
                    self.parent.onTextSelected(
                        body["cfi"] as? String ?? "",
                        body["text"] as? String ?? "",
                        body["chapterTitle"] as? String ?? "",
                        body["page"] as? Int ?? 1
                    )

                case "highlightClicked":
                    if let id = body["id"] as? String {
                        self.parent.onHighlightClicked(id)
                    }

                case "selectionCleared":
                    self.parent.onSelectionCleared()

                case "tapCenter":
                    self.parent.onTapCenter()

                case "searchResults":
                    let arr = body["results"] as? [[String: Any]] ?? []
                    let hits = arr.compactMap { row -> DocSearchHitIOS? in
                        guard let cfi = row["cfi"] as? String else { return nil }
                        return DocSearchHitIOS(
                            cfi: cfi,
                            label: row["label"] as? String ?? "",
                            pre: row["pre"] as? String ?? "",
                            match: row["match"] as? String ?? "",
                            post: row["post"] as? String ?? ""
                        )
                    }
                    self.parent.onSearchResults(hits)

                case "error":
                    self.parent.onError(body["message"] as? String ?? "Không thể mở sách EPUB")

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

// MARK: - Main Apple Books-style PDF & EPUB Reader View for iOS / iPadOS

struct DocumentReaderViewIOS: View {
    let book: Book

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject private var api = APIService.shared
    @ObservedObject private var cacheManager = BookCacheManager.shared

    private var isPdf: Bool { book.resolvedFormat == "pdf" }
    private var isEpub: Bool { book.resolvedFormat == "epub" }

    // Loading & Document State
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var pdfDocument: PDFDocument?
    @State private var localEpubURL: URL?
    @State private var epubWebView: WKWebView?

    // Apple Books Chrome Visibility & Navigation
    @State private var showChrome = true
    @State private var currentPage = 1
    @State private var totalPages = 1
    @State private var progression: Double = 0
    @State private var currentCfi = ""
    @State private var initialCfi: String?
    @State private var currentChapterTitle = ""
    @State private var currentVisibleText = ""
    @State private var didUserNavigate = false

    // Presentation Options
    @State private var pdfMode: PdfModeIOS = .paged
    @State private var pdfFilter: PdfFilterIOS = .original
    @State private var epubFlow = "paginated"
    @State private var selectedFontId = "default"
    @State private var selectedThemeId = "default"
    @State private var isSavingAppearanceDefault = false

    // Sheets
    @State private var showTocSheet = false
    @State private var showAppearanceSheet = false
    @State private var showHighlightsSheet = false
    @State private var showChatSheet = false
    @State private var showNoteSheet = false
    @State private var showVocaSheet = false

    // TOC & Search
    @State private var tocItems: [DocTocItemIOS] = []
    @State private var tocTab = 0
    @State private var searchQuery = ""
    @State private var searchResults: [DocSearchHitIOS] = []

    // Highlights & Selection
    @State private var highlights: [Highlight] = []
    @State private var selectedText = ""
    @State private var selectedPage = 1
    @State private var selectedPdfRects: [NormalizedPdfRect] = []
    @State private var selectedEpubCfi = ""
    @State private var editingHighlight: Highlight?
    @State private var noteDraft = ""
    @State private var noteDraftColor = "#fde68a"

    // Voca State
    @State private var vocaWord = ""
    @State private var vocaResult: VocaLookupResult?
    @State private var vocaError: String?
    @State private var isLookingUpVoca = false
    @State private var isCreatingVocaCard = false

    // AI Chat State
    @State private var chatMessages: [DocChatMessageIOS] = []
    @State private var chatInput = ""
    @State private var isSendingChat = false
    @State private var pdfContextGetter: (() -> (pageText: String, selectedText: String))?
    @State private var isBookFinished = false

    private let highlightColors: [(name: String, hex: String)] = [
        ("Vàng", "#fde68a"),
        ("Xanh dương", "#93c5fd"),
        ("Hồng", "#f9a8d4"),
        ("Xanh lá", "#86efac"),
    ]

    var body: some View {
        ZStack {
            Color(hex: "0f172a").ignoresSafeArea()

            // Main Reading Canvas
            readerCanvas
                .ignoresSafeArea(edges: showChrome ? [] : .all)

            // Apple Books Top & Bottom Chrome
            VStack(spacing: 0) {
                if showChrome {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if !selectedText.isEmpty || editingHighlight != nil {
                    selectionToolbar
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if showChrome {
                    bottomBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            if isLoading {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Đang mở sách \(book.resolvedFormat.uppercased())…")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(hex: "0f172a").opacity(0.88))
            } else if let loadError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundColor(Color(hex: "f59e0b"))
                    Text("Không thể mở sách").font(.headline).foregroundColor(.white)
                    Text(loadError)
                        .font(.subheadline)
                        .foregroundColor(Color(hex: "94a3b8"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                    Button("Quay lại") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(hex: "0f172a"))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showChrome)
        .sheet(isPresented: $showTocSheet) { tocSheetView }
        .sheet(isPresented: $showAppearanceSheet) {
            ReaderAppearancePopoverView(
                effectiveFontId: selectedFontId,
                effectiveThemeId: selectedThemeId,
                bookDefaultFontId: ReaderAppearance.getFont(book.defaultFont).id,
                bookDefaultThemeId: ReaderAppearance.serializeThemeDescriptor(
                    ReaderAppearance.parseThemeDescriptor(book.defaultTheme)
                ),
                hasUserOverride: selectedFontId != (book.defaultFont ?? "default") || selectedThemeId != (book.defaultTheme ?? "default"),
                isSavingDefault: isSavingAppearanceDefault,
                a4Status: ReaderA4Status(
                    appliedFontScale: ReaderAppearance.parseThemeDescriptor(selectedThemeId).fontScale,
                    clampedByA4: false,
                    atMaxA4Scale: false
                ),
                onSelectFont: { fontId in
                    selectedFontId = fontId
                    persistAppearance()
                },
                onSelectTheme: { themeId in
                    selectedThemeId = themeId
                    persistAppearance()
                },
                onResetToBookDefault: {
                    selectedFontId = ReaderAppearance.getFont(book.defaultFont).id
                    selectedThemeId = ReaderAppearance.serializeThemeDescriptor(
                        ReaderAppearance.parseThemeDescriptor(book.defaultTheme)
                    )
                    Task { _ = try? await api.updateBookState(slug: book.slug, patch: ["readerFont": "", "readerTheme": ""]) }
                },
                onSaveAsBookDefault: {
                    isSavingAppearanceDefault = true
                    Task {
                        try? await api.updateBookAppearanceDefaults(
                            slug: book.slug,
                            defaultFont: selectedFontId,
                            defaultTheme: selectedThemeId
                        )
                        await MainActor.run { isSavingAppearanceDefault = false }
                    }
                },
                onClose: { showAppearanceSheet = false }
            )
        }
        .sheet(isPresented: $showHighlightsSheet) { highlightsSheetView }
        .sheet(isPresented: $showChatSheet) { chatSheetView }
        .sheet(isPresented: $showNoteSheet) { noteSheetView }
        .sheet(isPresented: $showVocaSheet) { vocaSheetView }
        .task {
            await initializeDocument()
        }
    }

    // MARK: - Reader Canvas

    @ViewBuilder
    private var readerCanvas: some View {
        if isPdf {
            NativePDFViewIOS(
                document: pdfDocument,
                targetPage: currentPage,
                mode: pdfMode,
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
                onTapCenter: {
                    showChrome.toggle()
                },
                onContextProviderReady: { getter in
                    pdfContextGetter = getter
                }
            )
            .colorMultiply(pdfFilter == .warm ? Color(red: 0.98, green: 0.94, blue: 0.85) : .white)
            .applyInvert(pdfFilter == .dark)
        } else {
            let maxCols = (horizontalSizeClass == .regular && epubFlow == "paginated") ? 2 : 1
            NativeEpubWebViewIOS(
                epubFileURL: localEpubURL,
                initialCfi: initialCfi,
                estimatedTotalPages: max(1, book.pageCount),
                fontId: selectedFontId,
                themeId: selectedThemeId,
                flowMode: epubFlow,
                maxColumns: maxCols,
                highlights: highlights,
                onWebViewReady: { wv in epubWebView = wv },
                onReady: { items in
                    tocItems = items
                    isLoading = false
                },
                onRelocate: { cfi, frac, page, total, chapter, visibleText in
                    currentCfi = cfi
                    progression = frac
                    currentPage = page
                    totalPages = total
                    if !chapter.isEmpty { currentChapterTitle = chapter }
                    if !visibleText.isEmpty { currentVisibleText = visibleText }
                    if didUserNavigate {
                        saveCurrentProgress()
                    } else {
                        didUserNavigate = true
                    }
                },
                onTextSelected: { cfi, text, chapter, page in
                    selectedEpubCfi = cfi
                    selectedText = text
                    selectedPage = page
                    if !chapter.isEmpty { currentChapterTitle = chapter }
                    editingHighlight = nil
                },
                onHighlightClicked: { hlId in
                    if let found = highlights.first(where: { $0.id == hlId }) {
                        editingHighlight = found
                        selectedText = found.text
                    }
                },
                onSelectionCleared: {
                    if editingHighlight == nil {
                        selectedText = ""
                        selectedEpubCfi = ""
                    }
                },
                onTapCenter: {
                    showChrome.toggle()
                },
                onSearchResults: { hits in searchResults = hits },
                onError: { msg in
                    loadError = msg
                    isLoading = false
                }
            )
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.1), in: Circle())
            }

            Button { showTocSheet = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.1), in: Circle())
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(book.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(currentChapterTitle.isEmpty ? book.resolvedFormat.uppercased() : currentChapterTitle)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "94a3b8"))
                    .lineLimit(1)
            }

            Spacer()

            if isPdf {
                Menu {
                    Picker("Chế độ xem", selection: $pdfMode) {
                        ForEach(PdfModeIOS.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    Divider()
                    Picker("Màu giấy", selection: $pdfFilter) {
                        ForEach(PdfFilterIOS.allCases, id: \.self) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                } label: {
                    Image(systemName: "doc.plaintext")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
            } else {
                Menu {
                    Button { epubFlow = "paginated" } label: {
                        Label("Lật trang", systemImage: epubFlow == "paginated" ? "checkmark" : "book")
                    }
                    Button { epubFlow = "scrolled" } label: {
                        Label("Cuộn dọc", systemImage: epubFlow == "scrolled" ? "checkmark" : "scroll")
                    }
                } label: {
                    Image(systemName: epubFlow == "scrolled" ? "scroll" : "book")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.1), in: Circle())
                }

                Button { showAppearanceSheet = true } label: {
                    Text("Aa")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.1), in: Circle())
                }
            }

            Button { showHighlightsSheet = true } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "highlighter")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.1), in: Circle())
                    if !highlights.isEmpty {
                        Text("\(min(highlights.count, 99))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 4)
                            .background(Color(hex: "38bdf8"), in: Capsule())
                    }
                }
            }

            Button { showChatSheet = true } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.1), in: Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(hex: "111827").opacity(0.95))
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { stepPage(-1) } label: {
                Image(systemName: "chevron.left").foregroundColor(.white)
            }

            if isPdf {
                Slider(
                    value: Binding(
                        get: { Double(currentPage) },
                        set: { goToPdfPage(Int(round($0))) }
                    ),
                    in: 1...Double(max(1, totalPages))
                )
                .tint(Color(hex: "38bdf8"))
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
                .tint(Color(hex: "38bdf8"))
            }

            Button { stepPage(1) } label: {
                Image(systemName: "chevron.right").foregroundColor(.white)
            }

            Text(isPdf ? "\(currentPage)/\(totalPages)" : "\(Int(round(progression * 100)))%")
                .font(.caption.monospacedDigit().bold())
                .foregroundColor(.white)
                .frame(minWidth: 50, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(hex: "111827").opacity(0.95))
    }

    // MARK: - Floating Selection Toolbar

    private var selectionToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(highlightColors, id: \.hex) { c in
                    Button {
                        applyHighlight(color: c.hex, note: editingHighlight?.note ?? "")
                    } label: {
                        Circle()
                            .fill(Color(hex: c.hex))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 1))
                    }
                }

                Button {
                    noteDraft = editingHighlight?.note ?? ""
                    noteDraftColor = editingHighlight?.color ?? "#fde68a"
                    showNoteSheet = true
                } label: {
                    Label("Ghi chú", systemImage: "square.and.pencil")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.14), in: Capsule())
                        .foregroundColor(.white)
                }

                Button { lookupVoca() } label: {
                    Label("Tra Voca", systemImage: "character.book.closed")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(hex: "38bdf8"), in: Capsule())
                        .foregroundColor(.black)
                }

                Button {
                    chatInput = "Giải thích đoạn này giúp mình: \"\(selectedText.prefix(220))\""
                    showChatSheet = true
                } label: {
                    Label("Hỏi AI", systemImage: "sparkles")
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.14), in: Capsule())
                        .foregroundColor(.white)
                }

                if let editHl = editingHighlight {
                    Button {
                        deleteHighlight(editHl)
                        editingHighlight = nil
                        selectedText = ""
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(Color(hex: "f87171"))
                            .padding(6)
                    }
                }

                Button {
                    editingHighlight = nil
                    selectedText = ""
                    selectedEpubCfi = ""
                    selectedPdfRects = []
                    epubWebView?.evaluateJavaScript("window.BilingualEpub && window.BilingualEpub.clearSelection();", completionHandler: nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color(hex: "1e293b").opacity(0.96), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
        .padding(.horizontal, 12)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    // MARK: - Sheets (TOC/Search, Highlights, Note, Voca, AI Chat)

    private var tocSheetView: some View {
        NavigationView {
            VStack(spacing: 0) {
                if isEpub {
                    Picker("", selection: $tocTab) {
                        Text("Mục lục").tag(0)
                        Text("Tìm kiếm").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(12)
                }

                if isEpub && tocTab == 1 {
                    HStack {
                        TextField("Tìm trong sách…", text: $searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { runEpubSearch() }
                        Button("Tìm") { runEpubSearch() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 12)

                    List(searchResults) { hit in
                        Button {
                            jumpToEpubTarget(hit.cfi)
                            showTocSheet = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                if !hit.label.isEmpty {
                                    Text(hit.label).font(.caption).foregroundColor(.accentColor)
                                }
                                Text("\(hit.pre)\(hit.match)\(hit.post)")
                                    .font(.subheadline)
                                    .lineLimit(3)
                            }
                        }
                    }
                } else {
                    List(tocItems) { item in
                        Button {
                            if let p = item.page {
                                goToPdfPage(p)
                            } else if let href = item.href {
                                jumpToEpubTarget(href)
                            }
                            showTocSheet = false
                        } label: {
                            HStack {
                                Text(item.label)
                                    .padding(.leading, CGFloat(min(item.level, 4) * 14))
                                Spacer()
                                if let p = item.page {
                                    Text("\(p)").font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Mục lục")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { showTocSheet = false }
                }
            }
        }
    }

    private var highlightsSheetView: some View {
        NavigationView {
            List {
                if highlights.isEmpty {
                    Text("Chưa có đánh dấu nào. Bôi đen chữ để highlight hoặc ghi chú.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(highlights.sorted { $0.page < $1.page }) { hl in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Circle().fill(Color(hex: hl.color)).frame(width: 10, height: 10)
                                Text("Trang \(hl.page)").font(.caption.bold()).foregroundColor(.secondary)
                                Spacer()
                            }
                            Text("“\(hl.text)”").font(.subheadline)
                            if let note = hl.note, !note.isEmpty {
                                Text(note).font(.caption).foregroundColor(.orange)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isPdf {
                                goToPdfPage(hl.page)
                            } else if let anchor = DocumentHighlightAnchor.parse(hl.anchorJson),
                                      let cfi = anchor.cfi {
                                jumpToEpubTarget(cfi)
                            }
                            showHighlightsSheet = false
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                deleteHighlight(hl)
                            } label: {
                                Label("Xóa", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Ghi chú & Đánh dấu")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { showHighlightsSheet = false }
                }
            }
        }
    }

    private var noteSheetView: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Text("“\(selectedText)”")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                TextEditor(text: $noteDraft)
                    .frame(minHeight: 160)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3)))
                Spacer()
            }
            .padding()
            .navigationTitle("Ghi chú")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Huỷ") { showNoteSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        applyHighlight(color: noteDraftColor, note: noteDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                        showNoteSheet = false
                    }
                }
            }
        }
    }

    private var vocaSheetView: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 14) {
                if isLookingUpVoca {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Đang tra từ '\(vocaWord)'…")
                    }
                } else if let err = vocaError {
                    Text(err).foregroundColor(.red)
                } else if let card = vocaResult?.resolvedCards.first {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.word).font(.title2.bold())
                            if !card.displayIpa.isEmpty {
                                Text(card.displayIpa).font(.subheadline.monospaced()).foregroundColor(.accentColor)
                            }
                        }
                        Spacer()
                        Button {
                            Task { try? await VocaService.playAudio(slug: card.slug) }
                        } label: {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.bordered)
                    }
                    Text(card.displayMeaning).font(.body)
                    if let ex = card.examples?.first, !ex.isEmpty {
                        Text("“\(ex)”").font(.subheadline).italic().foregroundColor(.secondary)
                    }
                } else {
                    Text("Chưa có từ '\(vocaWord)' trong Voca.")
                    Button {
                        createVocaCard()
                    } label: {
                        if isCreatingVocaCard {
                            ProgressView()
                        } else {
                            Label("Tạo thẻ Voca mới", systemImage: "plus.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreatingVocaCard)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Từ điển Voca")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { showVocaSheet = false }
                }
            }
        }
    }

    private var chatSheetView: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if chatMessages.isEmpty {
                            Button("📝 Tóm tắt trang đang đọc") {
                                sendChat("Tóm tắt nội dung trang đang đọc ngắn gọn, dễ hiểu.")
                            }
                            .buttonStyle(.bordered)
                        }
                        ForEach(chatMessages) { msg in
                            Text(msg.content)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: msg.role == "user" ? .trailing : .leading)
                                .background(
                                    msg.role == "user" ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 12)
                                )
                        }
                        if isSendingChat {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("AI đang trả lời…").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding()
                }
                Divider()
                HStack(spacing: 8) {
                    TextField("Hỏi AI về trang này…", text: $chatInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { sendChat(chatInput) }
                    Button { sendChat(chatInput) } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSendingChat)
                }
                .padding(12)
            }
            .navigationTitle("Companion AI")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Đóng") { showChatSheet = false }
                }
            }
        }
    }

    // MARK: - Logic & Persistence

    private func initializeDocument() async {
        isLoading = true
        loadError = nil
        isBookFinished = book.isFinished == true
        totalPages = max(1, book.pageCount)
        selectedFontId = (book.readerFont?.isEmpty == false ? book.readerFont! : book.defaultFont) ?? "default"
        selectedThemeId = (book.readerTheme?.isEmpty == false ? book.readerTheme! : book.defaultTheme) ?? "default"

        // 1. Reconcile reading progress (newest lastRead wins)
        var resolvedProgress: ReadingProgress?
        if let localData = UserDefaults.standard.data(forKey: "progress_\(book.slug)"),
           let localProg = try? JSONDecoder().decode(ReadingProgress.self, from: localData) {
            resolvedProgress = localProg
        }
        if !api.isOfflineMode, let serverProg = try? await api.fetchProgress(slug: book.slug) {
            if (serverProg.lastRead ?? 0) >= (resolvedProgress?.lastRead ?? 0) {
                resolvedProgress = serverProg
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

        // 2. Load offline/server highlights
        if let fetched = try? await api.fetchHighlights(slug: book.slug) {
            highlights = fetched
        } else {
            highlights = cacheManager.loadCachedHighlights(
                slug: book.slug,
                serverUrl: api.normalizedServerUrl,
                username: api.username
            )
        }

        // 3. Locate offline cached file or download & cache now
        let fmt = book.resolvedFormat
        var fileURL = cacheManager.existingLocalSourceFileURL(slug: book.slug, format: fmt)
        if fileURL == nil {
            if api.isOfflineMode {
                loadError = "Sách chưa được tải về để đọc ngoại tuyến."
                isLoading = false
                return
            }
            do {
                let data = try await api.fetchBookSourceData(slug: book.slug)
                let target = cacheManager.localSourceFileURL(slug: book.slug, format: fmt)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                fileURL = target
                cacheManager.scanDownloadedBooks()
            } catch {
                loadError = "Không tải được sách: \(error.localizedDescription)"
                isLoading = false
                return
            }
        }

        guard let resolvedURL = fileURL else {
            loadError = "Không tìm thấy tệp sách."
            isLoading = false
            return
        }

        if isPdf {
            if let doc = PDFDocument(url: resolvedURL) {
                pdfDocument = doc
                totalPages = max(1, doc.pageCount)
                currentPage = max(1, min(totalPages, currentPage))
                tocItems = extractPdfOutline(from: doc)
                isLoading = false
            } else {
                loadError = "Tệp PDF không hợp lệ."
                isLoading = false
            }
        } else {
            localEpubURL = resolvedURL
        }
    }

    private func extractPdfOutline(from doc: PDFDocument) -> [DocTocItemIOS] {
        guard let root = doc.outlineRoot else { return [] }
        var out: [DocTocItemIOS] = []
        func walk(_ node: PDFOutline, level: Int) {
            for i in 0..<node.numberOfChildren {
                guard out.count < 600, let child = node.child(at: i) else { break }
                let pageNum = child.destination?.page.map { doc.index(for: $0) + 1 }
                out.append(DocTocItemIOS(
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
            goToPdfPage(currentPage + delta)
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
        let now = Int64(Date().timeIntervalSince1970)
        let loc = isEpub ? currentCfi : nil
        let frac = progression
        let localProg = ReadingProgress(
            page: currentPage,
            viewMode: "en",
            locator: loc,
            progression: frac,
            lastRead: now
        )
        if let data = try? JSONEncoder().encode(localProg) {
            UserDefaults.standard.set(data, forKey: "progress_\(book.slug)")
        }
        let slug = book.slug
        let p = currentPage
        Task {
            await api.saveProgress(
                slug: slug,
                page: p,
                viewMode: "en",
                lastRead: now,
                locator: loc,
                progression: frac
            )
        }
    }

    private func persistAppearance() {
        let f = selectedFontId
        let t = selectedThemeId
        Task {
            _ = try? await api.updateBookState(slug: book.slug, patch: ["readerFont": f, "readerTheme": t])
        }
    }

    private func applyHighlight(color: String, note: String) {
        if let existing = editingHighlight {
            let updated = Highlight(
                id: existing.id,
                page: existing.page,
                lang: existing.lang,
                color: color,
                text: existing.text,
                startOffset: existing.startOffset,
                endOffset: existing.endOffset,
                paragraphIndex: existing.paragraphIndex,
                anchorJson: existing.anchorJson,
                note: note,
                createdAt: existing.createdAt
            )
            if let idx = highlights.firstIndex(where: { $0.id == updated.id }) {
                highlights[idx] = updated
            }
            editingHighlight = nil
            selectedText = ""
            Task { try? await api.saveHighlight(slug: book.slug, highlight: updated) }
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
            id: "hl-\(Int64(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))",
            page: selectedPage,
            lang: lang,
            color: color,
            text: trimmed,
            startOffset: 0,
            endOffset: trimmed.count,
            paragraphIndex: 0,
            anchorJson: anchorJson,
            note: note,
            createdAt: Int64(Date().timeIntervalSince1970)
        )
        highlights.append(newHl)
        selectedText = ""
        selectedPdfRects = []
        selectedEpubCfi = ""
        epubWebView?.evaluateJavaScript("window.BilingualEpub && window.BilingualEpub.clearSelection();", completionHandler: nil)
        Task { try? await api.saveHighlight(slug: book.slug, highlight: newHl) }
    }

    private func deleteHighlight(_ hl: Highlight) {
        highlights.removeAll { $0.id == hl.id }
        Task { try? await api.deleteHighlight(slug: book.slug, highlightId: hl.id) }
    }

    private func lookupVoca() {
        let word = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        vocaWord = word
        vocaResult = nil
        vocaError = nil
        isLookingUpVoca = true
        showVocaSheet = true
        Task {
            do {
                let res = try await VocaService.lookupWord(word)
                await MainActor.run {
                    vocaResult = res
                    isLookingUpVoca = false
                }
            } catch {
                await MainActor.run {
                    vocaError = error.localizedDescription
                    isLookingUpVoca = false
                }
            }
        }
    }

    private func createVocaCard() {
        isCreatingVocaCard = true
        Task {
            do {
                let card = try await VocaService.addWordToVoca(vocaWord)
                await MainActor.run {
                    vocaResult = VocaLookupResult(found: true, word: vocaWord, matchType: "exact", card: card, cards: [card])
                    isCreatingVocaCard = false
                }
            } catch {
                await MainActor.run {
                    vocaError = error.localizedDescription
                    isCreatingVocaCard = false
                }
            }
        }
    }

    private func sendChat(_ rawPrompt: String) {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isSendingChat else { return }
        chatInput = ""
        chatMessages.append(DocChatMessageIOS(role: "user", content: prompt))
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
                    chatMessages.append(DocChatMessageIOS(role: "assistant", content: reply))
                    isSendingChat = false
                }
            } catch {
                await MainActor.run {
                    chatMessages.append(DocChatMessageIOS(role: "assistant", content: "Lỗi AI: \(error.localizedDescription)"))
                    isSendingChat = false
                }
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func applyInvert(_ enabled: Bool) -> some View {
        if enabled {
            self.colorInvert()
        } else {
            self
        }
    }
}
