import Foundation
import Combine

struct AppFeatureConfig: Codable, Equatable {
    struct Features: Codable, Equatable {
        let audiobookEnabled: Bool

        init(audiobookEnabled: Bool = false) {
            self.audiobookEnabled = audiobookEnabled
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.audiobookEnabled = try container.decodeIfPresent(Bool.self, forKey: .audiobookEnabled) ?? false
        }
    }

    let features: Features

    init(audiobookEnabled: Bool = false) {
        self.features = Features(audiobookEnabled: audiobookEnabled)
    }

    static var clientDefault: AppFeatureConfig {
        let bundled = (Bundle.main.object(forInfoDictionaryKey: "ENABLE_AUDIOBOOK") as? Bool) ?? false
        return AppFeatureConfig(audiobookEnabled: bundled)
    }
}

class APIService: ObservableObject {
    static let shared = APIService()

    @Published var serverUrl: String {
        didSet {
            UserDefaults.standard.set(serverUrl, forKey: "serverUrl")
        }
    }

    @Published var token: String {
        didSet {
            KeychainHelper.standard.save(token, forKey: "jwtToken")
        }
    }

    @Published var refreshToken: String {
        didSet {
            KeychainHelper.standard.save(refreshToken, forKey: "refreshToken")
        }
    }

    @Published var currentUser: User?
    @Published var isAuthenticated: Bool = false
    @Published var isVerifyingSession: Bool = true
    @Published var isOfflineMode: Bool = false
    @Published var isServerReachable: Bool = true
    @Published var books: [Book] = []
    @Published var highlights: [Highlight] = []
    @Published var isAudiobookEnabled: Bool = AppFeatureConfig.clientDefault.features.audiobookEnabled

    private var refreshTask: Task<Bool, Never>?

    private init() {
        let savedUrl = UserDefaults.standard.string(forKey: "serverUrl") ?? "https://book.thaonv.online"
        self.serverUrl = savedUrl
        let savedToken = KeychainHelper.standard.get(forKey: "jwtToken") ?? ""
        self.token = savedToken
        let savedRefresh = KeychainHelper.standard.get(forKey: "refreshToken") ?? ""
        self.refreshToken = savedRefresh

        if let cachedUsername = UserDefaults.standard.string(forKey: "cachedUsername"), !cachedUsername.isEmpty {
            let cachedAdmin = UserDefaults.standard.bool(forKey: "cachedIsAdmin")
            self.currentUser = User(username: cachedUsername, isAdmin: cachedAdmin)
        }

        if !savedToken.isEmpty {
            self.isAuthenticated = true
            Task { @MainActor in
                await self.verifyToken()
                await self.fetchAppConfig()
            }
        } else {
            self.isVerifyingSession = false
            Task { @MainActor in
                await self.fetchAppConfig()
            }
        }
    }

