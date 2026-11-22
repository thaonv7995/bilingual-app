import Foundation
import SwiftUI

struct User: Codable, Equatable {
    let username: String
    let isAdmin: Bool

    enum CodingKeys: String, CodingKey {
        case username
        case isAdmin = "is_admin"
    }
}

struct LoginResponse: Codable {
    let accessToken: String
    let refreshToken: String?
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

struct Book: Codable, Identifiable, Equatable, Hashable {
    var id: Int { bookId ?? slug.hashValue }
    let bookId: Int?
    let slug: String
    let title: String
    let author: String?
    let pageCount: Int?
    let cover: String?
    let format: String?
    let sourceUrl: String?
    let isPublished: Bool?
    var createdAt: Int?
    var lastRead: Int?
    var isFinished: Bool?
    var onShelf: Bool?
    var isPriority: Bool?
    var defaultFont: String?
    var defaultTheme: String?
    var readerFont: String?
    var readerTheme: String?

    var resolvedFormat: String {
        let f = (format ?? "bkb").lowercased()
        return (f == "pdf" || f == "epub") ? f : "bkb"
    }

    init(
        bookId: Int? = nil,
        slug: String,
        title: String,
        author: String? = nil,
        pageCount: Int? = nil,
        cover: String? = nil,
        format: String? = "bkb",
        sourceUrl: String? = nil,
        isPublished: Bool? = true,
        createdAt: Int? = nil,
        lastRead: Int? = nil,
        isFinished: Bool? = false,
        onShelf: Bool? = false,
        isPriority: Bool? = false,
        defaultFont: String? = "default",
        defaultTheme: String? = "default",
        readerFont: String? = "",
        readerTheme: String? = ""
    ) {
        self.bookId = bookId
        self.slug = slug
        self.title = title
        self.author = author
        self.pageCount = pageCount
        self.cover = cover
        self.format = format
        self.sourceUrl = sourceUrl
        self.isPublished = isPublished
        self.createdAt = createdAt
        self.lastRead = lastRead
        self.isFinished = isFinished
        self.onShelf = onShelf
        self.isPriority = isPriority
        self.defaultFont = defaultFont
        self.defaultTheme = defaultTheme
        self.readerFont = readerFont
        self.readerTheme = readerTheme
    }

    enum CodingKeys: String, CodingKey {
        case bookId = "id"
        case slug, title, author, pageCount, cover, format, sourceUrl, isPublished
        case createdAt, lastRead, isFinished, onShelf, isPriority
        case defaultFont, defaultTheme, readerFont, readerTheme
    }

    func pageURL(serverUrl: String, lang: String, page: Int) -> String {
        let p = String(format: "%04d", page)
        return "\(serverUrl)/books/\(slug)/output/\(lang)/page_\(p).html"
    }
}

enum BookSort {
    static func sortedShelf(
        _ books: [Book],
        localLastRead: (String) -> Int? = { _ in nil }
    ) -> [Book] {
        books.sorted { lhs, rhs in
            let p1 = lhs.isPriority == true
            let p2 = rhs.isPriority == true
            if p1 != p2 { return p1 && !p2 }

            let lr1 = maxIfPresent(lhs.lastRead, localLastRead(lhs.slug))
            let lr2 = maxIfPresent(rhs.lastRead, localLastRead(rhs.slug))
            switch (lr1, lr2) {
            case let (a?, b?) where a != b:
                return a > b
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }

            switch (lhs.createdAt, rhs.createdAt) {
            case let (a?, b?) where a != b:
                return a > b
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                break
            }

            let id1 = lhs.bookId ?? Int.min
            let id2 = rhs.bookId ?? Int.min
            if id1 != id2 { return id1 > id2 }

            return lhs.slug < rhs.slug
        }
    }

    private static func maxIfPresent(_ a: Int?, _ b: Int?) -> Int? {
        switch (a, b) {
        case let (x?, y?): return max(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        case (nil, nil): return nil
        }
    }
}

struct BookState: Codable {
    var isFinished: Bool?
    var onShelf: Bool?
    var isPriority: Bool?
    var readerFont: String?
    var readerTheme: String?
}

struct Highlight: Codable, Identifiable, Equatable {
    let id: String
    let page: Int
    let lang: String
    var color: String
    let text: String
    let startOffset: Int
    let endOffset: Int
    let paragraphIndex: Int
    var anchorJson: String?
    var note: String?
    let createdAt: Int?

    init(
        id: String,
        page: Int,
        lang: String,
        color: String,
        text: String,
        startOffset: Int,
        endOffset: Int,
        paragraphIndex: Int,
        anchorJson: String? = nil,
        note: String? = nil,
        createdAt: Int? = nil
    ) {
        self.id = id
        self.page = page
        self.lang = lang
        self.color = color
        self.text = text
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.paragraphIndex = paragraphIndex
        self.anchorJson = anchorJson
        self.note = note
        self.createdAt = createdAt
    }
}

struct NormalizedPdfRect: Codable, Equatable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

struct DocumentHighlightAnchor: Codable, Equatable {
    let kind: String // "pdf" | "epub"
    let rects: [NormalizedPdfRect]?
    let cfi: String?
    let chapterTitle: String?
    let href: String?
    let prefix: String?
    let suffix: String?

    static func parse(_ raw: String?) -> DocumentHighlightAnchor? {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DocumentHighlightAnchor.self, from: data)
    }

    static func encodePdf(rects: [NormalizedPdfRect]) -> String {
        let anchor = DocumentHighlightAnchor(
            kind: "pdf",
            rects: rects,
            cfi: nil,
            chapterTitle: nil,
            href: nil,
            prefix: nil,
            suffix: nil
        )
        guard let data = try? JSONEncoder().encode(anchor),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    static func encodeEpub(cfi: String, chapterTitle: String? = nil) -> String {
        let anchor = DocumentHighlightAnchor(
            kind: "epub",
            rects: nil,
            cfi: cfi,
            chapterTitle: chapterTitle,
            href: nil,
            prefix: nil,
            suffix: nil
        )
        guard let data = try? JSONEncoder().encode(anchor),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }
}

struct ReadingProgress: Codable {
    let page: Int
    let viewMode: String
    let locator: String?
    let progression: Double?
    let lastRead: Int?

    init(
        page: Int,
        viewMode: String,
        locator: String? = nil,
        progression: Double? = nil,
        lastRead: Int? = nil
    ) {
        self.page = page
        self.viewMode = viewMode
        self.locator = locator
        self.progression = progression
        self.lastRead = lastRead
    }
}

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: String
    let role: String
    let content: String
    var timestamp: Date = Date()

    init(id: String = UUID().uuidString, role: String, content: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

