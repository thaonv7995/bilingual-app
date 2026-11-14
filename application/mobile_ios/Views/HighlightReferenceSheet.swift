import SwiftUI
import WebKit

/// Shared highlight color palette and geometry helpers used by both `ReaderView`
/// and `HighlightReferenceSheet`.
enum ReaderHighlightPalette {
    static let colors: [(String, Color)] = [
        ("#fde68a", Color(hex: "fde68a")),
        ("#93c5fd", Color(hex: "93c5fd")),
        ("#f9a8d4", Color(hex: "f9a8d4")),
        ("#86efac", Color(hex: "86efac"))
    ]

    static func color(for hex: String) -> Color {
        colors.first(where: { $0.0.caseInsensitiveCompare(hex) == .orderedSame })?.1 ?? Color(hex: "fde68a")
    }

    static func vocaPanelSafeInsets(
        lang: String,
        page: Int,
        viewMode: String,
        bilingualLayoutMode: String,
        isDoubleSided: Bool
    ) -> (left: CGFloat, right: CGFloat) {
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

    static func clampedToolbarPosition(
        rect: CGRect,
        in size: CGSize,
        lang: String,
        page: Int,
        viewMode: String,
        bilingualLayoutMode: String,
        isDoubleSided: Bool
    ) -> CGPoint {
        let insets = vocaPanelSafeInsets(
            lang: lang,
            page: page,
            viewMode: viewMode,
            bilingualLayoutMode: bilingualLayoutMode,
            isDoubleSided: isDoubleSided
        )
        let menuHalfWidth: CGFloat = 112
        let menuHalfHeight: CGFloat = 28
        let minX = menuHalfWidth + insets.left
        let maxX = max(minX, size.width - menuHalfWidth - insets.right)
        let x = min(max(rect.midX, minX), maxX)
        let y = min(max(rect.minY - 30, menuHalfHeight + 8), size.height - menuHalfHeight - 8)
        return CGPoint(x: x, y: y)
    }
}

/// Highlights & Notes drawer (used as a side panel on iPad wide screens and a modal
/// sheet on iPhone / compact screens). Tapping a card opens an independent reference
/// sheet instead of navigating the main reader away from the user's current page.
struct HighlightsListPanelView: View {
    let highlights: [Highlight]
    let currentPage: Int
    let previewingHighlightId: String?
    let showsCloseButton: Bool
    let onSelectHighlight: (Highlight) -> Void
    let onDeleteHighlight: (Highlight) -> Void
    let onClose: () -> Void

    @State private var currentPageOnly = false

    private var currentPageCount: Int {
        highlights.filter { $0.page == currentPage }.count
    }

    private var visibleHighlights: [Highlight] {
        let filtered = currentPageOnly
            ? highlights.filter { $0.page == currentPage }
            : highlights
        return filtered.sorted { lhs, rhs in
            if lhs.page != rhs.page { return lhs.page < rhs.page }
            return lhs.createdAt < rhs.createdAt
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "highlighter")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(hex: "f59e0b"))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Đánh dấu & Ghi chú")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Text("Mở trang riêng · giữ nguyên trang \(currentPage)")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "94a3b8"))
                }

                Spacer()

