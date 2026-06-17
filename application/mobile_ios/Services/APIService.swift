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
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            logout()
            throw NSError(domain: "APIService", code: 401, userInfo: [NSLocalizedDescriptionKey: "Phiên làm việc hết hạn"])
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
        var mutableRequest = request
        mutableRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: mutableRequest)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 && retryCount < 1 {
            // Token expired, attempt refresh
            let newToken = try await performTokenRefresh()
            var retryRequest = request
            retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            return try await sendRequest(retryRequest, retryCount: retryCount + 1)
        }
        
        return (data, response)
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
}
