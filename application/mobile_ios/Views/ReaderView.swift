import SwiftUI
import WebKit

struct ChatMessage: Identifiable, Codable {
    var id = UUID()
    let role: String // "user" | "assistant"
    let content: String
}

struct ReaderView: View {
    let book: Book
    @Environment(\.dismiss) var dismiss
    @StateObject private var api = APIService.shared
    
    @State private var page: Int
    @State private var viewMode: String // "en" | "vi" | "split"
    
    // Jump to page dialog
    @State private var showJumpToPageDialog = false
    @State private var inputPageString = ""
    @FocusState private var isPageFieldFocused: Bool
    
    init(book: Book) {
        self.book = book
        
        var initialPage = 1
        var initialViewMode = "split"
        
        if let data = UserDefaults.standard.data(forKey: "progress_\(book.slug)"),
           let progress = try? JSONDecoder().decode(ReadingProgress.self, from: data) {
            initialPage = progress.page
            initialViewMode = progress.viewMode
        }
        
        self._page = State(initialValue: initialPage)
        self._viewMode = State(initialValue: initialViewMode)
    }
    
    // Highlights States
    @State private var activeSelection: SelectionInfo? = nil
    @State private var activeSelectionLang: String = ""
    @State private var activeSelectionPage: Int? = nil
    @State private var selectedHighlightId: String? = nil
    @State private var activeRect: CGRect? = nil
    @State private var showNoteInput: Bool = false
    @State private var highlightNote: String = ""
    @State private var selectedColor: String = "#fde68a" // yellow default
    @State private var activeSentenceId: String? = nil
    @State private var activeSentencePage: Int? = nil
    @State private var activeSentenceLang: String? = nil
    
    // AI Chat States
    @State private var isChatOpen = false
    @AppStorage("bilingualLayoutMode") private var bilingualLayoutMode: String = "en-vi"
    
    // AI Companion Voice Mode
    @StateObject private var companionVM = CompanionVoiceViewModel()
    
    // Apple Pencil Drawing State
    @State private var isPencilModeActive = false
    
    // Voca States
    @State private var vocaPanelMode: VocaLookupPanelMode? = nil
    @State private var vocaPanelRect: CGRect? = nil
    @State private var vocaPanelLang: String = ""
    @State private var vocaPanelPage: Int? = nil
    @State private var vocaPanelContainerMode: String = ""
    @State private var vocaProgressWord: String? = nil
    @State private var vocaIsPlayingAudio = false
    @State private var vocaToast: String? = nil
    @State private var vocaLookupInProgress = false
    @State private var vocaPanelWebView: WKWebView? = nil
    @State private var readerUsesDoubleSided = false
    @State private var selectionOverlayRevision = 0
    @State private var webViews: [String: WKWebView] = [:]
    
    let highlightColors = [
        ("#fde68a", Color(hex: "fde68a")), // Yellow
        ("#93c5fd", Color(hex: "93c5fd")), // Blue
        ("#f9a8d4", Color(hex: "f9a8d4")), // Pink
        ("#86efac", Color(hex: "86efac"))  // Green
    ]

    @State private var isReadyToRender = false
    
