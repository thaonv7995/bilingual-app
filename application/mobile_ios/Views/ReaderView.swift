import SwiftUI

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
    @State private var isLoading: Bool
    
    init(book: Book) {
        self.book = book
        
        var initialPage = 1
        var initialViewMode = "split"
        var hasCache = false
        
        if let data = UserDefaults.standard.data(forKey: "progress_\(book.slug)"),
           let progress = try? JSONDecoder().decode(ReadingProgress.self, from: data) {
            initialPage = progress.page
            initialViewMode = progress.viewMode
            hasCache = true
        }
        
        self._page = State(initialValue: initialPage)
        self._viewMode = State(initialValue: initialViewMode)
        self._isLoading = State(initialValue: !hasCache)
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
    @State private var isAISettingsOpen = false
    @State private var aiProvider: String = "openai"
    @State private var aiBaseURL: String = "https://api.openai.com/v1"
    @State private var aiApiKey: String = ""
    @State private var aiModel: String = "gpt-4o-mini"
    @State private var bilingualLayoutMode: String = "en-vi"
    @State private var chatMessages: [ChatMessage] = []
    @State private var chatInputText: String = ""
    @State private var isChatPending = false
    @State private var chatWidth: CGFloat = 350
    @State private var dragStartingWidth: CGFloat = 350
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging: Bool = false
    
    let highlightColors = [
        ("#fde68a", Color(hex: "fde68a")), // Yellow
        ("#93c5fd", Color(hex: "93c5fd")), // Blue
        ("#f9a8d4", Color(hex: "f9a8d4")), // Pink
        ("#86efac", Color(hex: "86efac"))  // Green
    ]
    
    var body: some View {
        GeometryReader { geometry in
            let isLargeScreen = geometry.size.width > 700
            
            HStack(spacing: 0) {
                // Main Reading Pane
                VStack(spacing: 0) {
                    // Custom Slim Top Navigation Bar
                    HStack(spacing: 12) {
                        Button(action: { dismiss() }) {
                            Image(systemName: "chevron.left")
                                .foregroundColor(.white)
                                .font(.system(size: 16))
                        }
                        
                        Spacer()
                        
                        Text(book.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        
                        Spacer()
                        
                        Text("\(page)/\(book.pageCount)")
                            .foregroundColor(Color.gray)
                            .font(.system(size: 13, weight: .medium))
                            .padding(.trailing, 8)
                        
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
                    
                    // Reading Area
                        ZStack {
                            Color(hex: "0f172a").ignoresSafeArea()
                            
                            if isLoading {
                                ProgressView().tint(.white)
                            } else {
                                let pageBinding = Binding(
                                    get: { self.page },
                                    set: { newPage in
                                        if newPage != self.page {
                                            self.page = newPage
                                            self.saveProgress()
                                            self.clearSelectionState()
                                        }
                                    }
                                )
                                
                                let isLandscape = geometry.size.width > geometry.size.height
                                let isLargeAndLandscape = isLargeScreen && isLandscape
                                let useDoubleSided = isLargeAndLandscape && !isChatOpen
                                
                                let readingPaneWidth = isLargeScreen && isChatOpen ? geometry.size.width - chatWidth : geometry.size.width
                                let isReadingPaneLarge = readingPaneWidth > 700
                                
                                ZStack {
                                    // Chế độ Song ngữ
                                    TabView(selection: pageBinding) {
                                        ForEach(1...max(1, book.pageCount), id: \.self) { p in
                                            let isHorizontal = (bilingualLayoutMode == "en-over-vi" || bilingualLayoutMode == "vi-over-en") ? false : isReadingPaneLarge
                                            let isEnFirst = bilingualLayoutMode.hasPrefix("en")
                                            let layout = isHorizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                                            layout {
                                                if isEnFirst {
                                                    renderWebView(lang: "en", p: p, isDoubleSided: false)
                                                        .padding(.leading, isHorizontal ? 28 : 16)
                                                        .padding(.trailing, isHorizontal ? 4 : 16)
                                                        .padding(.vertical, 6)
                                                    renderWebView(lang: "vi", p: p, isDoubleSided: false)
                                                        .padding(.leading, isHorizontal ? 4 : 16)
                                                        .padding(.trailing, isHorizontal ? 28 : 16)
                                                        .padding(.vertical, 6)
                                                } else {
                                                    renderWebView(lang: "vi", p: p, isDoubleSided: false)
                                                        .padding(.leading, isHorizontal ? 28 : 16)
                                                        .padding(.trailing, isHorizontal ? 4 : 16)
                                                        .padding(.vertical, 6)
                                                    renderWebView(lang: "en", p: p, isDoubleSided: false)
                                                        .padding(.leading, isHorizontal ? 4 : 16)
                                                        .padding(.trailing, isHorizontal ? 28 : 16)
                                                        .padding(.vertical, 6)
                                                }
                                            }
                                            .tag(p)
                                        }
                                    }
                                    .tabViewStyle(.page(indexDisplayMode: .never))
                                    .opacity(viewMode == "split" ? 1 : 0)
                                    .allowsHitTesting(viewMode == "split")
                                    
                                    // Chế độ Đơn ngữ (Tiếng Anh)
                                    BookPagerView(
                                        pageCount: max(1, book.pageCount),
                                        currentPage: pageBinding,
                                        isDoubleSided: useDoubleSided
                                    ) { p in
                                        let isLeft = p % 2 == 1
                                        renderWebView(lang: "en", p: p, isDoubleSided: useDoubleSided)
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
                                        isDoubleSided: useDoubleSided
                                    ) { p in
                                        let isLeft = p % 2 == 1
                                        renderWebView(lang: "vi", p: p, isDoubleSided: useDoubleSided)
                                            .padding(.top, 6)
                                            .padding(.bottom, 6)
                                            .padding(.leading, useDoubleSided ? (isLeft ? 32 : 0) : 16)
                                            .padding(.trailing, useDoubleSided ? (isLeft ? 0 : 32) : 16)
                                    }
                                    .id("vi_\(useDoubleSided)")
                                    .opacity(viewMode == "vi" ? 1 : 0)
                                    .allowsHitTesting(viewMode == "vi")
                                }
                            }
                        }
                        .ignoresSafeArea(edges: .bottom)
                    }
                    .frame(maxWidth: .infinity)
                    
                    // Slide-in AI Assistant Sidebar (For large screens)
                    if isChatOpen && isLargeScreen {
                        // Drag Resize Handle
                        HStack(spacing: 0) {
                            Divider().background(Color.white.opacity(0.1))
                            
                            // Visual Grip Zone
                            ZStack {
                                Color(hex: "0b0f19")
                                    .frame(width: 12)
                                
                                // Drag Line
                                Rectangle()
                                    .fill(isDragging ? Color(hex: "14b8a6") : Color(hex: "14b8a6").opacity(0.2))
                                    .frame(width: isDragging ? 2.5 : 1.5)
                                    .shadow(color: isDragging ? Color(hex: "14b8a6").opacity(0.6) : .clear, radius: 4)
                                
                                // Tactile visual indicator dots
                                VStack(spacing: 4) {
                                    ForEach(0..<3) { _ in
                                        Circle()
                                            .fill(isDragging ? Color.white : Color.gray.opacity(0.6))
                                            .frame(width: 3, height: 3)
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                            .offset(x: dragOffset)
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { gesture in
                                        isDragging = true
                                        let proposedWidth = dragStartingWidth - gesture.translation.width
                                        let maxWidth = geometry.size.width * 0.55
                                        let clampedWidth = min(max(proposedWidth, 280), maxWidth)
                                        dragOffset = dragStartingWidth - clampedWidth
                                    }
                                    .onEnded { gesture in
                                        let proposedWidth = dragStartingWidth - gesture.translation.width
                                        let maxWidth = geometry.size.width * 0.55
                                        let finalWidth = min(max(proposedWidth, 280), maxWidth)
                                        
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                            chatWidth = finalWidth
                                        }
                                        dragStartingWidth = finalWidth
                                        isDragging = false
                                        dragOffset = 0
                                    }
                            )
                        }
                        .ignoresSafeArea(edges: [.top, .bottom])
                        
                        aiAssistantPanel()
                            .frame(width: chatWidth)
                            .transition(.move(edge: .trailing))
                    }
                }
                // Sliding Overlay Sheet for smaller screens (iPhone)
                .sheet(isPresented: Binding(
                    get: { isChatOpen && !isLargeScreen },
                    set: { isChatOpen = $0 }
                )) {
                    aiAssistantPanel()
                        .background(Color(hex: "111827").ignoresSafeArea())
                }
            }
            .background(Color(hex: "0f172a"))
            .onAppear {
                loadProgress()
                loadAISettings()
                fetchHighlights()
            }
            .onChange(of: viewMode) { _ in
                saveProgress()
            }
    }
    
    // --- Highlights UI / logic ---
    @ViewBuilder
    private func renderWebView(lang: String, p: Int, isDoubleSided: Bool) -> some View {
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
            activeSentenceId: targetSentenceId,
            onScroll: { scrollTop in
                let otherLang = lang == "en" ? "vi" : "en"
                NotificationCenter.default.post(
                    name: NSNotification.Name("ScrollTo_\(otherLang)"),
                    object: nil,
                    userInfo: ["scrollTop": scrollTop]
                )
            },
            onHighlightMessage: { msg in
                handleHighlightMessage(msg, lang: lang, page: p)
            },
            onSentenceClicked: { sentenceId in
                self.activeSentenceId = sentenceId
                self.activeSentencePage = p
                self.activeSentenceLang = lang
            }
        )
        .modifier(PaperSheetModifier(viewMode: viewMode, page: p, isDoubleSided: isDoubleSided))
        .overlay(
            Group {
                if activeSelectionLang == lang && activeSelectionPage == p && (activeSelection != nil || selectedHighlightId != nil) {
                    if let rect = activeRect {
                        highlightPopupMenu()
                            .position(x: rect.midX, y: max(30, rect.minY - 30))
                    }
                }
            }
        )
    }
    
    @ViewBuilder
    private func highlightPopupMenu() -> some View {
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
                            saveHighlight()
                        }
                }
            }
            
            Divider().background(Color.white.opacity(0.3)).frame(height: 20)
            
            // Ask AI
            if let selection = activeSelection {
                Button(action: {
                    askAIShortcut(text: selection.text)
                }) {
                    Image(systemName: "sparkles")
                        .foregroundColor(.purple)
                        .font(.system(size: 18))
                }
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
                Button(action: {
                    deleteHighlight()
                }) {
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
                            Button("Lưu") { saveHighlight() }
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
    
    private func handleHighlightMessage(_ msg: HighlightMessage, lang: String, page: Int) {
        switch msg {
        case .textSelected(let selectionInfo):
            self.activeSelection = selectionInfo
            self.activeSelectionLang = lang
            self.activeSelectionPage = page
            self.selectedHighlightId = nil
            self.highlightNote = ""
            self.selectedColor = "#fde68a"
            self.activeRect = selectionInfo.rect
            self.showNoteInput = false
        case .highlightClicked(let id, let rect):
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
        case .clearSelection:
            clearSelectionState()
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
    
    private func fetchHighlights() {
        Task {
            _ = try? await api.fetchHighlights(slug: book.slug)
        }
    }
    
    private func saveHighlight() {
        let slug = book.slug
        if let selection = activeSelection {
            let newHighlight = Highlight(
                id: UUID().uuidString.lowercased(),
                page: page,
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
    
    // --- AI Chat Assistant UI ---
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
                        Text("Trợ lý AI")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Text("Trợ lý phân tích sách thông minh")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
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
            } else {
                // Messages List
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if chatMessages.isEmpty {
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
                                        
                                        Text("Tôi là Trợ lý AI. Tôi có thể giúp bạn phân tích, tóm tắt, giải thích thuật ngữ hoặc dịch nghĩa cuốn sách này.")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                            .multilineTextAlignment(.center)
                                            .lineSpacing(4)
                                            .padding(.horizontal, 20)
                                    }
                                    
                                    Spacer().frame(height: 10)
                                    
                                    // Suggested Prompt cards
                                    VStack(alignment: .leading, spacing: 10) {
                                        Text("GỢI Ý CÂU HỎI NHANH")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundColor(.gray.opacity(0.8))
                                            .padding(.horizontal, 4)
                                        
                                        SuggestedPromptRow(
                                            icon: "📝",
                                            title: "Tóm tắt trang này",
                                            prompt: "Tóm tắt nội dung chính của trang đang đọc..."
                                        ) {
                                            chatInputText = "Tóm tắt nội dung chính và các ý chính của trang sách này giúp tôi."
                                            sendChat()
                                        }
                                        
                                        SuggestedPromptRow(
                                            icon: "🔍",
                                            title: "Giải thích thuật ngữ",
                                            prompt: "Tìm và giải thích các từ khó, khái niệm..."
                                        ) {
                                            chatInputText = "Hãy tìm các thuật ngữ phức tạp, khái niệm quan trọng hoặc từ khó trong trang này và giải thích ngắn gọn."
                                            sendChat()
                                        }
                                        
                                        SuggestedPromptRow(
                                            icon: "💡",
                                            title: "Ý chính bài học",
                                            prompt: "Rút ra thông điệp chính cốt lõi..."
                                        ) {
                                            chatInputText = "Bài học hoặc thông điệp cốt lõi nhất mà tác giả muốn truyền đạt ở trang này là gì?"
                                            sendChat()
                                        }
                                        
                                        SuggestedPromptRow(
                                            icon: "🌐",
                                            title: "Dịch & Phân tích",
                                            prompt: "Dịch các câu phức tạp trong trang..."
                                        ) {
                                            chatInputText = "Dịch các câu học thuật hoặc câu khó trong trang này sang tiếng Việt và giải nghĩa chi tiết cấu trúc."
                                            sendChat()
                                        }
                                    }
                                }
                                .padding(.bottom, 20)
                            } else {
                                ForEach(chatMessages, id: \.id) { msg in
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
                                                Text(renderMarkdown(msg.content))
                                                    .font(.system(size: 14))
                                                    .lineSpacing(3)
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
                                
                                if isChatPending {
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
                                        Spacer()
                                    }
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
        }
    }
    
    @ViewBuilder
    private func aiSettingsForm() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("CẤU HÌNH AI AGENT")
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
                            }
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
                            }
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
                            }
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
                    saveAISettings()
                    withAnimation(.spring()) {
                        isAISettingsOpen = false
                    }
                }) {
                    Text("Lưu cấu hình")
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
    
    private func renderMarkdown(_ text: String) -> AttributedString {
        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            return try AttributedString(markdown: text, options: options)
        } catch {
            return AttributedString(text)
        }
    }
    
    private func askAIShortcut(text: String) {
        clearSelectionState()
        withAnimation {
            isChatOpen = true
        }
        chatInputText = "Giải thích chi tiết đoạn văn bản này bằng Tiếng Việt: \"\(text)\""
        sendChat()
    }
    
    private func sendChat() {
        let textToSend = chatInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if textToSend.isEmpty || isChatPending { return }
        
        if aiApiKey.isEmpty {
            chatMessages.append(ChatMessage(role: "assistant", content: "Vui lòng vào Settings (nút răng cưa góc trên phải) cấu hình API Key của bạn để sử dụng Trợ lý AI!"))
            chatInputText = ""
            return
        }
        
        let userMsg = ChatMessage(role: "user", content: textToSend)
        chatMessages.append(userMsg)
        chatInputText = ""
        isChatPending = true
        saveChatHistory()
        
        // Build prompt with page context
        let systemPrompt = """
        You are a helpful, expert AI Book Assistant. You are guiding the user who is reading the book "\(book.title)" by \(book.author ?? "Unknown").
        The user is currently reading page \(page).
        
        Please answer the user's questions accurately in Vietnamese. Keep code blocks in their original language.
        """
        
        // Convert histories
        var apiMessages = [
            ["role": "system", "content": systemPrompt]
        ]
        for msg in chatMessages.suffix(10) { // send last 10 messages for context
            apiMessages.append(["role": msg.role, "content": msg.content])
        }
        
        Task {
            do {
                let responseText = try await api.sendChat(
                    baseURL: aiBaseURL,
                    apiKey: aiApiKey,
                    model: aiModel,
                    messages: apiMessages
                )
                await MainActor.run {
                    self.chatMessages.append(ChatMessage(role: "assistant", content: responseText))
                    self.isChatPending = false
                    self.saveChatHistory()
                }
            } catch {
                await MainActor.run {
                    self.chatMessages.append(ChatMessage(role: "assistant", content: "Lỗi kết nối AI: \(error.localizedDescription). Hãy kiểm tra lại Base URL và API Key trong cài đặt."))
                    self.isChatPending = false
                    self.saveChatHistory()
                }
            }
        }
    }
    
    // --- Persistence helper logic ---
    private func saveProgress() {
        let now = Int64(Date().timeIntervalSince1970)
        let localProgress = ReadingProgress(page: page, viewMode: viewMode, lastRead: now)
        
        // Guard to avoid redundant network saves when values didn't change
        if let data = UserDefaults.standard.data(forKey: "progress_\(book.slug)"),
           let cached = try? JSONDecoder().decode(ReadingProgress.self, from: data) {
            if cached.page == page && cached.viewMode == viewMode {
                return
            }
        }
        
        if let data = try? JSONEncoder().encode(localProgress) {
            UserDefaults.standard.set(data, forKey: "progress_\(book.slug)")
        }
        
        Task {
            await api.saveProgress(slug: book.slug, page: page, viewMode: viewMode)
        }
    }
    
    private func loadProgress() {
        Task {
            do {
                let progress = try await api.fetchProgress(slug: book.slug)
                await MainActor.run {
                    var shouldUpdate = true
                    if let data = UserDefaults.standard.data(forKey: "progress_\(book.slug)"),
                       let localProgress = try? JSONDecoder().decode(ReadingProgress.self, from: data) {
                        let localTime = localProgress.lastRead ?? 0
                        let serverTime = progress.lastRead ?? 0
                        if serverTime < localTime {
                            shouldUpdate = false
                        }
                    }
                    
                    if shouldUpdate {
                        self.page = progress.page
                        self.viewMode = progress.viewMode
                        
                        let now = Int64(Date().timeIntervalSince1970)
                        let progressToSave = ReadingProgress(page: progress.page, viewMode: progress.viewMode, lastRead: progress.lastRead ?? now)
                        if let data = try? JSONEncoder().encode(progressToSave) {
                            UserDefaults.standard.set(data, forKey: "progress_\(book.slug)")
                        }
                    }
                    self.isLoading = false
                }
            } catch {
                print("Failed to fetch progress from server: \(error)")
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }
    
    private func loadAISettings() {
        self.aiProvider = UserDefaults.standard.string(forKey: "aiProvider") ?? "openai"
        self.aiBaseURL = UserDefaults.standard.string(forKey: "aiBaseURL") ?? "https://api.openai.com/v1"
        self.aiApiKey = UserDefaults.standard.string(forKey: "aiApiKey") ?? ""
        self.aiModel = UserDefaults.standard.string(forKey: "aiModel") ?? "gpt-4o-mini"
        self.bilingualLayoutMode = UserDefaults.standard.string(forKey: "bilingualLayoutMode") ?? "en-vi"
        
        if let data = UserDefaults.standard.data(forKey: "chatHistory_\(book.slug)"),
           let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            self.chatMessages = decoded
        }
    }
    
    private func saveAISettings() {
        UserDefaults.standard.set(aiProvider, forKey: "aiProvider")
        UserDefaults.standard.set(aiBaseURL, forKey: "aiBaseURL")
        UserDefaults.standard.set(aiApiKey, forKey: "aiApiKey")
        UserDefaults.standard.set(aiModel, forKey: "aiModel")
        UserDefaults.standard.set(bilingualLayoutMode, forKey: "bilingualLayoutMode")
    }
    
    private func saveChatHistory() {
        if let data = try? JSONEncoder().encode(chatMessages) {
            UserDefaults.standard.set(data, forKey: "chatHistory_\(book.slug)")
        }
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

