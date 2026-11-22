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
    let format: String?
    let sourceUrl: String?
    let isPublished: Bool
    /// Unix seconds the book was imported. Optional on purpose: an older backend that has not
    /// shipped the column yet simply omits the key, and the synthesized decoder leaves it nil
    /// instead of throwing.
    let createdAt: Int64?
    /// Unix seconds this user last read the book, as known to the server. Optional for the same
    /// reason as `createdAt`; 0/nil means "never read".
    var lastRead: Int64?
    var isFinished: Bool?
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
        bookId: Int64? = nil,
        slug: String,
        title: String,
        author: String? = nil,
        pageCount: Int,
        cover: String? = nil,
        format: String? = "bkb",
        sourceUrl: String? = nil,
        isPublished: Bool = true,
        createdAt: Int64? = nil,
        lastRead: Int64? = nil,
        isFinished: Bool? = false,
        isPriority: Bool? = false,
        defaultFont: String? = nil,
        defaultTheme: String? = nil,
        readerFont: String? = nil,
        readerTheme: String? = nil
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
        self.isPriority = isPriority
        self.defaultFont = defaultFont
        self.defaultTheme = defaultTheme
        self.readerFont = readerFont
        self.readerTheme = readerTheme
    }

    var coverPath: String? {
        guard let cover = cover else { return nil }
        let trimmed = cover.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = "books/\(slug)/output/"
        if trimmed.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count))
        }
        return trimmed.isEmpty ? nil : trimmed
    }
    
    enum CodingKeys: String, CodingKey {
        case bookId = "id"
        case slug, title, author, pageCount, cover, format, sourceUrl, isPublished, createdAt, lastRead
        case isFinished, isPriority
        case defaultFont, defaultTheme, readerFont, readerTheme
    }
}

struct BookState: Codable {
    let isFinished: Bool
    let isPriority: Bool
    let readerFont: String?
    let readerTheme: String?
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
    let anchorJson: String?
    let note: String?
    let createdAt: Int64

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
        createdAt: Int64
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
            kind: "pdf", rects: rects, cfi: nil, chapterTitle: nil, href: nil, prefix: nil, suffix: nil
        )
        guard let data = try? JSONEncoder().encode(anchor),
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }

    static func encodeEpub(cfi: String, chapterTitle: String? = nil) -> String {
        let anchor = DocumentHighlightAnchor(
            kind: "epub", rects: nil, cfi: cfi, chapterTitle: chapterTitle, href: nil, prefix: nil, suffix: nil
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
    let lastRead: Int64?

    init(
        page: Int,
        viewMode: String,
        locator: String? = nil,
        progression: Double? = nil,
        lastRead: Int64? = nil
    ) {
        self.page = page
        self.viewMode = viewMode
        self.locator = locator
        self.progression = progression
        self.lastRead = lastRead
    }
}

extension Book {
    /// Canonical server URL for a rendered book page HTML document.
    func pageURL(serverUrl: String, token: String, lang: String, page: Int) -> String {
        let padPage = String(format: "%04d", page)
        return "\(serverUrl)/books/\(slug)/output/\(lang)/page_\(padPage).html?token=\(token)"
    }
}
