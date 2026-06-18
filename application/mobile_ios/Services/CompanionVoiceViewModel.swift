import AVFoundation
import Foundation

/// ViewModel managing the AI Companion voice session lifecycle.
///
/// Orchestrates `RealtimeVoiceEngine` and `CompanionToolHandler` to provide
/// a voice conversation experience within the reader's chat panel.
@MainActor
final class CompanionVoiceViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case live
        case ended
    }

    enum MicState: Equatable {
        case muted
        case open
        case aiSpeaking
    }

    // MARK: Published State

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var micState: MicState = .muted
    @Published private(set) var aiCaption = ""
    @Published private(set) var userTranscript = ""
    @Published private(set) var userIsSpeaking = false
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var outputLevel: Float = 0
    @Published var errorMessage: String?

    /// Brief feedback messages from tool calls (auto-dismiss after 3s).
    @Published private(set) var toolFeedback: String?
    @Published private(set) var reconnecting = false

    let toolHandler = CompanionToolHandler()

    // MARK: Book Context (set by ReaderView)

    var bookTitle: String = ""
    var bookAuthor: String = ""
    var bookSlug: String = ""
    var currentPage: Int = 1
    var totalPages: Int = 1
    var currentViewMode: String = "split"

    /// Closure to fetch current page text content. Set by ReaderView.
    var pageContextProvider: ((Int, String) async -> String)?

    // MARK: Private

    private var engine: RealtimeVoiceEngine?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 3

    // MARK: - Session Lifecycle

    func start() async {
        guard phase == .idle || phase == .ended else { return }
        errorMessage = nil

        let apiKey = (UserDefaults.standard.string(forKey: "realtimeApiKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            errorMessage = "Vui lòng cấu hình Realtime API Key trong Settings."
            return
        }

        let granted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                continuation.resume(returning: allowed)
            }
        }
        guard granted else {
            errorMessage = "Cần quyền truy cập microphone để sử dụng voice mode."
            return
        }

        phase = .connecting
        reconnectAttempts = 0
        reconnecting = false
        openConnection(resume: false)
    }

    func end() {
        reconnectTask?.cancel()
        reconnecting = false
        engine?.stopPlayback()
        engine?.disconnect()
        engine = nil
        phase = .idle
        micState = .muted
        inputLevel = 0
        outputLevel = 0
        aiCaption = ""
        userTranscript = ""
        toolFeedback = nil
    }

    func toggleMic() {
        guard phase == .live, let engine else { return }
        switch micState {
        case .open:
            engine.isMuted = true
            micState = .muted
        case .muted:
            engine.isMuted = false
            micState = .open
        case .aiSpeaking:
            break
        }
    }

    /// Called when the user flips pages — inject updated context into the conversation.
    func updatePageContext(_ context: String, page: Int) {
        guard phase == .live else { return }
        currentPage = page
        engine?.injectConversationItem(text: """
        [PAGE UPDATE] User is now on page \(page) of \(totalPages).
        \(context)
        """)
    }

    // MARK: - Connection

    private func openConnection(resume: Bool) {
        let apiKey = (UserDefaults.standard.string(forKey: "realtimeApiKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = UserDefaults.standard.string(forKey: "realtimeModel")
            ?? "gpt-realtime-mini"
        let voice = UserDefaults.standard.string(forKey: "realtimeVoice") ?? "marin"

        let engine = RealtimeVoiceEngine()
        self.engine = engine
        wireEngineCallbacks(engine)

        let instructions = buildInstructions()
        var config = RealtimeVoiceEngine.sessionConfig(
            voice: voice,
            instructions: instructions,
            tools: CompanionToolHandler.toolDefinitions
        )

        if resume {
            // Append conversation summary so AI doesn't restart.
            if var instr = config["instructions"] as? String {
                instr += "\n\n[SESSION RESUMED after brief network drop. Continue naturally.]"
                config["instructions"] = instr
            }
        }

        engine.isMuted = true
        engine.connect(apiKey: apiKey, model: model, sessionConfig: config)
    }

    private func buildInstructions() -> String {
        let agentName = (UserDefaults.standard.string(forKey: "companionAgentName") ?? "Jarvis")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = agentName.isEmpty ? "Jarvis" : agentName
        let language = UserDefaults.standard.string(forKey: "companionLanguage") ?? "vi"

        let languageInstruction: String
        switch language {
        case "en":
            languageInstruction = "Always speak in English, regardless of what language the user speaks."
        case "bilingual":
            languageInstruction = "Speak in whatever language the user speaks. If the user speaks Vietnamese, reply in Vietnamese. If they speak English, reply in English."
        default: // "vi"
            languageInstruction = "Always speak in Vietnamese by default. Only switch to English if the user explicitly asks you to."
        }

        return """
        Your name is \(name). You are an AI reading companion for the bilingual book "\(bookTitle)" by \(bookAuthor.isEmpty ? "Unknown" : bookAuthor).
        The user is currently reading page \(currentPage) of \(totalPages).

        IDENTITY:
        - Your name is \(name). When the user calls "\(name)", they are talking to you. Respond naturally.
        - You are a knowledgeable, friendly reading partner — not a formal assistant.

        LANGUAGE:
        - \(languageInstruction)

        OPENING:
        - When the session starts, greet the user with a SHORT, warm greeting (1 sentence max).
        - Do NOT summarize, explain, or narrate the page content when starting.
        - Do NOT describe what is on the page unless the user explicitly asks.
        - The page context you receive is for YOUR reference only — use it when the user asks questions.

        BEHAVIOR:
        - Wait for the user to ask before discussing content. Do not volunteer explanations.
        - When the user asks about what they're reading, refer to the page context you have.
        - Keep responses concise and conversational — this is a voice chat, not a lecture.
        - Use the available tools when the user asks to highlight, look up words, or navigate pages.
        - You will receive page context updates when the user flips pages.

        TOOLS:
        - Color names for highlight_text: "yellow", "blue", "pink", "green"
        - Vietnamese color mapping: vàng=yellow, xanh/xanh dương=blue, hồng=pink, xanh lá=green
        - When user says "mark" or "đánh dấu" they mean highlight
        - switch_view_mode: "en" = English only, "vi" = Vietnamese only, "split" = bilingual/song ngữ
        - When user says "song ngữ", "bilingual", "cả hai" → use split
        - When user says "tiếng Anh thôi" → use en; "tiếng Việt thôi" → use vi
        - list_highlights: lists all highlights on the current page
        """
    }

    // MARK: - Engine Callbacks

    private func wireEngineCallbacks(_ engine: RealtimeVoiceEngine) {
        engine.onConnected = { [weak self] in
            guard let self else { return }
            self.phase = .live
            self.reconnecting = false
            self.reconnectAttempts = 0

            // Inject initial page context so AI knows what's on screen.
            Task { @MainActor [weak self] in
                guard let self, let provider = self.pageContextProvider else {
                    // No provider — just open mic and greet.
                    self?.engine?.isMuted = false
                    self?.micState = .open
                    self?.engine?.requestResponse()
                    self?.micState = .aiSpeaking
                    return
                }
                let context = await provider(self.currentPage, self.currentViewMode)
                if !context.isEmpty {
                    self.engine?.injectConversationItem(text: """
                    [REFERENCE ONLY — DO NOT READ ALOUD OR SUMMARIZE]
                    Page \(self.currentPage) of \(self.totalPages) content for your reference. Only discuss if the user asks:
                    \(context)
                    """)
                }
                // Open mic and request greeting after context is injected.
                self.engine?.isMuted = false
                self.micState = .open
                self.engine?.requestResponse()
                self.micState = .aiSpeaking
            }
        }

        engine.onAiResponseStarted = { [weak self] in
            guard let self else { return }
            self.engine?.isMuted = true
            self.micState = .aiSpeaking
            self.aiCaption = ""
        }

        engine.onAiTranscriptDelta = { [weak self] delta in
            self?.aiCaption += delta
        }

        engine.onAiTranscriptDone = { [weak self] transcript in
            self?.aiCaption = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        engine.onAiAudioFinished = { [weak self] in
            guard let self, self.phase == .live else { return }
            // AI finished speaking — open mic for user.
            self.engine?.isMuted = false
            self.micState = .open
        }

        engine.onUserTranscript = { [weak self] transcript in
            self?.userTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        engine.onUserSpeakingChanged = { [weak self] speaking in
            self?.userIsSpeaking = speaking
        }

        engine.onLevels = { [weak self] input, output in
            self?.inputLevel = input
            self?.outputLevel = output
        }

        engine.onToolCall = { [weak self] callId, name, argsJSON in
            guard let self else { return }
            Task { @MainActor in
                let result = await self.toolHandler.handleToolCall(name: name, argumentsJSON: argsJSON)
                self.engine?.sendToolResult(callId: callId, output: result)
            }
        }

        // Wire tool feedback to show toasts in the UI.
        toolHandler.onToolFeedback = { [weak self] message in
            guard let self else { return }
            self.toolFeedback = message
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if self?.toolFeedback == message {
                    self?.toolFeedback = nil
                }
            }
        }

        engine.onError = { [weak self] message in
            guard let self else { return }
            if self.phase == .live, message.hasPrefix("Connection lost") { return }
            self.errorMessage = message
        }

        engine.onDisconnected = { [weak self] in
            guard let self, self.phase == .live || self.phase == .connecting else { return }
            self.handleDisconnect()
        }
    }

    // MARK: - Reconnect

    private func handleDisconnect() {
        guard phase == .live, reconnectAttempts < maxReconnectAttempts else {
            if reconnecting {
                errorMessage = "Mất kết nối. Vui lòng thử lại."
            }
            end()
            return
        }
        reconnectAttempts += 1
        reconnecting = true
        micState = .muted
        engine?.disconnect()
        engine = nil

        let attempt = reconnectAttempts
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(attempt)))
            guard let self, !Task.isCancelled, self.phase == .live, self.reconnecting else { return }
            self.openConnection(resume: true)
        }
    }
}