                if showsCloseButton {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Color(hex: "cbd5e1"))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .accessibilityLabel("Đóng danh sách ghi chú")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(hex: "0f172a"))

            // Filter Chips
            HStack(spacing: 8) {
                filterChip(
                    title: "Tất cả (\(highlights.count))",
                    selected: !currentPageOnly,
                    action: { currentPageOnly = false }
                )
                filterChip(
                    title: "Trang này (\(currentPageCount))",
                    selected: currentPageOnly,
                    action: { currentPageOnly = true }
                )
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color(hex: "111827"))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 0.5)
            }

            if visibleHighlights.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleHighlights) { item in
                            highlightCard(item)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(Color(hex: "0f172a"))
    }

    @ViewBuilder
    private func filterChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(selected ? .white : Color(hex: "94a3b8"))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selected ? Color(hex: "2563eb") : Color.white.opacity(0.06))
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "highlighter")
                .font(.system(size: 28))
                .foregroundColor(Color(hex: "475569"))
            Text(currentPageOnly
                 ? "Chưa có đánh dấu nào ở trang \(currentPage)"
                 : "Chưa có đánh dấu hay ghi chú nào")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(hex: "cbd5e1"))
                .multilineTextAlignment(.center)
            Text("Bôi đen đoạn văn trên trang sách để tô màu, ghi chú hoặc tra từ điển Voca.")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "64748b"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func highlightCard(_ item: Highlight) -> some View {
        let isPreviewing = previewingHighlightId == item.id
        let isCurrentPage = item.page == currentPage
        let trimmedNote = (item.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(ReaderHighlightPalette.color(for: item.color))
                    .frame(width: 10, height: 10)

                Text("Trang \(item.page)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isCurrentPage ? Color(hex: "93c5fd") : .white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(isCurrentPage ? Color(hex: "1d4ed8").opacity(0.35) : Color.white.opacity(0.09))
                    .cornerRadius(5)

                Text(item.lang.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(hex: "94a3b8"))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(4)

                if !trimmedNote.isEmpty {
                    Label("Ghi chú", systemImage: "note.text")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "fbbf24"))
                }

                Spacer()

                Button {
                    onDeleteHighlight(item)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "f87171"))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Xoá đánh dấu")
            }

            Text(item.text)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "f1f5f9"))
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            if !trimmedNote.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "d97706"))
                        .padding(.top, 2)
                    Text(trimmedNote)
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "fef3c7"))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: "78350f").opacity(0.35))
                .cornerRadius(6)
            }

            HStack {
                Text("↗ Xem trang \(item.page) riêng")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "60a5fa"))
                Spacer()
            }
        }
        .padding(11)
        .background(isPreviewing ? Color(hex: "1e293b") : Color(hex: "162033"))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isPreviewing
                        ? Color(hex: "3b82f6")
                        : (isCurrentPage ? Color(hex: "38bdf8").opacity(0.35) : Color.white.opacity(0.08)),
                    lineWidth: isPreviewing ? 1.5 : 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            onSelectHighlight(item)
        }
    }
}

/// Independent modal reference viewer opened from any highlight or note.
/// Renders the target page on demand (with local prev/next page navigation,
/// EN/VI/Split switcher, highlight editing, and Voca dictionary lookup) WITHOUT
/// altering the main reader's current `page`, `viewMode`, or saved reading progress.
struct HighlightReferenceSheet: View {
    let book: Book
    let initialHighlight: Highlight
    let mainCurrentPage: Int
    let initialViewMode: String
    let effectiveFontId: String
    let effectiveThemeId: String
    let bilingualLayoutMode: String

    @ObservedObject var api = APIService.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var previewPage: Int
    @State private var previewViewMode: String
    @State private var shouldPulseInitialHighlight = true

    // Isolated WebView registry & sentence sync
    @State private var previewWebViews: [String: WKWebView] = [:]
    @State private var activeSentenceId: String? = nil
    @State private var activeSentencePage: Int? = nil
    @State private var activeSentenceLang: String? = nil

    // Isolated highlight & note editor state
    @State private var activeSelection: SelectionInfo? = nil
    @State private var activeSelectionLang: String = "en"
    @State private var activeSelectionPage: Int? = nil
    @State private var selectedHighlightId: String? = nil
    @State private var highlightNote: String = ""
    @State private var showNoteInput: Bool = false
    @State private var selectedColor: String = "#fde68a"
    @State private var activeRect: CGRect? = nil

    // Isolated Voca state
    @State private var vocaPanelMode: VocaLookupPanelMode? = nil
    @State private var vocaPanelRect: CGRect? = nil
    @State private var vocaPanelLang: String = ""
    @State private var vocaPanelPage: Int? = nil
    @State private var vocaPanelContainerMode: String = ""
    @State private var vocaProgressWord: String? = nil
    @State private var vocaToast: String? = nil
    @State private var vocaLookupInProgress = false
    @State private var vocaPanelWebView: WKWebView? = nil
    @State private var externalBrowserDestination: ExternalBrowserDestination? = nil

