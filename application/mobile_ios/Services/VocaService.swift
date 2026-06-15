import Foundation
import AVFoundation

struct VocaCard: Codable, Identifiable, Equatable {
    let id: String
    let word: String
    let meaningVi: String
    let ipa: String?
    let pronunciation: String?
    let audioUrl: String?
    let level: String?

    var displayIpa: String {
        let value = (ipa ?? pronunciation ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        return value.hasPrefix("/") ? value : "/\(value)/"
    }
}

struct VocaLookupResult: Codable {
    let found: Bool
    let word: String?
    let matchType: String?
    let card: VocaCard?
    let cards: [VocaCard]?

    var resolvedCards: [VocaCard] {
        if let cards, !cards.isEmpty { return cards }
        if let card { return [card] }
        return []
    }
}

struct VocaAISettings {
    let apiKey: String
    let baseURL: String
    let model: String
}

enum VocaServiceError: LocalizedError {
    case missingWord
    case missingAISettings
    case http(Int, String)
    case createFailed(String)
    case audioFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingWord:
            return "Select a word first."
        case .missingAISettings:
            return "Configure AI API Key, Base URL, and Model in Settings first."
        case .http(let code, let message):
            return message.isEmpty ? "Request failed (\(code))." : message
        case .createFailed(let message):
            return message
        case .audioFailed(let message):
            return message
        }
    }
}

enum VocaService {
    static let defaultBridgeOrigin = "https://voca-bridge.thaonv.online"
    static let defaultBridgeToken = "voca_55c2ac41266be58e43d0ef2b5817b4c9053a2ed7410fcefd"
    static let defaultTTSModel = "edge-tts/en-US-SteffanNeural"

    private static var audioPlayer: AVPlayer?

    static func bridgeOrigin() -> String {
        let trimmed = (UserDefaults.standard.string(forKey: "vocaBridgeOrigin") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? defaultBridgeOrigin : trimmed
    }

    static func bridgeToken() -> String {
        let trimmed = (UserDefaults.standard.string(forKey: "vocaBridgeToken") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultBridgeToken : trimmed
    }

    static func aiSettings() -> VocaAISettings? {
        let apiKey = (UserDefaults.standard.string(forKey: "aiApiKey") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = (UserDefaults.standard.string(forKey: "aiBaseURL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (UserDefaults.standard.string(forKey: "aiModel") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !baseURL.isEmpty, !model.isEmpty else { return nil }
        return VocaAISettings(apiKey: apiKey, baseURL: baseURL, model: model)
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

    private static func bridgeURL(path: String) -> URL? {
        let base = bridgeOrigin()
        let suffix = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: base + suffix)
    }

    private static func authorizedRequest(url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(bridgeToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func parseErrorMessage(data: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any],
            let message = error["message"] as? String
        else { return "" }
        return message
    }

    static func lookupWord(_ word: String) async throws -> VocaLookupResult {
        let query = cleanWord(word)
        guard !query.isEmpty else { return VocaLookupResult(found: false, word: "", matchType: nil, card: nil, cards: nil) }
        guard var components = URLComponents(string: bridgeOrigin() + "/v1/cards/lookup") else {
            throw VocaServiceError.http(0, "Invalid bridge URL.")
        }
        components.queryItems = [URLQueryItem(name: "word", value: query)]
        guard let url = components.url else { throw VocaServiceError.http(0, "Invalid lookup URL.") }

        let (data, response) = try await URLSession.shared.data(for: authorizedRequest(url: url))
        guard let http = response as? HTTPURLResponse else { throw VocaServiceError.http(0, "Lookup failed.") }
        guard http.statusCode == 200 else {
            throw VocaServiceError.http(http.statusCode, parseErrorMessage(data: data))
        }
        return try JSONDecoder().decode(VocaLookupResult.self, from: data)
    }

    static func addWordToVoca(_ word: String) async throws {
        let normalized = cleanWord(word)
        guard !normalized.isEmpty else { throw VocaServiceError.missingWord }
        guard let ai = aiSettings() else { throw VocaServiceError.missingAISettings }
        guard let url = bridgeURL(path: "/v1/cards/create") else {
            throw VocaServiceError.http(0, "Invalid bridge URL.")
        }

        var request = authorizedRequest(url: url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "word": normalized,
            "settings": [
                "apiKey": ai.apiKey,
                "baseURL": ai.baseURL,
                "model": ai.model,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VocaServiceError.http(0, "Create failed.") }
        guard http.statusCode == 200 else {
            throw VocaServiceError.http(http.statusCode, parseErrorMessage(data: data))
        }
        try consumeCreateStream(data: data)
    }

    private static func consumeCreateStream(data: Data) throws {
        let text = String(data: data, encoding: .utf8) ?? ""
        var lastError = ""
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }
            if type == "error" {
                lastError = event["message"] as? String ?? "Cannot create card."
            }
            if type == "done" { return }
        }
        if !lastError.isEmpty { throw VocaServiceError.createFailed(lastError) }
    }

    static func playCardAudio(_ card: VocaCard) async throws {
        let encodedId = card.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? card.id
        guard let url = bridgeURL(path: "/v1/audio/\(encodedId)") else {
            throw VocaServiceError.audioFailed("Invalid audio URL.")
        }

        let request = authorizedRequest(url: url)
        var (data, response) = try await URLSession.shared.data(for: request)
        guard var http = response as? HTTPURLResponse else {
            throw VocaServiceError.audioFailed("Audio request failed.")
        }

        if http.statusCode == 404 {
            guard let ai = aiSettings() else {
                throw VocaServiceError.audioFailed("Configure AI settings for TTS, or generate audio in Voca first.")
            }
            var post = authorizedRequest(url: url, method: "POST")
            post.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let ttsBody: [String: Any] = [
                "settings": [
                    "apiKey": ai.apiKey,
                    "baseURL": ai.baseURL,
                    "ttsEndpoint": UserDefaults.standard.string(forKey: "ttsEndpoint") ?? "",
                    "ttsModel": UserDefaults.standard.string(forKey: "ttsModel") ?? defaultTTSModel,
                ],
            ]
            post.httpBody = try JSONSerialization.data(withJSONObject: ttsBody)
            let generated = try await URLSession.shared.data(for: post)
            guard let postHttp = generated.1 as? HTTPURLResponse, postHttp.statusCode == 200 else {
                throw VocaServiceError.audioFailed(parseErrorMessage(data: generated.0))
            }
            (data, response) = try await URLSession.shared.data(for: authorizedRequest(url: url))
            http = response as? HTTPURLResponse ?? http
        }

        guard http.statusCode == 200 else {
            throw VocaServiceError.audioFailed("Audio request failed (\(http.statusCode)).")
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("voca-\(card.id).mp3")
        try data.write(to: tempURL, options: .atomic)
        await MainActor.run {
            audioPlayer = AVPlayer(url: tempURL)
            audioPlayer?.play()
        }
    }
}
