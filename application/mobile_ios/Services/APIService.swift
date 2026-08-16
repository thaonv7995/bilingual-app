import Foundation

@MainActor
class APIService: ObservableObject {
    @Published var serverUrl: String = "https://books.thaonv.online"
    @Published var token: String = ""
    @Published var refreshToken: String = ""
    @Published var username: String = ""
    @Published var isAdmin: Bool = false
    @Published var isAuthenticated: Bool = false
    @Published var isVerifyingSession: Bool = false
    
    // Shared highlights state
    @Published var highlights: [Highlight] = []
    
    static let shared = APIService()
    
    private init() {
        // First run after the Voca-through-the-proxy switch: drop the API key the old build
        // kept on the device, so a stale local copy cannot linger. No-op afterwards.
        VocaService.purgeDeviceCredentialsIfNeeded()

        // Load saved session
        if let savedToken = UserDefaults.standard.string(forKey: "token") {
            self.token = savedToken
            self.refreshToken = UserDefaults.standard.string(forKey: "refreshToken") ?? ""
            self.serverUrl = UserDefaults.standard.string(forKey: "serverUrl") ?? "https://books.thaonv.online"
            self.username = ServerUsernameHack()
            self.isAdmin = UserDefaults.standard.bool(forKey: "isAdmin")
            self.isAuthenticated = true
            
            // Verify session with server on launch
            self.isVerifyingSession = true
            Task { await self.verifySession() }
        }
    }
    
    private func ServerUsernameHack() -> String {
        return UserDefaults.standard.string(forKey: "username") ?? ""
    }
    
