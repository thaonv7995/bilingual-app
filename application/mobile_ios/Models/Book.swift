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

struct Book: Codable, Identifiable, Equatable {
    /// `Identifiable` conformance for SwiftUI's `ForEach`. Deliberately the slug, not `bookId`:
    /// it is non-optional and stable across backends.
    var id: String { slug }
    /// Autoincrement row id from the server (JSON key `"id"`), i.e. import order. Used only as
    /// an ordering tie-break. Optional: an older backend omits it and ordering falls to `slug`.
    let bookId: Int64?
    let slug: String
    let title: String
    let author: String?
    let pageCount: Int
    let cover: String?
    let isPublished: Bool
    /// Unix seconds the book was imported. Optional on purpose: an older backend that has not
    /// shipped the column yet simply omits the key, and the synthesized decoder leaves it nil
    /// instead of throwing.
    let createdAt: Int64?
    /// Unix seconds this user last read the book, as known to the server. Optional for the same
    /// reason as `createdAt`; 0/nil means "never read".
    let lastRead: Int64?

    var coverPath: String? {
        guard let cover = cover else { return nil }
        let prefix = "books/\(slug)/output/"
        if cover.hasPrefix(prefix) {
            return String(cover.dropFirst(prefix.count))
        }
        return cover
    }
    
    enum CodingKeys: String, CodingKey {
        case bookId = "id"
        case slug, title, author, pageCount, cover, isPublished, createdAt, lastRead
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
