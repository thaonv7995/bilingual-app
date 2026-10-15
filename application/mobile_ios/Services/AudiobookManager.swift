import Foundation
import WebKit
import SwiftUI

struct AudioSentenceItem: Identifiable, Equatable {
    var id: String
    var text: String
    var lang: String // "en" or "vi"
}

enum AudiobookLanguageMode: String, CaseIterable {
    case en = "en"
    case vi = "vi"

    var title: String {
        switch self {
        case .en: return "EN"
        case .vi: return "VI"
        }
    }
}

@MainActor
final class AudiobookManager: ObservableObject {
    static let shared = AudiobookManager()

    @Published var isPlaying: Bool = false
    @Published var currentSentenceIndex: Int = 0
    @Published var sentences: [AudioSentenceItem] = []
    @Published var mode: AudiobookLanguageMode = .en
    @Published var speed: String = "1.0"
    @Published var autoPageTurn: Bool = true
    @Published var errorMessage: String? = nil
    @Published var isBarVisible: Bool = false

    @Published var provider: String = "device"
    @Published var voice: String = ""
    @Published var voiceEn: String = ""
    @Published var voiceVi: String = ""
    @Published var currentViewMode: String = "split"
    @Published var bookSlug: String = ""
    @Published var currentPage: Int = 1
    @Published var totalPage: Int = 1
    var shouldContinuePlayingOnPageLoad: Bool = false

    private var playbackTask: Task<Void, Never>?
    private var timeTrackingTask: Task<Void, Never>?
    private weak var enWebView: WKWebView?
    private weak var viWebView: WKWebView?
    var onPageTurnNeeded: (() -> Void)?

    private var cumulativeOffsets: [Int] = []
    private var totalChars: Int = 0

    private init() {}

    func configure(provider: String, voice: String, speed: String, voiceEn: String = "", voiceVi: String = "") {
        self.provider = provider
        self.voice = voice
        self.voiceEn = voiceEn
        self.voiceVi = voiceVi
        self.speed = speed
    }

    func updateContext(bookSlug: String, currentPage: Int, totalPage: Int) {
        self.bookSlug = bookSlug
        self.currentPage = currentPage
        self.totalPage = totalPage
    }

    func voiceFor(lang: String) -> String {
        let isVi = lang.hasPrefix("vi")
        if isVi {
            if !voiceVi.isEmpty { return voiceVi }
            if provider == "azure" { return "vi-VN-HoaiMyNeural" }
            if provider == "openai" { return "alloy" }
            if provider == "elevenlabs" {
                if !voice.isEmpty && voice != "21m00Tcm4TlvDq8ikWAM" && !voice.hasPrefix("en-") {
                    return voice
                }
                return ""
            }
            return voice
        } else {
            if !voiceEn.isEmpty { return voiceEn }
            if !voice.isEmpty { return voice }
            if provider == "azure" { return "en-US-JennyNeural" }
            if provider == "elevenlabs" { return "21m00Tcm4TlvDq8ikWAM" }
            if provider == "openai" { return "alloy" }
            return ""
        }
    }

    func updateWebViews(en: WKWebView?, vi: WKWebView?, viewMode: String) {
        self.enWebView = en
        self.viWebView = vi
        self.currentViewMode = viewMode
        Task {
            // Wait briefly for DOM rendering/script execution if page just flipped
            try? await Task.sleep(nanoseconds: 180_000_000)
            await extractSentences(viewMode: viewMode)

            if self.shouldContinuePlayingOnPageLoad {
                if !self.sentences.isEmpty {
                    self.shouldContinuePlayingOnPageLoad = false
                    self.currentSentenceIndex = 0
                    self.play()
                } else {
                    // Retry once after additional 350ms in case WebView was still loading HTML
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if self.shouldContinuePlayingOnPageLoad {
                        await extractSentences(viewMode: viewMode)
                        if !self.sentences.isEmpty && self.shouldContinuePlayingOnPageLoad {
                            self.shouldContinuePlayingOnPageLoad = false
                            self.currentSentenceIndex = 0
                            self.play()
                        }
                    }
                }
            }
        }
    }

    func changeMode(_ newMode: AudiobookLanguageMode) {
        let wasPlaying = isPlaying
        shouldContinuePlayingOnPageLoad = false
        pause()
        AudioProviderFactory.shared.stop()
        highlightSentence(id: nil)
        self.mode = newMode
        self.currentSentenceIndex = 0
        Task {
            await extractSentences(viewMode: currentViewMode)
            if let first = sentences.first {
                highlightSentence(id: first.id, lang: first.lang)
            }
            if wasPlaying && !sentences.isEmpty {
                self.play()
            }
        }
    }

