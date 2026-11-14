import SwiftUI
import WebKit

/// Independent modal reader for inspecting a highlight or note on its own page
/// without mutating the main reader's current reading page, layout, or progress.
struct HighlightReferenceSheetMac: View {
    let book: Book
    let totalPages: Int
    let mainCurrentPage: Int
    let initialHighlight: Highlight
    let effectiveFontId: String
    let effectiveThemeId: String
    let layoutMode: String
    @Binding var highlights: [Highlight]

    @ObservedObject private var api = APIService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var previewPage: Int
    @State private var previewViewMode: String

    @State private var activeSentenceId: String?
    @State private var activeSentencePage: Int
    @State private var activeSentenceLang: String

    @State private var previewWebViews: [String: WKWebView] = [:]
    @State private var didPulseInitialHighlight = false

    // Selection, highlight & Voca lookup state (isolated to this reference sheet)
    @State private var activeLang: String = "en"
    @State private var activeSelection: SelectionInfo?
    @State private var activeSelectionPage: Int?
    @State private var selectedHighlightId: String?
    @State private var selectedHighlightPage: Int?
    @State private var activeRect: CGRect?
    @State private var highlightNote: String = ""
    @State private var selectedColor: String = "#fde68a"
    @State private var showNoteEditor = false
    @FocusState private var isNoteFieldFocused: Bool

    @State private var vocaPanelPage: Int?
    @State private var vocaPanelLang: String = ""
    @State private var vocaPanelRect: CGRect = CGRect(x: 40, y: 40, width: 80, height: 24)
    @State private var vocaProgressWord: String?
    @State private var toastMessage: String?

    private let highlightPalette: [(hex: String, name: String)] = [
        ("#fde68a", "Vàng"),
        ("#93c5fd", "Xanh dương"),
        ("#f9a8d4", "Hồng"),
        ("#86efac", "Xanh lá"),
    ]

    init(
        book: Book,
        totalPages: Int,
        mainCurrentPage: Int,
        initialHighlight: Highlight,
        initialViewMode: String,
        effectiveFontId: String,
        effectiveThemeId: String,
        layoutMode: String,
        highlights: Binding< [Highlight] >
    ) {
        self.book = book
        self.totalPages = max(1, totalPages)
        self.mainCurrentPage = mainCurrentPage
        self.initialHighlight = initialHighlight
        self.effectiveFontId = effectiveFontId
        self.effectiveThemeId = effectiveThemeId
        self.layoutMode = layoutMode
        self._highlights = highlights

        let clampedPage = max(1, min(max(1, totalPages), initialHighlight.page))
        let normalizedLang = initialHighlight.lang == "vi" ? "vi" : "en"
        let startMode = initialViewMode == "split" ? "split" : normalizedLang
        self._previewPage = State(initialValue: clampedPage)
        self._previewViewMode = State(initialValue: startMode)
        self._activeSentencePage = State(initialValue: clampedPage)
        self._activeSentenceLang = State(initialValue: normalizedLang)
    }

    private var liveHighlight: Highlight? {
        highlights.first(where: { $0.id == initialHighlight.id })
    }