    init(
        book: Book,
        initialHighlight: Highlight,
        mainCurrentPage: Int,
        initialViewMode: String,
        effectiveFontId: String,
        effectiveThemeId: String,
        bilingualLayoutMode: String
    ) {
        self.book = book
        self.initialHighlight = initialHighlight
        self.mainCurrentPage = mainCurrentPage
        self.initialViewMode = initialViewMode
        self.effectiveFontId = effectiveFontId
        self.effectiveThemeId = effectiveThemeId
        self.bilingualLayoutMode = bilingualLayoutMode

        let clampedPage = min(max(1, initialHighlight.page), max(1, book.pageCount))
        let startMode = (initialViewMode == "split") ? "split" : initialHighlight.lang
        _previewPage = State(initialValue: clampedPage)
        _previewViewMode = State(initialValue: startMode)
    }

    private var totalPages: Int {
        max(1, book.pageCount)
    }

    private var liveHighlight: Highlight? {
        api.highlights.first(where: { $0.id == initialHighlight.id })
    }

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    var body: some View {
        GeometryReader { geo in
            let isCompactWidth = geo.size.width < 660 || horizontalSizeClass == .compact
            let isLandscape = geo.size.width > geo.size.height

            VStack(spacing: 0) {
                headerBar(isCompact: isCompactWidth)
                contextBanner
                previewContentArea(width: geo.size.width, isLandscape: isLandscape)
            }
            .background(Color(hex: "0f172a"))
        }
        .background(Color(hex: "0f172a").ignoresSafeArea())
        .overlay(
            ReaderVocaOverlayView(progressWord: vocaProgressWord, toast: vocaToast)
        )
        .sheet(item: $externalBrowserDestination) { destination in
            ReaderSafariView(url: destination.url)
                .ignoresSafeArea()
        }
    }

    // MARK: - Header & Banner