    /// Extracts segmented sentences from active WKWebView DOM instances with robust fallbacks
    func extractSentences(viewMode: String) async {
        let jsExtract = """
        (function() {
            let nodes = Array.from(document.querySelectorAll('.sentence-node'));
            if (nodes.length === 0 && typeof segmentDocSentences === 'function') {
                try {
                    segmentDocSentences(document);
                    nodes = Array.from(document.querySelectorAll('.sentence-node'));
                } catch(e) {}
            }
            if (nodes.length === 0) {
                const pars = Array.from(document.querySelectorAll('p, h1, h2, h3, h4, h5, h6, li, blockquote, .chapter-start, .section-title, .action-header, .action-title'));
                return pars.map((p, idx) => {
                    if (!p.dataset.sentenceId) {
                        p.dataset.sentenceId = 'fallback-s-' + idx;
                        p.classList.add('sentence-node');
                    }
                    return {
                        id: p.dataset.sentenceId,
                        text: (p.textContent || '').trim()
                    };
                }).filter(x => x.text.length > 0);
            }
            return nodes.map(n => ({
                id: n.dataset.sentenceId || '',
                text: (n.textContent || '').trim()
            })).filter(x => x.text.length > 0);
        })();
        """

        var enItems: [AudioSentenceItem] = []
        var viItems: [AudioSentenceItem] = []

        if let en = enWebView {
            if let res = try? await en.evaluateJavaScript(jsExtract) as? [[String: Any]] {
                enItems = res.compactMap { dict in
                    guard let id = dict["id"] as? String, let text = dict["text"] as? String else { return nil }
                    return AudioSentenceItem(id: id, text: text, lang: "en")
                }
            }
        }

        if let vi = viWebView {
            if let res = try? await vi.evaluateJavaScript(jsExtract) as? [[String: Any]] {
                viItems = res.compactMap { dict in
                    guard let id = dict["id"] as? String, let text = dict["text"] as? String else { return nil }
                    return AudioSentenceItem(id: id, text: text, lang: "vi")
                }
            }
        }

        var combined: [AudioSentenceItem] = []
        if mode == .en {
            combined = !enItems.isEmpty ? enItems : viItems.map { AudioSentenceItem(id: $0.id, text: $0.text, lang: "en") }
        } else {
            combined = !viItems.isEmpty ? viItems : enItems.map { AudioSentenceItem(id: $0.id, text: $0.text, lang: "vi") }
        }

        self.sentences = combined
        updateSentenceOffsets(combined)
        if currentSentenceIndex >= combined.count {
            currentSentenceIndex = 0
        }
    }

    private func updateSentenceOffsets(_ items: [AudioSentenceItem]) {
        let charLengths = items.map { max(1, $0.text.count) }
        let total = charLengths.reduce(0, +)
        var offsets: [Int] = []
        var running = 0
        for len in charLengths {
            offsets.append(running)
            running += len
        }
        self.cumulativeOffsets = offsets
        self.totalChars = total
    }

    func play() {
        if sentences.isEmpty {
            Task {
                await extractSentences(viewMode: currentViewMode)
                if self.sentences.isEmpty {
                    self.errorMessage = "Không tìm thấy văn bản trên trang."
                } else {
                    self.play()
                }
            }
            return
        }

        // Resume existing audio if paused
        if AudioProviderFactory.shared.duration > 0 && !AudioProviderFactory.shared.isAudioPlaying {
            if AudioProviderFactory.shared.resume() {
                isPlaying = true
                startTimeTracking()
                return
            }
        }

        isPlaying = true
        errorMessage = nil
        playbackTask?.cancel()
        timeTrackingTask?.cancel()

        // Prefetch NEXT page audio in the background
        Task.detached(priority: .background) { [weak self] in
            guard let self = self else { return }
            let nextPage = await self.currentPage + 1
            let curMode = await self.mode
            await self.prefetchNextPageAudio(page: nextPage, targetMode: curMode)
        }

        playbackTask = Task {
            await startFullPagePlayback(from: currentSentenceIndex)
        }
    }

