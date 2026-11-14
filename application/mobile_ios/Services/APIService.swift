import Foundation
import Network

@MainActor
class APIService: ObservableObject {
    @Published var serverUrl: String = "https://books.thaonv.online"
    @Published var token: String = ""
    @Published var refreshToken: String = ""
    @Published var username: String = ""
    @Published var isAdmin: Bool = false
    @Published var isAuthenticated: Bool = false
    @Published var isVerifyingSession: Bool = false
    @Published var isNetworkAvailable: Bool = true
    @Published var isOfflineMode: Bool = false
    @Published var isServerReachable: Bool = true
    @Published var isAudiobookEnabled: Bool = AppFeatureFlags.clientDefault.audiobookEnabled

    // Shared highlights state scoped to the active book slug
    @Published var highlights: [Highlight] = []
    private var currentHighlightsSlug: String?
    private var isSyncingOfflineOps: Bool = false
    private var pathMonitor: NWPathMonitor?

    static let shared = APIService()

    var normalizedServerUrl: String {
        serverUrl
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private init() {
        // First run after the Voca-through-the-proxy switch: drop the API key the old build
        // kept on the device, so a stale local copy cannot linger. No-op afterwards.
        VocaService.purgeDeviceCredentialsIfNeeded()

        // Migrate legacy plaintext tokens from UserDefaults into Keychain if present
        if let legacyToken = UserDefaults.standard.string(forKey: "token"), !legacyToken.isEmpty {
            KeychainHelper.save(key: "auth.accessToken", value: legacyToken)
            UserDefaults.standard.removeObject(forKey: "token")
        }
        if let legacyRefresh = UserDefaults.standard.string(forKey: "refreshToken"), !legacyRefresh.isEmpty {
            KeychainHelper.save(key: "auth.refreshToken", value: legacyRefresh)
            UserDefaults.standard.removeObject(forKey: "refreshToken")
        }

        // Load saved session from Keychain
        if let savedToken = KeychainHelper.load(key: "auth.accessToken"), !savedToken.isEmpty {
            self.token = savedToken
            self.refreshToken = KeychainHelper.load(key: "auth.refreshToken") ?? ""
            self.serverUrl = UserDefaults.standard.string(forKey: "serverUrl") ?? "https://books.thaonv.online"
            self.username = ServerUsernameHack()
            self.isAdmin = UserDefaults.standard.bool(forKey: "isAdmin")
            self.isAuthenticated = true

            BookCacheManager.shared.refreshPendingCount(serverUrl: self.normalizedServerUrl, username: self.username)
            let hasOfflineShelf = BookCacheManager.shared.hasAnyOfflineBooks(
                serverUrl: self.normalizedServerUrl,
                username: self.username
            )
            // When cached offline books exist, enter BookshelfView immediately without blocking on network.
            self.isVerifyingSession = !hasOfflineShelf

            Task {
                await self.fetchAppConfig()
                await self.verifySession()
            }
        } else {
            Task { await self.fetchAppConfig() }
        }

        startNetworkMonitor()
    }

    deinit {
        pathMonitor?.cancel()
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasAvailable = self.isNetworkAvailable
                self.isNetworkAvailable = reachable

                if !reachable {
                    self.isOfflineMode = true
                    self.isServerReachable = false
                } else if !wasAvailable && self.isAuthenticated {
                    self.isOfflineMode = false
                    await self.syncPendingOfflineOperations()
                    NotificationCenter.default.post(name: NSNotification.Name("NetworkConnectivityRestored"), object: nil)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.bilingual.reader.network", qos: .utility))
        self.pathMonitor = monitor
    }

    private func ServerUsernameHack() -> String {
        return UserDefaults.standard.string(forKey: "username") ?? ""
    }

    /// Verify the saved session is still valid on app launch.
    /// Preserves session in offline mode on connectivity failures; logs out only on auth rejection.
    func verifySession() async {
        defer { isVerifyingSession = false }

        guard !token.isEmpty else {
            logout()
            return
        }

        guard isNetworkAvailable else {
            isOfflineMode = true
            isServerReachable = false
            return
        }

        guard let url = URL(string: "\(normalizedServerUrl)/api/auth/me") else {
            isOfflineMode = true
            isServerReachable = false
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6.0
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.username = json["username"] as? String ?? self.username
                        self.isAdmin = json["is_admin"] as? Bool ?? self.isAdmin
                        UserDefaults.standard.set(self.username, forKey: "username")
                        UserDefaults.standard.set(self.isAdmin, forKey: "isAdmin")
                    }
                    self.isOfflineMode = false
                    self.isServerReachable = true
                    await syncPendingOfflineOperations()
                    return
                } else if httpResponse.statusCode == 401 {
                    do {
                        _ = try await performTokenRefresh()
                        self.isOfflineMode = false
                        self.isServerReachable = true
                        await syncPendingOfflineOperations()
                        return
                    } catch {
                        // performTokenRefresh() calls logout() on 400/401/403; network failures preserve session.
                        if isConnectivityFailure(error) {
                            self.isOfflineMode = true
                            self.isServerReachable = false
                        }
                        return
                    }
                }
            }
            self.isOfflineMode = true
            self.isServerReachable = false
        } catch {
            self.isOfflineMode = true
            self.isServerReachable = false
            print("[APIService] Session verify failed (offline/network): \(error.localizedDescription)")
        }
    }
    
    func login(usernameInput: String, passwordInput: String) async throws -> Bool {
        let cleanUrl = normalizedServerUrl
        guard let url = URL(string: "\(cleanUrl)/api/auth/login") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15.0
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "username": usernameInput,
            "password": passwordInput
        ])
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "APIService", code: 401, userInfo: [NSLocalizedDescriptionKey: "Sai tài khoản hoặc mật khẩu"])
        }
        
        let decoder = JSONDecoder()
        let result = try decoder.decode(LoginResponse.self, from: data)
        
        self.token = result.accessToken
        self.refreshToken = result.refreshToken
        self.username = result.username
        self.isAdmin = result.isAdmin
        self.isAuthenticated = true
        self.isOfflineMode = false
        self.isServerReachable = true
        self.serverUrl = cleanUrl
        self.currentHighlightsSlug = nil
        
        // Save tokens to Keychain and non-sensitive profile metadata to UserDefaults
        KeychainHelper.save(key: "auth.accessToken", value: self.token)
        KeychainHelper.save(key: "auth.refreshToken", value: self.refreshToken)
        UserDefaults.standard.set(cleanUrl, forKey: "serverUrl")
        UserDefaults.standard.set(self.username, forKey: "username")
        UserDefaults.standard.set(self.isAdmin, forKey: "isAdmin")

        BookCacheManager.shared.refreshPendingCount(serverUrl: cleanUrl, username: self.username)
        await fetchAppConfig()
        
        return true
    }
    
    func logout() {
        let savedToken = token
        let savedRefreshToken = refreshToken
        let savedUrl = normalizedServerUrl
        
        token = ""
        refreshToken = ""
        isAuthenticated = false
        isAdmin = false
        isOfflineMode = false
        username = ""
        highlights = []
        currentHighlightsSlug = nil
        BookCacheManager.shared.pendingSyncCount = 0
        
        KeychainHelper.delete(key: "auth.accessToken")
        KeychainHelper.delete(key: "auth.refreshToken")
        UserDefaults.standard.removeObject(forKey: "token")
        UserDefaults.standard.removeObject(forKey: "refreshToken")
        UserDefaults.standard.removeObject(forKey: "username")
        UserDefaults.standard.removeObject(forKey: "isAdmin")

        // Voca is server-configured per user now, so both its "is a key stored?" answer and
        // the synced dictionary belong to the account that just left.
        VocaService.invalidateConfiguration()
        VocaService.clearCardsCache()

        // Notify server with the saved token and refresh token so the DB session is revoked
        if (!savedToken.isEmpty || !savedRefreshToken.isEmpty), let url = URL(string: "\(savedUrl)/api/auth/logout") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            if !savedToken.isEmpty {
                request.setValue("Bearer \(savedToken)", forHTTPHeaderField: "Authorization")
            }
            if !savedRefreshToken.isEmpty {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": savedRefreshToken])
            }
            URLSession.shared.dataTask(with: request).resume()
        }
    }
    
    // Perform automatic token refresh
    func performTokenRefresh() async throws -> String {
        guard let url = URL(string: "\(normalizedServerUrl)/api/auth/refresh") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload = ["refresh_token": refreshToken]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        if httpResponse.statusCode != 200 {
            if [400, 401, 403].contains(httpResponse.statusCode) {
                logout()
            }
            throw NSError(domain: "APIService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Lỗi làm mới phiên làm việc"])
        }
        
        struct RefreshResponse: Codable {
            let accessToken: String
            let refreshToken: String
            
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
            }
        }
        
        let result = try JSONDecoder().decode(RefreshResponse.self, from: data)
        self.token = result.accessToken
        self.refreshToken = result.refreshToken
        KeychainHelper.save(key: "auth.accessToken", value: self.token)
        KeychainHelper.save(key: "auth.refreshToken", value: self.refreshToken)
        return result.accessToken
    }
    
    // Custom URLSession request helper supporting retries with token refreshes
    private func sendRequest(_ request: URLRequest, retryCount: Int = 0) async throws -> (Data, URLResponse) {
        try await authorized(request, retryCount: retryCount) { try await URLSession.shared.data(for: $0) }
    }

    private func isConnectivityFailure(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                return true
            default:
                return false
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return true
        }
        if !isNetworkAvailable {
            return true
        }
        return false
    }

    private func encodedPathSegment(_ segment: String) -> String? {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    }

    /// The "sign it, and on a 401 refresh once and try again" rule, in ONE place, for any
    /// transport: `data(for:)` for ordinary calls, `bytes(for:)` for the streamed ones.
    /// The *original* request is re-signed on the retry, so the refreshed token is the one
    /// that actually goes out.
    private func authorized<Body>(
        _ request: URLRequest,
        retryCount: Int = 0,
        transport: (URLRequest) async throws -> (Body, URLResponse)
    ) async throws -> (Body, URLResponse) {
        var signedRequest = request
        signedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (body, response) = try await transport(signedRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 401, retryCount < 1 else {
            return (body, response)
        }
        // Token expired, attempt refresh
        _ = try await performTokenRefresh()
        return try await authorized(request, retryCount: retryCount + 1, transport: transport)
    }

    /// The authenticated transport, for services that live outside this class (`VocaService`
    /// calls the `/api/voca/*` proxy). Exposed rather than reimplemented so the 401 → refresh
    /// → retry, and the Bearer header itself, are never duplicated.
    func authorizedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await sendRequest(request)
    }

    /// Streaming twin of `authorizedData`: the Voca practice endpoints answer with SSE, whose
    /// body has to be consumed chunk by chunk and so cannot go through `data(for:)`.
    func authorizedBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await authorized(request) { try await URLSession.shared.bytes(for: $0) }
    }

    func fetchBooks() async throws -> [Book] {
        guard isNetworkAvailable else {
            isOfflineMode = true
            isServerReachable = false
            throw URLError(.notConnectedToInternet)
        }

        // Flush any pending offline changes first so server state reflects local offline edits.
        await syncPendingOfflineOperations()

        guard let url = URL(string: "\(normalizedServerUrl)/api/books") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        do {
            let (data, response) = try await sendRequest(request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode([Book].self, from: data)
            self.isOfflineMode = false
            self.isServerReachable = true
            return BookCacheManager.shared.reconcileAndSaveBooks(
                decoded,
                serverUrl: normalizedServerUrl,
                username: username
            )
        } catch {
            if isConnectivityFailure(error) {
                self.isOfflineMode = true
                self.isServerReachable = false
            }
            throw error
        }
    }

    func fetchBackupManifest() async throws -> BackupManifestResponse {
        guard isNetworkAvailable else {
            throw URLError(.notConnectedToInternet)
        }
        guard let url = URL(string: "\(normalizedServerUrl)/api/backup/manifest") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12.0
        let (data, response) = try await sendRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let manifest = try JSONDecoder().decode(BackupManifestResponse.self, from: data)
        BookCacheManager.shared.updateServerManifest(manifest)
        return manifest
    }

    func updateBookState(slug: String, patch: [String: Any]) async throws -> BookState {
        let isFinishedPatch = patch["isFinished"] as? Bool
        let isPriorityPatch = patch["isPriority"] as? Bool
        let readerFontPatch = patch["readerFont"] as? String
        let readerThemePatch = patch["readerTheme"] as? String

        func optimisticStateAndCache() -> BookState {
            let cachedBooks = BookCacheManager.shared.loadCachedBooks(serverUrl: normalizedServerUrl, username: username)
            let existing = cachedBooks.first(where: { $0.slug == slug })
            let state = BookState(
                isFinished: isFinishedPatch ?? (existing?.isFinished ?? false),
                isPriority: isPriorityPatch ?? (existing?.isPriority ?? false),
                readerFont: readerFontPatch ?? existing?.readerFont,
                readerTheme: readerThemePatch ?? existing?.readerTheme
            )
            BookCacheManager.shared.enqueuePendingOp(
                .patchBookState(
                    slug: slug,
                    isFinished: isFinishedPatch,
                    isPriority: isPriorityPatch,
                    readerFont: readerFontPatch,
                    readerTheme: readerThemePatch
                ),
                serverUrl: normalizedServerUrl,
                username: username
            )
            return state
        }

        guard isNetworkAvailable else {
            isOfflineMode = true
            isServerReachable = false
            return optimisticStateAndCache()
        }

        guard let encodedSlug = encodedPathSegment(slug),
              let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/state") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 10.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: patch)

        do {
            let (data, response) = try await sendRequest(request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            if httpResponse.statusCode == 200 {
                self.isOfflineMode = false
                self.isServerReachable = true
                let state = try JSONDecoder().decode(BookState.self, from: data)
                var cached = BookCacheManager.shared.loadCachedBooks(serverUrl: normalizedServerUrl, username: username)
                if let idx = cached.firstIndex(where: { $0.slug == slug }) {
                    cached[idx].isFinished = state.isFinished
                    cached[idx].isPriority = state.isPriority
                    cached[idx].readerFont = state.readerFont
                    cached[idx].readerTheme = state.readerTheme
                    _ = BookCacheManager.shared.reconcileAndSaveBooks(
                        cached,
                        serverUrl: normalizedServerUrl,
                        username: username
                    )
                }
                return state
            }
            if (500...599).contains(httpResponse.statusCode) {
                self.isOfflineMode = true
                self.isServerReachable = false
                return optimisticStateAndCache()
            }
            throw URLError(.badServerResponse)
        } catch {
            if isConnectivityFailure(error) {
                self.isOfflineMode = true
                self.isServerReachable = false
                return optimisticStateAndCache()
            }
            throw error
        }
    }

    func updateBookAppearanceDefaults(slug: String, defaultFont: String, defaultTheme: String) async throws {
        guard let encodedSlug = encodedPathSegment(slug),
              let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/appearance-defaults") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 10.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "defaultFont": defaultFont,
            "defaultTheme": defaultTheme
        ])
        let (_, response) = try await sendRequest(request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
    
    /// `lastRead` is the unix-seconds moment the reading action happened; the
    /// server keeps whichever copy is newest, so a delayed save can no longer
    /// overwrite fresher progress from another device. Nil lets the server
    /// stamp its own clock (legacy behaviour).
    func saveProgress(slug: String, page: Int, viewMode: String, lastRead: Int64? = nil) async {
        let effectiveLastRead = lastRead ?? Int64(Date().timeIntervalSince1970)
        func enqueueProgress() {
            BookCacheManager.shared.enqueuePendingOp(
                .saveProgress(slug: slug, page: page, viewMode: viewMode, lastRead: effectiveLastRead),
                serverUrl: normalizedServerUrl,
                username: username
            )
        }

        guard isNetworkAvailable,
              let encodedSlug = encodedPathSegment(slug),
              let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/progress") else {
            if !isNetworkAvailable {
                isOfflineMode = true
                isServerReachable = false
            }
            enqueueProgress()
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "page": page,
            "viewMode": viewMode,
            "lastRead": effectiveLastRead
        ])

        do {
            let (_, response) = try await sendRequest(request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                BookCacheManager.shared.removePendingProgress(
                    slug: slug,
                    upToLastRead: effectiveLastRead,
                    serverUrl: normalizedServerUrl,
                    username: username
                )
            } else {
                enqueueProgress()
            }
        } catch {
            if isConnectivityFailure(error) {
                isOfflineMode = true
                isServerReachable = false
            }
            enqueueProgress()
        }
    }
    
    func fetchProgress(slug: String) async throws -> ReadingProgress {
        guard isNetworkAvailable else {
            isOfflineMode = true
            isServerReachable = false
            throw URLError(.notConnectedToInternet)
        }
        guard let encodedSlug = encodedPathSegment(slug),
              let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/progress") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        do {
            let (data, response) = try await sendRequest(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            return try JSONDecoder().decode(ReadingProgress.self, from: data)
        } catch {
            if isConnectivityFailure(error) {
                isOfflineMode = true
                isServerReachable = false
            }
            throw error
        }
    }
    
    // --- Highlight APIs (Offline-Capable) ---

    @discardableResult
    func fetchHighlights(slug: String) async throws -> [Highlight] {
        // Scope state immediately to `slug` so another book's highlights never linger in memory.
        if currentHighlightsSlug != slug || highlights.isEmpty {
            currentHighlightsSlug = slug
            highlights = BookCacheManager.shared.loadCachedHighlights(
                slug: slug,
                serverUrl: normalizedServerUrl,
                username: username
            )
        }

        guard isNetworkAvailable else {
            isOfflineMode = true
            isServerReachable = false
            return highlights
        }

        // Flush offline highlight edits for any pending operations before pulling canonical server list.
        await syncPendingOfflineOperations()

        guard let encodedSlug = encodedPathSegment(slug),
              let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/highlights") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        do {
            let (data, response) = try await sendRequest(request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            
            struct HighlightResponse: Codable {
                let highlights: [Highlight]
            }
            
            let result = try JSONDecoder().decode(HighlightResponse.self, from: data)
            self.isOfflineMode = false
            self.isServerReachable = true

            BookCacheManager.shared.saveCachedHighlights(
                result.highlights,
                slug: slug,
                serverUrl: normalizedServerUrl,
                username: username
            )
            let merged = BookCacheManager.shared.mergeHighlightsWithPending(
                result.highlights,
                slug: slug,
                serverUrl: normalizedServerUrl,
                username: username
            )
            if currentHighlightsSlug == slug {
                self.highlights = merged
            }
            return merged
        } catch {
            if isConnectivityFailure(error) {
                self.isOfflineMode = true
                self.isServerReachable = false
                let cached = BookCacheManager.shared.loadCachedHighlights(
                    slug: slug,
                    serverUrl: normalizedServerUrl,
                    username: username
                )
                if currentHighlightsSlug == slug {
                    self.highlights = cached
                }
                return cached
            }
            throw error
        }
    }
    
    func saveHighlight(slug: String, highlight: Highlight) async throws {
        // Optimistic update + durable local cache regardless of connectivity
        var localList = (currentHighlightsSlug == slug)
            ? highlights
            : BookCacheManager.shared.loadCachedHighlights(slug: slug, serverUrl: normalizedServerUrl, username: username)
        if let idx = localList.firstIndex(where: { $0.id == highlight.id }) {
            localList[idx] = highlight
        } else {
            localList.append(highlight)
        }
        currentHighlightsSlug = slug
        highlights = localList
        BookCacheManager.shared.saveCachedHighlights(
            localList,
            slug: slug,
            serverUrl: normalizedServerUrl,
            username: username
        )

        let pendingOp = OfflinePendingOp.upsertHighlight(slug: slug, highlight: highlight)
        BookCacheManager.shared.enqueuePendingOp(pendingOp, serverUrl: normalizedServerUrl, username: username)

        guard isNetworkAvailable,
              let encodedSlug = encodedPathSegment(slug),
              let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/highlights") else {
            if !isNetworkAvailable {
                isOfflineMode = true
                isServerReachable = false
            }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(highlight)
        
        do {
            let (_, response) = try await sendRequest(request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            if (200..<300).contains(httpResponse.statusCode) {
                self.isOfflineMode = false
                self.isServerReachable = true
                BookCacheManager.shared.removeExactPendingOp(
                    pendingOp,
                    serverUrl: normalizedServerUrl,
                    username: username
                )
                _ = try? await fetchHighlights(slug: slug)
            } else if (500...599).contains(httpResponse.statusCode) {
                self.isOfflineMode = true
                self.isServerReachable = false
            } else {
                BookCacheManager.shared.removeExactPendingOp(
                    pendingOp,
                    serverUrl: normalizedServerUrl,
                    username: username
                )
                throw URLError(.badServerResponse)
            }
        } catch {
            if isConnectivityFailure(error) {
                self.isOfflineMode = true
                self.isServerReachable = false
                return
            }
            throw error
        }
    }
    
    func deleteHighlight(slug: String, highlightId: String) async throws {
        var localList = (currentHighlightsSlug == slug)
            ? highlights
            : BookCacheManager.shared.loadCachedHighlights(slug: slug, serverUrl: normalizedServerUrl, username: username)
        localList.removeAll { $0.id == highlightId }
        currentHighlightsSlug = slug
        highlights = localList
        BookCacheManager.shared.saveCachedHighlights(
            localList,
            slug: slug,
            serverUrl: normalizedServerUrl,
            username: username
        )

        let pendingOp = OfflinePendingOp.deleteHighlight(slug: slug, highlightId: highlightId)
        BookCacheManager.shared.enqueuePendingOp(pendingOp, serverUrl: normalizedServerUrl, username: username)

        guard isNetworkAvailable,
              let encodedSlug = encodedPathSegment(slug),
              let encodedId = encodedPathSegment(highlightId),
              let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/highlights/\(encodedId)") else {
            if !isNetworkAvailable {
                isOfflineMode = true
                isServerReachable = false
            }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 10.0
        
        do {
            let (_, response) = try await sendRequest(request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            if (200..<300).contains(httpResponse.statusCode) || httpResponse.statusCode == 404 {
                self.isOfflineMode = false
                self.isServerReachable = true
                BookCacheManager.shared.removeExactPendingOp(
                    pendingOp,
                    serverUrl: normalizedServerUrl,
                    username: username
                )
                _ = try? await fetchHighlights(slug: slug)
            } else if (500...599).contains(httpResponse.statusCode) {
                self.isOfflineMode = true
                self.isServerReachable = false
            } else {
                BookCacheManager.shared.removeExactPendingOp(
                    pendingOp,
                    serverUrl: normalizedServerUrl,
                    username: username
                )
                throw URLError(.badServerResponse)
            }
        } catch {
            if isConnectivityFailure(error) {
                self.isOfflineMode = true
                self.isServerReachable = false
                return
            }
            throw error
        }
    }

    private func buildSyncRequest(for op: OfflinePendingOp) -> URLRequest? {
        switch op {
        case .saveProgress(let slug, let page, let viewMode, let lastRead):
            guard let encodedSlug = encodedPathSegment(slug),
                  let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/progress") else {
                return nil
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 10.0
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "page": page,
                "viewMode": viewMode,
                "lastRead": lastRead
            ])
            return req

        case .patchBookState(let slug, let isFinished, let isPriority, let readerFont, let readerTheme):
            guard let encodedSlug = encodedPathSegment(slug),
                  let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/state") else {
                return nil
            }
            var patch: [String: Any] = [:]
            if let isFinished { patch["isFinished"] = isFinished }
            if let isPriority { patch["isPriority"] = isPriority }
            if let readerFont { patch["readerFont"] = readerFont }
            if let readerTheme { patch["readerTheme"] = readerTheme }
            guard !patch.isEmpty else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "PATCH"
            req.timeoutInterval = 10.0
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: patch)
            return req

        case .upsertHighlight(let slug, let highlight):
            guard let encodedSlug = encodedPathSegment(slug),
                  let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/highlights") else {
                return nil
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 10.0
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONEncoder().encode(highlight)
            return req

        case .deleteHighlight(let slug, let highlightId):
            guard let encodedSlug = encodedPathSegment(slug),
                  let encodedId = encodedPathSegment(highlightId),
                  let url = URL(string: "\(normalizedServerUrl)/api/books/\(encodedSlug)/highlights/\(encodedId)") else {
                return nil
            }
            var req = URLRequest(url: url)
            req.httpMethod = "DELETE"
            req.timeoutInterval = 10.0
            return req
        }
    }

    /// Flushes queued offline reading progress, book state changes, and highlight mutations to
    /// the server cleanly once connectivity returns.
    func syncPendingOfflineOperations() async {
        guard isAuthenticated, !token.isEmpty, isNetworkAvailable, !isSyncingOfflineOps else { return }
        let ops = BookCacheManager.shared.loadPendingOps(serverUrl: normalizedServerUrl, username: username)
        guard !ops.isEmpty else {
            BookCacheManager.shared.refreshPendingCount(serverUrl: normalizedServerUrl, username: username)
            return
        }

        isSyncingOfflineOps = true
        defer { isSyncingOfflineOps = false }

        var syncedAny = false
        for op in ops {
            guard let req = buildSyncRequest(for: op) else {
                BookCacheManager.shared.removeExactPendingOp(
                    op,
                    serverUrl: normalizedServerUrl,
                    username: username
                )
                continue
            }

            do {
                let (_, resp) = try await sendRequest(req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 500
                if (200..<300).contains(status) || status == 404 {
                    if case .saveProgress(let slug, _, _, let lastRead) = op {
                        BookCacheManager.shared.removePendingProgress(
                            slug: slug,
                            upToLastRead: lastRead,
                            serverUrl: normalizedServerUrl,
                            username: username
                        )
                    } else {
                        BookCacheManager.shared.removeExactPendingOp(
                            op,
                            serverUrl: normalizedServerUrl,
                            username: username
                        )
                    }
                    syncedAny = true
                } else if (500...599).contains(status) {
                    return
                }
            } catch {
                if isConnectivityFailure(error) {
                    isOfflineMode = true
                    isServerReachable = false
                }
                return
            }
        }

        if syncedAny {
            isOfflineMode = false
            isServerReachable = true
            NotificationCenter.default.post(name: NSNotification.Name("ReadingProgressUpdated"), object: nil)
        }
    }
    
    // --- AI Chat completions Proxy API ---
    func sendChat(baseURL: String, apiKey: String, model: String, messages: [[String: String]]) async throws -> String {
        guard let url = URL(string: "\(serverUrl)/api/chat") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "baseURL": baseURL,
            "apiKey": apiKey,
            "model": model,
            "messages": messages,
            "stream": false
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await sendRequest(request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = json["choices"] as? [[String: Any]],
           let firstChoice = choices.first,
           let message = firstChoice["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }
        
        throw NSError(domain: "APIService", code: 500, userInfo: [NSLocalizedDescriptionKey: "Malformed AI response"])
    }

    // MARK: - Unified user settings

    /// Canonical settings shared by Web and Mobile.
    ///
    /// Refreshes runtime feature flags from the backend (`/api/config`).
    /// Falls back to client config (`Info.plist`, default `false`) on network error.
    func fetchAppConfig() async {
        let cleanUrl = serverUrl
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(cleanUrl)/api/config") else { return }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(AppConfigResponse.self, from: data)
            self.isAudiobookEnabled = decoded.features.audiobookEnabled
            if !self.isAudiobookEnabled {
                AudiobookManager.shared.close()
            }
        } catch {
            // Keep existing value (defaults to client config `false`) while offline.
        }
    }

    /// Public preferences are returned in full. Secret values remain on the
    /// backend; clients receive only availability flags.
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

    typealias ServerSecrets = ServerSettings

    func fetchServerSettings() async throws -> ServerSettings {
        guard let url = URL(string: "\(serverUrl)/api/user/settings") else { throw URLError(.badURL) }
        let (data, response) = try await sendRequest(URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ServerSettings.self, from: data)
    }

    func fetchServerSecrets() async throws -> ServerSettings {
        try await fetchServerSettings()
    }

    /// Saves public preferences and optional secret replacements on the server.
    ///
    /// Passing nil keeps the current value. For secret fields, pass an empty
    /// string only when the user explicitly wants to clear the stored value.
    @discardableResult
    func saveServerSettings(
        provider: String? = nil,
        baseURL: String? = nil,
        model: String? = nil,
        realtimeModel: String? = nil,
        realtimeVoice: String? = nil,
        llmApiKey: String? = nil,
        realtimeApiKey: String? = nil,
        audioProvider: String? = nil,
        audioSource: String? = nil,
        audioVoice: String? = nil,
        audioVoiceEn: String? = nil,
        audioVoiceVi: String? = nil,
        ttsModel: String? = nil,
        speechSpeed: String? = nil,
        azureApiKey: String? = nil,
        elevenLabsApiKey: String? = nil,
        layoutMode: String? = nil,
        hideFinishedBooks: Bool? = nil,
        vocaOrigin: String? = nil,
        vocaToken: String? = nil
    ) async throws -> ServerSettings {
        guard let url = URL(string: "\(serverUrl)/api/user/settings") else { throw URLError(.badURL) }
        var body: [String: Any] = [:]
        if let v = provider { body["provider"] = v }
        if let v = baseURL { body["baseURL"] = v }
        if let v = model { body["model"] = v }
        if let v = realtimeModel { body["realtimeModel"] = v }
        if let v = realtimeVoice { body["realtimeVoice"] = v }
        if let v = llmApiKey { body["llmApiKey"] = v }
        if let v = realtimeApiKey { body["realtimeApiKey"] = v }
        if let v = audioProvider { body["audioProvider"] = v }
        if let v = audioSource { body["audioSource"] = v }
        if let v = audioVoice { body["audioVoice"] = v }
        if let v = audioVoiceEn { body["audioVoiceEn"] = v }
        if let v = audioVoiceVi { body["audioVoiceVi"] = v }
        if let v = ttsModel { body["ttsModel"] = v }
        if let v = speechSpeed { body["speechSpeed"] = v }
        if let v = azureApiKey { body["azureApiKey"] = v }
        if let v = elevenLabsApiKey { body["elevenLabsApiKey"] = v }
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
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ServerSettings.self, from: data)
    }

    /// Compatibility wrapper for callers being migrated to unified settings.
    @discardableResult
    func saveServerSecrets(
        llmApiKey: String? = nil,
        realtimeApiKey: String? = nil,
        audioProvider: String? = nil,
        audioVoice: String? = nil,
        audioVoiceEn: String? = nil,
        audioVoiceVi: String? = nil,
        speechSpeed: String? = nil,
        azureApiKey: String? = nil,
        elevenLabsApiKey: String? = nil,
        vocaOrigin: String? = nil,
        vocaToken: String? = nil
    ) async throws -> ServerSettings {
        try await saveServerSettings(
            llmApiKey: llmApiKey,
            realtimeApiKey: realtimeApiKey,
            audioProvider: audioProvider,
            audioVoice: audioVoice,
            audioVoiceEn: audioVoiceEn,
            audioVoiceVi: audioVoiceVi,
            speechSpeed: speechSpeed,
            azureApiKey: azureApiKey,
            elevenLabsApiKey: elevenLabsApiKey,
            vocaOrigin: vocaOrigin,
            vocaToken: vocaToken
        )
    }

    func synthesizeAudio(
        text: String,
        provider: String? = nil,
        voice: String? = nil,
        speed: String? = nil,
        lang: String? = nil
    ) async throws -> Data {
        guard let url = URL(string: "\(serverUrl)/api/audio/synthesize") else { throw URLError(.badURL) }
        var body: [String: Any] = ["text": text]
        if let provider = provider { body["provider"] = provider }
        if let voice = voice { body["voice"] = voice }
        if let speed = speed { body["speed"] = speed }
        if let lang = lang { body["lang"] = lang }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120.0

        let (data, response) = try await sendRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 500)"
            throw NSError(domain: "AudioSynthesis", code: (response as? HTTPURLResponse)?.statusCode ?? 500, userInfo: [NSLocalizedDescriptionKey: errorText])
        }
        return data
    }
}
