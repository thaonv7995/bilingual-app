import SwiftUI
import WebKit

struct ReaderViewMac: View {
    let book: Book
    let onClose: () -> Void

    @ObservedObject private var api = APIService.shared
    @ObservedObject private var backup = BackupManager.shared

    @State private var currentPage: Int = 1
    @State private var viewMode: String = "split" // "en" | "vi" | "split"
    @State private var isDoublePageSpread: Bool = true
    @State private var isFullScreen: Bool = false

    @State private var showJumpToPagePopover: Bool = false
    @State private var jumpPageText: String = ""
    @State private var showAppearancePopover: Bool = false
    @State private var showHighlightsSidebar: Bool = false
    @State private var highlightsFilterCurrentPageOnly: Bool = false
    @State private var showChatSidebar: Bool = false

    @State private var isBookFinished: Bool = false
    @State private var isUpdatingFinished: Bool = false

    @State private var selectedFontId: String = "default"
    @State private var selectedThemeId: String = "default"
    @State private var hasLoadedBookAppearance: Bool = false
    @State private var isSavingAppearanceDefault: Bool = false

    // Selection, Sentence Sync, Highlights & Sticky Note
    @State private var activeSelection: SelectionInfo?
    @State private var activeSelectionPage: Int?
    @State private var selectedHighlightId: String?
    @State private var selectedHighlightPage: Int?
    @State private var activeRect: CGRect? = nil
    @State private var activeSentenceId: String? = nil
    @State private var activeSentencePage: Int = 1
    @State private var activeSentenceLang: String = "en"
    @State private var activeLang: String = "en"
    @State private var selectedColor: String = "#fde68a"
    @State private var showNoteEditor: Bool = false
    @State private var highlightNote: String = ""

    @State private var highlights: [Highlight] = []
    @State private var previewingHighlight: Highlight?
    @State private var webViews: [String: WKWebView] = [:]
    @State private var vocaToast: String?
    @State private var vocaProgressWord: String?
    @State private var vocaPanelPage: Int?
    @State private var vocaPanelLang: String = ""
    @State private var vocaPanelRect: CGRect = CGRect(x: 40, y: 40, width: 80, height: 24)

    // AI Chat (Companion Agent)
    @State private var chatMessages: [ChatMessage] = []
    @State private var chatInput: String = ""
    @State private var isSendingChat: Bool = false
    @State private var chatWidth: CGFloat = 340
    @State private var dragStartChatWidth: CGFloat = 340
    @State private var isDraggingChatDivider: Bool = false
    @FocusState private var isTypingInInput: Bool

    @State private var layoutMode: String = UserDefaults.standard.string(forKey: "bilingualLayoutMode") ?? "en-vi"
    @State private var isHoveringTopZone: Bool = false
    @State private var isHoveringLeftEdge: Bool = false
    @State private var isHoveringRightEdge: Bool = false

    // Tactile 3D Page-Turn Animation State
    @State private var pageTurnSkew: Double = 0
    @State private var pageTurnShift: CGFloat = 0
    @State private var pageTurnShadowOpacity: Double = 0
    @State private var pageTurnForward: Bool = true

    private let highlightColors: [(name: String, hex: String)] = [
        ("Vàng", "#fde68a"),
        ("Xanh dương", "#93c5fd"),
        ("Hồng", "#f9a8d4"),
        ("Xanh lá", "#86efac"),
    ]

    private var totalPages: Int {
        max(1, book.pageCount ?? 1)
    }

    private var bookDefaultFontId: String {
        ReaderAppearance.getFont(book.defaultFont).id
    }

    private var bookDefaultThemeId: String {
        ReaderAppearance.serializeThemeDescriptor(ReaderAppearance.parseThemeDescriptor(book.defaultTheme))
    }

    private var hasAppearanceOverride: Bool {
        selectedFontId != bookDefaultFontId || selectedThemeId != bookDefaultThemeId
    }

    private var hasCustomAppearance: Bool {
        selectedFontId != "default" || selectedThemeId != "default"
    }

    private var isInterlinearActive: Bool {
        ReaderAppearance.parseThemeDescriptor(selectedThemeId).interlinear
    }

    private var paperColorForStage: Color {
        Color.readerPaper(for: selectedThemeId)
    }

    private func useDoubleSided(for totalWidth: CGFloat) -> Bool {
        let readingPaneWidth = totalWidth
            - (showHighlightsSidebar ? 300 : 0)
            - (showChatSidebar ? chatWidth : 0)
        return isDoublePageSpread && viewMode != "split" && readingPaneWidth >= 820
    }