    var body: some View {
        GeometryReader { geometry in
            let isLargeScreen = geometry.size.width > 700
            let isLandscape = geometry.size.width > geometry.size.height
            let isLargeAndLandscape = isLargeScreen && isLandscape
            let useDoubleSided = isLargeAndLandscape && !isChatOpen && viewMode != "split"
            
            HStack(spacing: 0) {
                // Main Reading Pane
                VStack(spacing: 0) {
                    // Custom Slim Top Navigation Bar
                    ReaderHeaderView(
                        book: book,
                        useDoubleSided: useDoubleSided,
                        page: $page,
                        viewMode: $viewMode,
                        isChatOpen: $isChatOpen,
                        isPencilModeActive: $isPencilModeActive,
                        showJumpToPageDialog: $showJumpToPageDialog,
                        inputPageString: $inputPageString,
                        onDismiss: { dismiss() }
                    )
                    
                    // Reading Area
                        ZStack {
                            Color(hex: "0f172a").ignoresSafeArea()
                            
                            if !isReadyToRender {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(1.5)
                            } else {
                                let pageBinding = Binding(
                                    get: { self.page },
                                    set: { newPage in
                                        if newPage != self.page {
                                            self.page = newPage
                                            self.saveProgress()
                                            self.clearSelectionState()
                                            // Update AI companion with new page context
                                            if self.companionVM.phase == .live,
                                               UserDefaults.standard.object(forKey: "companionAutoUpdateContext") as? Bool ?? true {
                                                self.updateCompanionAfterPageChange(newPage: newPage)
                                            }
                                        }
                                    }
                                )
                                
                                
                                
                                let readingPaneWidth = isLargeScreen && isChatOpen ? geometry.size.width - 350 : geometry.size.width
                                let isReadingPaneLarge = readingPaneWidth > 700
                                
                                ZStack {
                                    // Chế độ Song ngữ
                                    BookPagerView(
                                        pageCount: max(1, book.pageCount),
                                        currentPage: pageBinding,
                                        isDoubleSided: false,
                                        overlayRevision: selectionOverlayRevision,
                                        isPencilModeActive: isPencilModeActive
                                    ) { p in
                                        let isHorizontal = (bilingualLayoutMode == "en-over-vi" || bilingualLayoutMode == "vi-over-en") ? false : isReadingPaneLarge
                                        let isEnFirst = bilingualLayoutMode.hasPrefix("en")
                                        let layout = isHorizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                                        layout {
                                            if isEnFirst {
                                                renderWebView(lang: "en", p: p, isDoubleSided: false, containerMode: "split")
                                                    .padding(.leading, isHorizontal ? 28 : 16)
                                                    .padding(.trailing, isHorizontal ? 4 : 16)
                                                    .padding(.vertical, 6)
                                                renderWebView(lang: "vi", p: p, isDoubleSided: false, containerMode: "split")
                                                    .padding(.leading, isHorizontal ? 4 : 16)
                                                    .padding(.trailing, isHorizontal ? 28 : 16)
                                                    .padding(.vertical, 6)
                                            } else {
                                                renderWebView(lang: "vi", p: p, isDoubleSided: false, containerMode: "split")
                                                    .padding(.leading, isHorizontal ? 28 : 16)
                                                    .padding(.trailing, isHorizontal ? 4 : 16)
                                                    .padding(.vertical, 6)
                                                renderWebView(lang: "en", p: p, isDoubleSided: false, containerMode: "split")
                                                    .padding(.leading, isHorizontal ? 4 : 16)
                                                    .padding(.trailing, isHorizontal ? 28 : 16)
                                                    .padding(.vertical, 6)
                                            }
                                        }
                                    }
                                    .id("split_\(bilingualLayoutMode)")
                                    .opacity(viewMode == "split" ? 1 : 0)
                                    .allowsHitTesting(viewMode == "split")
                                    
                                    // Chế độ Đơn ngữ (Tiếng Anh)
                                    BookPagerView(
                                        pageCount: max(1, book.pageCount),
                                        currentPage: pageBinding,
                                        isDoubleSided: useDoubleSided,
                                        overlayRevision: selectionOverlayRevision,
                                        isPencilModeActive: isPencilModeActive
                                    ) { p in
                                        let isLeft = p % 2 == 1
                                        renderWebView(lang: "en", p: p, isDoubleSided: useDoubleSided, containerMode: "en")
                                            .padding(.top, 6)
                                            .padding(.bottom, 6)
                                            .padding(.leading, useDoubleSided ? (isLeft ? 32 : 0) : 16)
                                            .padding(.trailing, useDoubleSided ? (isLeft ? 0 : 32) : 16)
                                    }
                                    .id("en_\(useDoubleSided)")
                                    .opacity(viewMode == "en" ? 1 : 0)
                                    .allowsHitTesting(viewMode == "en")
                                    
                                    // Chế độ Đơn ngữ (Tiếng Việt)
                                    BookPagerView(
                                        pageCount: max(1, book.pageCount),
                                        currentPage: pageBinding,
                                        isDoubleSided: useDoubleSided,
                                        overlayRevision: selectionOverlayRevision,
                                        isPencilModeActive: isPencilModeActive
                                    ) { p in
                                        let isLeft = p % 2 == 1
                                        renderWebView(lang: "vi", p: p, isDoubleSided: useDoubleSided, containerMode: "vi")
                                            .padding(.top, 6)
                                            .padding(.bottom, 6)
                                            .padding(.leading, useDoubleSided ? (isLeft ? 32 : 0) : 16)
                                            .padding(.trailing, useDoubleSided ? (isLeft ? 0 : 32) : 16)
                                    }
                                    .id("vi_\(useDoubleSided)")
                                    .opacity(viewMode == "vi" ? 1 : 0)
                                    .allowsHitTesting(viewMode == "vi")
                                }
                            } // End of isReadyToRender block
                        }
                        .ignoresSafeArea(edges: .bottom)
                        .ignoresSafeArea(.keyboard)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                isReadyToRender = true
                            }
                            readerUsesDoubleSided = useDoubleSided
                        }
                        .onChange(of: useDoubleSided) { readerUsesDoubleSided = $0 }
                        .onChange(of: viewMode) { _ in readerUsesDoubleSided = useDoubleSided }
                        .onChange(of: isChatOpen) { _ in readerUsesDoubleSided = useDoubleSided }
                    }
                    .frame(maxWidth: .infinity)
                    
                    // Slide-in AI Assistant Sidebar (For large screens)
                    // Slide-in AI Assistant Sidebar (For large screens)
                    if isChatOpen && isLargeScreen {
                        ReaderChatPanelView(
                            isChatOpen: $isChatOpen,
                            bilingualLayoutMode: $bilingualLayoutMode,
                            book: book,
                            page: page,
                            viewMode: viewMode,
                            api: api,
                            isLargeScreen: true,
                            companionVM: companionVM,
                            pageContextBuilder: { page, mode in
                                await buildPageContext(for: page, viewMode: mode)
                            },
                            onAskAIShortcut: askAIShortcut
                        )
                        .transition(.move(edge: .trailing))
                    }
                }
                // Sliding Overlay Sheet for smaller screens (iPhone)
                .sheet(isPresented: Binding(
                    get: { isChatOpen && !isLargeScreen },
                    set: { isChatOpen = $0 }
                )) {
                    ReaderChatPanelView(
                        isChatOpen: $isChatOpen,
                        bilingualLayoutMode: $bilingualLayoutMode,
                        book: book,
                        page: page,
                        viewMode: viewMode,
                        api: api,
                        isLargeScreen: false,
                        companionVM: companionVM,
                        pageContextBuilder: { page, mode in
                            await buildPageContext(for: page, viewMode: mode)
                        },
                        onAskAIShortcut: askAIShortcut
                    )
                    .background(Color(hex: "111827").ignoresSafeArea())
                }
            }
            .background(Color(hex: "0f172a"))
            .onAppear {
                loadProgress()
                fetchHighlights()
                setupCompanionVM()
            }
            .onChange(of: viewMode) { _ in
                saveProgress()
            }
            .overlay(
                Group {
                    if showJumpToPageDialog {
                        jumpToPageDialogView()
                    }
                    ReaderVocaOverlayView(progressWord: vocaProgressWord, toast: vocaToast)
                }
            )
    }
    
    // --- Highlights UI / logic ---
    @ViewBuilder
    private func renderWebView(lang: String, p: Int, isDoubleSided: Bool, containerMode: String) -> some View {
        let padPage = String(format: "%04d", p)
        let urlString = "\(api.serverUrl)/books/\(book.slug)/output/\(lang)/page_\(padPage).html?token=\(api.token)"
        
        let activeSelectionLang = self.activeSelectionLang
        let activeSelection = self.activeSelection
        let selectedHighlightId = self.selectedHighlightId
        
        let isBilingual = viewMode == "split"
        let shouldHighlightActiveSentence = isBilingual ? (p == activeSentencePage) : (p == activeSentencePage && lang == activeSentenceLang)
        let targetSentenceId = shouldHighlightActiveSentence ? activeSentenceId : nil
        
        BilingualWebView(
            bookSlug: book.slug,
            urlString: urlString,
            lang: lang,
            page: p,
            viewMode: viewMode,
            activeSentenceId: targetSentenceId,
            isPencilModeActive: isPencilModeActive,
            onScroll: { scrollTop in
                if viewMode == "split" {
                    let otherLang = lang == "en" ? "vi" : "en"
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ScrollTo_\(otherLang)"),
                        object: nil,
                        userInfo: ["scrollTop": scrollTop]
                    )
                }
            },
            onHighlightMessage: { msg in
                handleHighlightMessage(msg, lang: lang, page: p)
            },
            onSentenceClicked: { sentenceId in
                self.activeSentenceId = sentenceId
                self.activeSentencePage = p
                self.activeSentenceLang = lang
                bumpSelectionOverlayRevision()
            },
            onVocaAction: { action in
                handleVocaWebAction(action)
            },
            onWebViewReady: { webView, readyLang, readyPage in
                registerWebView(webView, lang: readyLang, page: readyPage, containerMode: containerMode)
            },
            onWebViewDismantled: { webView, readyLang, readyPage in
                unregisterWebView(webView, lang: readyLang, page: readyPage, containerMode: containerMode)
            }
        )
        .id("webview-\(lang)-\(p)")
        .modifier(PaperSheetModifier(viewMode: viewMode, page: p, isDoubleSided: isDoubleSided))
        .overlay(
            GeometryReader { geo in
                Group {
                    if activeSelectionLang == lang && activeSelectionPage == p && (activeSelection != nil || selectedHighlightId != nil) {
                        if let rect = activeRect {
                            let pos = clampedToolbarPosition(
                                rect: rect,
                                in: geo.size,
                                lang: lang,
                                page: p,
                                isDoubleSided: isDoubleSided
                            )
                            highlightPopupMenu()
                                .position(x: pos.x, y: pos.y)
                        }
                    }
                }
            }
            .allowsHitTesting(true)
        )
    }

    private func vocaPanelSafeInsets(lang: String, page: Int, isDoubleSided: Bool) -> (left: CGFloat, right: CGFloat) {
        let base: CGFloat = 12
        let spine: CGFloat = 56

        if viewMode == "split" {
            let isHorizontal = bilingualLayoutMode == "en-vi" || bilingualLayoutMode == "vi-en"
            guard isHorizontal else { return (base, base) }
            let isEnFirst = bilingualLayoutMode.hasPrefix("en")
            if lang == "en" {
                return isEnFirst ? (base, spine) : (spine, base)
            }
            return isEnFirst ? (spine, base) : (base, spine)
        }

        if isDoubleSided {
            return page % 2 == 1 ? (base, spine) : (spine, base)
        }
        return (base, base)
    }

    private func clampedToolbarPosition(rect: CGRect, in size: CGSize, lang: String, page: Int, isDoubleSided: Bool) -> CGPoint {
        let insets = vocaPanelSafeInsets(lang: lang, page: page, isDoubleSided: isDoubleSided)
        let menuHalfWidth: CGFloat = 112
        let menuHalfHeight: CGFloat = 28
        let minX = menuHalfWidth + insets.left
        let maxX = max(minX, size.width - menuHalfWidth - insets.right)
        let x = min(max(rect.midX, minX), maxX)
        let y = min(max(rect.minY - 30, menuHalfHeight + 8), size.height - menuHalfHeight - 8)
        return CGPoint(x: x, y: y)
    }
    
    @ViewBuilder
    private func highlightPopupMenu() -> some View {
        ReaderHighlightMenuView(
            selectedColor: $selectedColor,
            showNoteInput: $showNoteInput,
            highlightNote: $highlightNote,
            activeSelectionLang: activeSelectionLang,
            hasActiveSelection: activeSelection != nil,
            selectedHighlightId: selectedHighlightId,
            highlightColors: highlightColors,
            onSaveHighlight: saveHighlight,
            onPerformVocaLookup: performVocaLookup,
            onDeleteHighlight: deleteHighlight
        )
    }
    
    private func handleHighlightMessage(_ msg: HighlightMessage, lang: String, page: Int) {
        switch msg {
        case .textSelected(let selectionInfo):
            dismissVocaPanel()
            self.activeSelection = selectionInfo
            self.activeSelectionLang = lang
            self.activeSelectionPage = page
            self.selectedHighlightId = nil
            self.highlightNote = ""
            self.selectedColor = "#fde68a"
            self.activeRect = selectionInfo.rect
            self.showNoteInput = false
            bumpSelectionOverlayRevision()
        case .highlightClicked(let id, let rect):
            dismissVocaPanel()
            self.selectedHighlightId = id
            self.activeSelection = nil
            self.activeRect = rect
            if let existing = api.highlights.first(where: { $0.id == id }) {
                self.selectedColor = existing.color
                self.highlightNote = existing.note ?? ""
                self.activeSelectionPage = existing.page
                self.activeSelectionLang = existing.lang
                self.showNoteInput = !(existing.note ?? "").isEmpty
            } else {
                self.showNoteInput = false
            }
            bumpSelectionOverlayRevision()
        case .clearSelection:
            clearSelectionState()
            bumpSelectionOverlayRevision()
            guard !vocaLookupInProgress else { return }
            guard vocaPanelMode == nil else { return }
            dismissVocaPanel()
        }
    }
    
    private func clearSelectionState() {
        self.activeSelection = nil
        self.selectedHighlightId = nil
        self.activeSelectionPage = nil
        self.highlightNote = ""
        self.activeSentenceId = nil
        self.activeSentencePage = nil
        self.activeSentenceLang = nil
        self.activeRect = nil
        self.showNoteInput = false
    }
    
    private func bumpSelectionOverlayRevision() {
        selectionOverlayRevision += 1
    }

    private func registerWebView(_ webView: WKWebView, lang: String, page: Int, containerMode: String) {
        DispatchQueue.main.async {
            let key = webViewKey(lang: lang, page: page, containerMode: containerMode)
            if webViews[key] !== webView {
                webViews[key] = webView
            }
            if vocaPanelLang == lang, vocaPanelPage == page, vocaPanelContainerMode == containerMode, vocaPanelWebView == nil {
                vocaPanelWebView = webView
            }
        }
    }

    private func unregisterWebView(_ webView: WKWebView, lang: String, page: Int, containerMode: String) {
        DispatchQueue.main.async {
            let key = webViewKey(lang: lang, page: page, containerMode: containerMode)
            if webViews[key] === webView {
                webViews.removeValue(forKey: key)
            }
            if vocaPanelWebView === webView {
                vocaPanelWebView = nil
            }
        }
    }

    private func webViewKey(lang: String, page: Int, containerMode: String) -> String {
        "\(containerMode)-\(lang)-\(page)"
    }

    private func vocaCardPayload(_ card: VocaCard) -> [String: Any] {
        var dict: [String: Any] = [
            "id": card.id,
            "word": card.word,
            "meaningVi": card.meaningVi,
        ]
        if let ipa = card.ipa { dict["ipa"] = ipa }
        if let pronunciation = card.pronunciation { dict["pronunciation"] = pronunciation }
        if let audioUrl = card.audioUrl { dict["audioUrl"] = audioUrl }
        if let level = card.level { dict["level"] = level }
        return dict
    }

    private func presentVocaPanelInWebView(retryCount: Int = 0) {
        guard let mode = vocaPanelMode,
              let rect = vocaPanelRect,
              let panelPage = vocaPanelPage,
              !vocaPanelLang.isEmpty,
              !vocaPanelContainerMode.isEmpty else { return }

        let key = webViewKey(lang: vocaPanelLang, page: panelPage, containerMode: vocaPanelContainerMode)
        let webView = vocaPanelWebView ?? webViews[key]
        guard let webView else {
            if retryCount < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    self.presentVocaPanelInWebView(retryCount: retryCount + 1)
                }
            } else {
                showVocaToast("Không tìm thấy trang để hiển thị từ điển.")
            }
            return
        }

        let insets = vocaPanelSafeInsets(lang: vocaPanelLang, page: panelPage, isDoubleSided: readerUsesDoubleSided)

        var payload: [String: Any] = [
            "rect": [
                "x": rect.origin.x,
                "y": rect.origin.y,
                "width": rect.width,
                "height": rect.height,
                "insetLeft": insets.left,
                "insetRight": insets.right,
            ],
        ]
        switch mode {
        case .single(let card):
            payload["mode"] = "single"
            payload["card"] = vocaCardPayload(card)
        case .multi(let query, let cards):
            payload["mode"] = "multi"
            payload["query"] = query
            payload["cards"] = cards.map(vocaCardPayload)
        case .notFound(let query):
            payload["mode"] = "notFound"
            payload["query"] = query
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }

        let panelJs = "window.showIOSVocaPanel(\(json));"
        webView.evaluateJavaScript("typeof window.showIOSVocaPanel === 'function' ? 1 : 0") { result, _ in
            DispatchQueue.main.async {
                let isReady = (result as? Int == 1) || (result as? Bool == true)
                if isReady {
                    webView.evaluateJavaScript(panelJs, completionHandler: nil)
                    self.vocaPanelWebView = webView
                } else if retryCount < 5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        self.presentVocaPanelInWebView(retryCount: retryCount + 1)
                    }
                } else {
                    self.showVocaToast("Không thể hiển thị từ điển trên trang này.")
                }
            }
        }
    }

    private func removeVocaPanelFromWebView() {
        guard let panelPage = vocaPanelPage,
              !vocaPanelLang.isEmpty,
              !vocaPanelContainerMode.isEmpty,
              let webView = webViews[webViewKey(lang: vocaPanelLang, page: panelPage, containerMode: vocaPanelContainerMode)] else { return }
        webView.evaluateJavaScript("window.removeIOSVocaPanel && window.removeIOSVocaPanel();", completionHandler: nil)
    }

    private func handleVocaWebAction(_ action: VocaWebAction) {
        switch action {
        case .addWord(let word):
            vocaPanelMode = .notFound(query: word)
            addSelectionToVoca()
        case .playAudio(let cardId):
            if case .single(let card) = vocaPanelMode, card.id == cardId {
                playVocaAudio(card)
            } else {
                playVocaAudio(VocaCard(
                    id: cardId,
                    word: cardId,
                    meaningVi: "",
                    ipa: nil,
                    pronunciation: nil,
                    audioUrl: nil,
                    level: nil
                ))
            }
        case .selectCard(let card):
            vocaPanelMode = .single(card)
            presentVocaPanelInWebView()
        case .dismiss:
            clearVocaPanelState()
        }
    }

    private func clearVocaPanelState() {
        vocaPanelMode = nil
        vocaPanelRect = nil
        vocaPanelLang = ""
        vocaPanelPage = nil
        vocaPanelContainerMode = ""
        vocaPanelWebView = nil
        vocaIsPlayingAudio = false
    }

    private func dismissVocaPanel() {
        removeVocaPanelFromWebView()
        clearVocaPanelState()
        vocaProgressWord = nil
    }

    private func hideVocaPanelInWebView() {
        removeVocaPanelFromWebView()
        vocaPanelMode = nil
        vocaIsPlayingAudio = false
    }
    
    private func showVocaToast(_ message: String) {
        withAnimation { vocaToast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { vocaToast = nil }
        }
    }
    
    private func performVocaLookup() {
        var textToLookup: String? = nil
        if let selection = activeSelection {
            textToLookup = selection.text
        } else if let highlightId = selectedHighlightId,
                  let existing = api.highlights.first(where: { $0.id == highlightId }) {
            textToLookup = existing.text
        }
        
        guard let text = textToLookup, activeSelectionLang == "en" else { return }
        let query = VocaService.cleanWord(text)
        guard !query.isEmpty else { return }

        let anchor = activeRect ?? CGRect(x: 180, y: 120, width: 40, height: 20)
        let panelLang = activeSelectionLang
        let panelPage = activeSelectionPage ?? page
        let containerMode = self.viewMode
        let key = webViewKey(lang: panelLang, page: panelPage, containerMode: containerMode)

        guard let webView = webViews[key] else {
            showVocaToast("Không tìm thấy trang để tra từ.")
            return
        }

        vocaPanelLang = panelLang
        vocaPanelPage = panelPage
        vocaPanelContainerMode = containerMode
        vocaPanelRect = anchor
        vocaPanelWebView = webView
        vocaLookupInProgress = true

        Task {
            do {
                let result = try await VocaService.lookupWord(query)
                await MainActor.run {
                    if result.found {
                        let cards = result.resolvedCards
                        if cards.count == 1 {
                            vocaPanelMode = .single(cards[0])
                        } else if cards.count > 1 {
                            vocaPanelMode = .multi(query: query, cards: cards)
                        } else {
                            vocaPanelMode = .notFound(query: query)
                        }
                    } else {
                        vocaPanelMode = .notFound(query: query)
                    }
                    presentVocaPanelInWebView()
                    clearSelectionState()
                    bumpSelectionOverlayRevision()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        vocaLookupInProgress = false
                    }
                }
            } catch {
                await MainActor.run {
                    vocaLookupInProgress = false
                    vocaPanelWebView = nil
                    dismissVocaPanel()
                    showVocaToast(error.localizedDescription)
                }
            }
        }
    }
    
    private func addSelectionToVoca() {
        guard case .notFound(let query) = vocaPanelMode else { return }
        let savedRect = vocaPanelRect
        let savedLang = vocaPanelLang
        let savedPage = vocaPanelPage
        let savedContainerMode = vocaPanelContainerMode
        let savedWebView = vocaPanelWebView

        vocaLookupInProgress = true
        hideVocaPanelInWebView()
        withAnimation { vocaProgressWord = query }

        Task {
            do {
                try await VocaService.addWordToVoca(query)
                let result = try await VocaService.lookupWord(query)
                await MainActor.run {
                    withAnimation { vocaProgressWord = nil }
                    if result.found, let card = result.resolvedCards.first {
                        vocaPanelRect = savedRect
                        vocaPanelLang = savedLang
                        vocaPanelPage = savedPage
                        vocaPanelContainerMode = savedContainerMode
                        if let savedWebView {
                            vocaPanelWebView = savedWebView
                        } else if let savedPage, !savedContainerMode.isEmpty {
                            vocaPanelWebView = webViews[webViewKey(lang: savedLang, page: savedPage, containerMode: savedContainerMode)]
                        }
                        vocaPanelMode = .single(card)
                        presentVocaPanelInWebView()
                    } else {
                        dismissVocaPanel()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        vocaLookupInProgress = false
                    }
                }
            } catch {
                await MainActor.run {
                    withAnimation { vocaProgressWord = nil }
                    vocaPanelRect = savedRect
                    vocaPanelLang = savedLang
                    vocaPanelPage = savedPage
                    vocaPanelContainerMode = savedContainerMode
                    if let savedWebView {
                        vocaPanelWebView = savedWebView
                    } else if let savedPage, !savedContainerMode.isEmpty {
                        vocaPanelWebView = webViews[webViewKey(lang: savedLang, page: savedPage, containerMode: savedContainerMode)]
                    }
                    vocaPanelMode = .notFound(query: query)
                    presentVocaPanelInWebView()
                    showVocaToast(error.localizedDescription)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        vocaLookupInProgress = false
                    }
                }
            }
        }
    }
    
    private func playVocaAudio(_ card: VocaCard) {
        vocaIsPlayingAudio = true
        Task {
            do {
                try await VocaService.playCardAudio(card)
                await MainActor.run { vocaIsPlayingAudio = false }
            } catch {
                await MainActor.run {
                    vocaIsPlayingAudio = false
                    showVocaToast(error.localizedDescription)
                }
            }
        }
    }
    
    private func fetchHighlights() {
        Task {
            _ = try? await api.fetchHighlights(slug: book.slug)
        }
    }
    
    private func saveHighlight() {
        let slug = book.slug
        if let selection = activeSelection {
            let highlightPage = activeSelectionPage ?? page
            let newHighlight = Highlight(
                id: UUID().uuidString.lowercased(),
                page: highlightPage,
                lang: activeSelectionLang,
                color: selectedColor,
                text: selection.text,
                startOffset: selection.startOffset,
                endOffset: selection.endOffset,
                paragraphIndex: selection.paragraphIndex,
                note: highlightNote.isEmpty ? nil : highlightNote,
                createdAt: Int64(Date().timeIntervalSince1970 * 1000)
            )
            Task {
                do {
                    try await api.saveHighlight(slug: slug, highlight: newHighlight)
                    await MainActor.run { clearSelectionState() }
                } catch {
                    print("Failed saving highlight: \(error)")
                }
            }
        } else if let id = selectedHighlightId, let existing = api.highlights.first(where: { $0.id == id }) {
            let updated = Highlight(
                id: existing.id,
                page: existing.page,
                lang: existing.lang,
                color: selectedColor,
                text: existing.text,
                startOffset: existing.startOffset,
                endOffset: existing.endOffset,
                paragraphIndex: existing.paragraphIndex,
                note: highlightNote.isEmpty ? nil : highlightNote,
                createdAt: existing.createdAt
            )
            Task {
                do {
                    try await api.saveHighlight(slug: slug, highlight: updated)
                    await MainActor.run { clearSelectionState() }
                } catch {
                    print("Failed updating highlight: \(error)")
                }
            }
        }
    }
    
    private func deleteHighlight() {
        guard let id = selectedHighlightId else { return }
        Task {
            do {
                try await api.deleteHighlight(slug: book.slug, highlightId: id)
                await MainActor.run { clearSelectionState() }
            } catch {
                print("Failed deleting highlight: \(error)")
            }
        }
    }
    
    

    private func askAIShortcut(_ text: String) {
        // Implement if needed, or pass it to ChatPanelView
    }

    // MARK: - Companion Voice Mode Setup

    private func setupCompanionVM() {
        companionVM.bookTitle = book.title
        companionVM.bookAuthor = book.author ?? ""
        companionVM.bookSlug = book.slug
        companionVM.currentPage = page
        companionVM.totalPages = book.pageCount
        companionVM.currentViewMode = viewMode

        // Provide page text content to the voice session
        companionVM.pageContextProvider = { [self] page, viewMode in
            return await self.buildPageContext(for: page, viewMode: viewMode)
        }

        // Wire tool handler callbacks to existing reader functionality
        companionVM.toolHandler.onGoToPage = { [self] targetPage in
            let clamped = max(1, min(book.pageCount, targetPage))
            self.page = clamped
            self.updateCompanionAfterPageChange(newPage: clamped)
        }
        companionVM.toolHandler.onNextPage = { [self] in
            if self.page < book.pageCount {
                self.page += 1
                self.updateCompanionAfterPageChange(newPage: self.page)
            }
        }
        companionVM.toolHandler.onPreviousPage = { [self] in
            if self.page > 1 {
                self.page -= 1
                self.updateCompanionAfterPageChange(newPage: self.page)
            }
        }
        companionVM.toolHandler.getCurrentContext = { [self] in
            return [
                "page": self.page,
                "totalPages": book.pageCount,
                "viewMode": self.viewMode,
                "bookTitle": book.title,
                "bookAuthor": book.author ?? "Unknown"
            ]
        }
        companionVM.toolHandler.getPageContent = { [self] targetPage, lang in
            let p = targetPage ?? self.page
            let mode = lang ?? self.viewMode
            return await self.buildPageContext(for: p, viewMode: mode)
        }
        companionVM.toolHandler.onHighlightText = { [self] text, colorHex in
            // Find text in current page highlights or create new highlight
            // For now, search through loaded page content via WebView
            return await self.highlightTextViaCompanion(text: text, colorHex: colorHex)
        }
        companionVM.toolHandler.onRemoveHighlight = { [self] text in
            return await self.removeHighlightViaCompanion(text: text)
        }
        companionVM.toolHandler.onLookupWord = { [self] word in
            return await self.lookupWordViaCompanion(word: word)
        }
        companionVM.toolHandler.onAddWordToVoca = { [self] word in
            return await self.addWordToVocaViaCompanion(word: word)
        }
        companionVM.toolHandler.onSwitchViewMode = { [self] mode in
            self.viewMode = mode
            self.companionVM.currentViewMode = mode
            self.saveProgress()
        }
        companionVM.toolHandler.listHighlights = { [self] in
            let pageHighlights = self.api.highlights.filter { $0.page == self.page }
            return pageHighlights.map { h in
                var info: [String: Any] = [
                    "text": h.text,
                    "color": h.color,
                    "lang": h.lang
                ]
                if let note = h.note, !note.isEmpty {
                    info["note"] = note
                }
                return info
            }
        }
    }

    /// Sync companion VM state and inject new page context after any page change.
    private func updateCompanionAfterPageChange(newPage: Int) {
        companionVM.currentPage = newPage
        guard companionVM.phase == .live else { return }
        Task {
            // Small delay to let the WebView start loading the new page
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            let context = await self.buildPageContext(for: newPage, viewMode: self.viewMode)
            self.companionVM.updatePageContext(context, page: newPage)
        }
    }

    // MARK: - Companion Tool Implementations

    private func highlightTextViaCompanion(text: String, colorHex: String) async -> Bool {
        let containerMode = viewMode
        let langs: [String] = viewMode == "split" ? ["en", "vi"] : [viewMode]
        let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")

        for lang in langs {
            let key = webViewKey(lang: lang, page: page, containerMode: containerMode)
            guard let webView = webViews[key] else { continue }

            // Use JS to find text node and wrap it with a highlight <mark> tag.
            // This matches the existing wrapTextRange infrastructure from BilingualWebView.
            let highlightId = UUID().uuidString.lowercased()
            let js = """
            (function() {
                var searchText = '\(escapedText)';
                var body = document.body;
                if (!body) return JSON.stringify({success: false, reason: 'no body'});

                // Walk all text nodes to find matching text
                var walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT, null, false);
                var node;
                while (node = walker.nextNode()) {
                    var content = node.textContent;
                    var idx = content.toLowerCase().indexOf(searchText.toLowerCase());
                    if (idx >= 0) {
                        // Found! Create a <mark> wrapper around the matched range
                        var range = document.createRange();
                        range.setStart(node, idx);
                        range.setEnd(node, idx + searchText.length);

                        var mark = document.createElement('mark');
                        mark.className = 'reader-highlight';
                        mark.dataset.highlightId = '\(highlightId)';
                        mark.style.backgroundColor = '\(colorHex)';
                        mark.style.borderRadius = '3px';
                        mark.style.padding = '1px 0';

                        try {
                            range.surroundContents(mark);
                        } catch(e) {
                            // surroundContents fails if range crosses element boundaries
                            // Fallback: extract and wrap
                            var fragment = range.extractContents();
                            mark.appendChild(fragment);
                            range.insertNode(mark);
                        }

                        // Compute paragraph index for persistence
                        var paragraphs = body.querySelectorAll('p, div, h1, h2, h3, h4, h5, h6, li, td, th');
                        var pIndex = 0;
                        for (var i = 0; i < paragraphs.length; i++) {
                            if (paragraphs[i].contains(mark)) { pIndex = i; break; }
                        }
                        return JSON.stringify({success: true, paragraphIndex: pIndex, startOffset: idx, endOffset: idx + searchText.length, lang: '\(lang)'});
                    }
                }
                return JSON.stringify({success: false, reason: 'text not found'});
            })();
            """

            let result: String? = await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(js) { result, _ in
                    continuation.resume(returning: result as? String)
                }
            }

            guard let jsonString = result,
                  let data = jsonString.data(using: .utf8),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  info["success"] as? Bool == true,
                  let paragraphIndex = info["paragraphIndex"] as? Int,
                  let startOffset = info["startOffset"] as? Int,
                  let endOffset = info["endOffset"] as? Int
            else { continue }

            // Also persist to API so highlight survives page reloads
            let highlight = Highlight(
                id: highlightId,
                page: page,
                lang: lang,
                color: colorHex,
                text: text,
                startOffset: startOffset,
                endOffset: endOffset,
                paragraphIndex: paragraphIndex,
                note: nil,
                createdAt: Int64(Date().timeIntervalSince1970 * 1000)
            )

            Task {
                try? await api.saveHighlight(slug: book.slug, highlight: highlight)
            }
            return true
        }
        return false
    }

    private func removeHighlightViaCompanion(text: String) async -> Bool {
        guard let existing = api.highlights.first(where: {
            $0.text.lowercased() == text.lowercased() && $0.page == page
        }) else { return false }

        // Remove <mark> element from DOM visually
        let containerMode = viewMode
        let key = webViewKey(lang: existing.lang, page: page, containerMode: containerMode)
        if let webView = webViews[key] {
            let escapedId = existing.id.replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function() {
                var mark = document.querySelector('mark.reader-highlight[data-highlight-id="\\(escapedId)"]');
                if (mark) {
                    var parent = mark.parentNode;
                    while (mark.firstChild) { parent.insertBefore(mark.firstChild, mark); }
                    parent.removeChild(mark);
                    parent.normalize();
                    return true;
                }
                return false;
            })();
            """
            let _: Any? = await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(js) { result, _ in
                    continuation.resume(returning: result)
                }
            }
        }

        // Delete from API
        do {
            try await api.deleteHighlight(slug: book.slug, highlightId: existing.id)
            return true
        } catch {
            print("[Companion] Failed to delete highlight: \(error)")
            return false
        }
    }

    private func lookupWordViaCompanion(word: String) async -> String? {
        let query = VocaService.cleanWord(word)
        guard !query.isEmpty else { return nil }
        do {
            let result = try await VocaService.lookupWord(query)
            guard result.found, let card = result.resolvedCards.first else { return nil }
            // Build a concise definition string for the AI to read back
            var parts: [String] = [card.word]
            if let ipa = card.ipa, !ipa.isEmpty { parts.append(ipa) }
            parts.append(card.meaningVi)
            if let level = card.level, !level.isEmpty { parts.append("(\(level))") }
            return parts.joined(separator: " — ")
        } catch {
            return nil
        }
    }

    private func addWordToVocaViaCompanion(word: String) async -> Bool {
        let query = VocaService.cleanWord(word)
        guard !query.isEmpty else { return false }
        do {
            try await VocaService.addWordToVoca(query)
            return true
        } catch {
            return false
        }
    }

    // --- Persistence helper logic ---
    private func saveProgress() {
        let now = Int64(Date().timeIntervalSince1970)
        let localProgress = ReadingProgress(page: page, viewMode: viewMode, lastRead: now)
        
        if let data = UserDefaults.standard.data(forKey: "progress_\(book.slug)"),
           let cached = try? JSONDecoder().decode(ReadingProgress.self, from: data) {
            if cached.page == page && cached.viewMode == viewMode {
                return
            }
        }
        
        if let data = try? JSONEncoder().encode(localProgress) {
            UserDefaults.standard.set(data, forKey: "progress_\(book.slug)")
            NotificationCenter.default.post(name: NSNotification.Name("ReadingProgressUpdated"), object: nil)
        }
        
        Task {
            await api.saveProgress(slug: book.slug, page: page, viewMode: viewMode)
        }
    }
    
    private func loadProgress() {
        if let data = UserDefaults.standard.data(forKey: "progress_\(book.slug)"),
           let localProgress = try? JSONDecoder().decode(ReadingProgress.self, from: data) {
            self.page = localProgress.page
            self.viewMode = localProgress.viewMode
        }
        
        Task {
            do {
                let progress = try await api.fetchProgress(slug: book.slug)
                await MainActor.run {
                    var finalPage = self.page
                    var finalViewMode = self.viewMode
                    
                    if let data = UserDefaults.standard.data(forKey: "progress_\(book.slug)"),
                       let localProgress = try? JSONDecoder().decode(ReadingProgress.self, from: data) {
                        let localTime = localProgress.lastRead ?? 0
                        let serverTime = progress.lastRead ?? 0
                        if serverTime >= localTime {
                            finalPage = progress.page
                            finalViewMode = progress.viewMode
                        }
                    } else {
                        finalPage = progress.page
                        finalViewMode = progress.viewMode
                    }
                    
                    self.page = finalPage
                    self.viewMode = finalViewMode
                    
                    let now = Int64(Date().timeIntervalSince1970)
                    let progressToSave = ReadingProgress(page: finalPage, viewMode: finalViewMode, lastRead: now)
                    if let data = try? JSONEncoder().encode(progressToSave) {
                        UserDefaults.standard.set(data, forKey: "progress_\(book.slug)")
                        NotificationCenter.default.post(name: NSNotification.Name("ReadingProgressUpdated"), object: nil)
                    }
                    
                    Task {
                        await api.saveProgress(slug: book.slug, page: finalPage, viewMode: finalViewMode)
                    }
                }
            } catch {
                print("Failed to fetch progress from server: \(error)")
                await MainActor.run {
                    let now = Int64(Date().timeIntervalSince1970)
                    let progressToSave = ReadingProgress(page: self.page, viewMode: self.viewMode, lastRead: now)
                    if let data = try? JSONEncoder().encode(progressToSave) {
                        UserDefaults.standard.set(data, forKey: "progress_\(book.slug)")
                        NotificationCenter.default.post(name: NSNotification.Name("ReadingProgressUpdated"), object: nil)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func jumpToPageDialogView() -> some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture {
                    showJumpToPageDialog = false
                }
            
            VStack(spacing: 20) {
                Text("Đi tới trang")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                
                Text("Nhập số trang từ 1 đến \(book.pageCount)")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                
                HStack {
                    TextField("", text: $inputPageString)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .background(Color(hex: "0f172a"))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                        .focused($isPageFieldFocused)
                        .frame(width: 120)
                }
                
                HStack(spacing: 16) {
                    Button(action: {
                        showJumpToPageDialog = false
                    }) {
                        Text("Hủy")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color(hex: "0f172a"))
                            .cornerRadius(6)
                    }
                    
                    Button(action: {
                        if let targetPage = Int(inputPageString.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            let clampedPage = max(1, min(book.pageCount, targetPage))
                            page = clampedPage
                            showJumpToPageDialog = false
                        }
                    }) {
                        Text("Đi tiếp")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color(hex: "6366f1"))
                            .cornerRadius(6)
                    }
                }
            }
            .padding(24)
            .background(Color(hex: "1e293b"))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .frame(width: 280)
            .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 5)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isPageFieldFocused = true
            }
        }
    }

    private func chatContainerMode(for viewMode: String) -> String {
        switch viewMode {
        case "en": return "en"
        case "vi": return "vi"
        default: return "split"
        }
    }

    private func chatLangs(for viewMode: String) -> [String] {
        viewMode == "split" ? ["en", "vi"] : [viewMode]
    }

    private func extractTextFromWebView(_ webView: WKWebView) async -> String {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("document.body ? document.body.innerText.trim() : ''") { result, _ in
                let text = (result as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text)
            }
        }
    }

    private func plainText(fromHTML html: String) -> String {
        guard let data = html.data(using: .utf8) else { return "" }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return ""
        }
        return attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func plainTextFromCachedPage(lang: String, page: Int) -> String? {
        guard let url = BookCacheManager.shared.localPageURL(slug: book.slug, lang: lang, page: page),
              let html = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let text = plainText(fromHTML: html)
        return text.isEmpty ? nil : text
    }

    private func fetchPagePlainText(lang: String, page: Int) async -> String? {
        if let cached = plainTextFromCachedPage(lang: lang, page: page) {
            return cached
        }

        let padPage = String(format: "%04d", page)
        let urlString = "\(api.serverUrl)/books/\(book.slug)/output/\(lang)/page_\(padPage).html?token=\(api.token)"
        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { return nil }
            let text = plainText(fromHTML: html)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    private func pageTextSection(lang: String, page: Int, containerMode: String) async -> String? {
        let key = webViewKey(lang: lang, page: page, containerMode: containerMode)
        if let webView = webViews[key] {
            let liveText = await extractTextFromWebView(webView)
            if !liveText.isEmpty {
                return "=== \(lang.uppercased()) PAGE \(page) ===\n\(liveText)"
            }
        }

        if let fallbackText = await fetchPagePlainText(lang: lang, page: page) {
            return "=== \(lang.uppercased()) PAGE \(page) ===\n\(fallbackText)"
        }

        return nil
    }

    private func buildPageContext(for page: Int, viewMode: String) async -> String {
        let containerMode = viewMode
        let langs: [String] = viewMode == "split" ? ["en", "vi"] : [viewMode]
        var sections: [String] = []

        for lang in langs {
            if let section = await pageTextSection(lang: lang, page: page, containerMode: containerMode) {
                sections.append(section)
            }
        }

        return sections.joined(separator: "\n\n")
    }
}

struct UnevenRoundedCorners: Shape {
    var tl: CGFloat = 0.0
    var tr: CGFloat = 0.0
    var bl: CGFloat = 0.0
    var br: CGFloat = 0.0

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let w = rect.size.width
        let h = rect.size.height

        let tr = min(min(self.tr, h/2), w/2)
        let tl = min(min(self.tl, h/2), w/2)
        let bl = min(min(self.bl, h/2), w/2)
        let br = min(min(self.br, h/2), w/2)

        path.move(to: CGPoint(x: w / 2.0, y: 0))
        path.addLine(to: CGPoint(x: w - tr, y: 0))
        path.addArc(center: CGPoint(x: w - tr, y: tr), radius: tr,
                    startAngle: Angle(degrees: -90), endAngle: Angle(degrees: 0), clockwise: false)
        path.addLine(to: CGPoint(x: w, y: h - br))
        path.addArc(center: CGPoint(x: w - br, y: h - br), radius: br,
                    startAngle: Angle(degrees: 0), endAngle: Angle(degrees: 90), clockwise: false)
        path.addLine(to: CGPoint(x: bl, y: h))
        path.addArc(center: CGPoint(x: bl, y: h - bl), radius: bl,
                    startAngle: Angle(degrees: 90), endAngle: Angle(degrees: 180), clockwise: false)
        path.addLine(to: CGPoint(x: 0, y: tl))
        path.addArc(center: CGPoint(x: tl, y: tl), radius: tl,
                    startAngle: Angle(degrees: 180), endAngle: Angle(degrees: 270), clockwise: false)
        path.closeSubpath()

        return path
    }
}

struct PaperSheetModifier: ViewModifier {
    var viewMode: String
    var page: Int
    var isDoubleSided: Bool
    
    func body(content: Content) -> some View {
        if isDoubleSided && viewMode != "split" {
            let isLeft = page % 2 == 1
            content
                .background(Color(hex: "F9F7F1"))
                .overlay(
                    Group {
                        if isLeft {
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.03), .black.opacity(0.12)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 40)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        } else {
                            LinearGradient(
                                colors: [.black.opacity(0.12), .black.opacity(0.03), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 40)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                )
                .clipShape(UnevenRoundedCorners(
                    tl: isLeft ? 6 : 0,
                    tr: isLeft ? 0 : 6,
                    bl: isLeft ? 6 : 0,
                    br: isLeft ? 0 : 6
                ))
                .shadow(color: .black.opacity(0.15), radius: 5, x: isLeft ? -2 : 2, y: 3)
        } else {
            content
                .background(Color(hex: "F9F7F1"))
                .cornerRadius(4)
                .shadow(color: .black.opacity(0.15), radius: 5, x: 0, y: 3)
        }
    }
}

struct BouncingDotsView: View {
    @State private var offset1: CGFloat = 0
    @State private var offset2: CGFloat = 0
    @State private var offset3: CGFloat = 0
    
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(hex: "14b8a6").opacity(0.8))
                .frame(width: 6, height: 6)
                .offset(y: offset1)
            Circle()
                .fill(Color(hex: "14b8a6").opacity(0.8))
                .frame(width: 6, height: 6)
                .offset(y: offset2)
            Circle()
                .fill(Color(hex: "14b8a6").opacity(0.8))
                .frame(width: 6, height: 6)
                .offset(y: offset3)
        }
        .onAppear {
            animateDots()
        }
    }
    
    private func animateDots() {
        let animation = Animation.easeInOut(duration: 0.5).repeatForever(autoreverses: true)
        withAnimation(animation) {
            offset1 = -6
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(animation) {
                offset2 = -6
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(animation) {
                offset3 = -6
            }
        }
    }
}

struct SuggestedPromptRow: View {
    let icon: String
    let title: String
    let prompt: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(icon)
                    .font(.system(size: 20))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                    Text(prompt)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.gray.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.04))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

struct MarkdownBlock: Identifiable {
    let id = UUID()
    enum BlockType {
        case header(level: Int)
        case bulletList
        case numberedList(index: Int)
        case code(language: String?)
        case paragraph
    }
    let type: BlockType
    let content: String
}

struct MarkdownView: View {
    let text: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(parseBlocks(text)) { block in
                renderBlock(block)
            }
        }
    }
    
    private func parseBlocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: .newlines)
        
        var inCodeBlock = false
        var codeContent = ""
        var codeLanguage: String? = nil
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if line.starts(with: "```") {
                if inCodeBlock {
                    // End of code block
                    blocks.append(MarkdownBlock(type: .code(language: codeLanguage), content: codeContent.trimmingCharacters(in: .whitespacesAndNewlines)))
                    inCodeBlock = false
                    codeContent = ""
                    codeLanguage = nil
                } else {
                    // Start of code block
                    inCodeBlock = true
                    let lang = line.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
                    codeLanguage = lang.isEmpty ? nil : lang
                }
                continue
            }
            
            if inCodeBlock {
                codeContent += line + "\n"
                continue
            }
            
            if trimmed.isEmpty {
                continue
            }
            
            // Check for Headers
            if trimmed.starts(with: "#") {
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                if let first = parts.first, first.allSatisfy({ $0 == "#" }) {
                    let level = first.count
                    let content = parts.count > 1 ? String(parts[1]) : ""
                    blocks.append(MarkdownBlock(type: .header(level: level), content: content))
                    continue
                }
            }
            
            // Check for Bullet List
            if trimmed.starts(with: "* ") || trimmed.starts(with: "- ") {
                let content = String(trimmed.dropFirst(2))
                blocks.append(MarkdownBlock(type: .bulletList, content: content))
                continue
            }
            
            // Check for Numbered List (e.g., "1. ")
            if let firstWord = trimmed.split(separator: " ").first,
               firstWord.hasSuffix("."),
               let index = Int(firstWord.dropLast()) {
                let content = trimmed.dropFirst(firstWord.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
                blocks.append(MarkdownBlock(type: .numberedList(index: index), content: content))
                continue
            }
            
            // Default to paragraph
            blocks.append(MarkdownBlock(type: .paragraph, content: trimmed))
        }
        
        // If we finished but are still in code block
        if inCodeBlock && !codeContent.isEmpty {
            blocks.append(MarkdownBlock(type: .code(language: codeLanguage), content: codeContent.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        
        return blocks
    }
    
    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block.type {
        case .header(let level):
            Text(parseInline(block.content))
                .font(.system(size: headerFontSize(level), weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 8)
                .padding(.bottom, 4)
            
        case .bulletList:
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .foregroundColor(Color(hex: "14b8a6"))
                    .font(.system(size: 14, weight: .bold))
                Text(parseInline(block.content))
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 8)
            
        case .numberedList(let index):
            HStack(alignment: .top, spacing: 6) {
                Text("\(index).")
                    .foregroundColor(Color(hex: "14b8a6"))
                    .font(.system(size: 14, weight: .bold))
                Text(parseInline(block.content))
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 8)
            
        case .code(let language):
            VStack(alignment: .leading, spacing: 0) {
                // Header bar
                HStack {
                    Text(language ?? "code")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                    Spacer()
                    Button(action: {
                        UIPasteboard.general.string = block.content
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.04))
                
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(block.content)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Color(hex: "e2e8f0"))
                        .padding(12)
                }
            }
            .background(Color.black.opacity(0.3))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .padding(.vertical, 4)
            
        case .paragraph:
            Text(parseInline(block.content))
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private func headerFontSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 20
        case 2: return 18
        case 3: return 16
        default: return 14
        }
    }
    
    private func parseInline(_ text: String) -> AttributedString {
        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            return try AttributedString(markdown: text, options: options)
        } catch {
            return AttributedString(text)
        }
    }
}



// --- Extracted Components ---

struct ReaderChatPanelView: View {
    @Binding var isChatOpen: Bool
    @Binding var bilingualLayoutMode: String
    
    // Callbacks to ReaderView
    let book: Book
    let page: Int
    let viewMode: String
    @ObservedObject var api: APIService
    var isLargeScreen: Bool = true
    @ObservedObject var companionVM: CompanionVoiceViewModel
    var pageContextBuilder: (Int, String) async -> String = { _, _ in "" }
    var onAskAIShortcut: ((String) -> Void)?
    
    // Internal States
    @State private var isAISettingsOpen = false
    @State private var chatMessages: [ChatMessage] = []
    @State private var chatInputText: String = ""
    @State private var isChatPending = false
    @State private var suggestedPrompts: [(icon: String, title: String, prompt: String)] = []
    @State private var suggestionsPage: Int = -1 // track which page suggestions were generated for
    @State private var isLoadingSuggestions = false
    
    // Settings States
    @AppStorage("aiProvider") private var aiProvider: String = "openai"
    @AppStorage("aiBaseURL") private var aiBaseURL: String = "https://api.openai.com/v1"
    @AppStorage("aiApiKey") private var aiApiKey: String = ""
    @AppStorage("aiModel") private var aiModel: String = "gpt-4o-mini"
    @AppStorage("vocaBridgeOrigin") private var vocaBridgeOrigin: String = VocaService.defaultBridgeOrigin
    @AppStorage("vocaBridgeToken") private var vocaBridgeToken: String = VocaService.defaultBridgeToken
    
    // Drag resizing states
    @State private var chatWidth: CGFloat = 350
    @State private var dragStartingWidth: CGFloat = 350
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging: Bool = false
    
    var body: some View {
        HStack(spacing: 0) {
            // Drag Handle
            if isLargeScreen {
                ZStack {
                    Rectangle()
                        .fill(Color(hex: "0b0f19"))
                        .frame(width: 14)
                    
                    Capsule()
                        .fill(isDragging ? Color(hex: "14b8a6") : Color(hex: "14b8a6").opacity(0.2))
                        .frame(width: isDragging ? 2.5 : 1.5)
                        .shadow(color: isDragging ? Color(hex: "14b8a6").opacity(0.6) : .clear, radius: 4)
                        .padding(.vertical, 100)
                }
                .contentShape(Rectangle())
                .overlay(
                    Circle()
                        .fill(isDragging ? Color.white : Color.gray.opacity(0.6))
                        .frame(width: 24, height: 24)
                        .overlay(
                            Image(systemName: "chevron.left.chevron.right")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Color(hex: "0b0f19"))
                        )
                )
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if !isDragging {
                                isDragging = true
                                dragStartingWidth = chatWidth
                            }
                            // Reversed offset because dragging left means wider chat panel
                            let delta = value.translation.width
                            dragOffset = delta
                        }
                        .onEnded { value in
                            let delta = value.translation.width
                            let newWidth = dragStartingWidth - delta
                            
                            // Limit width
                            chatWidth = max(250, min(800, newWidth))
                            dragOffset = 0
                            isDragging = false
                        }
                )
                
                // Divider
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1)
            }
            
            // Actual Chat Panel Content
            aiAssistantPanel()
        }
        .frame(width: isLargeScreen ? max(250, chatWidth - dragOffset) : nil)
        .background(Color(hex: "0b0f19"))
        .onAppear {
            loadChatHistory()
        }
    }
    
    @ViewBuilder
    private func aiAssistantPanel() -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Color(hex: "14b8a6"))
                            .shadow(color: Color(hex: "14b8a6").opacity(0.5), radius: 4)
                        Text("Companion Agent")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Text("AI-powered reading companion")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                // Voice Mode Toggle
                Button(action: {
                    toggleVoiceMode()
                }) {
                    ZStack {
                        Image(systemName: companionVM.phase != .idle ? "waveform.circle.fill" : "mic.fill")
                            .font(.system(size: 14))
                            .foregroundColor(companionVM.phase != .idle ? Color(hex: "14b8a6") : .white.opacity(0.8))
                            .frame(width: 32, height: 32)
                            .background(companionVM.phase != .idle ? Color(hex: "14b8a6").opacity(0.2) : Color.white.opacity(0.08))
                            .clipShape(Circle())
                        
                        if companionVM.phase != .idle {
                            Circle()
                                .stroke(Color(hex: "14b8a6").opacity(0.5), lineWidth: 1.5)
                                .frame(width: 36, height: 36)
                        }
                    }
                }
                
                // Settings Toggle
                Button(action: {
                    withAnimation(.spring()) {
                        isAISettingsOpen.toggle()
                    }
                }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14))
                        .foregroundColor(isAISettingsOpen ? Color(hex: "14b8a6") : .white.opacity(0.8))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(isAISettingsOpen ? 0.15 : 0.08))
                        .clipShape(Circle())
                }
                
                // Clear History Button
                Button(action: {
                    withAnimation(.spring()) {
                        chatMessages = []
                        saveChatHistory()
                    }
                }) {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.red.opacity(0.8))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(hex: "0b0f19"))
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(Color.white.opacity(0.06)),
                alignment: .bottom
            )
            
            if isAISettingsOpen {
                aiSettingsForm()
                    .transition(.move(edge: .trailing))
            } else if companionVM.phase != .idle {
                // Voice Mode UI
                voiceModeContent()
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                // Messages List
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if chatMessages.isEmpty {
                                emptyChatStateView()
                            } else {
                                ForEach(chatMessages, id: \.id) { msg in
                                    chatMessageRow(msg)
                                }
                                
                                if isChatPending {
                                    chatPendingView()
                                }
                            }
                        }
                        .padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: chatMessages.count) { _ in
                        if let last = chatMessages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: isChatPending) { pending in
                        if pending {
                            withAnimation {
                                proxy.scrollTo("pending_anchor", anchor: .bottom)
                            }
                        }
                    }
                }
                .background(Color(hex: "0b0f19"))
                
                // Input panel
                chatInputArea()
            }
        }
    }
    
    @ViewBuilder
    private func emptyChatStateView() -> some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 20)
            
            // Glowing AI Icon
            ZStack {
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(hex: "14b8a6").opacity(0.25), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 50
                    ))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "sparkles")
                    .font(.system(size: 38))
                    .foregroundColor(Color(hex: "14b8a6"))
                    .shadow(color: Color(hex: "14b8a6").opacity(0.6), radius: 8)
            }
            
            VStack(spacing: 8) {
                Text("Chào mừng bạn!")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text("Companion Agent sẵn sàng hỗ trợ bạn phân tích, thảo luận và khám phá nội dung cuốn sách.")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 20)
            }
            
            Spacer().frame(height: 10)
            
            // Suggested Prompt cards
            VStack(alignment: .leading, spacing: 10) {
                Text("GỢI Ý CÂU HỎI")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.gray.opacity(0.8))
                    .padding(.horizontal, 4)
                
                SuggestedPromptRow(
                    icon: "📝",
                    title: "Tóm tắt trang này",
                    prompt: "Tóm tắt nội dung chính của trang đang đọc..."
                ) {
                    sendChat(with: "Tóm tắt nội dung chính và các ý chính của trang sách này giúp tôi.")
                }
                
                if isLoadingSuggestions {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(.gray)
                        Text("Đang tạo gợi ý...")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                } else {
                    ForEach(Array(suggestedPrompts.enumerated()), id: \.offset) { _, item in
                        SuggestedPromptRow(
                            icon: item.icon,
                            title: item.title,
                            prompt: item.prompt
                        ) {
                            sendChat(with: item.prompt)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 20)
        .onAppear {
            if suggestionsPage != page {
                generateSuggestions()
            }
        }
        .onChange(of: page) { newPage in
            if suggestionsPage != newPage {
                generateSuggestions()
            }
        }
    }
    
    @ViewBuilder
    private func chatMessageRow(_ msg: ChatMessage) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if msg.role == "assistant" {
                // AI Avatar
                LinearGradient(
                    colors: [Color(hex: "0d9488"), Color(hex: "2dd4bf")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(width: 28, height: 28)
                .clipShape(Circle())
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                )
                .shadow(color: Color(hex: "14b8a6").opacity(0.3), radius: 3)
                .padding(.bottom, 2)
            }
            
            if msg.role == "user" { Spacer() }
            
            VStack(alignment: msg.role == "user" ? .trailing : .leading, spacing: 4) {
                if msg.role == "user" {
                    Text(msg.content)
                        .font(.system(size: 14))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "818cf8"), Color(hex: "6366f1")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .foregroundColor(.white)
                        .clipShape(UnevenRoundedCorners(tl: 16, tr: 16, bl: 16, br: 4))
                        .shadow(color: Color(hex: "6366f1").opacity(0.2), radius: 4, x: 0, y: 2)
                } else {
                    MarkdownView(text: msg.content)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.06))
                        .foregroundColor(.white)
                        .clipShape(UnevenRoundedCorners(tl: 16, tr: 16, bl: 4, br: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.05), lineWidth: 1)
                        )
                }
            }
            
            if msg.role == "assistant" { Spacer() }
        }
        .id(msg.id)
    }
    
    @ViewBuilder
    private func chatPendingView() -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            // AI Avatar
            LinearGradient(
                colors: [Color(hex: "0d9488"), Color(hex: "2dd4bf")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(width: 28, height: 28)
            .clipShape(Circle())
            .overlay(
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            )
            .shadow(color: Color(hex: "14b8a6").opacity(0.3), radius: 3)
            .padding(.bottom, 2)
            
            HStack(spacing: 8) {
                BouncingDotsView()
                    .frame(height: 12)
                Text("AI đang suy nghĩ...")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.white.opacity(0.06))
            .clipShape(UnevenRoundedCorners(tl: 16, tr: 16, bl: 4, br: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            )
            .id("pending_anchor")
            Spacer()
        }
    }
    
    @ViewBuilder
    private func chatInputArea() -> some View {
        HStack(spacing: 10) {
            TextField("Hỏi trợ lý...", text: $chatInputText, axis: .vertical)
                .lineLimit(1...5)
                .font(.system(size: 14))
                .foregroundColor(.white)
                .tint(Color(hex: "14b8a6"))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.05))
                .cornerRadius(18)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
            
            Button(action: {
                sendChat()
            }) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: "818cf8"), Color(hex: "6366f1")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Circle())
                    .shadow(color: Color(hex: "6366f1").opacity(0.3), radius: 6, x: 0, y: 2)
            }
            .disabled(chatInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChatPending)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(hex: "0b0f19"))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.white.opacity(0.06)),
            alignment: .top
        )
    }
    
    @ViewBuilder
    private func aiSettingsForm() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("CẤU HÌNH AI & VOCA")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.gray)
                    .padding(.top, 10)
                
                // Section 1: Provider Picker
                VStack(alignment: .leading, spacing: 10) {
                    Text("Nhà cung cấp")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))
                    
                    HStack(spacing: 4) {
                        ForEach(["openai", "gemini", "custom"], id: \.self) { provider in
                            let isSelected = aiProvider == provider
                            let displayName = provider == "openai" ? "OpenAI" : (provider == "gemini" ? "Gemini" : "Custom")
                            
                            Button(action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    aiProvider = provider
                                    if provider == "openai" {
                                        aiBaseURL = "https://api.openai.com/v1"
                                        aiModel = "gpt-4o-mini"
                                    } else if provider == "gemini" {
                                        aiBaseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
                                        aiModel = "gemini-1.5-flash"
                                    }
                                }
                            }) {
                                Text(displayName)
                                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                    .foregroundColor(isSelected ? .white : .gray.opacity(0.8))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
                                    )
                            }
                        }
                    }
                    .padding(4)
                    .background(Color.white.opacity(0.03))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                }
                .padding()
                .background(Color.white.opacity(0.04))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                
                // Section 2: Input fields
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Base URL")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.gray)
                        
                        HStack {
                            TextField("Base URL", text: $aiBaseURL, prompt: Text("Nhập URL cơ sở...").foregroundColor(.gray.opacity(0.5)))
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.none)
                            
                            Button(action: {
                                if let pasteboardString = UIPasteboard.general.string {
                                    aiBaseURL = pasteboardString.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            }) {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(hex: "14b8a6"))
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Key")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.gray)
                        
                        HStack {
                            SecureField("API Key", text: $aiApiKey, prompt: Text("Nhập API Key của bạn...").foregroundColor(.gray.opacity(0.5)))
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.none)
                            
                            Button(action: {
                                if let pasteboardString = UIPasteboard.general.string {
                                    aiApiKey = pasteboardString.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            }) {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(hex: "14b8a6"))
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tên Model")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.gray)
                        
                        HStack {
                            TextField("Model Name", text: $aiModel, prompt: Text("Ví dụ: gpt-4o-mini").foregroundColor(.gray.opacity(0.5)))
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.none)
                            
                            Button(action: {
                                if let pasteboardString = UIPasteboard.general.string {
                                    aiModel = pasteboardString.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            }) {
                                Image(systemName: "doc.on.clipboard")
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(hex: "14b8a6"))
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    }
                }
                .padding()
                .background(Color.white.opacity(0.04))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                
                // Section: Voca Dictionary Bridge
                VStack(alignment: .leading, spacing: 16) {
                    Text("Voca Dictionary Bridge")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Voca Bridge URL")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.gray)
                        TextField("https://voca-bridge.thaonv.online", text: $vocaBridgeOrigin)
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(12)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Voca API Token")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.gray)
                        SecureField("Bearer token", text: $vocaBridgeToken)
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(12)
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    }
                }
                .padding()
                .background(Color.white.opacity(0.04))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                
                // Section 3: Bilingual Layout Mode
                VStack(alignment: .leading, spacing: 12) {
                    Text("Bố cục song ngữ")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                    
                    HStack(spacing: 8) {
                        LayoutOptionButton(mode: "en-vi", badge1: "EN", badge2: "VI", isVertical: false, selectedMode: $bilingualLayoutMode)
                        LayoutOptionButton(mode: "vi-en", badge1: "VI", badge2: "EN", isVertical: false, selectedMode: $bilingualLayoutMode)
                        LayoutOptionButton(mode: "en-over-vi", badge1: "EN", badge2: "VI", isVertical: true, selectedMode: $bilingualLayoutMode)
                        LayoutOptionButton(mode: "vi-over-en", badge1: "VI", badge2: "EN", isVertical: true, selectedMode: $bilingualLayoutMode)
                    }
                }
                .padding()
                .background(Color.white.opacity(0.04))
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                
                // Save Button
                Button(action: {
                    withAnimation(.spring()) {
                        isAISettingsOpen = false
                    }
                }) {
                    Text("Hoàn tất")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [Color(hex: "0d9488"), Color(hex: "14b8a6")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .cornerRadius(14)
                        .shadow(color: Color(hex: "14b8a6").opacity(0.25), radius: 8, x: 0, y: 4)
                }
                .padding(.top, 10)
            }
            .padding(16)
        }
        .background(Color(hex: "0b0f19"))
    }
    
    private func loadChatHistory() {
        if let data = UserDefaults.standard.data(forKey: "chatHistory_\(book.slug)"),
           let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            self.chatMessages = decoded
        }
    }
    
    private func saveChatHistory() {
        if let data = try? JSONEncoder().encode(chatMessages) {
            UserDefaults.standard.set(data, forKey: "chatHistory_\(book.slug)")
        }
    }
    
    private func sendChat(with presetText: String? = nil) {
        let textToSend = (presetText ?? chatInputText).trimmingCharacters(in: .whitespacesAndNewlines)
        if textToSend.isEmpty || isChatPending { return }
        
        if aiApiKey.isEmpty {
            chatMessages.append(ChatMessage(role: "assistant", content: "Vui lòng vào Settings (nút răng cưa góc trên phải) cấu hình API Key của bạn để sử dụng Companion Agent!"))
            chatInputText = ""
            return
        }
        
        let userMsg = ChatMessage(role: "user", content: textToSend)
        chatMessages.append(userMsg)
        chatInputText = ""
        isChatPending = true
        saveChatHistory()
        
        let contextPage = page
        let contextViewMode = viewMode
        
        Task { @MainActor in
            let activePageText = await pageContextBuilder(contextPage, contextViewMode)
            let pageContextBlock = activePageText.isEmpty
                ? "Page text unavailable. Ask the user to wait for the page to finish loading, then try again."
                : activePageText
            
            let systemPrompt = """
            You are a helpful, expert AI Book Assistant. You are guiding the user who is reading the book "\(book.title)" by \(book.author ?? "Unknown").
            The user is currently reading page \(contextPage).
            
            CURRENT PAGE CONTEXT:
            \(pageContextBlock)
            
            Instructions:
            1. Answer the user's questions accurately based on the CURRENT PAGE CONTEXT above.
            2. If the user asks about something on this page, prioritize the CURRENT PAGE CONTEXT.
            3. Keep your responses structured, clear, and scan-friendly.
            4. Please answer in Vietnamese unless the user asks you to write or explain in English. Keep code blocks in their original programming language.
            """
            
            var apiMessages = [
                ["role": "system", "content": systemPrompt]
            ]
            for msg in chatMessages.suffix(10) {
                apiMessages.append(["role": msg.role, "content": msg.content])
            }
            
            do {
                let responseText = try await api.sendChat(
                    baseURL: aiBaseURL,
                    apiKey: aiApiKey,
                    model: aiModel,
                    messages: apiMessages
                )
                self.chatMessages.append(ChatMessage(role: "assistant", content: responseText))
                self.isChatPending = false
                self.saveChatHistory()
            } catch {
                self.chatMessages.append(ChatMessage(role: "assistant", content: "Lỗi kết nối AI: \(error.localizedDescription). Hãy kiểm tra lại Base URL và API Key trong cài đặt."))
                self.isChatPending = false
                self.saveChatHistory()
            }
        }
    }

    // MARK: - Dynamic Suggestion Prompts

    private func generateSuggestions() {
        guard !aiApiKey.isEmpty else { return }
        let targetPage = page
        isLoadingSuggestions = true
        suggestedPrompts = []

        Task { @MainActor in
            let pageText = await pageContextBuilder(targetPage, viewMode)
            guard !pageText.isEmpty else {
                isLoadingSuggestions = false
                return
            }

            let systemPrompt = """
            You generate 3 contextual question suggestions for a reader. The reader is reading page \(targetPage) of "\(book.title)".

            PAGE CONTENT:
            \(pageText.prefix(2000))

            Return ONLY a JSON array of exactly 3 objects, each with:
            - "icon": a single emoji that fits the question theme
            - "title": short title in Vietnamese (max 20 chars)
            - "prompt": the full question in Vietnamese (1-2 sentences)

            The questions should be specific to THIS page content, not generic. Focus on:
            - Key concepts, terminology, or ideas mentioned on this page
            - Interesting connections or deeper analysis
            - Practical applications or real-world relevance

            Example format: [{"icon":"🧠","title":"Khái niệm X","prompt":"Giải thích khái niệm X được đề cập trong trang này..."}]
            Return ONLY the JSON array, no other text.
            """

            let messages = [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Generate 3 suggestion prompts for this page."]
            ]

            do {
                let response = try await api.sendChat(
                    baseURL: aiBaseURL,
                    apiKey: aiApiKey,
                    model: aiModel,
                    messages: messages
                )
                // Parse JSON response
                let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "```json", with: "")
                    .replacingOccurrences(of: "```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if let data = cleaned.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                    self.suggestedPrompts = arr.prefix(3).compactMap { item in
                        guard let icon = item["icon"],
                              let title = item["title"],
                              let prompt = item["prompt"]
                        else { return nil }
                        return (icon: icon, title: title, prompt: prompt)
                    }
                }
                self.suggestionsPage = targetPage
            } catch {
                print("[Companion] Failed to generate suggestions: \(error)")
            }
            self.isLoadingSuggestions = false
        }
    }

    // MARK: - Voice Mode

    private func toggleVoiceMode() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            if companionVM.phase != .idle {
                companionVM.end()
            } else {
                isAISettingsOpen = false
                Task {
                    await companionVM.start()
                }
            }
        }
    }

    @ViewBuilder
    private func voiceModeContent() -> some View {
        ZStack {
            Color(hex: "0b0f19").ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Connecting spinner
                if companionVM.phase == .connecting {
                    ProgressView()
                        .tint(Color(hex: "14b8a6"))
                        .scaleEffect(1.2)
                        .padding(.bottom, 24)
                }

                // Error
                if let error = companionVM.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title2)
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("Thử lại") {
                            companionVM.errorMessage = nil
                            Task { await companionVM.start() }
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(Color(hex: "14b8a6"))
                        .cornerRadius(8)
                    }
                    .padding(.bottom, 24)
                }

                // Audio Orb — the main visual
                if companionVM.phase == .live {
                    CompanionOrbView(
                        level: max(companionVM.inputLevel, companionVM.outputLevel),
                        aiSpeaking: companionVM.micState == .aiSpeaking,
                        userSpeaking: companionVM.userIsSpeaking
                    )
                    .frame(width: 220, height: 220)
                }

                // Tool feedback (transient)
                if let feedback = companionVM.toolFeedback {
                    Text(feedback)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "14b8a6"))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color(hex: "14b8a6").opacity(0.08))
                        .cornerRadius(16)
                        .padding(.top, 16)
                        .transition(.opacity)
                }

                Spacer()

                // Bottom controls
                ZStack {
                    // Center: End call button
                    Button(action: {
                        withAnimation(.spring()) {
                            companionVM.end()
                        }
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.red.opacity(0.15))
                                .frame(width: 56, height: 56)
                            Circle()
                                .strokeBorder(Color.red.opacity(0.4), lineWidth: 1.5)
                                .frame(width: 56, height: 56)
                            Image(systemName: "phone.down.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.red)
                        }
                    }

                    // Right: Small mic indicator
                    HStack {
                        Spacer()
                        Button(action: {
                            companionVM.toggleMic()
                        }) {
                            ZStack {
                                Circle()
                                    .fill(voiceMicColor.opacity(0.12))
                                    .frame(width: 36, height: 36)
                                Image(systemName: voiceMicIcon)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(voiceMicColor)
                            }
                        }
                        .disabled(companionVM.phase != .live || companionVM.micState == .aiSpeaking)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
    }

    private var voiceMicColor: Color {
        switch companionVM.micState {
        case .open:
            return Color(hex: "14b8a6")
        case .aiSpeaking:
            return Color(hex: "818cf8")
        case .muted:
            return .gray
        }
    }

    private var voiceMicIcon: String {
        switch companionVM.micState {
        case .open:
            return "mic.fill"
        case .aiSpeaking:
            return "speaker.wave.2.fill"
        case .muted:
            return "mic.slash.fill"
        }
    }
}

/// Vivid multi-layered audio visualizer orb.
struct CompanionOrbView: View {
    let level: Float
    let aiSpeaking: Bool
    let userSpeaking: Bool

    @State private var breathe: CGFloat = 1.0
    @State private var rotation: Double = 0
    @State private var ringPhase: CGFloat = 0

    private var teal: Color { Color(hex: "14b8a6") }
    private var indigo: Color { Color(hex: "818cf8") }
    private var accent: Color { aiSpeaking ? indigo : teal }
    private var amp: CGFloat { CGFloat(min(level * 1.5, 1.0)) }

    var body: some View {
        ZStack {
            // Layer 1: Outer ambient glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(0.08 + Double(amp) * 0.15), .clear],
                        center: .center,
                        startRadius: 20,
                        endRadius: 130
                    )
                )
                .frame(width: 260, height: 260)
                .scaleEffect(breathe + amp * 0.08)

            // Layer 2: Rotating ring (dashed)
            Circle()
                .stroke(
                    accent.opacity(0.15 + Double(amp) * 0.2),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 8], dashPhase: ringPhase)
                )
                .frame(width: 160, height: 160)
                .rotationEffect(.degrees(rotation))
                .scaleEffect(1.0 + amp * 0.06)

            // Layer 3: Pulsing outer ring
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [accent.opacity(0.3 + Double(amp) * 0.3), accent.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 2
                )
                .frame(width: 130, height: 130)
                .scaleEffect(1.0 + amp * 0.12)

            // Layer 4: Inner glow ring
            Circle()
                .strokeBorder(accent.opacity(0.2 + Double(amp) * 0.4), lineWidth: 1.5)
                .frame(width: 100, height: 100)
                .scaleEffect(1.0 + amp * 0.08)

            // Layer 5: Core orb with gradient
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            accent.opacity(0.5 + Double(amp) * 0.3),
                            accent.opacity(0.15),
                            accent.opacity(0.05),
                        ],
                        center: .center,
                        startRadius: 5,
                        endRadius: 45
                    )
                )
                .frame(width: 80, height: 80)
                .scaleEffect(1.0 + amp * 0.15)
                .shadow(color: accent.opacity(Double(amp) * 0.5), radius: 20)

            // Layer 6: Glass highlight
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.15), .clear],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .frame(width: 50, height: 30)
                .offset(y: -15)
                .scaleEffect(1.0 + amp * 0.1)
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .animation(.easeInOut(duration: 0.4), value: aiSpeaking)
        .onAppear {
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                breathe = 1.03
            }
            withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) {
                rotation = 360
            }
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                ringPhase = 24
            }
        }
    }
}

struct ReaderHeaderView: View {
    let book: Book
    let useDoubleSided: Bool
    
    @Binding var page: Int
    @Binding var viewMode: String
    @Binding var isChatOpen: Bool
    @Binding var isPencilModeActive: Bool
    @Binding var showJumpToPageDialog: Bool
    @Binding var inputPageString: String
    
    var onDismiss: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Button(action: onDismiss) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                    Text("Library")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
            }
            
            Spacer()
            
            Text(book.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            
            Spacer()
            
            let canPrev = useDoubleSided ? (page > 2) : (page > 1)
            let canNext = {
                if useDoubleSided {
                    let left = page % 2 == 1 ? page : max(1, page - 1)
                    return left + 1 < book.pageCount
                } else {
                    return page < book.pageCount
                }
            }()
            let pageText: String = {
                if useDoubleSided {
                    let left = page % 2 == 1 ? page : max(1, page - 1)
                    let right = left + 1
                    if right <= book.pageCount {
                        return "Trang \(left)-\(right)/\(book.pageCount)"
                    } else {
                        return "Trang \(left)/\(book.pageCount)"
                    }
                } else {
                    return "Trang \(page)/\(book.pageCount)"
                }
            }()

            HStack(spacing: 0) {
                Button(action: {
                    let step = useDoubleSided ? 2 : 1
                    if page > 1 { page = max(1, page - step) }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .opacity(canPrev ? 1.0 : 0.25)
                        .frame(width: 32, height: 28)
                }
                .disabled(!canPrev)
                
                Button(action: {
                    inputPageString = "\(page)"
                    showJumpToPageDialog = true
                }) {
                    Text(pageText)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                }
                
                Button(action: {
                    let step = useDoubleSided ? 2 : 1
                    if page < book.pageCount { page = min(book.pageCount, page + step) }
                }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .opacity(canNext ? 1.0 : 0.25)
                        .frame(width: 32, height: 28)
                }
                .disabled(!canNext)
            }
            .background(Color(hex: "1e293b"))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .padding(.trailing, 8)
            
            Button(action: { isPencilModeActive.toggle() }) {
                Image(systemName: isPencilModeActive ? "pencil.tip.crop.circle.badge.minus" : "pencil.tip.crop.circle")
                    .foregroundColor(isPencilModeActive ? Color(hex: "818cf8") : .white)
                    .font(.system(size: 15))
            }
            
            Button(action: { isChatOpen.toggle() }) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundColor(.white)
                    .font(.system(size: 14))
            }
            
            // Language Switcher (Web Style)
            HStack(spacing: 0) {
                Button(action: { viewMode = "en" }) {
                    Text("EN")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 36, height: 28)
                        .background(viewMode == "en" ? Color(hex: "6366f1") : Color.clear)
                        .foregroundColor(viewMode == "en" ? .white : .gray)
                }
                Button(action: { viewMode = "vi" }) {
                    Text("VI")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 36, height: 28)
                        .background(viewMode == "vi" ? Color(hex: "6366f1") : Color.clear)
                        .foregroundColor(viewMode == "vi" ? .white : .gray)
                }
                Button(action: { viewMode = "split" }) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 13))
                        .frame(width: 36, height: 28)
                        .background(viewMode == "split" ? Color(hex: "6366f1") : Color.clear)
                        .foregroundColor(viewMode == "split" ? .white : .gray)
                }
            }
            .background(Color(hex: "1e293b"))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(hex: "0f172a"))
    }
}

struct ReaderHighlightMenuView: View {
    @Binding var selectedColor: String
    @Binding var showNoteInput: Bool
    @Binding var highlightNote: String
    
    let activeSelectionLang: String?
    let hasActiveSelection: Bool
    let selectedHighlightId: String?
    let highlightColors: [(String, Color)]
    
    let onSaveHighlight: () -> Void
    let onPerformVocaLookup: () -> Void
    let onDeleteHighlight: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Colors
            HStack(spacing: 8) {
                ForEach(highlightColors, id: \.0) { colorHex, colorVal in
                    Circle()
                        .fill(colorVal)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: selectedColor == colorHex ? 2 : 0)
                        )
                        .onTapGesture {
                            selectedColor = colorHex
                            onSaveHighlight()
                        }
                }
            }
            
            Divider().background(Color.white.opacity(0.3)).frame(height: 20)
            
            // Voca lookup (EN only)
            if activeSelectionLang == "en" {
                Button(action: onPerformVocaLookup) {
                    Image(systemName: "book.closed")
                        .foregroundColor(Color(hex: "38bdf8"))
                        .font(.system(size: 18))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            
            // Add Note Icon
            Button(action: {
                withAnimation { showNoteInput.toggle() }
            }) {
                Image(systemName: "square.and.pencil")
                    .foregroundColor(highlightNote.isEmpty ? .gray : .yellow)
                    .font(.system(size: 18))
            }
            
            // Delete Highlight
            if selectedHighlightId != nil {
                Button(action: onDeleteHighlight) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .font(.system(size: 18))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(hex: "1e293b").opacity(0.95))
        .cornerRadius(20)
        .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
        .overlay(
            Group {
                if showNoteInput {
                    VStack(spacing: 8) {
                        TextField("Nhập ghi chú...", text: $highlightNote, axis: .vertical)
                            .lineLimit(3...6)
                            .padding(6)
                            .foregroundColor(Color(hex: "422006"))
                            .font(.system(.body, design: .serif))
                            .accentColor(Color(hex: "b45309"))
                        
                        HStack {
                            Spacer()
                            Button("Lưu") { onSaveHighlight() }
                                .font(.system(size: 12, weight: .bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color(hex: "b45309"))
                                .foregroundColor(.white)
                                .cornerRadius(4)
                        }
                    }
                    .padding(8)
                    .frame(width: 200)
                    .background(
                        LinearGradient(
                            colors: [Color(hex: "fef9c3"), Color(hex: "fde68a"), Color(hex: "fcd34d")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(4)
                    .shadow(color: .black.opacity(0.25), radius: 4, x: 1, y: 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(hex: "d97706").opacity(0.35), lineWidth: 1)
                    )
                    .offset(y: 85)
                }
            }
        )
    }
}

struct ReaderVocaOverlayView: View {
    let progressWord: String?
    let toast: String?
    
    var body: some View {
        Group {
            if let progressWord = progressWord {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HStack(spacing: 10) {
                            ProgressView()
                                .tint(.white)
                            Text(progressWord)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color(hex: "1e293b").opacity(0.94))
                        .cornerRadius(10)
                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                        .padding(.trailing, 16)
                        .padding(.bottom, 24)
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if let toast = toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.82))
                        .cornerRadius(10)
                        .padding(.bottom, 28)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}
