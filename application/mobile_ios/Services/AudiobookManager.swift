import Foundation
import WebKit
import SwiftUI
import UIKit

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
    @Published var bookTitle: String = ""
    @Published var bookAuthor: String = ""
    @Published var currentPage: Int = 1
    @Published var totalPage: Int = 1
    var shouldContinuePlayingOnPageLoad: Bool = false
    private var isPausedOnCurrentPage: Bool = false

    private var playbackTask: Task<Void, Never>?
    private var timeTrackingTask: Task<Void, Never>?
    private weak var enWebView: WKWebView?
    private weak var viWebView: WKWebView?
    var onPageTurnNeeded: (() -> Void)?

    private var cumulativeOffsets: [Int] = []
    private var totalChars: Int = 0
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    private var hasSetupRemoteCommands: Bool = false

    // In-memory cache for parsed page sentences
    private var pageSentencesCache: [Int: [AudioSentenceItem]] = [:]

    private init() {}

    private func ensureRemoteCommandsConfigured() {
        guard !hasSetupRemoteCommands else { return }
        hasSetupRemoteCommands = true
        setupRemoteCommands()
    }

    private func setupRemoteCommands() {
        NowPlayingManager.shared.setupRemoteCommands(
            onPlay: { [weak self] in
                self?.play()
            },
            onPause: { [weak self] in
                self?.pause()
            },
            onToggle: { [weak self] in
                guard let self = self else { return }
                if self.isPlaying {
                    self.pause()
                } else {
                    self.play()
                }
            },
            onNextTrack: { [weak self] in
                self?.nextSentence()
            },
            onPrevTrack: { [weak self] in
                self?.prevSentence()
            },
            onSeek: { [weak self] time in
                AudioProviderFactory.shared.seek(to: time)
                self?.updateNowPlayingInfo()
            }
        )
    }

    private func beginBackgroundTransitionTask() {
        endBackgroundTransitionTask()
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "AudiobookPlaybackTransition") { [weak self] in
            self?.endBackgroundTransitionTask()
        }
    }

    private func endBackgroundTransitionTask() {
        if backgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
    }

    func updateNowPlayingInfo() {
        let currentItem = currentSentenceIndex < sentences.count ? sentences[currentSentenceIndex] : nil
        let sentenceText = currentItem?.text ?? ""
        let title = !sentenceText.isEmpty ? sentenceText : (!bookTitle.isEmpty ? "\(bookTitle) - Trang \(currentPage)" : "Trang \(currentPage)")
        let artist = !bookTitle.isEmpty ? "\(bookTitle) • \(mode.title) Mode" : "Bilingual Reader • \(mode.title)"
        let album = totalPage > 0 ? "Trang \(currentPage)/\(totalPage)" : "Trang \(currentPage)"

        let rate = isPlaying ? (Double(speed) ?? 1.0) : 0.0
        let curTime = AudioProviderFactory.shared.currentTime
        let duration = AudioProviderFactory.shared.duration

        NowPlayingManager.shared.updateNowPlaying(
            title: title,
            artist: artist,
            albumTitle: album,
            currentTime: curTime,
            duration: duration,
            playbackRate: rate
        )
    }

    func configure(provider: String, voice: String, speed: String, voiceEn: String = "", voiceVi: String = "") {
        self.provider = provider
        self.voice = voice
        self.voiceEn = voiceEn
        self.voiceVi = voiceVi
        self.speed = speed
    }

    func updateContext(bookSlug: String, currentPage: Int, totalPage: Int, bookTitle: String = "", bookAuthor: String = "") {
        guard APIService.shared.isAudiobookEnabled else { return }
        let isNewBook = self.bookSlug != bookSlug
        let isNewPage = self.currentPage != currentPage

        self.bookSlug = bookSlug
        self.totalPage = totalPage
        if !bookTitle.isEmpty { self.bookTitle = bookTitle }
        if !bookAuthor.isEmpty { self.bookAuthor = bookAuthor }

        if isNewBook {
            pageSentencesCache.removeAll()
            AudioProviderFactory.shared.clearCache()
        }

        // A page selected manually must immediately stop the audio that belongs
        // to the previous page. Automatic audiobook page turns set
        // shouldContinuePlayingOnPageLoad before changing the reader page, so
        // they are still allowed to continue seamlessly.
        if isNewPage && isPlaying && !shouldContinuePlayingOnPageLoad {
            isPlaying = false
            isPausedOnCurrentPage = false
            playbackTask?.cancel()
            playbackTask = nil
            stopTimeTracking()
            endBackgroundTransitionTask()
            AudioProviderFactory.shared.stop()
            highlightSentence(id: nil)
            currentSentenceIndex = 0
        }

        if isNewBook || (isNewPage && !shouldContinuePlayingOnPageLoad) {
            self.currentPage = currentPage
            isPausedOnCurrentPage = false
            AudioProviderFactory.shared.stop()
            preloadCurrentPageSentences()
        } else if isNewPage && !isPlaying {
            self.currentPage = currentPage
            preloadCurrentPageSentences()
        }

        if isPlaying {
            updateNowPlayingInfo()
        }
    }

    /// Fast preload of current page sentences from memory cache or local HTML storage (< 1ms)
    func preloadCurrentPageSentences() {
        guard APIService.shared.isAudiobookEnabled, !bookSlug.isEmpty else { return }

        if let cached = pageSentencesCache[currentPage], !cached.isEmpty {
            self.sentences = cached
            self.updateSentenceOffsets(cached)
            return
        }

        // Fast synchronous check from local file on disk
        if let localUrl = BookCacheManager.shared.localPageURL(slug: bookSlug, lang: mode.rawValue, page: currentPage),
           let data = try? Data(contentsOf: localUrl),
           let str = String(data: data, encoding: .utf8) {
            let items = parseHtmlToSentenceItems(html: str, lang: mode.rawValue)
            if !items.isEmpty {
                self.pageSentencesCache[currentPage] = items
                self.sentences = items
                self.updateSentenceOffsets(items)
                return
            }
        }
    }

    /// Prepares state immediately when user opens the player bar on a page
    func syncWithCurrentPage(page: Int, viewMode: String, en: WKWebView?, vi: WKWebView?) {
        guard APIService.shared.isAudiobookEnabled else {
            isBarVisible = false
            return
        }
        ensureRemoteCommandsConfigured()
        self.enWebView = en
        self.viWebView = vi
        self.currentViewMode = viewMode

        // When the player is opened, immediately derive its reading language
        // from the page currently visible in the reader. Split mode keeps the
        // user's most recently selected audiobook language.
        let visibleMode: AudiobookLanguageMode? = {
            switch viewMode {
            case "en": return .en
            case "vi": return .vi
            default: return nil
            }
        }()

        if let visibleMode, mode != visibleMode {
            changeMode(visibleMode)
            return
        }

        if self.currentPage != page || self.sentences.isEmpty {
            self.currentPage = page
            self.currentSentenceIndex = 0
            self.preloadCurrentPageSentences()
        }

        // Smoothly highlight and scroll to active sentence
        if !sentences.isEmpty {
            let idx = min(currentSentenceIndex, sentences.count - 1)
            let item = sentences[idx]
            highlightSentence(id: item.id, lang: item.lang)
        } else {
            Task {
                await extractSentences(viewMode: viewMode)
                if let first = self.sentences.first {
                    self.highlightSentence(id: first.id, lang: first.lang)
                }
            }
        }

        // Pre-fetch NEXT page audio in the background
        Task.detached(priority: .background) { [weak self] in
            guard let self = self else { return }
            await self.prefetchNextPageAudio(page: page + 1, targetMode: await self.mode)
        }
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

        // If audio is already actively playing on this page (e.g. instant continuous playback),
        // we just update the web views and highlight the active sentence without any interruption!
        if isPlaying {
            if currentSentenceIndex < sentences.count {
                let item = sentences[currentSentenceIndex]
                highlightSentence(id: item.id, lang: item.lang)
            }
            return
        }

        // Preload immediately from cache/disk without sleeping
        preloadCurrentPageSentences()

        if sentences.isEmpty {
            Task {
                await extractSentences(viewMode: viewMode)
                if self.shouldContinuePlayingOnPageLoad && !self.sentences.isEmpty {
                    self.shouldContinuePlayingOnPageLoad = false
                    self.currentSentenceIndex = 0
                    self.play()
                } else if let first = self.sentences.first {
                    self.highlightSentence(id: first.id, lang: first.lang)
                }
            }
        } else {
            if self.shouldContinuePlayingOnPageLoad {
                self.shouldContinuePlayingOnPageLoad = false
                self.currentSentenceIndex = 0
                self.play()
            } else if !self.sentences.isEmpty {
                let item = sentences[min(currentSentenceIndex, sentences.count - 1)]
                highlightSentence(id: item.id, lang: item.lang)
            }
        }
    }

    func changeMode(_ newMode: AudiobookLanguageMode) {
        let wasPlaying = isPlaying
        shouldContinuePlayingOnPageLoad = false
        isPausedOnCurrentPage = false
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
        stopTimeTracking()
        endBackgroundTransitionTask()
        AudioProviderFactory.shared.stop()
        highlightSentence(id: nil)
        self.mode = newMode
        self.currentSentenceIndex = 0
        self.pageSentencesCache.removeAll()

        preloadCurrentPageSentences()

        Task {
            if self.sentences.isEmpty {
                await extractSentences(viewMode: currentViewMode)
            }
            if let first = sentences.first {
                highlightSentence(id: first.id, lang: first.lang)
            }
            if wasPlaying && !sentences.isEmpty {
                self.play()
            } else {
                updateNowPlayingInfo()
            }
        }
    }

    /// Extracts segmented sentences from active WKWebView DOM instances with robust storage fallbacks
    func extractSentences(viewMode: String) async {
        let jsExtract = """
        (function() {
            const excludedSelector = [
                'script', 'style', 'noscript', 'template', 'head',
                'nav', 'footer', '.book-footer', '.running-header',
                '[hidden]', '[aria-hidden="true"]',
                '[data-audiobook-ignore="true"]'
            ].join(',');

            const isReadable = (element) => {
                if (!element || element.closest(excludedSelector)) return false;
                const style = window.getComputedStyle(element);
                if (style.display === 'none' || style.visibility === 'hidden') return false;
                if (Number(style.opacity) === 0) return false;
                return element.getClientRects().length > 0;
            };

            const orderedListMarker = (element) => {
                if (element.tagName !== 'LI') return '';

                const list = element.parentElement;
                if (!list || list.tagName !== 'OL') return '';

                const explicitValue = Number.parseInt(element.getAttribute('value') || '', 10);
                if (Number.isFinite(explicitValue)) return explicitValue + '. ';

                const start = Number.parseInt(list.getAttribute('start') || '1', 10);
                const reversed = list.hasAttribute('reversed');
                const siblings = Array.from(list.children).filter(child => child.tagName === 'LI');
                const index = siblings.indexOf(element);
                const initial = Number.isFinite(start)
                    ? start
                    : (reversed ? siblings.length : 1);
                const number = reversed ? initial - index : initial + index;
                return number + '. ';
            };

            const visibleText = (element) => {
                const text = (element.innerText || '')
                    .replace(/\\s+/g, ' ')
                    .trim();
                return orderedListMarker(element) + text;
            };

            let nodes = Array.from(document.querySelectorAll('.sentence-node'))
                .filter(isReadable);
            if (nodes.length === 0 && typeof segmentDocSentences === 'function') {
                try {
                    segmentDocSentences(document);
                    nodes = Array.from(document.querySelectorAll('.sentence-node'))
                        .filter(isReadable);
                } catch(e) {}
            }
            if (nodes.length === 0) {
                const root = document.querySelector('article') || document.querySelector('main') || document.body;
                const pars = Array.from(root.querySelectorAll(
                    'p, h1, h2, h3, h4, h5, h6, li, blockquote, dt, dd, figcaption, th, td, pre, .chapter-start, .section-title, .action-header, .action-title'
                )).filter(isReadable);
                return pars.map((p, idx) => {
                    if (!p.dataset.sentenceId) {
                        p.dataset.sentenceId = 'fallback-s-' + idx;
                        p.classList.add('sentence-node');
                    }
                    return {
                        id: p.dataset.sentenceId,
                        text: visibleText(p)
                    };
                }).filter(x => x.text.length > 0);
            }
            return nodes.map(n => ({
                id: n.dataset.sentenceId || '',
                text: visibleText(n)
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

        // If WebViews returned nothing (e.g. app in background / screen off / WebKit paused)
        if combined.isEmpty && !bookSlug.isEmpty {
            combined = await extractSentencesDirectlyFromStorage(slug: bookSlug, page: currentPage, lang: mode.rawValue)
        }

        if !combined.isEmpty {
            self.pageSentencesCache[currentPage] = combined
            self.sentences = combined
            updateSentenceOffsets(combined)
            if currentSentenceIndex >= combined.count {
                currentSentenceIndex = 0
            }
        }
    }

    /// Background-safe extraction from local HTML cache or remote server when WebKit is suspended
    private func extractSentencesDirectlyFromStorage(slug: String, page: Int, lang: String) async -> [AudioSentenceItem] {
        if let cached = pageSentencesCache[page], !cached.isEmpty {
            return cached
        }

        var html: String = ""
        if let localUrl = BookCacheManager.shared.localPageURL(slug: slug, lang: lang, page: page),
           let data = try? Data(contentsOf: localUrl),
           let str = String(data: data, encoding: .utf8) {
            html = str
        } else if let remoteUrl = URL(string: "\(APIService.shared.serverUrl)/books/\(slug)/output/\(lang)/page_\(String(format: "%04d", page)).html?token=\(APIService.shared.token)"),
                  let (data, _) = try? await URLSession.shared.data(from: remoteUrl),
                  let str = String(data: data, encoding: .utf8) {
            html = str
        }

        guard !html.isEmpty else { return [] }
        let items = parseHtmlToSentenceItems(html: html, lang: lang)
        if !items.isEmpty {
            self.pageSentencesCache[page] = items
        }
        return items
    }

    private func parseHtmlToSentenceItems(html: String, lang: String) -> [AudioSentenceItem] {
        // Background parsing cannot inspect computed styles, so first remove
        // document configuration and restrict extraction to the semantic book
        // container. This prevents CSS/JavaScript/JSON and page chrome from
        // being included in synthesized speech.
        var contentHtml = html
        let removablePatterns = [
            #"(?is)<!DOCTYPE[\s\S]*?>"#,
            #"(?is)<head\b[^>]*>[\s\S]*?</head>"#,
            #"(?is)<script\b[^>]*>[\s\S]*?</script>"#,
            #"(?is)<style\b[^>]*>[\s\S]*?</style>"#,
            #"(?is)<noscript\b[^>]*>[\s\S]*?</noscript>"#,
            #"(?is)<template\b[^>]*>[\s\S]*?</template>"#,
            #"(?is)<nav\b[^>]*>[\s\S]*?</nav>"#,
            #"(?is)<footer\b[^>]*>[\s\S]*?</footer>"#,
            #"(?is)<!--[\s\S]*?-->"#
        ]
        for pattern in removablePatterns {
            contentHtml = contentHtml.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }

        if let article = firstHtmlContainer(named: "article", in: contentHtml) {
            contentHtml = article
        } else if let main = firstHtmlContainer(named: "main", in: contentHtml) {
            contentHtml = main
        } else if let body = firstHtmlContainer(named: "body", in: contentHtml) {
            contentHtml = body
        }

        contentHtml = addOrderedListMarkers(to: contentHtml)

        let nsHtml = contentHtml as NSString
        var results: [AudioSentenceItem] = []

        // 1. Try finding .sentence-node with data-sentence-id
        let sentenceNodeRegex = try? NSRegularExpression(
            pattern: #"<[^>]+class="[^"]*sentence-node[^"]*"[^>]*data-sentence-id="([^"]+)"[^>]*>([\s\S]*?)</[^>]+>"#,
            options: .caseInsensitive
        )
        if let matches = sentenceNodeRegex?.matches(
            in: contentHtml,
            range: NSRange(location: 0, length: nsHtml.length)
        ), !matches.isEmpty {
            for match in matches {
                guard match.numberOfRanges >= 3 else { continue }
                let id = nsHtml.substring(with: match.range(at: 1))
                let rawText = nsHtml.substring(with: match.range(at: 2))
                let cleaned = stripHtmlToText(rawText)
                if !cleaned.isEmpty {
                    results.append(AudioSentenceItem(id: id, text: cleaned, lang: lang))
                }
            }
        }

        if !results.isEmpty { return results }

        // 2. Fallback: extract paragraphs, headings, list items
        let blockRegex = try? NSRegularExpression(
            pattern: #"<(p|h[1-6]|li|blockquote|dt|dd|figcaption|th|td|pre)[^>]*>([\s\S]*?)</\1>"#,
            options: .caseInsensitive
        )
        if let blockMatches = blockRegex?.matches(
            in: contentHtml,
            range: NSRange(location: 0, length: nsHtml.length)
        ), !blockMatches.isEmpty {
            for (idx, match) in blockMatches.enumerated() {
                guard match.numberOfRanges >= 3 else { continue }
                let rawText = nsHtml.substring(with: match.range(at: 2))
                let cleaned = stripHtmlToText(rawText)
                if !cleaned.isEmpty {
                    results.append(AudioSentenceItem(id: "fallback-\(lang)-s-\(idx)", text: cleaned, lang: lang))
                }
            }
        }

        if !results.isEmpty { return results }

        // 3. Fallback: plain text stripped from entire page
        let fullText = stripHtmlToText(contentHtml)
        if !fullText.isEmpty {
            results.append(AudioSentenceItem(id: "fallback-\(lang)-s-0", text: fullText, lang: lang))
        }

        return results
    }

    /// HTML list markers are generated by the browser and therefore are not
    /// part of `textContent`. Add them explicitly when parsing cached HTML so
    /// ordered steps such as 1, 2, 3 are also spoken by the audiobook.
    private func addOrderedListMarkers(to html: String) -> String {
        guard let orderedListRegex = try? NSRegularExpression(
            pattern: #"(?is)<ol\b([^>]*)>([\s\S]*?)</ol>"#
        ) else {
            return html
        }

        let source = html as NSString
        let matches = orderedListRegex.matches(
            in: html,
            range: NSRange(location: 0, length: source.length)
        )

        var result = html

        // Replace from the end so earlier NSRange values remain valid.
        for listMatch in matches.reversed() {
            guard listMatch.numberOfRanges >= 3 else { continue }

            let attributes = source.substring(with: listMatch.range(at: 1))
            let listBody = source.substring(with: listMatch.range(at: 2))
            let isReversed = attributes.range(
                of: #"\breversed\b"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil

            let startValue: Int? = {
                guard let regex = try? NSRegularExpression(
                    pattern: #"\bstart\s*=\s*["']?(-?\d+)"#,
                    options: .caseInsensitive
                ) else {
                    return nil
                }
                let nsAttributes = attributes as NSString
                guard let match = regex.firstMatch(
                    in: attributes,
                    range: NSRange(location: 0, length: nsAttributes.length)
                ), match.numberOfRanges >= 2 else {
                    return nil
                }
                return Int(nsAttributes.substring(with: match.range(at: 1)))
            }()

            guard let listItemRegex = try? NSRegularExpression(
                pattern: #"(?is)<li\b([^>]*)>([\s\S]*?)</li>"#
            ) else {
                continue
            }

            let nsListBody = listBody as NSString
            let itemMatches = listItemRegex.matches(
                in: listBody,
                range: NSRange(location: 0, length: nsListBody.length)
            )

            var numberedBody = listBody
            let defaultStart = startValue ?? (isReversed ? itemMatches.count : 1)

            for (offset, itemMatch) in itemMatches.enumerated().reversed() {
                guard itemMatch.numberOfRanges >= 3 else { continue }

                let itemAttributes = nsListBody.substring(with: itemMatch.range(at: 1))
                let itemContent = nsListBody.substring(with: itemMatch.range(at: 2))

                let explicitValue: Int? = {
                    guard let regex = try? NSRegularExpression(
                        pattern: #"\bvalue\s*=\s*["']?(-?\d+)"#,
                        options: .caseInsensitive
                    ) else {
                        return nil
                    }
                    let nsAttributes = itemAttributes as NSString
                    guard let match = regex.firstMatch(
                        in: itemAttributes,
                        range: NSRange(location: 0, length: nsAttributes.length)
                    ), match.numberOfRanges >= 2 else {
                        return nil
                    }
                    return Int(nsAttributes.substring(with: match.range(at: 1)))
                }()

                let number = explicitValue ??
                    (isReversed ? defaultStart - offset : defaultStart + offset)
                let replacement = "<li\(itemAttributes)>\(number). \(itemContent)</li>"

                guard let swiftRange = Range(itemMatch.range, in: numberedBody) else {
                    continue
                }
                numberedBody.replaceSubrange(swiftRange, with: replacement)
            }

            let replacement = "<ol\(attributes)>\(numberedBody)</ol>"
            guard let swiftRange = Range(listMatch.range, in: result) else {
                continue
            }
            result.replaceSubrange(swiftRange, with: replacement)
        }

        return result
    }

    private func firstHtmlContainer(named tag: String, in html: String) -> String? {
        let escapedTag = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "(?is)<\(escapedTag)\\b[^>]*>([\\s\\S]*?)</\(escapedTag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsHtml = html as NSString
        guard let match = regex.firstMatch(
            in: html,
            range: NSRange(location: 0, length: nsHtml.length)
        ), match.numberOfRanges >= 2 else {
            return nil
        }

        return nsHtml.substring(with: match.range(at: 1))
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
        guard APIService.shared.isAudiobookEnabled else {
            close()
            return
        }
        ensureRemoteCommandsConfigured()
        if sentences.isEmpty {
            preloadCurrentPageSentences()
            if sentences.isEmpty {
                Task {
                    await extractSentences(viewMode: currentViewMode)
                    if self.sentences.isEmpty {
                        self.errorMessage = "Không tìm thấy văn bản trên trang."
                        self.endBackgroundTransitionTask()
                    } else {
                        self.play()
                    }
                }
                return
            }
        }

        errorMessage = nil

        // Only resume if user was actively paused on this current page and player is not already playing
        if isPausedOnCurrentPage && playbackTask != nil && !AudioProviderFactory.shared.isAudioPlaying {
            if AudioProviderFactory.shared.resume() {
                isPlaying = true
                isPausedOnCurrentPage = false
                startTimeTracking()
                updateNowPlayingInfo()
                return
            }
        }

        // Fresh page playback
        isPausedOnCurrentPage = false
        isPlaying = true
        playbackTask?.cancel()
        playbackTask = nil
        stopTimeTracking()

        // Prefetch NEXT page audio in the background immediately
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
        guard !sentences.isEmpty else {
            endBackgroundTransitionTask()
            return
        }

        let fullPageText = sentences.map { $0.text }.joined(separator: " ")
        let isVi = mode == .vi
        let langTag = isVi ? "vi-VN" : "en-US"
        let selectedVoice = voiceFor(lang: langTag)

        print("[AudiobookManager] startFullPagePlayback page=\(currentPage) mode=\(mode.rawValue) provider=\(provider) voice=\(selectedVoice) speed=\(speed) sentences=\(sentences.count) startIndex=\(startIndex)")

        var startRatio: Double = 0.0
        if startIndex > 0 && startIndex < cumulativeOffsets.count && totalChars > 0 {
            startRatio = Double(cumulativeOffsets[startIndex]) / Double(totalChars)
        }

        startTimeTracking()
        updateNowPlayingInfo()

        do {
            try await AudioProviderFactory.shared.speak(
                text: fullPageText,
                provider: provider,
                voice: selectedVoice,
                speed: speed,
                lang: langTag,
                startRatio: startRatio
            )

            // Audio finished playing
            isPausedOnCurrentPage = false
            stopTimeTracking()
            if isPlaying {
                if autoPageTurn && currentPage < totalPage {
                    beginBackgroundTransitionTask()
                    let nextPage = currentPage + 1

                    // INSTANT ZERO-GAP TRANSITION if next page sentences are already cached:
                    if let nextSentences = pageSentencesCache[nextPage], !nextSentences.isEmpty {
                        self.currentPage = nextPage
                        self.sentences = nextSentences
                        self.updateSentenceOffsets(nextSentences)
                        self.currentSentenceIndex = 0
                        self.shouldContinuePlayingOnPageLoad = false

                        // Smoothly advance UI page
                        self.onPageTurnNeeded?()

                        // Play immediately without waiting for WKWebView DOM
                        self.play()
                        return
                    }

                    // Fallback to waiting for onPageTurnNeeded
                    shouldContinuePlayingOnPageLoad = true
                    onPageTurnNeeded?()
                } else {
                    isPlaying = false
                    endBackgroundTransitionTask()
                    highlightSentence(id: nil)
                    updateNowPlayingInfo()
                }
            } else {
                endBackgroundTransitionTask()
            }
        } catch is CancellationError {
            stopTimeTracking()
            endBackgroundTransitionTask()
        } catch {
            stopTimeTracking()
            endBackgroundTransitionTask()
            isPausedOnCurrentPage = false
            if !Task.isCancelled {
                print("[AudiobookManager] Playback error: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
                isPlaying = false
                updateNowPlayingInfo()
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
                        self.updateNowPlayingInfo()
                    }
                }
            }
        }
    }

    private func stopTimeTracking() {
        timeTrackingTask?.cancel()
        timeTrackingTask = nil
    }

    /// Prefetches next page sentences and EXACT synthesized audio matching startFullPagePlayback
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
        let items = parseHtmlToSentenceItems(html: htmlString, lang: targetMode.rawValue)
        guard !items.isEmpty else { return }

        // Cache the parsed sentences in memory for instant transition!
        self.pageSentencesCache[page] = items

        // CRITICAL: The prefetched text MUST MATCH EXACTLY what startFullPagePlayback will request:
        let fullPageText = items.map { $0.text }.joined(separator: " ")
        guard !fullPageText.isEmpty else { return }

        let langTag = targetMode == .vi ? "vi-VN" : "en-US"
        let nextVoice = voiceFor(lang: langTag)
        AudioProviderFactory.shared.prefetch(
            text: fullPageText,
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
        isPausedOnCurrentPage = true
        stopTimeTracking()
        endBackgroundTransitionTask()
        AudioProviderFactory.shared.pause()
        updateNowPlayingInfo()
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
            updateNowPlayingInfo()
        } else if isPlaying {
            AudioProviderFactory.shared.stop()
            isPausedOnCurrentPage = false
            play()
        }
    }

    func nextSentence() {
        if currentSentenceIndex < sentences.count - 1 {
            seekToSentence(currentSentenceIndex + 1)
        } else if autoPageTurn && currentPage < totalPage {
            beginBackgroundTransitionTask()
            let nextPage = currentPage + 1
            if let nextSentences = pageSentencesCache[nextPage], !nextSentences.isEmpty {
                self.currentPage = nextPage
                self.sentences = nextSentences
                self.updateSentenceOffsets(nextSentences)
                self.currentSentenceIndex = 0
                self.shouldContinuePlayingOnPageLoad = false
                self.onPageTurnNeeded?()
                self.play()
                return
            }
            shouldContinuePlayingOnPageLoad = true
            onPageTurnNeeded?()
        }
    }

    func prevSentence() {
        if currentSentenceIndex > 0 {
            seekToSentence(currentSentenceIndex - 1)
        }
    }

    func highlightSentence(id: String?, lang: String? = nil) {
        let jsHighlight: String
        if let id = id {
            jsHighlight = """
            (function() {
                if (typeof segmentDocSentences === 'function' && document.querySelectorAll('.sentence-node').length === 0) {
                    try { segmentDocSentences(document); } catch(e) {}
                }
                window.highlightSentence && window.highlightSentence('\(id)');
                const el = document.querySelector('.sentence-node[data-sentence-id="\(id)"]') || document.querySelector('[data-sentence-id="\(id)"]');
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
        isPausedOnCurrentPage = false
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
        stopTimeTracking()
        endBackgroundTransitionTask()
        AudioProviderFactory.shared.stop()
        highlightSentence(id: nil)
        isBarVisible = false
        if hasSetupRemoteCommands {
            NowPlayingManager.shared.clearNowPlaying()
        }
    }
}
