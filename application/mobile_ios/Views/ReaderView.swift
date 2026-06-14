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
    
    @State private var page: Int = 1
    @State private var viewMode: String = "split" // "en" | "vi" | "split"
    @State private var isLoading = false
    
    // Highlights States
    @State private var activeSelection: SelectionInfo? = nil
    @State private var activeSelectionLang: String = ""
    @State private var selectedHighlightId: String? = nil
    @State private var activeRect: CGRect? = nil
    @State private var showNoteInput: Bool = false
    @State private var highlightNote: String = ""
    @State private var selectedColor: String = "#fde68a" // yellow default
    @State private var activeSentenceId: String? = nil
    
    // AI Chat States
    @State private var isChatOpen = false
    @State private var isAISettingsOpen = false
    @State private var aiProvider: String = "openai"
    @State private var aiBaseURL: String = "https://api.openai.com/v1"
    @State private var aiApiKey: String = ""
    @State private var aiModel: String = "gpt-4o-mini"
    @State private var chatMessages: [ChatMessage] = []
    @State private var chatInputText: String = ""
    @State private var isChatPending = false
    
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
                                TabView(selection: Binding(
                                    get: { self.page },
                                    set: { newPage in
                                        if newPage != self.page {
                                            self.page = newPage
                                            self.saveProgress()
                                        }
                                    }
                                )) {
                                    ForEach(1...max(1, book.pageCount), id: \.self) { p in
                                        let layout = (viewMode == "split" && !isLargeScreen) ? AnyLayout(VStackLayout(spacing: 16)) : AnyLayout(HStackLayout(spacing: 16))
                                        
                                        layout {
                                            let padPage = String(format: "%04d", p)
                                            
                                            // English WebView
                                            if viewMode == "en" || viewMode == "split" {
                                                let enUrlString = "\(api.serverUrl)/books/\(book.slug)/output/en/page_\(padPage).html?token=\(api.token)"
                                                BilingualWebView(
                                                    urlString: enUrlString,
                                                    lang: "en",
                                                    page: p,
                                                    activeSentenceId: activeSentenceId,
                                                    onScroll: { scrollTop in
                                                        NotificationCenter.default.post(
                                                            name: NSNotification.Name("ScrollTo_vi"),
                                                            object: nil,
                                                            userInfo: ["scrollTop": scrollTop]
                                                        )
                                                    },
                                                    onHighlightMessage: { msg in
                                                        handleHighlightMessage(msg, lang: "en")
                                                    },
                                                    onSentenceClicked: { sentenceId in
                                                        self.activeSentenceId = sentenceId
                                                    }
                                                )
                                                .modifier(PaperSheetModifier(isLargeScreen: isLargeScreen, viewMode: viewMode))
                                                .overlay(
                                                    Group {
                                                        if activeSelectionLang == "en" && (activeSelection != nil || selectedHighlightId != nil) {
                                                            if let rect = activeRect {
                                                                highlightPopupMenu()
                                                                    .position(x: rect.midX, y: max(30, rect.minY - 30))
                                                            }
                                                        }
                                                    }
                                                )
                                            }
                                            
                                            // Vietnamese WebView
                                            if viewMode == "vi" || viewMode == "split" {
                                                let viUrlString = "\(api.serverUrl)/books/\(book.slug)/output/vi/page_\(padPage).html?token=\(api.token)"
                                                BilingualWebView(
                                                    urlString: viUrlString,
                                                    lang: "vi",
                                                    page: p,
                                                    activeSentenceId: activeSentenceId,
                                                    onScroll: { scrollTop in
                                                        NotificationCenter.default.post(
                                                            name: NSNotification.Name("ScrollTo_en"),
                                                            object: nil,
                                                            userInfo: ["scrollTop": scrollTop]
                                                        )
                                                    },
                                                    onHighlightMessage: { msg in
                                                        handleHighlightMessage(msg, lang: "vi")
                                                    },
                                                    onSentenceClicked: { sentenceId in
                                                        self.activeSentenceId = sentenceId
                                                    }
                                                )
                                                .modifier(PaperSheetModifier(isLargeScreen: isLargeScreen, viewMode: viewMode))
                                                .overlay(
                                                    Group {
                                                        if activeSelectionLang == "vi" && (activeSelection != nil || selectedHighlightId != nil) {
                                                            if let rect = activeRect {
                                                                highlightPopupMenu()
                                                                    .position(x: rect.midX, y: max(30, rect.minY - 30))
                                                            }
                                                        }
                                                    }
                                                )
                                            }
                                        }
                                        .padding(16)
                                        .tag(p)
                                    }
                                }
                                .tabViewStyle(.page(indexDisplayMode: .never))
                            }
                        }
                        
                        // Bottom Navigation Bar
                        HStack(alignment: .center) {
                            Button(action: {
                                withAnimation(.easeInOut) {
                                    if page > 1 { page -= 1 }
                                }
                            }) {
                                Text("◀ Trang trước")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(page <= 1 ? .gray : .white)
                            }
                            .disabled(page <= 1)
                            
                            Spacer()
                            
                            Text("Trang \(page) / \(book.pageCount)")
                                .foregroundColor(.gray)
                                .font(.system(size: 13))
                            
                            Spacer()
                            
                            Button(action: {
                                withAnimation(.easeInOut) {
                                    if page < book.pageCount { page += 1 }
                                }
                            }) {
                                Text("Trang tiếp ▶")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(page >= book.pageCount ? .gray : .white)
                            }
                            .disabled(page >= book.pageCount)
                        }
                        .frame(height: 44)
                        .padding(.horizontal, 16)
                        .background(Color(hex: "0f172a"))
                    }
                    .frame(maxWidth: .infinity)
                    
                    // Slide-in AI Assistant Sidebar (For large screens)
                    if isChatOpen && isLargeScreen {
                        Divider().background(Color.white.opacity(0.1))
                        aiAssistantPanel()
                            .frame(width: 320)
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
    }
    
    // --- Highlights UI / logic ---
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
                        TextField("Nhập ghi chú...", text: $highlightNote)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .foregroundColor(.black)
                            .frame(width: 200)
                        HStack {
                            Spacer()
                            Button("Lưu") { saveHighlight() }
                                .font(.system(size: 13, weight: .bold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color(hex: "6366f1"))
                                .foregroundColor(.white)
                                .cornerRadius(6)
                        }
                    }
                    .padding(10)
                    .background(Color(hex: "1e293b"))
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
                    .offset(y: 60)
                }
            }
        )
    }
    
    private func handleHighlightMessage(_ msg: HighlightMessage, lang: String) {
        switch msg {
        case .textSelected(let selectionInfo):
            self.activeSelection = selectionInfo
            self.activeSelectionLang = lang
            self.selectedHighlightId = nil
            self.highlightNote = ""
            self.selectedColor = "#fde68a"
            self.activeRect = selectionInfo.rect
            self.showNoteInput = false
        case .highlightClicked(let id, let rect):
            self.selectedHighlightId = id
            self.activeSelection = nil
            self.activeRect = rect
            self.showNoteInput = false
            if let existing = api.highlights.first(where: { $0.id == id }) {
                self.selectedColor = existing.color
                self.highlightNote = existing.note ?? ""
            }
        case .clearSelection:
            clearSelectionState()
        }
    }
    
    private func clearSelectionState() {
        self.activeSelection = nil
        self.selectedHighlightId = nil
        self.highlightNote = ""
        self.activeSentenceId = nil
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
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundColor(.purple)
                    Text("Trợ lý AI")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                
                Spacer()
                
                // Settings Toggle
                Button(action: {
                    isAISettingsOpen.toggle()
                }) {
                    Image(systemName: "gearshape")
                        .foregroundColor(.gray)
                }
                
                // Clear History Button
                Button(action: {
                    chatMessages = []
                    saveChatHistory()
                }) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .padding(.horizontal, 8)
            }
            .padding()
            .background(Color(hex: "111827"))
            
            if isAISettingsOpen {
                aiSettingsForm()
                    .transition(.slide)
            } else {
                // Messages List
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if chatMessages.isEmpty {
                                Text("Hãy hỏi AI bất cứ điều gì liên quan đến cuốn sách này. Bạn có thể bôi đen văn bản trong trang sách và nhấn 'Hỏi AI' để phân tích nhanh!")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .padding(.top, 40)
                                    .multilineTextAlignment(.center)
                            } else {
                                ForEach(chatMessages, id: \.id) { msg in
                                    HStack {
                                        if msg.role == "user" { Spacer() }
                                        
                                        Text(msg.content)
                                            .font(.subheadline)
                                            .padding(10)
                                            .background(msg.role == "user" ? Color(hex: "4f46e5") : Color(hex: "1f2937"))
                                            .foregroundColor(.white)
                                            .cornerRadius(12)
                                        
                                        if msg.role == "assistant" { Spacer() }
                                    }
                                    .id(msg.id)
                                }
                                
                                if isChatPending {
                                    HStack {
                                        ProgressView().tint(.white)
                                        Text("AI đang suy nghĩ...")
                                            .font(.caption)
                                            .foregroundColor(.gray)
                                        Spacer()
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                    .onChange(of: chatMessages.count) { _ in
                        if let last = chatMessages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .background(Color(hex: "0b0f19"))
                
                // Input panel
                HStack(spacing: 8) {
                    TextField("Hỏi trợ lý...", text: $chatInputText)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .foregroundColor(.black)
                        .frame(height: 36)
                    
                    Button(action: {
                        sendChat()
                    }) {
                        Image(systemName: "paperplane.fill")
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color(hex: "6366f1"))
                            .cornerRadius(8)
                    }
                    .disabled(chatInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isChatPending)
                }
                .padding()
                .background(Color(hex: "111827"))
            }
        }
    }
    
    @ViewBuilder
    private func aiSettingsForm() -> some View {
        Form {
            Section(header: Text("AI MODEL CONFIG").foregroundColor(.white)) {
                Picker("Provider", selection: $aiProvider) {
                    Text("OpenAI").tag("openai")
                    Text("Gemini").tag("gemini")
                    Text("Custom").tag("custom")
                }
                .onChange(of: aiProvider) { val in
                    if val == "openai" {
                        aiBaseURL = "https://api.openai.com/v1"
                        aiModel = "gpt-4o-mini"
                    } else if val == "gemini" {
                        aiBaseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
                        aiModel = "gemini-1.5-flash"
                    }
                }
                
                TextField("Base URL", text: $aiBaseURL)
                TextField("API Key", text: $aiApiKey)
                TextField("Model Name", text: $aiModel)
            }
            .listRowBackground(Color(hex: "1f2937"))
            
            Button("Lưu cấu hình") {
                saveAISettings()
                withAnimation {
                    isAISettingsOpen = false
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .listRowBackground(Color.purple)
            .foregroundColor(.white)
            .fontWeight(.bold)
        }
        .background(Color(hex: "0b0f19"))
        .onAppear {
            UITableView.appearance().backgroundColor = .clear
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
        Task {
            await api.saveProgress(slug: book.slug, page: page, viewMode: viewMode)
        }
    }
    
    private func loadProgress() {
        isLoading = true
        Task {
            do {
                let progress = try await api.fetchProgress(slug: book.slug)
                await MainActor.run {
                    self.page = progress.page
                    self.viewMode = progress.viewMode
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
    }
    
    private func saveChatHistory() {
        if let data = try? JSONEncoder().encode(chatMessages) {
            UserDefaults.standard.set(data, forKey: "chatHistory_\(book.slug)")
        }
    }
}

struct PaperSheetModifier: ViewModifier {
    var isLargeScreen: Bool
    var viewMode: String
    
    func body(content: Content) -> some View {
        if isLargeScreen && viewMode != "split" {
            content
                .background(Color(hex: "F9F7F1"))
                .cornerRadius(4)
                .shadow(color: .black.opacity(0.15), radius: 5, x: 0, y: 3)
                .aspectRatio(1 / 1.414, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(hex: "0f172a"))
        } else {
            content
                .background(Color(hex: "F9F7F1"))
                .cornerRadius(4)
                .shadow(color: .black.opacity(0.15), radius: 5, x: 0, y: 3)
        }
    }
}