    @ViewBuilder
    private func headerBar(isCompact: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "highlighter")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(hex: "f59e0b"))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Xem ghi chú")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(book.title)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "94a3b8"))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                mainPageBadge

                if !isCompact {
                    pageNavigator
                    viewModeSwitcher
                }

                Button("Đóng") {
                    dismiss()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12))
                .cornerRadius(8)
            }

            if isCompact {
                HStack(spacing: 8) {
                    pageNavigator
                    Spacer(minLength: 4)
                    viewModeSwitcher
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(hex: "0f172a"))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    private var mainPageBadge: some View {
        Text("Đang đọc: tr.\(mainCurrentPage)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Color(hex: "5eead4"))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(hex: "14b8a6").opacity(0.16))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(hex: "2dd4bf").opacity(0.35), lineWidth: 1)
            )
            .cornerRadius(6)
            .lineLimit(1)
    }

    private var pageNavigator: some View {
        HStack(spacing: 6) {
            Button {
                navigatePreview(to: previewPage - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(previewPage > 1 ? .white : Color(hex: "475569"))
                    .frame(width: 28, height: 28)
                    .background(Color(hex: "1e293b"))
                    .cornerRadius(6)
            }
            .disabled(previewPage <= 1)

            Text("Tr.\(previewPage)/\(totalPages)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "e2e8f0"))
                .monospacedDigit()
                .padding(.horizontal, 4)

            Button {
                navigatePreview(to: previewPage + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(previewPage < totalPages ? .white : Color(hex: "475569"))
                    .frame(width: 28, height: 28)
                    .background(Color(hex: "1e293b"))
                    .cornerRadius(6)
            }
            .disabled(previewPage >= totalPages)

            Button {
                jumpAndFocusInitialHighlight()
            } label: {
                Text(previewPage == initialHighlight.page ? "Cuộn tới" : "Về tr.\(initialHighlight.page)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "93c5fd"))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Color(hex: "1d4ed8").opacity(0.28))
                    .cornerRadius(6)
            }
        }
    }

    private var viewModeSwitcher: some View {
        HStack(spacing: 0) {
            modeButton(title: "EN", mode: "en")
            modeButton(title: "VI", mode: "vi")
            Button {
                switchPreviewMode("split")
            } label: {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 34, height: 28)
                    .background(previewViewMode == "split" ? Color(hex: "6366f1") : Color.clear)
                    .foregroundColor(previewViewMode == "split" ? .white : Color(hex: "94a3b8"))
            }
        }
        .background(Color(hex: "1e293b"))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func modeButton(title: String, mode: String) -> some View {
        Button {
            switchPreviewMode(mode)
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 32, height: 28)
                .background(previewViewMode == mode ? Color(hex: "6366f1") : Color.clear)
                .foregroundColor(previewViewMode == mode ? .white : Color(hex: "94a3b8"))
        }
    }

    @ViewBuilder
    private var contextBanner: some View {
        let displayHighlight = liveHighlight ?? initialHighlight
        let isDeleted = liveHighlight == nil
        let trimmedNote = (displayHighlight.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(ReaderHighlightPalette.color(for: displayHighlight.color))
                .frame(width: 10, height: 10)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Trang \(displayHighlight.page) · \(displayHighlight.lang.uppercased())")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(hex: "cbd5e1"))
                    if isDeleted {
                        Text("(Đã xoá)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "f87171"))
                    }
                }
                Text("“\(displayHighlight.text)”")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "f8fafc"))
                    .lineLimit(2)
                if !trimmedNote.isEmpty && !isDeleted {
                    Text("Ghi chú: \(trimmedNote)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "fde68a"))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(hex: "111827"))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    // MARK: - Content Area

    @ViewBuilder
    private func previewContentArea(width: CGFloat, isLandscape: Bool) -> some View {
        let isHorizontalSplit: Bool = {
            if bilingualLayoutMode == "en-over-vi" || bilingualLayoutMode == "vi-over-en" {
                return false
            }
            return width > 680 || (isPhone && isLandscape)
        }()
        let isEnFirst = bilingualLayoutMode.hasPrefix("en")

        Group {
            if previewViewMode == "split" {
                let layout = isHorizontalSplit ? AnyLayout(HStackLayout(spacing: 4)) : AnyLayout(VStackLayout(spacing: 4))
                layout {
                    if isEnFirst {
                        renderPreviewWebView(lang: "en", page: previewPage, containerMode: "split")
                        renderPreviewWebView(lang: "vi", page: previewPage, containerMode: "split")
                    } else {
                        renderPreviewWebView(lang: "vi", page: previewPage, containerMode: "split")
                        renderPreviewWebView(lang: "en", page: previewPage, containerMode: "split")
                    }
                }
            } else {
                renderPreviewWebView(
                    lang: previewViewMode == "vi" ? "vi" : "en",
                    page: previewPage,
                    containerMode: "single"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func renderPreviewWebView(lang: String, page: Int, containerMode: String) -> some View {
        let urlString = book.pageURL(serverUrl: api.serverUrl, token: api.token, lang: lang, page: page)
        let isBilingual = previewViewMode == "split"
        let shouldSyncSentence = isBilingual
            ? (page == activeSentencePage)
            : (page == activeSentencePage && lang == activeSentenceLang)
        let targetSentenceId = shouldSyncSentence ? activeSentenceId : nil

        BilingualWebView(
            bookSlug: book.slug,
            urlString: urlString,
            lang: lang,
            page: page,
            viewMode: previewViewMode,
            activeSentenceId: targetSentenceId,
            isPencilModeActive: false,
            topOverlayInset: 0,
            effectiveFontId: effectiveFontId,
            effectiveThemeId: effectiveThemeId,
            containerMode: containerMode,
            scrollSyncScope: "preview-\(initialHighlight.id)",
            onHighlightMessage: { msg in
                handleHighlightMessage(msg, lang: lang, page: page)
            },
            onSentenceClicked: { sentenceId in
                activeSentenceId = sentenceId
                activeSentencePage = page
                activeSentenceLang = lang
            },
            onVocaAction: { action in
                handleVocaWebAction(action)
            },
            onOpenExternalURL: { url in
                openExternalURL(url)
            },
            onWebViewReady: { webView, readyLang, readyPage in
                registerPreviewWebView(webView, lang: readyLang, page: readyPage, containerMode: containerMode)
            },
            onWebViewDismantled: { webView, readyLang, readyPage in
                unregisterPreviewWebView(webView, lang: readyLang, page: readyPage, containerMode: containerMode)
            },
            onPageDidFinish: { webView, readyLang, readyPage in
                if shouldPulseInitialHighlight,
                   readyPage == initialHighlight.page,
                   readyLang == initialHighlight.lang {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        webView.evaluateScrollAndPulseHighlight(id: initialHighlight.id)
                        shouldPulseInitialHighlight = false
                    }
                }
            }
        )
        .id("ref-webview-\(containerMode)-\(lang)-\(page)")
        .modifier(PaperSheetModifier(viewMode: previewViewMode, page: page, isDoubleSided: false))
        .overlay(
            GeometryReader { geo in
                Group {
                    if activeSelectionLang == lang,
                       activeSelectionPage == page,
                       (activeSelection != nil || selectedHighlightId != nil),
                       let rect = activeRect {
                        let pos = ReaderHighlightPalette.clampedToolbarPosition(
                            rect: rect,
                            in: geo.size,
                            lang: lang,
                            page: page,
                            viewMode: previewViewMode,
                            bilingualLayoutMode: bilingualLayoutMode,
                            isDoubleSided: false
                        )
                        ReaderHighlightMenuView(
                            selectedColor: $selectedColor,
                            showNoteInput: $showNoteInput,
                            highlightNote: $highlightNote,
                            activeSelectionLang: activeSelectionLang,
                            hasActiveSelection: activeSelection != nil,
                            selectedHighlightId: selectedHighlightId,
                            highlightColors: ReaderHighlightPalette.colors,
                            onSaveHighlight: saveHighlight,
                            onPerformVocaLookup: performVocaLookup,
                            onDeleteHighlight: deleteHighlight
                        )
                        .position(x: pos.x, y: pos.y)
                    }
                }
            }
            .allowsHitTesting(activeSelectionLang == lang && activeSelectionPage == page && (activeSelection != nil || selectedHighlightId != nil))
        )
    }

    // MARK: - Navigation & Mode Actions

    private func navigatePreview(to newPage: Int) {
        let clamped = min(max(1, newPage), totalPages)
        guard clamped != previewPage else { return }
        dismissVocaPanel()
        clearSelectionState()
        previewPage = clamped
        shouldPulseInitialHighlight = (clamped == initialHighlight.page)
    }

    private func switchPreviewMode(_ newMode: String) {
        guard previewViewMode != newMode else { return }
        dismissVocaPanel()
        clearSelectionState()
        previewViewMode = newMode
        if previewPage == initialHighlight.page && (newMode == "split" || newMode == initialHighlight.lang) {
            shouldPulseInitialHighlight = true
        }
    }

    private func jumpAndFocusInitialHighlight() {
        dismissVocaPanel()
        clearSelectionState()
        let targetLang = initialHighlight.lang
        if previewViewMode != "split" && previewViewMode != targetLang {
            previewViewMode = targetLang
        }
        if previewPage != initialHighlight.page {
            shouldPulseInitialHighlight = true
            previewPage = initialHighlight.page
            return
        }
        let containerMode = previewViewMode == "split" ? "split" : "single"
        let key = webViewKey(lang: targetLang, page: initialHighlight.page, containerMode: containerMode)
        if let webView = previewWebViews[key] {
            webView.evaluateScrollAndPulseHighlight(id: initialHighlight.id)
        } else {
            shouldPulseInitialHighlight = true
        }
    }

    // MARK: - WebView Registry

    private func webViewKey(lang: String, page: Int, containerMode: String) -> String {
        "\(containerMode)-\(lang)-\(page)"
    }

    private func registerPreviewWebView(_ webView: WKWebView, lang: String, page: Int, containerMode: String) {
        DispatchQueue.main.async {
            previewWebViews[webViewKey(lang: lang, page: page, containerMode: containerMode)] = webView
        }
    }

    private func unregisterPreviewWebView(_ webView: WKWebView, lang: String, page: Int, containerMode: String) {
        DispatchQueue.main.async {
            let key = webViewKey(lang: lang, page: page, containerMode: containerMode)
            if previewWebViews[key] === webView {
                previewWebViews.removeValue(forKey: key)
            }
            if vocaPanelWebView === webView {
                vocaPanelWebView = nil
            }
        }
    }

    // MARK: - Highlight & Voca Handlers (Isolated from Main Reader)

    private func handleHighlightMessage(_ msg: HighlightMessage, lang: String, page: Int) {
        switch msg {
        case .textSelected(let selectionInfo):
            dismissVocaPanel()
            activeSelection = selectionInfo
            activeSelectionLang = lang
            activeSelectionPage = page
            selectedHighlightId = nil
            highlightNote = ""
            selectedColor = "#fde68a"
            activeRect = selectionInfo.rect
            showNoteInput = false
        case .highlightClicked(let id, let rect):
            dismissVocaPanel()
            selectedHighlightId = id
            activeSelection = nil
            activeRect = rect
            if let existing = api.highlights.first(where: { $0.id == id }) {
                selectedColor = existing.color
                highlightNote = existing.note ?? ""
                activeSelectionPage = existing.page
                activeSelectionLang = existing.lang
                showNoteInput = !(existing.note ?? "").isEmpty
            } else {
                showNoteInput = false
            }
        case .clearSelection:
            clearSelectionState()
            guard !vocaLookupInProgress, vocaPanelMode == nil else { return }
            if vocaPanelWebView != nil || vocaProgressWord != nil || !vocaPanelContainerMode.isEmpty {
                dismissVocaPanel()
            }
        case .toggleFullScreen:
            if vocaPanelMode != nil {
                dismissVocaPanel()
            }
        }
    }

    private func clearSelectionState() {
        activeSelection = nil
        selectedHighlightId = nil
        activeSelectionPage = nil
        highlightNote = ""
        activeSentenceId = nil
        activeSentencePage = nil
        activeSentenceLang = nil
        activeRect = nil
        showNoteInput = false
    }

    private func saveHighlight() {
        let slug = book.slug
        if let selection = activeSelection {
            let highlightPage = activeSelectionPage ?? previewPage
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
                if (try? await api.saveHighlight(slug: slug, highlight: newHighlight)) != nil {
                    await MainActor.run { clearSelectionState() }
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
                if (try? await api.saveHighlight(slug: slug, highlight: updated)) != nil {
                    await MainActor.run { clearSelectionState() }
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
                await MainActor.run {
                    showVocaToast("Không xoá được ghi chú.")
                }
            }
        }
    }

    private func performVocaLookup() {
        let textToLookup: String?
        if let selection = activeSelection {
            textToLookup = selection.text
        } else if let highlightId = selectedHighlightId,
                  let existing = api.highlights.first(where: { $0.id == highlightId }) {
            textToLookup = existing.text
        } else {
            textToLookup = nil
        }

        guard let text = textToLookup, activeSelectionLang == "en" else { return }
        let query = VocaService.cleanWord(text)
        guard !query.isEmpty else { return }

        let anchor = activeRect ?? CGRect(x: 180, y: 120, width: 40, height: 20)
        let panelLang = activeSelectionLang
        let panelPage = activeSelectionPage ?? previewPage
        let containerMode = previewViewMode == "split" ? "split" : "single"
        let key = webViewKey(lang: panelLang, page: panelPage, containerMode: containerMode)

        guard let webView = previewWebViews[key] else {
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
                    vocaPanelMode = VocaLookupPanelMode.from(lookupResult: result, query: query)
                    presentVocaPanelInWebView()
                    clearSelectionState()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        vocaLookupInProgress = false
                    }
                }
            } catch {
                await MainActor.run {
                    vocaLookupInProgress = false
                    dismissVocaPanel()
                    showVocaToast(error.localizedDescription)
                }
            }
        }
    }

    private func presentVocaPanelInWebView(retryCount: Int = 0) {
        guard let mode = vocaPanelMode,
              let rect = vocaPanelRect,
              let panelPage = vocaPanelPage,
              !vocaPanelLang.isEmpty,
              !vocaPanelContainerMode.isEmpty else { return }

        let key = webViewKey(lang: vocaPanelLang, page: panelPage, containerMode: vocaPanelContainerMode)
        guard let webView = vocaPanelWebView ?? previewWebViews[key] else {
            if retryCount < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    presentVocaPanelInWebView(retryCount: retryCount + 1)
                }
            }
            return
        }

        let insets = ReaderHighlightPalette.vocaPanelSafeInsets(
            lang: vocaPanelLang,
            page: panelPage,
            viewMode: previewViewMode,
            bilingualLayoutMode: bilingualLayoutMode,
            isDoubleSided: false
        )
        guard let json = mode.toIOSPanelJSON(rect: rect, insetLeft: insets.left, insetRight: insets.right) else {
            return
        }

        webView.evaluateShowIOSVocaPanel(json: json) { isReady in
            if isReady {
                vocaPanelWebView = webView
            } else if retryCount < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    presentVocaPanelInWebView(retryCount: retryCount + 1)
                }
            } else {
                showVocaToast("Không thể hiển thị từ điển trên trang này.")
            }
        }
    }

    private func addSelectionToVoca(_ word: String) {
        let savedRect = vocaPanelRect
        let savedLang = vocaPanelLang
        let savedPage = vocaPanelPage
        let savedContainerMode = vocaPanelContainerMode
        let savedWebView = vocaPanelWebView

        vocaLookupInProgress = true
        vocaPanelWebView?.evaluateRemoveIOSVocaPanel()
        vocaPanelMode = nil
        withAnimation { vocaProgressWord = word }

        Task {
            do {
                let card = try await VocaService.addWordToVoca(word)
                await MainActor.run {
                    withAnimation { vocaProgressWord = nil }
                    vocaPanelRect = savedRect
                    vocaPanelLang = savedLang
                    vocaPanelPage = savedPage
                    vocaPanelContainerMode = savedContainerMode
                    vocaPanelWebView = savedWebView
                    vocaPanelMode = .single(card)
                    presentVocaPanelInWebView()
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
                    vocaPanelWebView = savedWebView
                    vocaPanelMode = .notFound(query: word)
                    presentVocaPanelInWebView()
                    showVocaToast(error.localizedDescription)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        vocaLookupInProgress = false
                    }
                }
            }
        }
    }

    private func handleVocaWebAction(_ action: VocaWebAction) {
        switch action {
        case .addWord(let word):
            addSelectionToVoca(word)
        case .playAudio(let slug):
            let word = vocaPanelMode?.word(forSlug: slug) ?? ""
            Task {
                do {
                    let outcome = try await VocaService.playCardAudio(slug: slug, word: word)
                    await MainActor.run {
                        if case .device(let notice) = outcome, let notice {
                            showVocaToast(notice)
                        }
                    }
                } catch is CancellationError {
                    // Interrupted by a newer audio request
                } catch {
                    await MainActor.run {
                        showVocaToast(error.localizedDescription)
                    }
                }
            }
        case .selectCard(let card):
            vocaPanelMode = .single(card)
            presentVocaPanelInWebView()
        case .dismiss:
            dismissVocaPanel()
        }
    }

    private func dismissVocaPanel() {
        vocaPanelWebView?.evaluateRemoveIOSVocaPanel()
        vocaPanelMode = nil
        vocaPanelRect = nil
        vocaPanelLang = ""
        vocaPanelPage = nil
        vocaPanelContainerMode = ""
        vocaPanelWebView = nil
        vocaProgressWord = nil
    }

    private func showVocaToast(_ message: String) {
        withAnimation { vocaToast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { vocaToast = nil }
        }
    }

    private func openExternalURL(_ url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }
        if scheme == "http" || scheme == "https" {
            externalBrowserDestination = ExternalBrowserDestination(url: url)
        } else if scheme == "mailto" || scheme == "tel" {
            UIApplication.shared.open(url)
        }
    }
}

