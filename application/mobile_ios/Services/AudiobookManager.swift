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
    case bilingual = "bilingual"

    var title: String {
        switch self {
        case .en: return "Chỉ EN"
        case .vi: return "Chỉ VI"
        case .bilingual: return "Lặp Song Ngữ"
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
    @Published var currentViewMode: String = "split"

    private var playbackTask: Task<Void, Never>?
    private weak var enWebView: WKWebView?
    private weak var viWebView: WKWebView?
    var onPageTurnNeeded: (() -> Void)?

    private init() {}

    func configure(provider: String, voice: String, speed: String) {
        self.provider = provider
        self.voice = voice
        self.speed = speed
    }

    func updateWebViews(en: WKWebView?, vi: WKWebView?, viewMode: String) {
        self.enWebView = en
        self.viWebView = vi
        self.currentViewMode = viewMode
        Task {
            await extractSentences(viewMode: viewMode)
        }
    }

    func changeMode(_ newMode: AudiobookLanguageMode) {
        pause()
        highlightSentence(id: nil)
        self.mode = newMode
        self.currentSentenceIndex = 0
        Task {
            await extractSentences(viewMode: currentViewMode)
            if let first = sentences.first {
                highlightSentence(id: first.id, lang: first.lang)
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
            combined = !enItems.isEmpty ? enItems : viItems
        } else if mode == .vi {
            combined = !viItems.isEmpty ? viItems : enItems
        } else if mode == .bilingual {
            if !enItems.isEmpty && !viItems.isEmpty {
                let maxCount = max(enItems.count, viItems.count)
                for i in 0..<maxCount {
                    if i < enItems.count { combined.append(enItems[i]) }
                    if i < viItems.count { combined.append(viItems[i]) }
                }
            } else if !enItems.isEmpty {
                combined = enItems
            } else {
                combined = viItems
            }
        }

        self.sentences = combined
        if currentSentenceIndex >= combined.count {
            currentSentenceIndex = 0
        }
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

        isPlaying = true
        errorMessage = nil
        playbackTask?.cancel()

        playbackTask = Task {
            await runPlaybackLoop(from: currentSentenceIndex)
        }
    }

    func pause() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
        AudioProviderFactory.shared.stop()
    }

    func nextSentence() {
        guard !sentences.isEmpty else { return }
        AudioProviderFactory.shared.stop()
        let nextIdx = min(sentences.count - 1, currentSentenceIndex + 1)
        currentSentenceIndex = nextIdx
        let item = sentences[nextIdx]
        highlightSentence(id: item.id, lang: item.lang)
        if isPlaying {
            play()
        }
    }

    func prevSentence() {
        guard !sentences.isEmpty else { return }
        AudioProviderFactory.shared.stop()
        let prevIdx = max(0, currentSentenceIndex - 1)
        currentSentenceIndex = prevIdx
        let item = sentences[prevIdx]
        highlightSentence(id: item.id, lang: item.lang)
        if isPlaying {
            play()
        }
    }

    private func runPlaybackLoop(from startIndex: Int) async {
        for idx in startIndex..<sentences.count {
            guard isPlaying, !Task.isCancelled else { break }

            currentSentenceIndex = idx
            let item = sentences[idx]
            highlightSentence(id: item.id, lang: item.lang)

            do {
                let langTag = item.lang == "vi" ? "vi-VN" : "en-US"
                try await AudioProviderFactory.shared.speak(
                    text: item.text,
                    provider: provider,
                    voice: voice,
                    speed: speed,
                    lang: langTag
                )

                // Brief natural pause (250ms)
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch is CancellationError {
                break
            } catch {
                if !Task.isCancelled {
                    errorMessage = error.localizedDescription
                    isPlaying = false
                }
                break
            }
        }

        // Reached end of sentences
        if isPlaying && currentSentenceIndex >= sentences.count - 1 {
            if autoPageTurn {
                onPageTurnNeeded?()
            } else {
                isPlaying = false
                highlightSentence(id: nil)
            }
        }
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
        pause()
        highlightSentence(id: nil)
        isBarVisible = false
    }
}