    /// Verify the saved session is still valid on app launch.
    /// If the access token is expired, attempt a refresh. If refresh also fails, logout.
    func verifySession() async {
        defer { isVerifyingSession = false }
        
        guard !token.isEmpty else {
            logout()
            return
        }
        
        guard let url = URL(string: "\(serverUrl)/api/auth/me") else {
            logout()
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    // Session valid — sync user info
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.username = json["username"] as? String ?? self.username
                        self.isAdmin = json["is_admin"] as? Bool ?? self.isAdmin
                        UserDefaults.standard.set(self.username, forKey: "username")
                        UserDefaults.standard.set(self.isAdmin, forKey: "isAdmin")
                    }
                    return
                } else if httpResponse.statusCode == 401 {
                    // Access token expired, attempt refresh
                    do {
                        _ = try await performTokenRefresh()
                        // Refresh succeeded, session restored
                        return
                    } catch {
                        // Refresh also failed
                        logout()
                        return
                    }
                }
            }
            // Any other error — keep session but don't logout (could be network issue)
        } catch {
            // Network error — keep current session, don't force logout on connectivity issues
            print("[APIService] Session verify failed (network): \(error.localizedDescription)")
        }
    }
    
    func login(usernameInput: String, passwordInput: String) async throws -> Bool {
        let cleanUrl = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var urlComponents = URLComponents(string: "\(cleanUrl)/api/auth/login") else {
            throw URLError(.badURL)
        }
        
        urlComponents.queryItems = [
            URLQueryItem(name: "username", value: usernameInput),
            URLQueryItem(name: "password", value: passwordInput)
        ]
        
        guard let url = urlComponents.url else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
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
        
        // Save to UserDefaults
        UserDefaults.standard.set(self.token, forKey: "token")
        UserDefaults.standard.set(self.refreshToken, forKey: "refreshToken")
        UserDefaults.standard.set(self.serverUrl, forKey: "serverUrl")
        UserDefaults.standard.set(self.username, forKey: "username")
        UserDefaults.standard.set(self.isAdmin, forKey: "isAdmin")
        
        return true
    }
    
    func logout() {
        let savedToken = token
        
        token = ""
        refreshToken = ""
        isAuthenticated = false
        isAdmin = false
        username = ""
        highlights = []
        
        UserDefaults.standard.removeObject(forKey: "token")
        UserDefaults.standard.removeObject(forKey: "refreshToken")
        UserDefaults.standard.removeObject(forKey: "username")
        UserDefaults.standard.removeObject(forKey: "isAdmin")

        // Voca is server-configured per user now, so both its "is a key stored?" answer and
        // the synced dictionary belong to the account that just left.
        VocaService.invalidateConfiguration()
        VocaService.clearCardsCache()

        // Notify server with the saved (valid) token
        if !savedToken.isEmpty, let url = URL(string: "\(serverUrl)/api/auth/logout") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(savedToken)", forHTTPHeaderField: "Authorization")
            URLSession.shared.dataTask(with: request).resume()
        }
    }
    
    // Perform automatic token refresh
    func performTokenRefresh() async throws -> String {
        guard let url = URL(string: "\(serverUrl)/api/auth/refresh") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
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
        UserDefaults.standard.set(self.token, forKey: "token")
        UserDefaults.standard.set(self.refreshToken, forKey: "refreshToken")
        return result.accessToken
    }
    
    // Custom URLSession request helper supporting retries with token refreshes
    private func sendRequest(_ request: URLRequest, retryCount: Int = 0) async throws -> (Data, URLResponse) {
        try await authorized(request, retryCount: retryCount) { try await URLSession.shared.data(for: $0) }
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
        guard let url = URL(string: "\(serverUrl)/api/books") else {
            throw URLError(.badURL)
        }
        
        let request = URLRequest(url: url)
        let (data, response) = try await sendRequest(request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        return try JSONDecoder().decode([Book].self, from: data)
    }
    
    func saveProgress(slug: String, page: Int, viewMode: String) async {
        guard let url = URL(string: "\(serverUrl)/api/books/\(slug)/progress") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = [
            "page": page,
            "viewMode": viewMode
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        _ = try? await sendRequest(request)
    }
    
    func fetchProgress(slug: String) async throws -> ReadingProgress {
        guard let url = URL(string: "\(serverUrl)/api/books/\(slug)/progress") else {
            throw URLError(.badURL)
        }
        
        let request = URLRequest(url: url)
        let (data, _) = try await sendRequest(request)
        return try JSONDecoder().decode(ReadingProgress.self, from: data)
    }
    
    // --- Highlight APIs ---
    func fetchHighlights(slug: String) async throws -> [Highlight] {
        guard let url = URL(string: "\(serverUrl)/api/books/\(slug)/highlights") else {
            throw URLError(.badURL)
        }
        
        let request = URLRequest(url: url)
        let (data, response) = try await sendRequest(request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        struct HighlightResponse: Codable {
            let highlights: [Highlight]
        }
        
        let result = try JSONDecoder().decode(HighlightResponse.self, from: data)
        self.highlights = result.highlights
        return result.highlights
    }
    
    func saveHighlight(slug: String, highlight: Highlight) async throws {
        guard let url = URL(string: "\(serverUrl)/api/books/\(slug)/highlights") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(highlight)
        
        let (_, response) = try await sendRequest(request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        _ = try? await fetchHighlights(slug: slug)
    }
    
    func deleteHighlight(slug: String, highlightId: String) async throws {
        guard let url = URL(string: "\(serverUrl)/api/books/\(slug)/highlights/\(highlightId)") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        
        let (_, response) = try await sendRequest(request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        _ = try? await fetchHighlights(slug: slug)
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

    // --- Per-user AI secrets (server-side) ---
    // Secrets live on the backend (user_settings) and are attached by the /api/chat
    // and /api/voca proxies. GET returns only booleans, never the raw secret.
    struct ServerSecrets: Codable {
        let hasLlmKey: Bool
        let hasRealtimeKey: Bool
        let vocaOrigin: String
        let hasVocaToken: Bool
    }

    func fetchServerSecrets() async throws -> ServerSecrets {
        guard let url = URL(string: "\(serverUrl)/api/user/settings") else { throw URLError(.badURL) }
        let (data, response) = try await sendRequest(URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ServerSecrets.self, from: data)
    }

    /// Upsert secrets on the server. Pass nil to leave a field unchanged, "" to clear.
    func saveServerSecrets(
        llmApiKey: String? = nil,
        realtimeApiKey: String? = nil,
        vocaOrigin: String? = nil,
        vocaToken: String? = nil
    ) async throws {
        guard let url = URL(string: "\(serverUrl)/api/user/settings") else { throw URLError(.badURL) }
        var body: [String: Any] = [:]
        if let v = llmApiKey { body["llmApiKey"] = v }
        if let v = realtimeApiKey { body["realtimeApiKey"] = v }
        if let v = vocaOrigin { body["vocaOrigin"] = v }
        if let v = vocaToken { body["vocaToken"] = v }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await sendRequest(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
}