    private func isShowingLastPage(doubleSided: Bool) -> Bool {
        if doubleSided {
            let left = currentPage % 2 == 1 ? currentPage : max(1, currentPage - 1)
            return min(totalPages, left + 1) >= totalPages
        }
        return currentPage >= totalPages
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let doubleSided = useDoubleSided(for: geo.size.width)

            ZStack(alignment: .top) {
                Color(hex: "0f172a").ignoresSafeArea()

                VStack(spacing: 0) {
                    if !isFullScreen {
                        readerHeader(doubleSided: doubleSided, canToggleSpread: geo.size.width >= 880)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    HStack(spacing: 0) {
                        // Main Reading Desk Stage
                        ZStack(alignment: .bottom) {
                            readingStage(doubleSided: doubleSided)
                                .offset(x: pageTurnShift)
                                .rotation3DEffect(
                                    .degrees(pageTurnSkew),
                                    axis: (x: 0, y: 1, z: 0),
                                    perspective: 0.52
                                )
                                .overlay {
                                    if pageTurnShadowOpacity > 0.001 {
                                        LinearGradient(
                                            colors: pageTurnForward
                                                ? [.clear, .black.opacity(pageTurnShadowOpacity), .clear]
                                                : [.clear, .black.opacity(pageTurnShadowOpacity), .clear],
                                            startPoint: pageTurnForward ? .trailing : .leading,
                                            endPoint: pageTurnForward ? .leading : .trailing
                                        )
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: isFullScreen ? 0 : 16, style: .continuous))
                                        .allowsHitTesting(false)
                                    }
                                }
                                .padding(.horizontal, isFullScreen ? 0 : 18)
                                .padding(.top, isFullScreen ? 0 : 10)
                                .padding(.bottom, isFullScreen ? 0 : 14)

                            // Left / Right Edge Page-Turn Hover Zones
                            edgePageTurnOverlays(doubleSided: doubleSided)

                            // Voca Loading Pill
                            if let word = vocaProgressWord {
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small).tint(Color(hex: "38bdf8"))
                                    Text("Đang tạo thẻ Voca cho '\(word)'…")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.white)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color(hex: "1e293b").opacity(0.95), in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                                .padding(.bottom, 64)
                                .transition(.scale(scale: 0.92).combined(with: .opacity))
                            }

                            // Toast
                            if let toast = vocaToast {
                                Text(toast)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 9)
                                    .background(Color(hex: "1e293b").opacity(0.95), in: Capsule())
                                    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
                                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                                    .padding(.bottom, 68)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: activeSelection != nil || selectedHighlightId != nil)
                        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: viewMode)
                        .animation(.spring(response: 0.30, dampingFraction: 0.86), value: isDoublePageSpread)
                        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: isFullScreen)

                        if showHighlightsSidebar {
                            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                            highlightsDrawerView
                                .frame(width: 300)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }

                        if showChatSidebar {
                            chatCompanionDrawer
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }

                    // Slim Bottom Reading Progress Footer (subtle, non-intrusive)
                    if !isFullScreen {
                        bottomProgressStrip(doubleSided: doubleSided)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                // Focus Mode Exit Pill when hovering top-right
                if isFullScreen {
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isFullScreen = false
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                Text("Hiện thanh công cụ (Esc)")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color(hex: "1e293b").opacity(0.9), in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
                        }
                        .buttonStyle(.macCapsule)
                        .opacity(isHoveringTopZone ? 1.0 : 0.22)
                        .padding(14)
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isHoveringTopZone = hovering
                            }
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .focusable()
        .onKeyPress(.leftArrow) {
            guard previewingHighlight == nil, !isTypingInInput else { return .ignored }
            stepPage(forward: false, doubleSided: isDoublePageSpread && viewMode != "split")
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard previewingHighlight == nil, !isTypingInInput else { return .ignored }
            stepPage(forward: true, doubleSided: isDoublePageSpread && viewMode != "split")
            return .handled
        }
        .onKeyPress(.escape) {
            guard previewingHighlight == nil else { return .ignored }
            if showNoteEditor || activeSelection != nil || selectedHighlightId != nil {
                clearSelectionBar()
                return .handled
            }
            if isFullScreen {
                withAnimation(.easeInOut(duration: 0.2)) { isFullScreen = false }
                return .handled
            }
            return .ignored
        }
        .onKeyPress("f") {
            guard previewingHighlight == nil, !isTypingInInput else { return .ignored }
            withAnimation(.easeInOut(duration: 0.2)) { isFullScreen.toggle() }
            return .handled
        }
        .sheet(item: $previewingHighlight) { hl in
            HighlightReferenceSheetMac(
                book: book,
                totalPages: totalPages,
                mainCurrentPage: currentPage,
                initialHighlight: hl,
                initialViewMode: viewMode,
                effectiveFontId: selectedFontId,
                effectiveThemeId: selectedThemeId,
                layoutMode: layoutMode,
                highlights: $highlights
            )
        }
        .onAppear {
            loadInitialState()
        }
    }

    // MARK: - iPad-style Header Bar

    private func readerHeader(doubleSided: Bool, canToggleSpread: Bool) -> some View {
        let left = currentPage % 2 == 1 ? currentPage : max(1, currentPage - 1)
        let right = left + 1
        let canPrev = doubleSided ? (left > 1) : (currentPage > 1)
        let canNext = doubleSided ? (right <= totalPages && left + 1 < totalPages) : (currentPage < totalPages)

        let pageText: String = {
            if doubleSided {
                if right <= totalPages {
                    return "Trang \(left)-\(right)/\(totalPages)"
                } else {
                    return "Trang \(left)/\(totalPages)"
                }
            } else {
                return "Trang \(currentPage)/\(totalPages)"
            }
        }()

        return HStack(spacing: 10) {
            Button {
                onClose()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .bold))
                    Text("Tủ sách")
                        .font(.system(size: 13.5, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.macInteractive(cornerRadius: 8))

            Spacer(minLength: 10)

            HStack(spacing: 8) {
                Text(book.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if api.isOfflineMode {
                    Text("Offline")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(hex: "fbbf24"))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(hex: "f59e0b").opacity(0.16), in: Capsule())
                }
            }

            Spacer(minLength: 10)

            // iPad Dark Pill Page Navigator
            HStack(spacing: 0) {
                Button {
                    stepPage(forward: false, doubleSided: doubleSided)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.white)
                        .opacity(canPrev ? 1.0 : 0.25)
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.macRect())
                .disabled(!canPrev)

                Button {
                    jumpPageText = "\(currentPage)"
                    showJumpToPagePopover.toggle()
                } label: {
                    Text(pageText)
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                }
                .buttonStyle(.macRect())
                .popover(isPresented: $showJumpToPagePopover, arrowEdge: .bottom) {
                    jumpToPagePopover
                }

                Button {
                    stepPage(forward: true, doubleSided: doubleSided)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.white)
                        .opacity(canNext ? 1.0 : 0.25)
                        .frame(width: 34, height: 30)
                }
                .buttonStyle(.macRect())
                .disabled(!canNext)
            }
            .background(Color(hex: "1e293b"))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))

            // Finish Book Toggle on Last Page (iPad parity)
            if isShowingLastPage(doubleSided: doubleSided) {
                Button {
                    toggleBookFinished()
                } label: {
                    Label(
                        isBookFinished ? "Đã hoàn thành" : "Hoàn thành",
                        systemImage: isBookFinished ? "checkmark.circle.fill" : "checkmark.circle"
                    )
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isBookFinished ? Color(hex: "22c55e") : .white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(isBookFinished ? Color(hex: "22c55e").opacity(0.14) : Color(hex: "1e293b"))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isBookFinished ? Color(hex: "22c55e").opacity(0.35) : Color.white.opacity(0.1), lineWidth: 1)
                    )
                }
                .buttonStyle(.macInteractive(cornerRadius: 8))
                .disabled(isUpdatingFinished)
            }

            // 1-Page / 2-Page Spread Toggle in EN/VI mode
            if viewMode != "split" && canToggleSpread {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isDoublePageSpread.toggle()
                    }
                } label: {
                    Image(systemName: isDoublePageSpread ? "book.pages.fill" : "doc.text")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isDoublePageSpread ? Color(hex: "38bdf8") : .white)
                        .frame(width: 34, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isDoublePageSpread ? Color(hex: "38bdf8").opacity(0.16) : Color(hex: "1e293b"))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(isDoublePageSpread ? Color(hex: "38bdf8").opacity(0.45) : Color.white.opacity(0.1), lineWidth: 1)
                        )
                }
                .buttonStyle(.macInteractive(cornerRadius: 8))
                .help(isDoublePageSpread ? "Đang mở 2 trang (nhấn để đọc 1 trang)" : "Đang đọc 1 trang (nhấn để mở sách 2 trang)")
            }

            // Interlinear Toggle
            Button {
                toggleInterlinearMode()
            } label: {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isInterlinearActive ? Color(hex: "38bdf8") : .white)
                    .frame(width: 34, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isInterlinearActive ? Color(hex: "38bdf8").opacity(0.18) : Color(hex: "1e293b"))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isInterlinearActive ? Color(hex: "38bdf8").opacity(0.45) : Color.white.opacity(0.1), lineWidth: 1)
                    )
            }
            .buttonStyle(.macInteractive(cornerRadius: 8))
            .help("Dịch xen dòng (Interlinear)")

            // Aa Appearance Popover
            Button {
                showAppearancePopover.toggle()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Text("Aa")
                        .font(.system(size: 13.5, weight: .bold, design: .serif))
                        .foregroundStyle(showAppearancePopover || hasCustomAppearance ? Color(hex: "38bdf8") : .white)
                        .frame(width: 34, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(showAppearancePopover ? Color(hex: "38bdf8").opacity(0.18) : Color(hex: "1e293b"))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(showAppearancePopover || hasCustomAppearance ? Color(hex: "38bdf8").opacity(0.45) : Color.white.opacity(0.1), lineWidth: 1)
                        )

                    if hasCustomAppearance {
                        Circle()
                            .fill(Color(hex: "38bdf8"))
                            .frame(width: 6, height: 6)
                            .offset(x: -3, y: 3)
                    }
                }
            }
            .buttonStyle(.macInteractive(cornerRadius: 8))
            .popover(isPresented: $showAppearancePopover, arrowEdge: .bottom) {
                ReaderAppearancePopoverMac(
                    effectiveFontId: selectedFontId,
                    effectiveThemeId: selectedThemeId,
                    bookDefaultFontId: bookDefaultFontId,
                    bookDefaultThemeId: bookDefaultThemeId,
                    hasUserOverride: hasAppearanceOverride,
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
                        selectedFontId = bookDefaultFontId
                        selectedThemeId = bookDefaultThemeId
                        persistAppearanceOverride()
                    },
                    onSaveAsBookDefault: saveAsBookDefault,
                    onClose: { showAppearancePopover = false }
                )
            }

            // Highlights & Notes Drawer
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showHighlightsSidebar.toggle()
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: showHighlightsSidebar ? "highlighter" : "bookmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(showHighlightsSidebar ? Color(hex: "fbbf24") : .white)
                        .frame(width: 34, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(showHighlightsSidebar ? Color(hex: "fbbf24").opacity(0.16) : Color(hex: "1e293b"))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(showHighlightsSidebar ? Color(hex: "fbbf24").opacity(0.4) : Color.white.opacity(0.1), lineWidth: 1)
                        )

                    if !highlights.isEmpty {
                        Text("\(highlights.count)")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .background(Color(hex: "fde68a"), in: Capsule())
                            .offset(x: 4, y: -4)
                    }
                }
            }
            .buttonStyle(.macInteractive(cornerRadius: 8))
            .help("Highlights & Ghi chú")

            // AI Companion
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showChatSidebar.toggle()
                }
            } label: {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(showChatSidebar ? Color(hex: "14b8a6") : .white)
                    .frame(width: 34, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(showChatSidebar ? Color(hex: "14b8a6").opacity(0.18) : Color(hex: "1e293b"))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(showChatSidebar ? Color(hex: "14b8a6").opacity(0.45) : Color.white.opacity(0.1), lineWidth: 1)
                    )
            }
            .buttonStyle(.macInteractive(cornerRadius: 8))
            .help("Companion Agent (AI)")

            // Focus / Fullscreen Toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isFullScreen = true
                }
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 30)
                    .background(Color(hex: "1e293b"), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
            }
            .buttonStyle(.macInteractive(cornerRadius: 8))
            .help("Chế độ tập trung (phím F)")

            // Language Switcher Pill [EN | VI | Split] (exact iPad style)
            HStack(spacing: 0) {
                viewModeSegmentButton(title: "EN", mode: "en")
                viewModeSegmentButton(title: "VI", mode: "vi")
                Button {
                    setViewMode("split")
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 12.5))
                        .frame(width: 38, height: 30)
                        .background(viewMode == "split" ? Color(hex: "6366f1") : Color.clear)
                        .foregroundStyle(viewMode == "split" ? .white : Color(hex: "94a3b8"))
                }
                .buttonStyle(.macRect())
                .help("Đọc Song ngữ 2 cột")
            }
            .background(Color(hex: "1e293b"))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color(hex: "0f172a"))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
        }
    }

    private func viewModeSegmentButton(title: String, mode: String) -> some View {
        Button {
            setViewMode(mode)
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: .bold))
                .frame(width: 38, height: 30)
                .background(viewMode == mode ? Color(hex: "6366f1") : Color.clear)
                .foregroundStyle(viewMode == mode ? .white : Color(hex: "94a3b8"))
        }
        .buttonStyle(.macRect())
    }

    private func setViewMode(_ nextMode: String) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            viewMode = nextMode
            activeSentenceId = nil
        }
        if nextMode == "split" {
            var desc = ReaderAppearance.parseThemeDescriptor(selectedThemeId)
            if desc.interlinear {
                desc.interlinear = false
                selectedThemeId = ReaderAppearance.serializeThemeDescriptor(desc)
                persistAppearanceOverride()
            }
        }
        saveProgress()
    }

    // MARK: - Reading Stage (iPad Floating Book Sheets + Spine Shadow)

    @ViewBuilder
    private func readingStage(doubleSided: Bool) -> some View {
        let radius: CGFloat = isFullScreen ? 0 : 16

        if viewMode == "split" {
            let isStacked = (layoutMode == "en-over-vi" || layoutMode == "vi-over-en")
            let isEnFirst = layoutMode.hasPrefix("en")
            let panes = isEnFirst ? ["en", "vi"] : ["vi", "en"]

            Group {
                if isStacked {
                    VStack(spacing: 4) {
                        bookPaneWebView(lang: panes[0], page: currentPage, containerMode: "split")
                        bookPaneWebView(lang: panes[1], page: currentPage, containerMode: "split")
                    }
                } else {
                    HStack(spacing: 4) {
                        bookPaneWebView(lang: panes[0], page: currentPage, containerMode: "split")
                        bookPaneWebView(lang: panes[1], page: currentPage, containerMode: "split")
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.white.opacity(isFullScreen ? 0 : 0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(isFullScreen ? 0 : 0.45), radius: 22, x: 0, y: 10)
        } else if doubleSided {
            let lang = viewMode == "vi" ? "vi" : "en"
            let leftPage = currentPage % 2 == 1 ? currentPage : max(1, currentPage - 1)
            let rightPage = leftPage + 1

            ZStack {
                HStack(spacing: 0) {
                    bookPaneWebView(lang: lang, page: leftPage, containerMode: lang)

                    if rightPage <= totalPages {
                        bookPaneWebView(lang: lang, page: rightPage, containerMode: lang)
                    } else {
                        ZStack {
                            paperColorForStage
                            VStack(spacing: 10) {
                                Image(systemName: "checkmark.seal")
                                    .font(.largeTitle)
                                    .foregroundStyle(.secondary.opacity(0.45))
                                Text("Trang cuối của sách")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.secondary.opacity(0.6))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                // 3D Center Book Spine Shadow (exact iPad book spread feel)
                LinearGradient(
                    colors: [
                        .black.opacity(0.0),
                        .black.opacity(0.04),
                        .black.opacity(0.16),
                        .black.opacity(0.04),
                        .black.opacity(0.0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 46)
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.white.opacity(isFullScreen ? 0 : 0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(isFullScreen ? 0 : 0.48), radius: 24, x: 0, y: 10)
        } else {
            let lang = viewMode == "vi" ? "vi" : "en"
            bookPaneWebView(lang: lang, page: currentPage, containerMode: lang)
                .frame(maxWidth: 920)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Color.white.opacity(isFullScreen ? 0 : 0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(isFullScreen ? 0 : 0.45), radius: 22, x: 0, y: 10)
        }
    }

    private func bookPaneWebView(lang: String, page: Int, containerMode: String) -> some View {
        let isBilingual = viewMode == "split"
        let shouldHighlightSentence = isBilingual
            ? (page == activeSentencePage)
            : (page == activeSentencePage && lang == activeSentenceLang)
        let targetSentenceId = shouldHighlightSentence ? activeSentenceId : nil
        let scrollMirrorPane = isBilingual && shouldHighlightSentence && (activeSentenceLang != lang)

        return BilingualWebViewMac(
            bookSlug: book.slug,
            urlString: pageURL(lang: lang, page: page),
            lang: lang,
            page: page,
            viewMode: viewMode,
            containerMode: containerMode,
            effectiveFontId: selectedFontId,
            effectiveThemeId: selectedThemeId,
            activeSentenceId: targetSentenceId,
            scrollActiveSentenceIntoView: scrollMirrorPane,
            highlights: highlights,
            onHighlightMessage: { msg in
                handleHighlightMessage(msg, lang: lang, page: page)
            },
            onSentenceClicked: { sentenceId in
                guard let sentenceId else {
                    if activeSentenceId != nil {
                        activeSentenceId = nil
                    }
                    return
                }
                if activeSentenceId == sentenceId && activeSentencePage == page && activeSentenceLang == lang {
                    activeSentenceId = nil
                } else {
                    activeSentenceId = sentenceId
                    activeSentencePage = page
                    activeSentenceLang = lang
                    activeSelection = nil
                    activeSelectionPage = nil
                    selectedHighlightId = nil
                    selectedHighlightPage = nil
                    activeRect = nil
                    showNoteEditor = false
                }
            },
            onVocaAction: handleVocaAction,
            onWebViewReady: { wv, l, p in
                webViews["\(l):\(p)"] = wv
            },
            onWebViewDismantled: { _, l, p in
                webViews.removeValue(forKey: "\(l):\(p)")
            }
        )
        .overlay {
            GeometryReader { geo in
                let isTargetPane = activeLang == lang
                    && (activeSelectionPage == page || selectedHighlightPage == page)
                    && (activeSelection != nil || selectedHighlightId != nil)
                if isTargetPane {
                    let anchorRect = activeRect ?? CGRect(
                        x: geo.size.width / 2 - 40,
                        y: geo.size.height / 2,
                        width: 80,
                        height: 24
                    )
                    let pos = clampedToolbarPosition(rect: anchorRect, in: geo.size)
                    let placeNoteBelow = pos.y < 185

                    iPadStyleHighlightMenu(placeNoteBelow: placeNoteBelow)
                        .position(x: pos.x, y: pos.y)
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.88).combined(with: .opacity),
                                removal: .scale(scale: 0.94).combined(with: .opacity)
                            )
                        )
                }
            }
        }
    }

    private func clampedToolbarPosition(rect: CGRect, in size: CGSize) -> CGPoint {
        let menuHalfWidth: CGFloat = (selectedHighlightId != nil && canLookupActiveTextInVoca)
            ? 158
            : (showNoteEditor ? 140 : 136)
        let menuHalfHeight: CGFloat = 24
        let minX = menuHalfWidth + 12
        let maxX = max(minX, size.width - menuHalfWidth - 12)
        let x = min(max(rect.midX, minX), maxX)

        // Prefer directly above the selected word/phrase; flip below if too close to top edge.
        let aboveY = rect.minY - 30
        let rawY = aboveY >= (menuHalfHeight + 10) ? aboveY : (rect.maxY + 30)
        let minY = menuHalfHeight + 8
        let maxY = max(minY, size.height - menuHalfHeight - 8)
        let y = min(max(rawY, minY), maxY)
        return CGPoint(x: x, y: y)
    }

    @ViewBuilder
    private func edgePageTurnOverlays(doubleSided: Bool) -> some View {
        let left = currentPage % 2 == 1 ? currentPage : max(1, currentPage - 1)
        let canPrev = doubleSided ? (left > 1) : (currentPage > 1)
        let canNext = doubleSided ? (left + 1 < totalPages) : (currentPage < totalPages)

        HStack {
            // Left margin edge flip
            ZStack(alignment: .leading) {
                Color.clear
                    .frame(width: 56)

                if canPrev {
                    Button {
                        stepPage(forward: false, doubleSided: doubleSided)
                    } label: {
                        ZStack {
                            Color.clear
                                .frame(width: 56, height: 120)
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 64)
                                .background(Color(hex: "1e293b").opacity(isHoveringLeftEdge ? 0.96 : 0.86), in: RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(isHoveringLeftEdge ? 0.3 : 0.16), lineWidth: 1))
                                .shadow(color: .black.opacity(isHoveringLeftEdge ? 0.34 : 0.16), radius: 8, y: 3)
                        }
                    }
                    .buttonStyle(.macInteractive(cornerRadius: 14, hoverColor: Color.white.opacity(0.06)))
                    .padding(.leading, 4)
                    .scaleEffect(isHoveringLeftEdge ? 1.05 : 1.0)
                    .opacity(isHoveringLeftEdge ? 1.0 : 0.32)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                    isHoveringLeftEdge = hovering
                }
            }

            Spacer()

            // Right margin edge flip
            ZStack(alignment: .trailing) {
                Color.clear
                    .frame(width: 56)

                if canNext {
                    Button {
                        stepPage(forward: true, doubleSided: doubleSided)
                    } label: {
                        ZStack {
                            Color.clear
                                .frame(width: 56, height: 120)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 64)
                                .background(Color(hex: "1e293b").opacity(isHoveringRightEdge ? 0.96 : 0.86), in: RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(isHoveringRightEdge ? 0.3 : 0.16), lineWidth: 1))
                                .shadow(color: .black.opacity(isHoveringRightEdge ? 0.34 : 0.16), radius: 8, y: 3)
                        }
                    }
                    .buttonStyle(.macInteractive(cornerRadius: 14, hoverColor: Color.white.opacity(0.06)))
                    .padding(.trailing, 4)
                    .scaleEffect(isHoveringRightEdge ? 1.05 : 1.0)
                    .opacity(isHoveringRightEdge ? 1.0 : 0.32)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) {
                    isHoveringRightEdge = hovering
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func bottomProgressStrip(doubleSided: Bool) -> some View {
        let shownPage = doubleSided
            ? min(totalPages, (currentPage % 2 == 1 ? currentPage : max(1, currentPage - 1)) + 1)
            : currentPage
        let pct = Int(round((Double(shownPage) / Double(totalPages)) * 100.0))

        return HStack(spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 3)
                    Capsule()
                        .fill(Color(hex: "2dd4bf"))
                        .frame(width: max(4, geo.size.width * CGFloat(Double(shownPage) / Double(totalPages))), height: 3)
                        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: shownPage)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 12)

            Text("\(pct)%")
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color(hex: "94a3b8"))
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.2), value: pct)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 8)
    }

    // MARK: - Jump to Page Popover

    private var jumpToPagePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Đi đến trang")
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(.white)

            HStack(spacing: 8) {
                TextField("1 - \(totalPages)", text: $jumpPageText)
                    .textFieldStyle(.plain)
                    .padding(8)
                    .frame(width: 96)
                    .background(Color(hex: "0b0f19"))
                    .cornerRadius(7)
                    .foregroundStyle(.white)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .focused($isTypingInInput)
                    .onSubmit {
                        if let p = Int(jumpPageText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            goToPage(p)
                            showJumpToPagePopover = false
                        }
                    }

                Text("/ \(totalPages)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color(hex: "94a3b8"))

                Spacer()

                Button("Chuyển") {
                    if let p = Int(jumpPageText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        goToPage(p)
                        showJumpToPagePopover = false
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            if totalPages > 1 {
                Slider(
                    value: Binding(
                        get: { Double(currentPage) },
                        set: { val in
                            let p = Int(val.rounded())
                            jumpPageText = "\(p)"
                            goToPage(p)
                        }
                    ),
                    in: 1...Double(totalPages),
                    step: 1
                )
                .tint(Color(hex: "38bdf8"))
            }
        }
        .padding(16)
        .frame(width: 260)
        .background(Color(hex: "0d1321"))
        .preferredColorScheme(.dark)
    }

    // MARK: - iPad Floating Highlight & Voca Menu (with Warm Post-It Note Card)

    private func iPadStyleHighlightMenu(placeNoteBelow: Bool) -> some View {
        let pill = HStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(highlightColors, id: \.hex) { item in
                    Button {
                        selectedColor = item.hex
                        applyHighlight(color: item.hex)
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(hex: String(item.hex.dropFirst())))
                                .frame(width: 22, height: 22)
                                .scaleEffect(selectedColor == item.hex ? 1.12 : 1.0)
                                .overlay(
                                    Circle().stroke(Color.white, lineWidth: selectedColor == item.hex ? 2 : 0)
                                )
                                .animation(.spring(response: 0.2, dampingFraction: 0.75), value: selectedColor)
                        }
                        .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.macCircle(hoverColor: Color.white.opacity(0.16), pressedScale: 0.9))
                    .help("Highlight màu \(item.name)")
                }
            }

            Divider().background(Color.white.opacity(0.25)).frame(height: 18)

            if canLookupActiveTextInVoca {
                Button {
                    lookupActiveSelectionInVoca()
                } label: {
                    Image(systemName: "book.closed")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(hex: "38bdf8"))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.05), in: Circle())
                }
                .buttonStyle(.macCircle())
                .help("Tra & thêm từ vào Voca 2.0")
            }

            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                    showNoteEditor.toggle()
                }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16))
                    .foregroundStyle(highlightNote.isEmpty ? Color(hex: "cbd5e1") : Color(hex: "fbbf24"))
                    .frame(width: 32, height: 32)
                    .background(Color.white.opacity(0.05), in: Circle())
            }
            .buttonStyle(.macCircle())
            .help("Thêm / sửa ghi chú")

            if let hlId = selectedHighlightId {
                Button {
                    Task {
                        highlights.removeAll { $0.id == hlId }
                        await api.deleteHighlight(slug: book.slug, id: hlId)
                        clearSelectionBar()
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(hex: "f87171"))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.05), in: Circle())
                }
                .buttonStyle(.macCircle())
                .help("Xoá highlight")
            }

            Button {
                clearSelectionBar()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Color(hex: "94a3b8"))
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(0.05), in: Circle())
            }
            .buttonStyle(.macCircle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            ZStack {
                Color.clear
                    .contentShape(Capsule())
                    .onTapGesture {}
                Capsule()
                    .fill(Color(hex: "1e293b").opacity(0.96))
            }
        }
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)

        let noteCard = VStack(alignment: .leading, spacing: 8) {
            TextField("Nhập ghi chú của bạn…", text: $highlightNote, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...6)
                .padding(8)
                .foregroundStyle(Color(hex: "422006"))
                .font(.system(.body, design: .serif))
                .focused($isTypingInInput)

            HStack {
                Button {
                    withAnimation { showNoteEditor = false }
                } label: {
                    Text("Đóng")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color(hex: "78350f"))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.macInteractive(cornerRadius: 6, hoverColor: Color.black.opacity(0.09)))

                Spacer()

                Button {
                    if activeSelection != nil {
                        applyHighlight(color: selectedColor)
                    } else if let id = selectedHighlightId {
                        updateExistingHighlightNote(id: id)
                    }
                } label: {
                    Text("Lưu ghi chú")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(hex: "b45309"), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.macInteractive(cornerRadius: 6, hoverColor: Color.white.opacity(0.16)))
            }
        }
        .padding(10)
        .frame(width: 256)
        .background {
            ZStack {
                Color.clear
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture {}
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "fef9c3"), Color(hex: "fde68a"), Color(hex: "fcd34d")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "d97706").opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .rotationEffect(.degrees(-1.2))
        .transition(.scale(scale: 0.9, anchor: placeNoteBelow ? .top : .bottom).combined(with: .opacity))

        return pill
            .overlay(alignment: placeNoteBelow ? .top : .bottom) {
                if showNoteEditor {
                    noteCard
                        .offset(y: placeNoteBelow ? 48 : -48)
                }
            }
    }

    // MARK: - Dark iPad Highlights Drawer

    private var highlightsDrawerView: some View {
        let displayed = highlightsFilterCurrentPageOnly
            ? highlights.filter { $0.page == currentPage }
            : highlights.sorted { $0.page < $1.page }

        return VStack(spacing: 0) {
            HStack {
                Label("Ghi chú & Đánh dấu", systemImage: "highlighter")
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    withAnimation { showHighlightsSidebar = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(Color(hex: "94a3b8"))
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.macCircle())
            }
            .padding(14)
            .background(Color(hex: "0b0f19"))

            Picker("Lọc", selection: $highlightsFilterCurrentPageOnly) {
                Text("Tất cả (\(highlights.count))").tag(false)
                Text("Trang này").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .background(Color(hex: "0b0f19"))

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)

            if displayed.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "highlighter")
                        .font(.title)
                        .foregroundStyle(Color(hex: "475569"))
                    Text("Chưa có highlight nào")
                        .font(.subheadline)
                        .foregroundStyle(Color(hex: "94a3b8"))
                    Text("Bôi đen đoạn văn bản bất kỳ để đánh dấu hoặc thêm ghi chú.")
                        .font(.caption)
                        .foregroundStyle(Color(hex: "64748b"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(displayed) { hl in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Circle()
                                        .fill(Color(hex: String(hl.color.dropFirst())))
                                        .frame(width: 9, height: 9)
                                    Text("Trang \(hl.page) • \(hl.lang.uppercased())")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(Color(hex: "94a3b8"))
                                    Spacer()
                                    Button {
                                        Task {
                                            highlights.removeAll { $0.id == hl.id }
                                            await api.deleteHighlight(slug: book.slug, id: hl.id)
                                        }
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                            .foregroundStyle(Color(hex: "f87171"))
                                            .frame(width: 28, height: 28)
                                            .background(Color.white.opacity(0.05), in: Circle())
                                    }
                                    .buttonStyle(.macCircle())
                                }

                                Text("“\(hl.text)”")
                                    .font(.callout)
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(4)

                                if let note = hl.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(note)
                                        .font(.caption)
                                        .foregroundStyle(Color(hex: "fde68a"))
                                        .padding(6)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(hex: "fbbf24").opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                                }

                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up.right.square")
                                    Text("Mở trang \(hl.page) ở cửa sổ xem riêng (giữ nguyên trang \(currentPage))")
                                }
                                .font(.caption2)
                                .foregroundStyle(Color(hex: "5eead4").opacity(0.85))
                                .padding(.top, 2)
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color(hex: String(hl.color.dropFirst())).opacity(0.3), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                previewingHighlight = hl
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(Color(hex: "0b0f19"))
    }

    // MARK: - iPad Companion Agent Sidebar

    private var chatCompanionDrawer: some View {
        HStack(spacing: 0) {
            // Draggable width handle (iPad parity)
            ZStack {
                Rectangle().fill(Color(hex: "0b0f19")).frame(width: 10)
                Capsule()
                    .fill(isDraggingChatDivider ? Color(hex: "14b8a6") : Color.white.opacity(0.14))
                    .frame(width: 2.5, height: 64)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if !isDraggingChatDivider {
                            isDraggingChatDivider = true
                            dragStartChatWidth = chatWidth
                        }
                        chatWidth = max(280, min(620, dragStartChatWidth - value.translation.width))
                    }
                    .onEnded { _ in
                        isDraggingChatDivider = false
                    }
            )

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Color(hex: "14b8a6"))
                            Text("Companion Agent")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        Text("Trợ lý đọc sách song ngữ")
                            .font(.caption2)
                            .foregroundStyle(Color(hex: "64748b"))
                    }
                    Spacer()
                    Button {
                        chatMessages.removeAll()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(Color(hex: "f87171"))
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.macCircle())
                    .help("Xoá lịch sử chat")

                    Button {
                        withAnimation { showChatSidebar = false }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                            .foregroundStyle(Color(hex: "94a3b8"))
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.06), in: Circle())
                    }
                    .buttonStyle(.macCircle())
                }
                .padding(14)
                .background(Color(hex: "0b0f19"))

                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if chatMessages.isEmpty {
                                companionWelcomeView
                            } else {
                                ForEach(chatMessages) { msg in
                                    HStack(alignment: .bottom, spacing: 8) {
                                        if msg.role == "assistant" {
                                            LinearGradient(
                                                colors: [Color(hex: "0d9488"), Color(hex: "2dd4bf")],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                            .frame(width: 26, height: 26)
                                            .clipShape(Circle())
                                            .overlay(
                                                Image(systemName: "sparkles")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundStyle(.white)
                                            )
                                        } else {
                                            Spacer()
                                        }

                                        Text(msg.content)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.white)
                                            .textSelection(.enabled)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 9)
                                            .background(
                                                msg.role == "user"
                                                    ? AnyShapeStyle(LinearGradient(colors: [Color(hex: "818cf8"), Color(hex: "6366f1")], startPoint: .topLeading, endPoint: .bottomTrailing))
                                                    : AnyShapeStyle(Color.white.opacity(0.07))
                                            )
                                            .cornerRadius(12)

                                        if msg.role == "assistant" { Spacer(minLength: 16) }
                                    }
                                    .id(msg.id)
                                }
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: chatMessages.count) { _, _ in
                        if let last = chatMessages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
                .background(Color(hex: "0b0f19"))

                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

                HStack(spacing: 8) {
                    TextField("Hỏi về trang \(currentPage)…", text: $chatInput)
                        .textFieldStyle(.plain)
                        .padding(9)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(9)
                        .foregroundStyle(.white)
                        .focused($isTypingInInput)
                        .onSubmit { sendChatMessage() }

                    Button {
                        sendChatMessage()
                    } label: {
                        Group {
                            if isSendingChat {
                                ProgressView().controlSize(.small).tint(Color(hex: "14b8a6"))
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(Color(hex: "14b8a6"))
                            }
                        }
                        .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.macCircle())
                    .disabled(chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSendingChat)
                }
                .padding(12)
                .background(Color(hex: "0b0f19"))
            }
        }
        .frame(width: chatWidth)
        .background(Color(hex: "0b0f19"))
    }

    private var companionWelcomeView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color(hex: "14b8a6").opacity(0.25), .clear], center: .center, startRadius: 0, endRadius: 42))
                    .frame(width: 84, height: 84)
                Image(systemName: "sparkles")
                    .font(.system(size: 32))
                    .foregroundStyle(Color(hex: "14b8a6"))
            }
            .padding(.top, 10)

            VStack(spacing: 6) {
                Text("Chào bạn!")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                Text("Companion Agent đọc cùng trang sách hiện tại để hỗ trợ giải thích ngữ cảnh, từ vựng và tóm tắt ý chính.")
                    .font(.caption)
                    .foregroundStyle(Color(hex: "94a3b8"))
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("GỢI Ý CÂU HỎI")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color(hex: "64748b"))

                suggestedPromptButton(icon: "📝", title: "Tóm tắt trang này") {
                    sendChatMessage(overridePrompt: "Hãy tóm tắt ngắn gọn nội dung chính của trang \(currentPage) bằng tiếng Việt.")
                }
                suggestedPromptButton(icon: "💡", title: "Giải thích từ & cấu trúc câu hay") {
                    sendChatMessage(overridePrompt: "Liệt kê 3–5 từ vựng hoặc cấu trúc tiếng Anh đáng chú ý trên trang \(currentPage) kèm nghĩa và giải thích ngữ cảnh.")
                }
                suggestedPromptButton(icon: "📘", title: "Phân tích ý tác giả") {
                    sendChatMessage(overridePrompt: "Phân tích thông điệp cốt lõi tác giả muốn truyền tải ở trang \(currentPage).")
                }
            }
        }
    }

    private func suggestedPromptButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(icon).font(.title3)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.caption2.bold())
                    .foregroundStyle(Color(hex: "14b8a6"))
            }
            .padding(10)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.macInteractive(cornerRadius: 10))
    }

    // MARK: - Actions & Sync

    private func pageURL(lang: String, page: Int) -> String {
        book.pageURL(serverUrl: api.normalizedServerUrl, lang: lang, page: page)
    }

    private func loadInitialState() {
        isBookFinished = book.isFinished == true
        let resolved = ReaderAppearance.resolveEffectiveAppearance(
            book: book,
            localOverride: ReaderAppearance.loadLocalOverride(slug: book.slug)
        )
        selectedFontId = resolved.effectiveFontId
        selectedThemeId = resolved.effectiveThemeId
        hasLoadedBookAppearance = true

        if let cachedData = UserDefaults.standard.data(forKey: "progress_\(book.slug)"),
           let cached = try? JSONDecoder().decode(ReadingProgress.self, from: cachedData) {
            currentPage = max(1, min(totalPages, cached.page))
            viewMode = cached.viewMode
        }
        jumpPageText = "\(currentPage)"

        Task {
            if api.isOfflineMode {
                let uname = api.currentUser?.username ?? ""
                highlights = backup.offlineHighlights(forUsername: uname, slug: book.slug)
                if let prog = backup.offlineProgress(forUsername: uname, slug: book.slug) {
                    currentPage = max(1, min(totalPages, prog.page))
                    viewMode = prog.viewMode
                    jumpPageText = "\(currentPage)"
                }
            } else {
                await api.fetchHighlights(slug: book.slug)
                highlights = api.highlights
                if let prog = await api.fetchReadingProgress(slug: book.slug) {
                    currentPage = max(1, min(totalPages, prog.page))
                    viewMode = prog.viewMode
                    jumpPageText = "\(currentPage)"
                }
            }
        }
    }

    private func stepPage(forward: Bool, doubleSided: Bool) {
        let step = doubleSided ? 2 : 1
        let target = forward ? (currentPage + step) : (currentPage - step)
        goToPage(target)
    }

    private func goToPage(_ target: Int) {
        let clamped = max(1, min(totalPages, target))
        guard clamped != currentPage else { return }
        let forward = clamped > currentPage
        currentPage = clamped
        jumpPageText = "\(clamped)"
        clearSelectionBar()
        saveProgress()
        triggerPageTurnAnimation(forward: forward)
    }

    private func triggerPageTurnAnimation(forward: Bool) {
        var instantTx = Transaction()
        instantTx.disablesAnimations = true
        withTransaction(instantTx) {
            pageTurnForward = forward
            pageTurnSkew = forward ? -3.2 : 3.2
            pageTurnShift = forward ? 20 : -20
            pageTurnShadowOpacity = 0.24
        }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
            pageTurnSkew = 0
            pageTurnShift = 0
            pageTurnShadowOpacity = 0
        }
    }

    private func saveProgress() {
        let ts = Int(Date().timeIntervalSince1970)
        Task {
            if api.isOfflineMode {
                let localProgress = ReadingProgress(page: currentPage, viewMode: viewMode, lastRead: ts)
                if let data = try? JSONEncoder().encode(localProgress) {
                    UserDefaults.standard.set(data, forKey: "progress_\(book.slug)")
                }
                return
            }
            await api.saveReadingProgress(slug: book.slug, page: currentPage, viewMode: viewMode, lastRead: ts)
        }
    }

    private func toggleBookFinished() {
        guard !api.isOfflineMode else {
            showToast("Không thể cập nhật trạng thái khi đang ngoại tuyến.")
            return
        }
        let next = !isBookFinished
        isUpdatingFinished = true
        Task {
            let ok = await api.updateBookState(slug: book.slug, isFinished: next)
            await MainActor.run {
                isUpdatingFinished = false
                if ok {
                    isBookFinished = next
                    showToast(next ? "Đã đánh dấu hoàn thành sách!" : "Đã bỏ đánh dấu hoàn thành.")
                    NotificationCenter.default.post(name: NSNotification.Name("BookStateUpdated"), object: nil)
                }
            }
        }
    }

    private func toggleInterlinearMode() {
        var desc = ReaderAppearance.parseThemeDescriptor(selectedThemeId)
        desc.interlinear.toggle()
        if desc.interlinear && viewMode == "split" {
            viewMode = "en"
            saveProgress()
        }
        selectedThemeId = ReaderAppearance.serializeThemeDescriptor(desc)
        persistAppearanceOverride()
    }

    private func persistAppearanceOverride() {
        guard hasLoadedBookAppearance else { return }
        ReaderAppearance.saveLocalOverride(slug: book.slug, readerFont: selectedFontId, readerTheme: selectedThemeId)
        guard !api.isOfflineMode else { return }
        Task {
            await api.updateBookState(slug: book.slug, readerFont: selectedFontId, readerTheme: selectedThemeId)
        }
    }

    private func saveAsBookDefault() {
        guard !api.isOfflineMode else {
            showToast("Không thể lưu mặc định sách khi đang ngoại tuyến.")
            return
        }
        isSavingAppearanceDefault = true
        Task {
            let ok = await api.updateBookAppearanceDefaults(
                slug: book.slug,
                defaultFont: selectedFontId,
                defaultTheme: selectedThemeId
            )
            await MainActor.run {
                isSavingAppearanceDefault = false
                showToast(ok ? "Đã lưu giao diện mặc định cho sách." : "Lưu mặc định sách thất bại.")
            }
        }
    }

    private var activeLookupText: String? {
        if let sel = activeSelection {
            return sel.text
        }
        if let hlId = selectedHighlightId,
           let existing = highlights.first(where: { $0.id == hlId }) {
            return existing.text
        }
        return nil
    }

    private var canLookupActiveTextInVoca: Bool {
        guard activeLang == "en", let raw = activeLookupText else { return false }
        return !VocaService.cleanWord(raw).isEmpty
    }

    private func dismissOpenVocaPanels() {
        for wv in webViews.values {
            wv.evaluateJavaScript("window.removeIOSVocaPanel && window.removeIOSVocaPanel();", completionHandler: nil)
        }
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
        activeSentenceId = nil
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
        let targetPage = activeSelectionPage ?? currentPage
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

    private func lookupActiveSelectionInVoca() {
        guard let rawText = activeLookupText else { return }
        let lang = activeLang
        guard lang == "en" else { return }
        let targetPage = activeSelectionPage ?? selectedHighlightPage ?? currentPage
        guard let webView = webViews["\(lang):\(targetPage)"] else { return }
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
                        if let webView = webViews["\(vocaPanelLang):\(vocaPanelPage ?? currentPage)"],
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
            guard let webView = webViews["\(vocaPanelLang):\(vocaPanelPage ?? currentPage)"],
                  let json = VocaService.singleCardPanelJSON(card: card, rect: savedRect) else { return }
            webView.evaluateShowVocaPanel(json: json)
        case .dismiss:
            break
        }
    }

    private func extractCurrentPageContext() async -> String {
        var snippets: [String] = []
        for lang in ["en", "vi"] {
            if let wv = webViews["\(lang):\(currentPage)"] {
                let text = await withCheckedContinuation { cont in
                    wv.evaluateJavaScript("window.getPageTextForAI ? window.getPageTextForAI() : (document.body.innerText || '')") { val, _ in
                        cont.resume(returning: (val as? String) ?? "")
                    }
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    snippets.append("[\(lang.uppercased()) - Trang \(currentPage)]\n\(String(trimmed.prefix(3500)))")
                }
            }
        }
        return snippets.joined(separator: "\n\n")
    }

    private func sendChatMessage(overridePrompt: String? = nil) {
        let trimmed = (overridePrompt ?? chatInput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSendingChat else { return }
        if api.isOfflineMode {
            chatMessages.append(ChatMessage(role: "assistant", content: "Không thể gọi AI Companion khi đang ngoại tuyến."))
            return
        }
        chatMessages.append(ChatMessage(role: "user", content: trimmed))
        if overridePrompt == nil { chatInput = "" }
        isSendingChat = true

        let baseURL = UserDefaults.standard.string(forKey: "aiBaseURL") ?? "https://api.openai.com/v1"
        let apiKey = UserDefaults.standard.string(forKey: "aiApiKey") ?? ""
        let model = UserDefaults.standard.string(forKey: "aiModel") ?? "gpt-4o-mini"

        Task {
            let pageContext = await extractCurrentPageContext()
            let sysText = """
            You are Companion Agent, a bilingual reading assistant for the book '\(book.title)' (page \(currentPage)/\(totalPages)).
            Answer concisely and insightfully in Vietnamese (or English if asked).
            Current visible page text:
            \(pageContext)
            """
            let history = chatMessages.suffix(10).map { ["role": $0.role, "content": $0.content] }
            let sysPrompt = ["role": "system", "content": sysText]

            do {
                let reply = try await api.sendChat(baseURL: baseURL, apiKey: apiKey, model: model, messages: [sysPrompt] + history)
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

    private func showToast(_ text: String) {
        withAnimation { vocaToast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            withAnimation { vocaToast = nil }
        }
    }
}