    private func startFullPagePlayback(from startIndex: Int) async {
        guard !sentences.isEmpty else { return }

        let fullPageText = sentences.map { $0.text }.joined(separator: " ")
        let isVi = mode == .vi
        let langTag = isVi ? "vi-VN" : "en-US"
        let selectedVoice = voiceFor(lang: langTag)

        startTimeTracking()

        do {
            try await AudioProviderFactory.shared.speak(
                text: fullPageText,
                provider: provider,
                voice: selectedVoice,
                speed: speed,
                lang: langTag
            )

            // Audio finished playing
            stopTimeTracking()
            if isPlaying {
                if autoPageTurn && currentPage < totalPage {
                    shouldContinuePlayingOnPageLoad = true
                    onPageTurnNeeded?()
                } else {
                    isPlaying = false
                    highlightSentence(id: nil)
                }
            }
        } catch is CancellationError {
            stopTimeTracking()
        } catch {
            stopTimeTracking()
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
                isPlaying = false
            }
        }
    }

    private func startTimeTracking() {
        timeTrackingTask?.cancel()
        timeTrackingTask = Task { [weak self] in
            var hasInitialSeek = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                guard let self = self, self.isPlaying else { break }

                let duration = AudioProviderFactory.shared.duration
                let currentTime = AudioProviderFactory.shared.currentTime
                let total = self.totalChars
                let offsets = self.cumulativeOffsets

                if duration > 0 && total > 0 && !offsets.isEmpty {
                    if !hasInitialSeek && self.currentSentenceIndex > 0 && offsets.count > self.currentSentenceIndex {
                        hasInitialSeek = true
                        let targetOffset = offsets[self.currentSentenceIndex]
                        let targetTime = (Double(targetOffset) / Double(total)) * duration
                        AudioProviderFactory.shared.seek(to: targetTime)
                        continue
                    }

                    let fraction = min(1.0, max(0.0, currentTime / duration))
                    let currentChar = Int(fraction * Double(total))

                    var activeIdx = 0
                    for i in 0..<offsets.count {
                        if currentChar >= offsets[i] {
                            activeIdx = i
                        } else {
                            break
                        }
                    }

                    if activeIdx != self.currentSentenceIndex && activeIdx < self.sentences.count {
                        self.currentSentenceIndex = activeIdx
                        let item = self.sentences[activeIdx]
                        self.highlightSentence(id: item.id, lang: item.lang)
                    }
                }
            }
        }
    }

    private func stopTimeTracking() {
        timeTrackingTask?.cancel()
        timeTrackingTask = nil
    }

    private func prefetchNextPageAudio(page: Int, targetMode: AudiobookLanguageMode) async {
        guard page <= totalPage, !bookSlug.isEmpty, provider != "device" else { return }

        var htmlString: String = ""
        if let localUrl = BookCacheManager.shared.localPageURL(slug: bookSlug, lang: targetMode.rawValue, page: page),
           let localData = try? Data(contentsOf: localUrl),
           let localHtml = String(data: localData, encoding: .utf8) {
            htmlString = localHtml
        } else if let remoteUrl = URL(string: "\(APIService.shared.serverUrl)/books/\(bookSlug)/output/\(targetMode.rawValue)/page_\(String(format: "%04d", page)).html?token=\(APIService.shared.token)") {
            if let (data, _) = try? await URLSession.shared.data(from: remoteUrl),
               let remoteHtml = String(data: data, encoding: .utf8) {
                htmlString = remoteHtml
            }
        }

        guard !htmlString.isEmpty else { return }
        let plainText = stripHtmlToText(htmlString)
        guard !plainText.isEmpty else { return }

        let langTag = targetMode == .vi ? "vi-VN" : "en-US"
        let nextVoice = voiceFor(lang: langTag)
        AudioProviderFactory.shared.prefetch(
            text: plainText,
            provider: provider,
            voice: nextVoice,
            speed: speed,
            lang: langTag
        )
    }

    private func stripHtmlToText(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let cleaned = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return cleaned
    }

    func pause() {
        shouldContinuePlayingOnPageLoad = false
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
        stopTimeTracking()
        AudioProviderFactory.shared.pause()
    }

    func seekToSentence(_ index: Int) {
        guard !sentences.isEmpty else { return }
        let clamped = max(0, min(sentences.count - 1, index))
        currentSentenceIndex = clamped
        let item = sentences[clamped]
        highlightSentence(id: item.id, lang: item.lang)

        let duration = AudioProviderFactory.shared.duration
        if duration > 0 && totalChars > 0 && clamped < cumulativeOffsets.count {
            let targetOffset = cumulativeOffsets[clamped]
            let targetTime = (Double(targetOffset) / Double(totalChars)) * duration
            AudioProviderFactory.shared.seek(to: targetTime)
        } else if isPlaying {
            AudioProviderFactory.shared.stop()
            play()
        }
    }

    func nextSentence() {
        seekToSentence(currentSentenceIndex + 1)
    }

    func prevSentence() {
        seekToSentence(currentSentenceIndex - 1)
    }

    func highlightSentence(id: String?, lang: String? = nil) {
        let jsHighlight: String
        if let id = id {
            jsHighlight = """
            (function() {
                window.highlightSentence && window.highlightSentence('\(id)');
                const el = document.querySelector('.sentence-node[data-sentence-id="\(id)"]');
                if (el) {
                    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                }
            })();
            """
        } else {
            jsHighlight = "window.highlightSentence && window.highlightSentence(null);"
        }

        if lang == "en" || lang == nil {
            enWebView?.evaluateJavaScript(jsHighlight, completionHandler: nil)
        }
        if lang == "vi" || lang == nil {
            viWebView?.evaluateJavaScript(jsHighlight, completionHandler: nil)
        }
    }

    func close() {
        shouldContinuePlayingOnPageLoad = false
        pause()
        AudioProviderFactory.shared.stop()
        highlightSentence(id: nil)
        isBarVisible = false
    }
}
