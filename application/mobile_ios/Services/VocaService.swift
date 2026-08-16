import Foundation
import AVFoundation

/// Client for the Voca 2.0 vocabulary API — reached **through our own backend**, never direct.
///
/// Every call goes to `<APIService.serverUrl>/api/voca/...`; the backend attaches the `voca_`
/// key it holds for this user (`user_settings`) and forwards Voca's response body verbatim.
/// Configuring Voca once — here or in the web app — therefore configures it in both places.
///
/// What that transport implies, and what keeps biting people:
/// - **the key is not on the device.** It is typed in Settings and PUT to
///   `/api/user/settings`, which never hands it back; `isConfigured()` asks the server whether
///   a key is stored (cached for the session). There is nothing local left to read.
/// - **Voca now needs an app session.** With `APIService.isAuthenticated == false` every call
///   fails as `.notSignedIn` — Voca used to work with no backend login at all.
/// - **decide the error from the envelope `code`, never from the HTTP status.** The proxy
///   deliberately remaps an upstream Voca 401/403 to HTTP 502 so a bad Voca key can never look
///   like an expired app session; the body still carries the real code.
/// - every JSON response, success **and** error, is wrapped in `{status, code, message, data}`,
///   so nothing decodes straight off the body — go through `send(_:)`;
/// - audio and card detail key off the card **`slug`**, never the numeric `id`;
/// - `GET /api/voca/audio/{slug}` answers with raw mp3 — only a *failure* there is JSON.

// MARK: - Models

/// A Voca 2.0 Card. Decoding is deliberately forgiving (see `init(from:)`): a single
/// unexpected field type must degrade that field, not kill the whole lookup.
struct VocaCard: Codable, Identifiable, Equatable {
    let id: Int
    /// The key for `/api/voca/audio/{slug}` and `/api/voca/cards/{slug}` — not `id`.
    let slug: String
    let word: String
    let ipa: String?
    let pronunciation: String?
    let frequency: String?
    let meaningEn: String?
    let meaningVi: String?
    let useCases: [String]?
    let examples: [String]?
    let memoryTip: String?
    let toeicTrap: String?
    let partOfSpeech: String?
    let topic: String?
    let tags: [String]?
    let keyword: String?
    let practicePrompt: String?
    let answer: String?
    /// `new | learning | known | mastered`
    let level: String?
    /// A **Voca-side** path (`/v1/audio/{slug}`), not a path on our proxy — display only.
    let audioUrl: String?
    let createdAt: String?