    var normalizedServerUrl: String {
        serverUrl
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: - Authenticated Requests

    @discardableResult
    private func sendRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var req = request
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            let refreshed = await refreshAccessToken()
            if refreshed {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return try await URLSession.shared.data(for: req)
            }
        }
        return (data, response)
    }

    func authorizedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await sendRequest(request)
    }

    func authorizedBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var req = request
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            let refreshed = await refreshAccessToken()
            if refreshed {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return try await URLSession.shared.bytes(for: req)
            }
        }
        return (bytes, response)
    }

    // MARK: - Auth

    func login(url: String, username: String, password: String) async throws {
        let cleanUrl = url.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let apiUrl = URL(string: "\(cleanUrl)/api/auth/login") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: apiUrl)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: String] = ["username": username, "password": password]
        request.httpBody = try? JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Đăng nhập thất bại"
            throw NSError(domain: "APIService", code: (response as? HTTPURLResponse)?.statusCode ?? 401, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        let decoded = try JSONDecoder().decode(LoginResponse.self, from: data)
        await MainActor.run {
            self.serverUrl = cleanUrl
            self.token = decoded.accessToken
            self.refreshToken = decoded.refreshToken ?? ""
            self.currentUser = User(username: decoded.username, isAdmin: decoded.isAdmin)
            UserDefaults.standard.set(decoded.username, forKey: "cachedUsername")
            UserDefaults.standard.set(decoded.isAdmin, forKey: "cachedIsAdmin")
            self.isAuthenticated = true
            self.isVerifyingSession = false
            self.isOfflineMode = false
            self.isServerReachable = true
        }
        await fetchAppConfig()
    }

    @MainActor
    func enterOfflineVaultSession(username: String, isAdmin: Bool) {
        self.currentUser = User(username: username.isEmpty ? "offline_vault" : username, isAdmin: isAdmin)
        self.isAuthenticated = true
        self.isVerifyingSession = false
        self.isOfflineMode = true
        self.isServerReachable = false
    }

    func verifyToken() async {
        guard !token.isEmpty else {
            await MainActor.run {
                self.isAuthenticated = false
                self.isVerifyingSession = false
            }
            return
        }

        await MainActor.run {
            self.isVerifyingSession = true
        }

        guard let url = URL(string: "\(normalizedServerUrl)/api/auth/me") else {
            await MainActor.run {
                self.isOfflineMode = true
                self.isServerReachable = false
                self.isVerifyingSession = false
            }
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    let user = try JSONDecoder().decode(User.self, from: data)
                    await MainActor.run {
                        self.currentUser = user
                        UserDefaults.standard.set(user.username, forKey: "cachedUsername")
                        UserDefaults.standard.set(user.isAdmin, forKey: "cachedIsAdmin")
                        self.isAuthenticated = true
                        self.isOfflineMode = false
                        self.isServerReachable = true
                        self.isVerifyingSession = false
                    }
                    return
                } else if httpResponse.statusCode == 401 {
                    let refreshed = await refreshAccessToken()
                    if !refreshed {
                        await logout()
                    }
                    await MainActor.run { self.isVerifyingSession = false }
                    return
                }
            }
            await MainActor.run {
                self.isOfflineMode = true
                self.isServerReachable = false
                self.isVerifyingSession = false
            }
        } catch {
            // Preserve local session in Offline Vault Mode when server is down/unreachable
            await MainActor.run {
                self.isOfflineMode = true
                self.isServerReachable = false
                self.isVerifyingSession = false
            }
        }
    }

    func refreshAccessToken() async -> Bool {
        if let existing = refreshTask {
            return await existing.value
        }

        let task = Task<Bool, Never> {
            guard !refreshToken.isEmpty, let url = URL(string: "\(normalizedServerUrl)/api/auth/refresh") else {
                return false
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
            request.timeoutInterval = 10

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let newAccess = json["access_token"] as? String {
                    let newRefresh = json["refresh_token"] as? String
                    let uname = json["username"] as? String
                    let isAdmin = json["is_admin"] as? Bool
                    await MainActor.run {
                        self.token = newAccess
                        if let nr = newRefresh { self.refreshToken = nr }
                        if let u = uname, let a = isAdmin {
                            self.currentUser = User(username: u, isAdmin: a)
                        }
                        self.isAuthenticated = true
                        self.isOfflineMode = false
                        self.isServerReachable = true
                    }
                    return true
                }
            } catch {
                return false
            }
            return false
        }

        self.refreshTask = task
        let result = await task.value
        self.refreshTask = nil
        return result
    }

    @MainActor
    func logout() {
        token = ""
        refreshToken = ""
        currentUser = nil
        UserDefaults.standard.removeObject(forKey: "cachedUsername")
        UserDefaults.standard.removeObject(forKey: "cachedIsAdmin")
        isAuthenticated = false
        isOfflineMode = false
        books = []
        highlights = []
    }

    func pingServer() async -> Bool {
        guard let url = URL(string: "\(normalizedServerUrl)/api/config") else {
            await MainActor.run { self.isServerReachable = false }
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            await MainActor.run {
                self.isServerReachable = ok
                if ok { self.isOfflineMode = false }
            }
            return ok
        } catch {
            await MainActor.run { self.isServerReachable = false }
            return false
        }
    }

    // MARK: - Books & Reader APIs

    func fetchBooks() async throws {
        guard let url = URL(string: "\(normalizedServerUrl)/api/books") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        let (data, response) = try await sendRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode([Book].self, from: data)
        await MainActor.run {
            self.books = BookSort.sortedShelf(decoded)
            self.isOfflineMode = false
            self.isServerReachable = true
        }
    }

    @discardableResult
    func updateBookState(
        slug: String,
        isFinished: Bool? = nil,
        onShelf: Bool? = nil,
        isPriority: Bool? = nil,
        readerFont: String? = nil,
        readerTheme: String? = nil
    ) async -> Bool {
        guard let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/state") else {
            return false
        }
        var body: [String: Any] = [:]
        if let v = isFinished { body["isFinished"] = v }
        if let v = onShelf { body["onShelf"] = v }
        if let v = isPriority { body["isPriority"] = v }
        if let v = readerFont { body["readerFont"] = v }
        if let v = readerTheme { body["readerTheme"] = v }
        guard !body.isEmpty else { return true }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await sendRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            if let decoded = try? JSONDecoder().decode(BookState.self, from: data) {
                await MainActor.run {
                    if let idx = self.books.firstIndex(where: { $0.slug == slug }) {
                        if let v = decoded.isFinished { self.books[idx].isFinished = v }
                        if let v = decoded.onShelf { self.books[idx].onShelf = v }
                        if let v = decoded.isPriority { self.books[idx].isPriority = v }
                        if let v = decoded.readerFont { self.books[idx].readerFont = v }
                        if let v = decoded.readerTheme { self.books[idx].readerTheme = v }
                    }
                }
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func updateBookAppearanceDefaults(slug: String, defaultFont: String, defaultTheme: String) async -> Bool {
        guard let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/appearance-defaults") else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "defaultFont": defaultFont,
            "defaultTheme": defaultTheme,
        ])
        do {
            let (_, response) = try await sendRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            await MainActor.run {
                if let idx = self.books.firstIndex(where: { $0.slug == slug }) {
                    self.books[idx].defaultFont = defaultFont
                    self.books[idx].defaultTheme = defaultTheme
                }
            }
            return true
        } catch {
            return false
        }
    }

    func fetchHighlights(slug: String) async {
        guard let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/highlights") else { return }
        do {
            let (data, response) = try await sendRequest(URLRequest(url: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            struct Resp: Codable { let highlights: [Highlight] }
            let decoded = try JSONDecoder().decode(Resp.self, from: data)
            await MainActor.run { self.highlights = decoded.highlights }
        } catch {}
    }

    func saveHighlight(slug: String, highlight: Highlight) async {
        await MainActor.run {
            if let idx = self.highlights.firstIndex(where: { $0.id == highlight.id }) {
                self.highlights[idx] = highlight
            } else {
                self.highlights.append(highlight)
            }
        }
        guard let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/highlights") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(highlight)
        _ = try? await sendRequest(request)
    }

    func deleteHighlight(slug: String, id: String) async {
        await MainActor.run {
            self.highlights.removeAll { $0.id == id }
        }
        guard let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/highlights/\(encodedId)") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try? await sendRequest(request)
    }

    func fetchReadingProgress(slug: String) async -> ReadingProgress? {
        guard let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/progress") else { return nil }
        do {
            let (data, response) = try await sendRequest(URLRequest(url: url))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let serverProgress = try JSONDecoder().decode(ReadingProgress.self, from: data)
            cacheReadingProgressIfNewer(serverProgress, forSlug: slug)
            return serverProgress
        } catch {
            return nil
        }
    }

    func saveReadingProgress(slug: String, page: Int, viewMode: String, lastRead: Int) async {
        let localProgress = ReadingProgress(page: page, viewMode: viewMode, lastRead: lastRead)
        if let encoded = try? JSONEncoder().encode(localProgress) {
            UserDefaults.standard.set(encoded, forKey: "progress_\(slug)")
        }
        await MainActor.run {
            if let idx = self.books.firstIndex(where: { $0.slug == slug }) {
                self.books[idx].lastRead = max(self.books[idx].lastRead ?? 0, lastRead)
            }
            NotificationCenter.default.post(name: NSNotification.Name("ReadingProgressUpdated"), object: nil)
        }

        guard let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/progress") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "page": page,
            "viewMode": viewMode,
            "lastRead": lastRead,
        ])
        _ = try? await sendRequest(request)
    }

    private func cacheReadingProgressIfNewer(_ progress: ReadingProgress, forSlug slug: String) {
        if let existingData = UserDefaults.standard.data(forKey: "progress_\(slug)"),
           let existing = try? JSONDecoder().decode(ReadingProgress.self, from: existingData),
           let existingTs = existing.lastRead,
           let incomingTs = progress.lastRead,
           incomingTs < existingTs {
            return
        }
        if let data = try? JSONEncoder().encode(progress) {
            UserDefaults.standard.set(data, forKey: "progress_\(slug)")
        }
    }

    func sendChat(baseURL: String, apiKey: String, model: String, messages: [[String: String]]) async throws -> String {
        guard let url = URL(string: "\(normalizedServerUrl)/api/chat") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "baseURL": baseURL,
            "apiKey": apiKey,
            "model": model,
            "messages": messages,
        ])
        request.timeoutInterval = 60

        let (data, response) = try await sendRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Lỗi AI Server"
            throw NSError(domain: "APIService", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errorText])
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let msg = choices.first?["message"] as? [String: Any],
           let content = msg["content"] as? String {
            return content
        }
        throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Phản hồi AI không hợp lệ"])
    }

    // MARK: - App Config & Settings

    func fetchAppConfig() async {
        guard let url = URL(string: "\(normalizedServerUrl)/api/config") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(AppFeatureConfig.self, from: data)
            await MainActor.run {
                self.isAudiobookEnabled = decoded.features.audiobookEnabled
                self.isServerReachable = true
            }
        } catch {}
    }

    struct ServerSettings: Codable {
        let provider: String
        let baseURL: String
        let model: String
        let realtimeModel: String
        let realtimeVoice: String
        let hasLlmKey: Bool
        let hasRealtimeKey: Bool
        let audioProvider: String
        let audioSource: String
        let audioVoice: String
        let audioVoiceEn: String
        let audioVoiceVi: String
        let ttsModel: String
        let speechSpeed: String
        let hasAzureKey: Bool
        let hasElevenLabsKey: Bool
        let layoutMode: String
        let hideFinishedBooks: Bool
        let vocaOrigin: String
        let hasVocaToken: Bool
    }

    func fetchServerSettings() async throws -> ServerSettings {
        guard let url = URL(string: "\(normalizedServerUrl)/api/user/settings") else { throw URLError(.badURL) }
        let (data, response) = try await sendRequest(URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ServerSettings.self, from: data)
    }

    func fetchServerSecrets() async throws -> ServerSettings {
        try await fetchServerSettings()
    }

    @discardableResult
    func saveServerSettings(
        provider: String? = nil,
        baseURL: String? = nil,
        model: String? = nil,
        llmApiKey: String? = nil,
        audioSource: String? = nil,
        layoutMode: String? = nil,
        hideFinishedBooks: Bool? = nil,
        vocaOrigin: String? = nil,
        vocaToken: String? = nil
    ) async throws -> ServerSettings {
        guard let url = URL(string: "\(normalizedServerUrl)/api/user/settings") else { throw URLError(.badURL) }
        var body: [String: Any] = [:]
        if let v = provider { body["provider"] = v }
        if let v = baseURL { body["baseURL"] = v }
        if let v = model { body["model"] = v }
        if let v = llmApiKey { body["llmApiKey"] = v }
        if let v = audioSource { body["audioSource"] = v }
        if let v = layoutMode { body["layoutMode"] = v }
        if let v = hideFinishedBooks { body["hideFinishedBooks"] = v }
        if let v = vocaOrigin { body["vocaOrigin"] = v }
        if let v = vocaToken { body["vocaToken"] = v }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await sendRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errText = String(data: data, encoding: .utf8) ?? "Không lưu được cài đặt"
            throw NSError(domain: "APIService", code: (response as? HTTPURLResponse)?.statusCode ?? 400, userInfo: [NSLocalizedDescriptionKey: errText])
        }
        return try JSONDecoder().decode(ServerSettings.self, from: data)
    }

    func fetchBookCoverData(coverPath: String) async -> Data? {
        let clean = coverPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty, let url = URL(string: "\(normalizedServerUrl)/\(clean)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await sendRequest(request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else {
            return nil
        }
        return data
    }

    // MARK: - Backup & Emergency Restore APIs

    func fetchBackupManifest() async throws -> BackupManifest {
        guard let url = URL(string: "\(normalizedServerUrl)/api/backup/manifest") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await sendRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errText = String(data: data, encoding: .utf8) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 500)"
            throw NSError(domain: "BackupAPI", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errText])
        }
        return try JSONDecoder().decode(BackupManifest.self, from: data)
    }

    func exportBackupSnapshot(includeSecrets: Bool) async throws -> BackupSnapshot {
        let flag = includeSecrets ? "true" : "false"
        guard let url = URL(string: "\(normalizedServerUrl)/api/backup/export?include_secrets=\(flag)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (data, response) = try await sendRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errText = String(data: data, encoding: .utf8) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 500)"
            throw NSError(domain: "BackupAPI", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errText])
        }
        return try JSONDecoder().decode(BackupSnapshot.self, from: data)
    }

    func downloadBookArchive(slug: String, to destinationURL: URL) async throws {
        let safeSlug = try BookArchiveExtractor.validateSlug(slug)
        guard let encodedSlug = safeSlug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/download") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        let (data, response) = try await sendRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errText = String(data: data, encoding: .utf8) ?? "Download .bkb thất bại"
            throw NSError(domain: "BackupAPI", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errText])
        }
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destinationURL, options: .atomic)
    }

    func uploadBookArchive(fileURL: URL) async throws -> String {
        guard let url = URL(string: "\(normalizedServerUrl)/api/books/upload") else {
            throw URLError(.badURL)
        }
        let fileData = try Data(contentsOf: fileURL)
        let boundary = "Boundary-\(UUID().uuidString)"

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 300

        let (data, response) = try await sendRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errText = String(data: data, encoding: .utf8) ?? "Upload .bkb thất bại"
            throw NSError(domain: "BackupAPI", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errText])
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let slug = json["slug"] as? String {
            return slug
        }
        return fileURL.deletingPathExtension().lastPathComponent
    }

    func restoreBackupSnapshot(_ restoreRequest: BackupRestoreRequest) async throws -> BackupRestoreResponse {
        guard let url = URL(string: "\(normalizedServerUrl)/api/backup/restore") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(restoreRequest)
        request.timeoutInterval = 120

        let (data, response) = try await sendRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errText = String(data: data, encoding: .utf8) ?? "Restore thất bại"
            throw NSError(domain: "BackupAPI", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errText])
        }
        return try JSONDecoder().decode(BackupRestoreResponse.self, from: data)
    }
}
