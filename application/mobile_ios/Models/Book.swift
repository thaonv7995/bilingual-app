import Foundation

struct User: Codable {
    let username: String
    let isAdmin: Bool
    
    enum CodingKeys: String, CodingKey {
        case username
        case isAdmin = "is_admin"
    }
}

struct LoginResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let username: String
    let isAdmin: Bool
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case username
        case isAdmin = "is_admin"
    }
}

struct Book: Codable, Identifiable {
    var id: String { slug }
    let slug: String
    let title: String
    let author: String?
    let pageCount: Int
    let cover: String?
    let isPublished: Bool
    
    var coverPath: String? {
        guard let cover = cover else { return nil }
        let prefix = "books/\(slug)/output/"
        if cover.hasPrefix(prefix) {
            return String(cover.dropFirst(prefix.count))
        }
        return cover
    }
    
    enum CodingKeys: String, CodingKey {
        case slug, title, author, pageCount, cover, isPublished
    }
}

struct Highlight: Codable, Identifiable, Equatable {
    let id: String
    let page: Int
    let lang: String
    let color: String
    let text: String
    let startOffset: Int
    let endOffset: Int
    let paragraphIndex: Int
    let note: String?
    let createdAt: Int64
}

struct ReadingProgress: Codable {
    let page: Int
    let viewMode: String
    let lastRead: Int64?
}
