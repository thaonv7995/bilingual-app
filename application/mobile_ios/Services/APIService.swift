import Foundation

class APIService: ObservableObject {
    @Published var serverUrl: String = "http://localhost:27099"
    @Published var token: String = ""
    @Published var refreshToken: String = ""
    @Published var username: String = ""
    @Published var isAdmin: Bool = false
    @Published var isAuthenticated: Bool = false
    
    // Shared highlights state
    @Published var highlights: [Highlight] = []
    
    static let shared = APIService()
    
    private init() {
        // Load saved session
        if let savedToken = UserDefaults.standard.string(forKey: "token") {
            self.token = savedToken
            self.refreshToken = UserDefaults.standard.string(forKey: "refreshToken") ?? ""
            self.serverUrl = UserDefaults.standard.string(forKey: "serverUrl") ?? "http://localhost:27099"
            self.username = ServerUsernameHack()
            self.isAdmin = UserDefaults.standard.bool(forKey: "isAdmin")
            self.isAuthenticated = true
        }
    }
    
    private func ServerUsernameHack() -> String {
        return UserDefaults.standard.string(forKey: "username") ?? ""
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
        
        await MainActor.run {
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
        }
        
        return true
    }
    
    func logout() {
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
        
        // Notify server
        if let url = URL(string: "\(serverUrl)/api/auth/logout") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
            await MainActor.run { logout() }
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
        await MainActor.run {
            self.token = result.accessToken
            self.refreshToken = result.refreshToken
            UserDefaults.standard.set(self.token, forKey: "token")
            UserDefaults.standard.set(self.refreshToken, forKey: "refreshToken")
        }
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
        await MainActor.run {
            self.highlights = result.highlights
        }
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