    var displayIpa: String {
        let value = (ipa ?? pronunciation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        return value.hasPrefix("/") ? value : "/\(value)/"
    }

    var displayMeaning: String {
        let vi = (meaningVi ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return vi.isEmpty ? (meaningEn ?? "") : vi
    }

    enum CodingKeys: String, CodingKey {
        case id, slug, word, ipa, pronunciation, frequency, meaningEn, meaningVi
        case useCases, examples, memoryTip, toeicTrap, partOfSpeech, topic, tags
        case keyword, practicePrompt, answer, level, audioUrl, createdAt
    }
}

// `init(from:)` lives in an extension so the memberwise initialiser survives.
extension VocaCard {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id` is a number in 2.0 (it was a string in the old bridge) — accept either.
        id = (try? c.decode(Int.self, forKey: .id)) ?? Int(VocaScalar.text(in: c, forKey: .id) ?? "") ?? 0
        slug = (try? c.decode(String.self, forKey: .slug)) ?? ""
        word = (try? c.decode(String.self, forKey: .word)) ?? ""
        ipa = try? c.decode(String.self, forKey: .ipa)
        pronunciation = try? c.decode(String.self, forKey: .pronunciation)
        frequency = VocaScalar.text(in: c, forKey: .frequency)
        meaningEn = try? c.decode(String.self, forKey: .meaningEn)
        meaningVi = try? c.decode(String.self, forKey: .meaningVi)
        useCases = VocaScalar.texts(in: c, forKey: .useCases)
        examples = VocaScalar.texts(in: c, forKey: .examples)
        memoryTip = try? c.decode(String.self, forKey: .memoryTip)
        toeicTrap = try? c.decode(String.self, forKey: .toeicTrap)
        partOfSpeech = try? c.decode(String.self, forKey: .partOfSpeech)
        topic = try? c.decode(String.self, forKey: .topic)
        tags = VocaScalar.texts(in: c, forKey: .tags)
        keyword = try? c.decode(String.self, forKey: .keyword)
        practicePrompt = try? c.decode(String.self, forKey: .practicePrompt)
        answer = try? c.decode(String.self, forKey: .answer)
        level = try? c.decode(String.self, forKey: .level)
        audioUrl = try? c.decode(String.self, forKey: .audioUrl)
        createdAt = VocaScalar.text(in: c, forKey: .createdAt)
    }

    /// Rebuilds a card from the JS-bridge payload produced by `ReaderView.vocaCardPayload`.
    init?(webPayload: [String: Any]) {
        guard let slug = webPayload["slug"] as? String, !slug.isEmpty,
              let word = webPayload["word"] as? String else { return nil }
        self.init(
            id: webPayload["id"] as? Int ?? 0,
            slug: slug,
            word: word,
            ipa: webPayload["ipa"] as? String,
            pronunciation: webPayload["pronunciation"] as? String,
            frequency: nil,
            meaningEn: nil,
            meaningVi: webPayload["meaningVi"] as? String,
            useCases: nil,
            examples: nil,
            memoryTip: nil,
            toeicTrap: nil,
            partOfSpeech: nil,
            topic: nil,
            tags: nil,
            keyword: nil,
            practicePrompt: nil,
            answer: nil,
            level: webPayload["level"] as? String,
            audioUrl: webPayload["audioUrl"] as? String,
            createdAt: nil
        )
    }
}

/// Upstream is loose about scalar types (`frequency` and the cards `version` arrive as either
/// a string or a number), so read them through this instead of throwing a `typeMismatch`.
private struct VocaScalar: Decodable {
    let text: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let value = try? c.decode(String.self) { text = value }
        else if let value = try? c.decode(Int.self) { text = String(value) }
        else if let value = try? c.decode(Double.self) { text = String(value) }
        else if let value = try? c.decode(Bool.self) { text = String(value) }
        else if let value = try? c.decode([String: String].self) {
            text = value["en"] ?? value["text"] ?? value["sentence"] ?? value["vi"]
        } else { text = nil }
    }

    static func text<K: CodingKey>(in container: KeyedDecodingContainer<K>, forKey key: K) -> String? {
        (try? container.decode(VocaScalar.self, forKey: key))?.text
    }

    static func texts<K: CodingKey>(in container: KeyedDecodingContainer<K>, forKey key: K) -> [String]? {
        guard let items = try? container.decode([VocaScalar].self, forKey: key) else { return nil }
        return items.compactMap { $0.text }
    }
}

struct VocaLookupResult: Codable {
    let found: Bool
    let word: String?
    /// `exact | partial`
    let matchType: String?
    let card: VocaCard?
    let cards: [VocaCard]?

    var resolvedCards: [VocaCard] {
        if let cards, !cards.isEmpty { return cards }
        if let card { return [card] }
        return []
    }
}

/// `GET /api/voca/cards` — `changed: false` omits `cards` entirely.
struct VocaCardsPage: Decodable {
    let version: String?
    let changed: Bool?
    let cards: [VocaCard]?

    private enum CodingKeys: String, CodingKey { case version, changed, cards }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = VocaScalar.text(in: c, forKey: .version)
        changed = try? c.decode(Bool.self, forKey: .changed)
        cards = try? c.decode([VocaCard].self, forKey: .cards)
    }
}

/// The on-disk mirror of the dictionary, so lookups can answer from a local store first.
struct VocaCardsSnapshot: Codable {
    let version: String
    let cards: [VocaCard]
}

struct VocaHealth: Codable {
    let status: String?
    let service: String?
    let storage: String?
    let version: String?
}

/// `POST /api/voca/audio/{slug}` — confirmation that the file now exists.
struct VocaAudioRef: Decodable {
    let audioUrl: String?
    let id: String?

    private enum CodingKeys: String, CodingKey { case audioUrl, id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audioUrl = try? c.decode(String.self, forKey: .audioUrl)
        id = VocaScalar.text(in: c, forKey: .id)
    }
}

/// The wrapper every JSON response carries — success and error alike.
struct VocaEnvelope<T: Decodable>: Decodable {
    let status: Int?
    let code: String?
    let message: String?
    let data: T?
}

/// Where a card's pronunciation comes from — the same three-value preference as the web app.
///
/// It replaces v1's `useApiTts` / `ttsEndpoint`, which Voca 2.0 retired: the client can no
/// longer supply TTS credentials, so when the Voca server has no TTS provider configured every
/// generate answers `503 TTS_NOT_CONFIGURED` and the only audio left is the device's own voice.
enum VocaAudioSource: String, CaseIterable {
    /// Try Voca, fall back to the device. The default.
    case auto
    /// Voca only — surface the error instead of quietly speaking.
    case voca
    /// Device only; never calls Voca audio at all (fastest, works offline).
    case device

    /// Shared with the web app's setting of the same name.
    static let defaultsKey = "audioSource"

    static var current: VocaAudioSource {
        VocaAudioSource(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .auto
    }
}

/// Which voice actually produced the sound, so the caller can tell the user when it was not Voca.
enum VocaAudioOutcome: Equatable {
    case voca
    /// Spoken by the device. `notice` is non-nil exactly ONCE per app session — the first time
    /// `auto` mode had to stand in for Voca — and is nil when the user asked for `device`
    /// themselves (they already know) or has been told once already.
    case device(notice: String?)
}

/// Which panel the reader shows for a lookup. Lives here with the models because the panel
/// itself is rendered inside the page WebView (see `BilingualWebView.showIOSVocaPanel`).
enum VocaLookupPanelMode: Equatable {
    case single(VocaCard)
    case multi(query: String, cards: [VocaCard])
    case notFound(query: String)
}

enum VocaServiceError: LocalizedError {
    case missingWord
    /// No app session — the proxy (and therefore Voca) is unreachable without one.
    case notSignedIn
    /// The server holds no `voca_` key for this user yet.
    case notConfigured
    case invalidURL
    /// Carries the envelope triple so callers can branch on `code` rather than parse text.
    case api(status: Int, code: String, message: String)
    case invalidResponse(String)
    case audioFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingWord:
            return "Chưa chọn từ nào."
        case .notSignedIn:
            return "Đăng nhập để dùng từ điển Voca."
        case .notConfigured:
            return "Chưa cấu hình Voca API key trên server. Vào Cài đặt AI & Voca (hoặc bản web) để nhập key."
        case .invalidURL:
            return "Địa chỉ server không hợp lệ. Kiểm tra lại trong Cài đặt."
        case .api(let status, let code, let message):
            switch code {
            case "UNAUTHORIZED", "FORBIDDEN":
                // The proxy turned Voca's 401/403 into a 502 — this is the Voca key, not the app session.
                return "API key Voca không hợp lệ hoặc đã bị thu hồi. Cập nhật lại trong Cài đặt (key lưu trên server, dùng chung với bản web)."
            case "APP_UNAUTHORIZED":
                return "Phiên đăng nhập đã hết hạn. Đăng nhập lại để dùng từ điển Voca."
            case "VOCA_NOT_CONFIGURED":
                return "Server chưa có Voca API key. Vào Cài đặt AI & Voca để nhập key."
            case "INVALID_ORIGIN":
                return message.isEmpty ? "Voca API URL không hợp lệ. Kiểm tra lại trong Cài đặt." : message
            case "VOCA_UNREACHABLE":
                // Raised by our proxy, not by Voca: the backend could not reach the Voca host.
                return "Server không kết nối được tới Voca. Kiểm tra Voca API URL trong Cài đặt hoặc thử lại sau."
            case "UPSTREAM_ERROR":
                // Voca (or something in front of it) answered with a non-JSON body.
                return "Voca đang gặp sự cố (\(status)). Thử lại sau ít phút."
            case "RATE_LIMITED":
                return "Voca đang giới hạn số lượt gọi. Thử lại sau vài giây."
            case "LLM_NOT_CONFIGURED":
                return "Voca chưa bật LLM nên không tạo được thẻ mới."
            case "TTS_NOT_CONFIGURED":
                return "Voca chưa bật TTS nên không tạo được audio."
            case "MISSING_WORD":
                return "Thiếu từ cần tra."
            case "INVALID_LEVEL":
                return "Cấp độ thẻ không hợp lệ."
            case "NOT_FOUND", "AUDIO_NOT_FOUND":
                return message.isEmpty ? "Không tìm thấy dữ liệu trên Voca." : message
            default:
                return message.isEmpty ? "Voca gặp lỗi (\(status))." : message
            }
        case .invalidResponse(let message):
            return message
        case .audioFailed(let message):
            return message
        }
    }
}

// MARK: - Service

enum VocaService {
    /// Offered as the default value in Settings and stored **on the server** from there.
    /// iOS itself never sends a request to this host — everything goes through the proxy.
    static let defaultOrigin = "https://voca.thaonv.online"
    static let defaultTTSModel = "edge-tts/en-US-SteffanNeural"

    /// Every path below is relative to this: `<serverUrl>/api/voca/...`.
    private static let proxyPrefix = "/api/voca"

    // Pre-proxy storage. Nothing reads these any more; they exist only to be deleted once
    // (see `purgeDeviceCredentialsIfNeeded`).
    private static let legacyOriginDefaultsKey = "vocaBridgeOrigin"
    private static let legacyKeyDefaultsKey = "vocaBridgeToken"
    private static let legacyKeychainAccount = "vocaApiKey"
    private static let purgeDoneDefaultsKey = "vocaLocalCredentialsPurged.v1"

    private static let cardsCacheFileName = "voca-cards.json"

    private static var audioPlayer: AVPlayer?
    private static var snapshotCache: VocaCardsSnapshot?
    /// Whether the SERVER holds a Voca key. Cached for the session so a lookup does not
    /// re-query `/api/user/settings` every time; `nil` means "not asked / could not ask".
    private static var configuredCache: Bool?

    // MARK: Configuration

    /// Trim, drop a trailing slash or `/v1`, and force `https`. Only used to tidy what the
    /// user types before it is PUT to the server — the backend normalises it again and is
    /// the one that actually calls the host.
    static func normalizedOrigin(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        value = forcedHTTPS(value)
        if !value.lowercased().hasPrefix("https://") {
            value = "https://" + value
        }
        while value.hasSuffix("/") { value.removeLast() }
        if value.lowercased().hasSuffix("/v1") { value.removeLast(3) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// Voca rejects a key pasted without its prefix as `UNAUTHORIZED`, and so does our own
    /// `PUT /api/user/settings` (400) — catch it in the UI before either.
    static func isValidAPIKeyFormat(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("voca_")
    }

    /// One-shot cleanup for installs upgrading from the direct-to-Voca build: the API key
    /// used to sit in the Keychain (and, before that, in UserDefaults). It is server-held
    /// now, so any device copy is dead weight that must not linger. Guarded by a flag so it
    /// runs once, not on every request.
    static func purgeDeviceCredentialsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: purgeDoneDefaultsKey) else { return }
        KeychainHelper.delete(key: legacyKeychainAccount)
        defaults.removeObject(forKey: legacyKeyDefaultsKey)
        // The origin was never secret, but it is server-held too now and a stale local copy
        // would only mislead whoever reads it next.
        defaults.removeObject(forKey: legacyOriginDefaultsKey)
        defaults.set(true, forKey: purgeDoneDefaultsKey)
    }

    /// Does the server hold a Voca key for this user? `nil` = could not find out (no session,
    /// or the settings call failed) — callers must treat that as "carry on", never as "no".
    @discardableResult
    static func isConfigured(forceRefresh: Bool = false) async -> Bool? {
        purgeDeviceCredentialsIfNeeded()
        if !forceRefresh, let configuredCache { return configuredCache }
        guard await backendSession().isAuthenticated else { return nil }
        guard let secrets = try? await APIService.shared.fetchServerSecrets() else { return nil }
        configuredCache = secrets.hasVocaToken
        return secrets.hasVocaToken
    }

    /// Settings screens call this right after a successful save, so the next lookup does not
    /// have to re-ask the server what it just told it.
    static func noteConfiguration(hasVocaToken: Bool) {
        configuredCache = hasVocaToken
    }

    /// Drop the cached answer — on logout, or when the account behind it may have changed.
    static func invalidateConfiguration() {
        configuredCache = nil
    }

    private static func forcedHTTPS(_ value: String) -> String {
        guard value.lowercased().hasPrefix("http://") else { return value }
        return "https://" + value.dropFirst("http://".count)
    }

    static func cleanWord(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let edgeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'-"))
        while let first = text.unicodeScalars.first, !edgeCharacters.contains(first) {
            text.removeFirst()
        }
        while let last = text.unicodeScalars.last, !edgeCharacters.contains(last) {
            text.removeLast()
        }
        if text.count > 120 {
            text = String(text.prefix(120))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Requests

    private struct BackendSession {
        let serverUrl: String
        let isAuthenticated: Bool
    }

    /// This type is deliberately **not** `@MainActor` — decoding a full card sync on the main
    /// thread would be felt — but `APIService` is. So the one piece of main-actor state a
    /// request needs (the server URL, and whether there is a session at all) is read here, in
    /// a single hop, instead of scattering `MainActor.run` over every call site.
    private static func backendSession() async -> BackendSession {
        await MainActor.run {
            BackendSession(
                serverUrl: APIService.shared.serverUrl,
                isAuthenticated: APIService.shared.isAuthenticated
            )
        }
    }

    private static func backendURL(_ path: String, query: [URLQueryItem] = []) async throws -> URL {
        purgeDeviceCredentialsIfNeeded()
        let session = await backendSession()
        // Voca lives behind our authenticated proxy now, so no session means no dictionary.
        guard session.isAuthenticated else { throw VocaServiceError.notSignedIn }
        var base = session.serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard !base.isEmpty else { throw VocaServiceError.invalidURL }
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        guard var components = URLComponents(string: base + proxyPrefix + suffix) else {
            throw VocaServiceError.invalidURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw VocaServiceError.invalidURL }
        return url
    }

    /// Builds a request against the proxy. There is **no `X-API-Key` here**: the backend adds
    /// the Voca key, and the app's own Bearer token is attached by `APIService`.
    private static func makeRequest(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil,
        timeout: TimeInterval = 30,
        requiresKey: Bool = true
    ) async throws -> URLRequest {
        let url = try await backendURL(path, query: query)
        // Only say "chưa cấu hình" when the server actually said so; an unanswerable check
        // must not block a call that would have worked.
        if requiresKey, await isConfigured() == false {
            throw VocaServiceError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// The one door every JSON call goes through: unwraps the envelope, and turns anything
    /// that is not a 2xx-with-`data` into a typed `.api(status, code, message)`.
    /// `authorizedData` is `APIService`'s transport, so the Bearer token — and the single
    /// 401 → refresh → retry — stay in one place.
    private static func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await APIService.shared.authorizedData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VocaServiceError.invalidResponse("Không nhận được phản hồi từ server.")
        }

        var envelope: VocaEnvelope<T>?
        var decodeError: Error?
        do {
            envelope = try JSONDecoder().decode(VocaEnvelope<T>.self, from: data)
        } catch {
            decodeError = error
        }

        guard (200..<300).contains(http.statusCode) else {
            throw apiError(status: http.statusCode, code: envelope?.code, message: envelope?.message, data: data)
        }
        guard let envelope else {
            if let decodeError { print("[Voca] decode failed for \(request.url?.path ?? "?"): \(decodeError)") }
            throw VocaServiceError.invalidResponse("Voca trả về dữ liệu không đọc được.")
        }
        guard let payload = envelope.data else {
            throw apiError(
                status: envelope.status ?? http.statusCode,
                code: envelope.code,
                message: envelope.message,
                data: data
            )
        }
        return payload
    }

    /// Idempotent GETs only. A 429 carries no `X-RateLimit-*` header — there is no reset time
    /// to read — so back off exponentially instead of hammering the key's 120 req/min quota.
    private static func sendRetrying<T: Decodable>(
        _ request: URLRequest,
        attempts: Int = 3
    ) async throws -> T {
        var delay: UInt64 = 500_000_000
        for attempt in 1...attempts {
            do {
                let payload: T = try await send(request)
                return payload
            } catch let error as VocaServiceError {
                guard case .api(_, let code, _) = error, code == "RATE_LIMITED", attempt < attempts else {
                    throw error
                }
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
        throw VocaServiceError.api(status: 429, code: "RATE_LIMITED", message: "")
    }

    /// Same 429 backoff, for the response that is not a JSON envelope (the audio bytes).
    private static func fetchRetrying(_ request: URLRequest, attempts: Int = 3) async throws -> (Data, HTTPURLResponse) {
        var delay: UInt64 = 500_000_000
        for attempt in 1...attempts {
            let (data, response) = try await APIService.shared.authorizedData(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw VocaServiceError.audioFailed("Không nhận được phản hồi audio từ server.")
            }
            if http.statusCode == 429, attempt < attempts {
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
                continue
            }
            return (data, http)
        }
        throw VocaServiceError.api(status: 429, code: "RATE_LIMITED", message: "")
    }

    private static func apiError(status: Int, code: String?, message: String?, data: Data) -> VocaServiceError {
        let resolvedCode = code ?? ""
        var text = message ?? ""
        if resolvedCode.isEmpty {
            // No envelope: the failure came from OUR backend rather than from Voca (the proxy
            // envelopes everything it forwards). FastAPI answers `{"detail": ...}`; a dead
            // gateway answers with plain text.
            if text.isEmpty,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = json["detail"] as? String {
                text = detail
            }
            if text.isEmpty {
                let raw = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                text = String(raw.prefix(120))
            }
            // An enveloped Voca 401 arrives as a 502 by design, so a *bare* 401/403 here can
            // only be our own auth layer: the app session, not the Voca key.
            if status == 401 || status == 403 {
                return .api(status: status, code: "APP_UNAUTHORIZED", message: text)
            }
        }
        return .api(status: status, code: resolvedCode, message: text)
    }

    // MARK: Health

    /// `GET /api/voca/health` — tests the whole real path (app → backend → Voca) with the
    /// origin and key the server holds. The proxy allows it without a Voca token, so it still
    /// separates "URL sai" from "key sai".
    @discardableResult
    static func health() async throws -> VocaHealth {
        let request = try await makeRequest(path: "/health", timeout: 20, requiresKey: false)
        return try await sendRetrying(request)
    }

    // MARK: Lookup

    static func lookupWord(_ word: String) async throws -> VocaLookupResult {
        let query = cleanWord(word)
        guard !query.isEmpty else {
            return VocaLookupResult(found: false, word: "", matchType: nil, card: nil, cards: nil)
        }
        // Deliberately before the session check: a synced word stays available offline.
        if let cached = cachedLookup(query) { return cached }

        let request = try await makeRequest(
            path: "/lookup",
            query: [URLQueryItem(name: "word", value: query)]
        )
        return try await sendRetrying(request)
    }

    /// `GET /api/voca/cards/{slug}` — the full card behind a lookup hit.
    static func fetchCard(slug: String) async throws -> VocaCard {
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        guard !encoded.isEmpty else { throw VocaServiceError.invalidURL }
        let request = try await makeRequest(path: "/cards/\(encoded)")
        return try await sendRetrying(request)
    }

    // MARK: Create

    /// `POST /api/voca/create` — plain JSON, **not** a stream, and no `settings` object: the
    /// LLM runs server-side at Voca, so this works without the user's own LLM config.
    /// Generation regularly takes several seconds, hence the long timeout.
    @discardableResult
    static func addWordToVoca(_ word: String) async throws -> VocaCard {
        let normalized = cleanWord(word)
        guard !normalized.isEmpty else { throw VocaServiceError.missingWord }
        let request = try await makeRequest(
            path: "/create",
            method: "POST",
            body: ["word": normalized],
            timeout: 120
        )
        return try await send(request)
    }

    // MARK: Incremental sync + local store

    /// `GET /api/voca/cards?ifChangedSince=<version>` — sends the cached version so an
    /// unchanged dictionary comes back as `changed:false` with no card payload at all.
    @discardableResult
    static func syncCards(force: Bool = false) async throws -> VocaCardsSnapshot {
        let cached = force ? nil : cachedSnapshot()
        var query: [URLQueryItem] = []
        if let version = cached?.version, !version.isEmpty {
            query.append(URLQueryItem(name: "ifChangedSince", value: version))
        }
        let request = try await makeRequest(path: "/cards", query: query, timeout: 60)
        let page: VocaCardsPage = try await sendRetrying(request)

        if page.changed == false, let cached {
            return cached
        }
        let snapshot = VocaCardsSnapshot(
            version: page.version ?? cached?.version ?? "",
            cards: page.cards ?? cached?.cards ?? []
        )
        writeSnapshot(snapshot)
        return snapshot
    }

    /// Kept in memory as well as on disk: `lookupWord` consults it on every tap, and the file
    /// holds the whole dictionary.
    static func cachedSnapshot() -> VocaCardsSnapshot? {
        if let snapshotCache { return snapshotCache }
        guard let url = cardsCacheURL, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(VocaCardsSnapshot.self, from: data)
        else { return nil }
        snapshotCache = snapshot
        return snapshot
    }

    /// Also the "this deck may belong to another account now" reset — call it on logout and
    /// whenever the server-side Voca configuration changes.
    static func clearCardsCache() {
        snapshotCache = nil
        guard let url = cardsCacheURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Exact match against the synced store; `nil` means "ask the server". Partial matches
    /// stay server-side so the local store can never silently shrink a result set.
    static func cachedLookup(_ word: String) -> VocaLookupResult? {
        let query = cleanWord(word).lowercased()
        guard !query.isEmpty, let snapshot = cachedSnapshot(), !snapshot.cards.isEmpty else { return nil }
        guard let match = snapshot.cards.first(where: { $0.word.lowercased() == query }) else { return nil }
        return VocaLookupResult(found: true, word: match.word, matchType: "exact", card: match, cards: nil)
    }

    private static var cardsCacheURL: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        if !fm.fileExists(atPath: base.path) {
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        }
        return base.appendingPathComponent(cardsCacheFileName)
    }

    private static func writeSnapshot(_ snapshot: VocaCardsSnapshot) {
        snapshotCache = snapshot
        guard let url = cardsCacheURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Audio

    /// Shown once per session when the device voice stands in for Voca. Informational, not an
    /// error — the word still gets pronounced, just not by Voca.
    static let deviceFallbackNotice = "Voca chưa bật TTS — đang đọc bằng giọng thiết bị."
    private static var announcedDeviceFallback = false

    /// The entry point the reader uses: honours `VocaAudioSource` and the fallback rule.
    ///
    /// - `device`: speak immediately, no network at all.
    /// - `voca`:   Voca only; whatever it fails with is what the caller sees.
    /// - `auto`:   try Voca; fall back to speaking the word for **any** failure except a Voca
    ///             `UNAUTHORIZED`. That one code means the user has to fix their key, and
    ///             speaking anyway would hide a real misconfiguration behind a button that
    ///             looks like it works. Everything else — `TTS_NOT_CONFIGURED`,
    ///             `AUDIO_NOT_FOUND` after a generate attempt, `RATE_LIMITED`,
    ///             `VOCA_UNREACHABLE`, `UPSTREAM_ERROR`, no session, no key, a dead network —
    ///             falls back.
    @discardableResult
    static func playCardAudio(_ card: VocaCard) async throws -> VocaAudioOutcome {
        try await playCardAudio(slug: card.slug, word: card.word)
    }

    /// `word` is what the device would say; pass it whenever the caller has the card, since the
    /// reader panel hands back a slug only. Empty means "look it up, and if that fails there is
    /// nothing to fall back to".
    @discardableResult
    static func playCardAudio(slug: String, word: String = "") async throws -> VocaAudioOutcome {
        // D4: the card's `word`, in English. `meaningVi` is never spoken.
        let spoken = spokenWord(slug: slug, word: word)

        switch VocaAudioSource.current {
        case .device:
            // Chosen deliberately, so a speech failure IS the error — there is nothing to hide.
            try await DeviceSpeech.shared.speak(spoken)
            return .device(notice: nil)

        case .voca:
            try await playAudio(slug: slug)
            return .voca

        case .auto:
            do {
                try await playAudio(slug: slug)
                return .voca
            } catch let vocaError {
                guard shouldFallBackToDevice(from: vocaError) else { throw vocaError }
                // A cancelled Voca fetch means the caller walked away — do not start talking.
                try Task.checkCancellation()
                guard !spoken.isEmpty, DeviceSpeech.shared.isAvailable else { throw vocaError }
                do {
                    try await DeviceSpeech.shared.speak(spoken)
                } catch is CancellationError {
                    // A newer tap took over, or the caller went away. Not a failure to report.
                    throw CancellationError()
                } catch {
                    // The device could not stand in either (a live companion conversation owns
                    // the audio session, no voice installed, …). The user still needs the REAL
                    // reason there is no audio, so surface Voca's error, not the speech one.
                    print("[Voca] device speech fallback failed: \(error)")
                    throw vocaError
                }
                return .device(notice: takeDeviceFallbackNotice())
            }
        }
    }

    /// D1: only a Voca `UNAUTHORIZED` blocks the fallback. NOTE: `FORBIDDEN` and
    /// `APP_UNAUTHORIZED` describe the same "fix your credentials" situation and arguably
    /// belong here too, but the rule as specified names `UNAUTHORIZED` alone, so that is what
    /// this implements — widening it is a product decision, not a cleanup.
    private static func shouldFallBackToDevice(from error: Error) -> Bool {
        if let vocaError = error as? VocaServiceError, case .api(_, let code, _) = vocaError {
            return code != "UNAUTHORIZED"
        }
        return true
    }

    /// The reader panel calls back with a slug only; the synced snapshot knows the word.
    private static func spokenWord(slug: String, word: String) -> String {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return cachedSnapshot()?.cards.first(where: { $0.slug == slug })?.word ?? ""
    }

    /// One per session (D3): repeating it on every word would be noise.
    private static func takeDeviceFallbackNotice() -> String? {
        guard !announcedDeviceFallback else { return nil }
        announcedDeviceFallback = true
        return deviceFallbackNotice
    }

    /// `GET /api/voca/audio/{slug}` streams raw mp3 through the proxy — it is **not**
    /// enveloped, so success is never JSON-decoded. A 404 `AUDIO_NOT_FOUND` means nothing has
    /// been generated yet: POST once (that one *is* enveloped), then re-GET the same proxy
    /// path. The `audioUrl` the POST returns is a Voca-side path we must not call directly.
    ///
    /// This is the Voca-only leg; readers call `playCardAudio` so the audio-source preference
    /// and the device fallback apply.
    static func playAudio(slug: String) async throws {
        let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        guard !encoded.isEmpty else { throw VocaServiceError.audioFailed("Thẻ không có slug để phát audio.") }

        let getRequest = try await makeRequest(path: "/audio/\(encoded)", timeout: 60)
        var (data, http) = try await fetchRetrying(getRequest)

        if http.statusCode == 404 {
            let voiceModel = (UserDefaults.standard.string(forKey: "ttsModel") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let generateRequest = try await makeRequest(
                path: "/audio/\(encoded)",
                method: "POST",
                body: ["voiceModel": voiceModel.isEmpty ? defaultTTSModel : voiceModel],
                timeout: 120
            )
            // Decoded for its envelope, not its payload: a failed generation must surface as
            // `.api(...)` here rather than as an empty second fetch.
            let _: VocaAudioRef = try await send(generateRequest)
            (data, http) = try await fetchRetrying(getRequest)
        }

        guard (200..<300).contains(http.statusCode) else {
            // A failed audio GET answers with the normal JSON envelope, not audio bytes.
            let envelope = try? JSONDecoder().decode(VocaEnvelope<VocaScalar>.self, from: data)
            throw apiError(status: http.statusCode, code: envelope?.code, message: envelope?.message, data: data)
        }
        guard !data.isEmpty else {
            throw VocaServiceError.audioFailed("Voca trả về audio rỗng.")
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("voca-\(slug).mp3")
        try data.write(to: tempURL, options: .atomic)
        await MainActor.run {
            audioPlayer = AVPlayer(url: tempURL)
            audioPlayer?.play()
        }
    }

    // MARK: Practice (SSE)

    /// `POST /api/voca/practice/drills` — streamed, returns the parsed JSON payload once done.
    static func practiceDrills(
        count: Int? = nil,
        selectedWord: String? = nil,
        onDelta: ((String) -> Void)? = nil
    ) async throws -> Any {
        var body: [String: Any] = [:]
        if let count { body["count"] = count }
        if let selectedWord, !selectedWord.isEmpty { body["selectedWord"] = selectedWord }
        return try await streamPracticeJSON(path: "/practice/drills", body: body, onDelta: onDelta)
    }

    /// `POST /api/voca/practice/reading` — `format` is `part6` or `part7`.
    static func practiceReading(
        format: String? = nil,
        selectedWord: String? = nil,
        onDelta: ((String) -> Void)? = nil
    ) async throws -> Any {
        var body: [String: Any] = [:]
        if let format, !format.isEmpty { body["format"] = format }
        if let selectedWord, !selectedWord.isEmpty { body["selectedWord"] = selectedWord }
        return try await streamPracticeJSON(path: "/practice/reading", body: body, onDelta: onDelta)
    }

    /// Practice endpoints are the only ones that are not enveloped: they stream OpenAI
    /// `chat.completion.chunk` lines (the proxy passes the stream through untouched).
    /// Concatenating `choices[0].delta.content` across chunks yields one JSON payload, which
    /// is parsed after `data: [DONE]`.
    private static func streamPracticeJSON(
        path: String,
        body: [String: Any],
        onDelta: ((String) -> Void)?
    ) async throws -> Any {
        var request = try await makeRequest(path: path, method: "POST", body: body, timeout: 180)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await APIService.shared.authorizedBytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VocaServiceError.invalidResponse("Không nhận được phản hồi từ server.")
        }
        guard (200..<300).contains(http.statusCode) else {
            // A failure before the stream starts still comes back as the JSON envelope.
            var raw = Data()
            for try await byte in bytes { raw.append(byte) }
            let envelope = try? JSONDecoder().decode(VocaEnvelope<VocaScalar>.self, from: raw)
            throw apiError(status: http.statusCode, code: envelope?.code, message: envelope?.message, data: raw)
        }

        var content = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            guard let chunk = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: chunk) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let piece = delta["content"] as? String
            else { continue }
            content += piece
            onDelta?(piece)
        }

        return try parseStreamedJSON(content)
    }

    private static func parseStreamedJSON(_ raw: String) throws -> Any {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The model occasionally wraps its JSON in a markdown fence.
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "^```[a-zA-Z]*\\s*", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "```$", with: "", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty, let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            throw VocaServiceError.invalidResponse("Voca trả về nội dung luyện tập không đọc được.")
        }
        return json
    }
}