    private var activeLookupText: String? {
        if let selected = activeSelection?.text, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return selected
        }
        if let id = selectedHighlightId,
           let existing = highlights.first(where: { $0.id == id }),
           !existing.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing.text
        }
        return nil
    }

    private var canLookupActiveTextInVoca: Bool {
        guard activeLang == "en", let raw = activeLookupText else { return false }
        return !VocaService.cleanWord(raw).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            referenceHeader
            if previewPage == initialHighlight.page {
                highlightContextBanner
            }

            ZStack {
                Color.readerPaper(for: effectiveThemeId)
                    .ignoresSafeArea()

                previewStage
                    .padding(14)

                if let toast = toastMessage {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color(hex: "34d399"))
                            Text(toast)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
                        .padding(.bottom, 18)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(50)
                }
            }
        }
        .frame(minWidth: 860, idealWidth: 1020, minHeight: 620, idealHeight: 760)
        .background(Color(hex: "0b1120"))
        .preferredColorScheme(.dark)
        .macReaderKeyboardShortcuts(
            allowsInSheet: true,
            onLeftArrow: {
                guard !isNoteFieldFocused, !showNoteEditor, vocaPanelPage == nil else { return false }
                goToPreviewPage(previewPage - 1)
                return true
            },
            onRightArrow: {
                guard !isNoteFieldFocused, !showNoteEditor, vocaPanelPage == nil else { return false }
                goToPreviewPage(previewPage + 1)
                return true
            },
            onEscape: {
                if vocaPanelPage != nil {
                    vocaPanelPage = nil
                    return true
                }
                if showNoteEditor || activeSelection != nil || selectedHighlightId != nil {
                    clearSelectionBar()
                    return true
                }
                if !isNoteFieldFocused {
                    dismiss()
                    return true
                }
                return false
            }
        )
    }

    // MARK: - Header & Banner

    private var referenceHeader: some View {
        let displayedHL = liveHighlight ?? initialHighlight
        let accentHex = String(displayedHL.color.dropFirst())

        return HStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: accentHex))
                    .frame(width: 9, height: 9)

                Text("Xem ghi chú")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)

                Text("Trang đọc chính: \(mainCurrentPage)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: "5eead4"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(hex: "14b8a6").opacity(0.14), in: Capsule())
                    .overlay(Capsule().stroke(Color(hex: "14b8a6").opacity(0.32), lineWidth: 1))
                    .help("Xem trang này không làm thay đổi tiến độ trang \(mainCurrentPage) của bạn.")
            }

            Spacer(minLength: 8)

            // Isolated Reference Page Navigator
            HStack(spacing: 0) {
                Button {
                    goToPreviewPage(previewPage - 1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.white)
                        .opacity(previewPage > 1 ? 1.0 : 0.25)
                        .frame(width: 32, height: 30)
                }
                .buttonStyle(.macRect())
                .disabled(previewPage <= 1)

                Text("Trang \(previewPage)/\(totalPages)")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 30)

                Button {
                    goToPreviewPage(previewPage + 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.white)
                        .opacity(previewPage < totalPages ? 1.0 : 0.25)
                        .frame(width: 32, height: 30)
                }
                .buttonStyle(.macRect())
                .disabled(previewPage >= totalPages)
            }
            .background(Color(hex: "1e293b"))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))

            Button {
                if previewPage != initialHighlight.page {
                    didPulseInitialHighlight = false
                    goToPreviewPage(initialHighlight.page)
                } else {
                    pulseInitialHighlight()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: previewPage != initialHighlight.page ? "arrow.uturn.backward" : "scope")
                        .font(.system(size: 11, weight: .bold))
                    Text(previewPage != initialHighlight.page ? "Về trang \(initialHighlight.page)" : "Cuộn tới highlight")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(Color(hex: "fde68a"))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color(hex: "f59e0b").opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(hex: "f59e0b").opacity(0.32), lineWidth: 1))
            }
            .buttonStyle(.macInteractive(cornerRadius: 8))

            Spacer(minLength: 8)

            // Local Reference View Mode Switcher (never alters main reader viewMode)
            HStack(spacing: 0) {
                modeSegmentButton(title: "EN", mode: "en")
                modeSegmentButton(title: "VI", mode: "vi")
                modeSegmentButton(title: "Split", mode: "split")
            }
            .background(Color(hex: "1e293b"))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))

            Button {
                dismiss()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                    Text("Đóng")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.macInteractive(cornerRadius: 8))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(hex: "0f172a"))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
        }
    }

    private func modeSegmentButton(title: String, mode: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                previewViewMode = mode
                activeSentenceId = nil
                clearSelectionBar()
            }
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: .bold))
                .frame(width: 42, height: 30)
                .background(previewViewMode == mode ? Color(hex: "6366f1") : Color.clear)
                .foregroundStyle(previewViewMode == mode ? .white : Color(hex: "94a3b8"))
        }
        .buttonStyle(.macRect())
    }

    private var highlightContextBanner: some View {
        let hl = liveHighlight ?? initialHighlight
        let accentColor = Color(hex: String(hl.color.dropFirst()))
        let trimmedNote = (hl.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        return HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor)
                .frame(width: 3.5, height: trimmedNote.isEmpty ? 20 : 34)

            VStack(alignment: .leading, spacing: 3) {
                Text("“\(hl.text)”")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(2)

                if !trimmedNote.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "note.text")
                            .font(.caption2)
                        Text(trimmedNote)
                            .font(.caption)
                            .lineLimit(2)
                    }
                    .foregroundStyle(Color(hex: "fde68a"))
                }
            }

            Spacer(minLength: 8)

            if liveHighlight == nil {
                Text("Đã xoá")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(hex: "f87171"))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(hex: "ef4444").opacity(0.14), in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(hex: "0b0f19"))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
        }
    }

    // MARK: - Reference Web Stage

    @ViewBuilder
    private var previewStage: some View {
        if previewViewMode == "split" {
            let isStacked = layoutMode == "topBottom"
            let isEnFirst = layoutMode.hasPrefix("en")
            let panes = isEnFirst ? ["en", "vi"] : ["vi", "en"]

            Group {
                if isStacked {
                    VStack(spacing: 4) {
                        previewPaneWebView(lang: panes[0], page: previewPage, containerMode: "split")
                        previewPaneWebView(lang: panes[1], page: previewPage, containerMode: "split")
                    }
                } else {
                    HStack(spacing: 4) {
                        previewPaneWebView(lang: panes[0], page: previewPage, containerMode: "split")
                        previewPaneWebView(lang: panes[1], page: previewPage, containerMode: "split")
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.42), radius: 18, x: 0, y: 8)
        } else {
            let lang = previewViewMode == "vi" ? "vi" : "en"
            previewPaneWebView(lang: lang, page: previewPage, containerMode: lang)
                .frame(maxWidth: 880)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.42), radius: 18, x: 0, y: 8)
        }
    }

    private func previewPaneWebView(lang: String, page: Int, containerMode: String) -> some View {
        let isBilingual = previewViewMode == "split"
        let shouldHighlightSentence = isBilingual
            ? (page == activeSentencePage)
            : (page == activeSentencePage && lang == activeSentenceLang)
        let targetSentenceId = shouldHighlightSentence ? activeSentenceId : nil
        let scrollMirrorPane = isBilingual && shouldHighlightSentence && (activeSentenceLang != lang)
        let scope = "preview-\(initialHighlight.id)"

        return BilingualWebViewMac(
            bookSlug: book.slug,
            urlString: book.pageURL(serverUrl: api.normalizedServerUrl, lang: lang, page: page),
            lang: lang,
            page: page,
            viewMode: previewViewMode,
            containerMode: containerMode,
            effectiveFontId: effectiveFontId,
            effectiveThemeId: effectiveThemeId,
            activeSentenceId: targetSentenceId,
            scrollActiveSentenceIntoView: scrollMirrorPane,
            scrollSyncScope: scope,
            highlights: highlights,
            onHighlightMessage: { msg in
                handleHighlightMessage(msg, lang: lang, page: page)
            },
            onSentenceClicked: { sentenceId in
                guard let sentenceId else {
                    activeSentenceId = nil
                    return
                }
                if activeSentenceId == sentenceId && activeSentencePage == page && activeSentenceLang == lang {
                    activeSentenceId = nil
                } else {
                    activeSentenceId = sentenceId
                    activeSentencePage = page
                    activeSentenceLang = lang
                    clearSelectionBar()
                }
            },
            onVocaAction: handleVocaAction,
            onWebViewReady: { wv, l, p in
                previewWebViews["\(l):\(p)"] = wv
            },
            onWebViewDismantled: { _, l, p in
                previewWebViews.removeValue(forKey: "\(l):\(p)")
            },
            onPageDidFinish: { wv, l, p in
                if !didPulseInitialHighlight && l == initialHighlight.lang && p == initialHighlight.page {
                    didPulseInitialHighlight = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                        wv.evaluateScrollAndPulseHighlight(id: initialHighlight.id)
                    }
                }
            }
        )
        .overlay {
            GeometryReader { geo in
                let isTargetPane = activeLang == lang
                    && (activeSelectionPage == page || selectedHighlightPage == page)
                    && (activeSelection != nil || selectedHighlightId != nil)
                if isTargetPane {
                    let anchorRect = activeRect ?? CGRect(x: geo.size.width / 2 - 40, y: geo.size.height / 2, width: 80, height: 24)
                    let pos = CGPoint.clampedFloatingToolbarPosition(
                        for: anchorRect,
                        in: geo.size,
                        menuWidth: showNoteEditor ? 310 : 280,
                        menuHeight: showNoteEditor ? 142 : 46
                    )
                    floatingSelectionMenu
                        .position(pos)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                        .zIndex(30)
                }
            }
        }
    }

    // MARK: - Floating Selection / Highlight / Voca Toolbar

    private var floatingSelectionMenu: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(highlightPalette, id: \.hex) { item in
                    Button {
                        applyHighlight(color: item.hex)
                    } label: {
                        Circle()
                            .fill(Color(hex: String(item.hex.dropFirst())))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .stroke(.white, lineWidth: selectedColor == item.hex ? 2.2 : 0)
                            )
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.macCircle())
                }

                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 18)

                if canLookupActiveTextInVoca {
                    Button {
                        lookupActiveSelectionInVoca()
                    } label: {
                        Group {
                            if vocaProgressWord != nil {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(Color(hex: "34d399"))
                            } else {
                                Image(systemName: "book.closed")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color(hex: "34d399"))
                            }
                        }
                        .frame(width: 30, height: 30)
                        .background(Color(hex: "10b981").opacity(0.16), in: Circle())
                    }
                    .buttonStyle(.macCircle())
                    .help("Tra hoặc thêm từ vào Voca")
                    .disabled(vocaProgressWord != nil)
                }

                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        showNoteEditor.toggle()
                        isNoteFieldFocused = showNoteEditor
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(showNoteEditor ? Color(hex: "fde68a") : .white)
                        .frame(width: 30, height: 30)
                        .background(showNoteEditor ? Color(hex: "f59e0b").opacity(0.22) : Color.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.macCircle())
                .help("Sửa ghi chú")

                if let hlId = selectedHighlightId {
                    Button {
                        deleteHighlight(id: hlId)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(hex: "f87171"))
                            .frame(width: 30, height: 30)
                            .background(Color(hex: "ef4444").opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.macCircle())
                    .help("Xoá đánh dấu")
                }

                Button {
                    clearSelectionBar()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: "94a3b8"))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.macCircle())
            }

            if showNoteEditor {
                HStack(spacing: 8) {
                    TextField("Nhập ghi chú...", text: $highlightNote)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                        .focused($isNoteFieldFocused)

                    Button("Lưu") {
                        if let hlId = selectedHighlightId {
                            updateExistingHighlightNote(id: hlId)
                        } else {
                            applyHighlight(color: selectedColor)
                        }
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(hex: "fde68a"), in: Capsule())
                    .buttonStyle(.macCapsule())
                }
                .frame(width: 280)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(hex: "0f172a").opacity(0.95), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 16, x: 0, y: 6)
    }

    // MARK: - Navigation & Interactions (Zero Main Progress Mutation)

    private func goToPreviewPage(_ target: Int) {
        let clamped = max(1, min(totalPages, target))
        guard clamped != previewPage else { return }
        previewPage = clamped
        activeSentenceId = nil
        clearSelectionBar()
        dismissOpenVocaPanels()
    }

    private func pulseInitialHighlight() {
        previewWebViews["\(initialHighlight.lang):\(initialHighlight.page)"]?
            .evaluateScrollAndPulseHighlight(id: initialHighlight.id)
    }

    private func handleHighlightMessage(_ msg: HighlightMessage, lang: String, page: Int) {
        switch msg {
        case .textSelected(let info):
            dismissOpenVocaPanels()
            activeLang = lang
            activeSelection = info
            activeSelectionPage = page
            selectedHighlightId = nil
            selectedHighlightPage = nil
            activeRect = info.rect
            activeSentenceId = nil
            selectedColor = "#fde68a"
            highlightNote = ""
            showNoteEditor = false
        case .highlightClicked(let id, let rect):
            dismissOpenVocaPanels()
            let existing = highlights.first(where: { $0.id == id })
            activeLang = existing?.lang ?? lang
            activeSelection = nil
            activeSelectionPage = nil
            selectedHighlightId = id
            selectedHighlightPage = existing?.page ?? page
            activeRect = rect
            highlightNote = existing?.note ?? ""
            if let c = existing?.color { selectedColor = c }
            showNoteEditor = !(existing?.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .clearSelection:
            clearSelectionBar()
        }
    }

    private func clearSelectionBar() {
        activeSelection = nil
        activeSelectionPage = nil
        selectedHighlightId = nil
        selectedHighlightPage = nil
        activeRect = nil
        highlightNote = ""
        showNoteEditor = false
    }

    private func applyHighlight(color: String) {
        guard let sel = activeSelection else {
            if let hlId = selectedHighlightId, let idx = highlights.firstIndex(where: { $0.id == hlId }) {
                var updated = highlights[idx]
                updated.color = color
                updated.note = highlightNote
                highlights[idx] = updated
                Task { await api.saveHighlight(slug: book.slug, highlight: updated) }
                clearSelectionBar()
            }
            return
        }
        let targetPage = activeSelectionPage ?? previewPage
        let hl = Highlight(
            id: UUID().uuidString,
            page: targetPage,
            lang: activeLang,
            color: color,
            text: sel.text,
            startOffset: sel.startOffset,
            endOffset: sel.endOffset,
            paragraphIndex: sel.paragraphIndex,
            note: highlightNote,
            createdAt: Int(Date().timeIntervalSince1970)
        )
        highlights.append(hl)
        Task { await api.saveHighlight(slug: book.slug, highlight: hl) }
        clearSelectionBar()
    }

    private func updateExistingHighlightNote(id: String) {
        guard let idx = highlights.firstIndex(where: { $0.id == id }) else { return }
        var updated = highlights[idx]
        updated.note = highlightNote
        highlights[idx] = updated
        Task { await api.saveHighlight(slug: book.slug, highlight: updated) }
        clearSelectionBar()
    }

    private func deleteHighlight(id: String) {
        highlights.removeAll { $0.id == id }
        Task { await api.deleteHighlight(slug: book.slug, id: id) }
        clearSelectionBar()
    }

    private func dismissOpenVocaPanels() {
        vocaPanelPage = nil
        for wv in previewWebViews.values {
            wv.evaluateDismissVocaPanel()
        }
    }

    private func lookupActiveSelectionInVoca() {
        guard let rawText = activeLookupText else { return }
        let lang = activeLang
        guard lang == "en" else { return }
        let targetPage = activeSelectionPage ?? selectedHighlightPage ?? previewPage
        guard let webView = previewWebViews["\(lang):\(targetPage)"] else { return }
        let query = VocaService.cleanWord(rawText)
        guard !query.isEmpty else { return }

        let anchorRect = activeRect ?? activeSelection?.rect ?? CGRect(x: 40, y: 40, width: 80, height: 24)
        vocaPanelPage = targetPage
        vocaPanelLang = lang
        vocaPanelRect = anchorRect
        clearSelectionBar()
        Task {
            do {
                if let json = try await VocaService.lookupPanelJSON(query: query, rect: anchorRect) {
                    await MainActor.run {
                        webView.evaluateShowVocaPanel(json: json)
                    }
                }
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    private func handleVocaAction(_ action: VocaWebAction) {
        let savedRect = vocaPanelRect
        switch action {
        case .addWord(let word):
            vocaProgressWord = word
            Task {
                do {
                    let card = try await VocaService.addWordToVoca(word)
                    await MainActor.run {
                        vocaProgressWord = nil
                        showToast("Đã thêm '\(card.word)' vào Voca!")
                        if let webView = previewWebViews["\(vocaPanelLang):\(vocaPanelPage ?? previewPage)"],
                           let json = VocaService.singleCardPanelJSON(card: card, rect: savedRect) {
                            webView.evaluateShowVocaPanel(json: json)
                        }
                    }
                } catch {
                    await MainActor.run {
                        vocaProgressWord = nil
                        showToast(error.localizedDescription)
                    }
                }
            }
        case .playAudio(let slug):
            Task {
                _ = try? await VocaService.playCardAudio(slug: slug)
            }
        case .selectCard(let card):
            guard let webView = previewWebViews["\(vocaPanelLang):\(vocaPanelPage ?? previewPage)"],
                  let json = VocaService.singleCardPanelJSON(card: card, rect: savedRect) else { return }
            webView.evaluateShowVocaPanel(json: json)
        case .dismiss:
            break
        }
    }

    private func showToast(_ text: String) {
        withAnimation { toastMessage = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            withAnimation { toastMessage = nil }
        }
    }
}

extension Color {
    static func readerPaper(for themeId: String) -> Color {
        let desc = ReaderAppearance.parseThemeDescriptor(themeId)
        if desc.themeId == "custom", ReaderAppearance.isValidHexColor(desc.customPaperColor) {
            return Color(hex: String(desc.customPaperColor.dropFirst()))
        }
        let theme = ReaderAppearance.getTheme(themeId)
        return Color(hex: String(theme.paper.dropFirst()))
    }
}

extension CGPoint {
    static func clampedFloatingToolbarPosition(
        for selectionRect: CGRect,
        in containerSize: CGSize,
        menuWidth: CGFloat,
        menuHeight: CGFloat
    ) -> CGPoint {
        let margin: CGFloat = 12
        let halfW = min(menuWidth / 2, max(1, containerSize.width / 2 - margin))
        let halfH = menuHeight / 2
        let centerX = selectionRect.midX
        let x = max(margin + halfW, min(max(margin + halfW, containerSize.width - margin - halfW), centerX))

        let preferredAbove = selectionRect.minY - halfH - 12
        let preferredBelow = selectionRect.maxY + halfH + 12
        let y: CGFloat
        if preferredAbove >= margin + halfH {
            y = preferredAbove
        } else if preferredBelow <= containerSize.height - margin - halfH {
            y = preferredBelow
        } else {
            y = max(margin + halfH, min(max(margin + halfH, containerSize.height - margin - halfH), selectionRect.midY))
        }
        return CGPoint(x: x, y: y)
    }
}
