import Foundation
import CryptoKit

struct OfflineAccountKey: Equatable {
    let serverUrl: String
    let username: String

    var normalizedServerUrl: String {
        serverUrl
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    var normalizedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        !normalizedUsername.isEmpty
    }

    /// Stable filesystem-safe identifier scoped to both server URL and username so switching
    /// accounts or servers never leaks another user's private shelf, highlights, or pending ops.
    var folderName: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let safeUser = normalizedUsername.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "_"
        }
        let userPrefix = String(String(safeUser).prefix(32))
        let digest = SHA256.hash(data: Data("\(normalizedServerUrl)|\(normalizedUsername)".utf8))
        let hex8 = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(userPrefix.isEmpty ? "user" : userPrefix)_\(hex8)"
    }
}

enum OfflinePendingOp: Codable, Equatable, Identifiable {
    case upsertHighlight(slug: String, highlight: Highlight)
    case deleteHighlight(slug: String, highlightId: String)
    case saveProgress(slug: String, page: Int, viewMode: String, lastRead: Int64)
    case patchBookState(slug: String, isFinished: Bool?, isPriority: Bool?, readerFont: String?, readerTheme: String?)

    var id: String {
        switch self {
        case .upsertHighlight(let slug, let highlight):
            return "hl_upsert:\(slug):\(highlight.id)"
        case .deleteHighlight(let slug, let highlightId):
            return "hl_delete:\(slug):\(highlightId)"
        case .saveProgress(let slug, _, _, _):
            return "progress:\(slug)"
        case .patchBookState(let slug, _, _, _, _):
            return "state:\(slug)"
        }
    }

    var slug: String {
        switch self {
        case .upsertHighlight(let slug, _),
             .deleteHighlight(let slug, _),
             .saveProgress(let slug, _, _, _),
             .patchBookState(let slug, _, _, _, _):
            return slug
        }
    }
}

/// Manages per-account cached library metadata, highlights, and a coalesced queue of
/// offline edits so the reader stays responsive without internet and syncs cleanly later.
final class OfflineSyncStore {
    let rootDirectory: URL
    private let fm = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(rootDirectory: URL? = nil) {
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.rootDirectory = docs.appendingPathComponent("offline_store", isDirectory: true)
        }
    }

    private func accountDir(for account: OfflineAccountKey) -> URL {
        rootDirectory.appendingPathComponent(account.folderName, isDirectory: true)
    }

    private func booksFileURL(for account: OfflineAccountKey) -> URL {
        accountDir(for: account).appendingPathComponent("books.json")
    }

    private func highlightsDir(for account: OfflineAccountKey) -> URL {
        accountDir(for: account).appendingPathComponent("highlights", isDirectory: true)
    }

    private func highlightsFileURL(slug: String, for account: OfflineAccountKey) -> URL? {
        guard let safeSlug = try? BookArchiveExtractorIOS.validateSlug(slug) else { return nil }
        return highlightsDir(for: account).appendingPathComponent("\(safeSlug).json")
    }

    private func pendingOpsFileURL(for account: OfflineAccountKey) -> URL {
        accountDir(for: account).appendingPathComponent("pending_ops.json")
    }

    // MARK: - Cached Library Books

    func hasSavedLibraryFile(for account: OfflineAccountKey) -> Bool {
        guard account.isValid else { return false }
        return fm.fileExists(atPath: booksFileURL(for: account).path)
    }

    func saveCachedBooks(_ books: [Book], for account: OfflineAccountKey) {
        guard account.isValid else { return }
        let url = booksFileURL(for: account)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(books) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func loadCachedBooks(for account: OfflineAccountKey) -> [Book] {
        guard account.isValid else { return [] }
        let url = booksFileURL(for: account)
        guard let data = try? Data(contentsOf: url),
              var decoded = try? decoder.decode([Book].self, from: data) else {
            return []
        }

        // Layer any still-unsynced offline state or progress updates on top so offline restarts
        // preserve starred books, finished status, appearance overrides, and newest lastRead.
        let ops = loadPendingOps(for: account)
        for op in ops {
            switch op {
            case .patchBookState(let slug, let isFinished, let isPriority, let readerFont, let readerTheme):
                guard let idx = decoded.firstIndex(where: { $0.slug == slug }) else { continue }
                if let isFinished { decoded[idx].isFinished = isFinished }
                if let isPriority { decoded[idx].isPriority = isPriority }
                if let readerFont { decoded[idx].readerFont = readerFont }
                if let readerTheme { decoded[idx].readerTheme = readerTheme }
            case .saveProgress(let slug, _, _, let lastRead):
                guard let idx = decoded.firstIndex(where: { $0.slug == slug }) else { continue }
                decoded[idx].lastRead = max(decoded[idx].lastRead ?? 0, lastRead)
            case .upsertHighlight, .deleteHighlight:
                break
            }
        }
        return decoded
    }

    /// Applies a fetched server library list on top of any pending local state overrides, returning
    /// the effective books list while saving it for offline access.
    func reconcileAndSaveBooks(_ serverBooks: [Book], for account: OfflineAccountKey) -> [Book] {
        saveCachedBooks(serverBooks, for: account)
        return loadCachedBooks(for: account)
    }

    /// Reconstructs minimal `Book` records from locally extracted `<slug>/manifest.json` files
    /// when a user upgrades from a version that had downloaded books without `books.json`.
    static func reconstructFallbackBooks(from booksDirectory: URL) -> [Book] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: booksDirectory, includingPropertiesForKeys: nil) else {
            return []
        }

        struct RawManifest: Decodable {
            let slug: String?
            let title: String?
            let author: String?
            let pageCount: Int?
            let cover: String?
            let coverPath: String?
            let isPublished: Bool?
            let createdAt: Int64?
            let defaultFont: String?
            let defaultTheme: String?
            let files: [String]?
        }

        var result: [Book] = []
        for dir in entries where !dir.lastPathComponent.hasPrefix(".") {
            let slug = dir.lastPathComponent
            let outputDir = dir.appendingPathComponent("output", isDirectory: true)
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: outputDir.path),
                  fm.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL) else {
                continue
            }

            let raw = try? JSONDecoder().decode(RawManifest.self, from: data)
            let resolvedSlug = (try? BookArchiveExtractorIOS.validateSlug(raw?.slug ?? slug)) ?? slug
            let inferredPages = inferPageCount(outputDir: outputDir)
            let pageCount = max(raw?.pageCount ?? 0, inferredPages, 1)
            let resolvedCover = raw?.cover ?? raw?.coverPath ?? detectFallbackCoverRelativePath(outputDir: outputDir)

            result.append(Book(
                bookId: nil,
                slug: resolvedSlug,
                title: (raw?.title?.isEmpty == false) ? raw!.title! : resolvedSlug,
                author: raw?.author,
                pageCount: pageCount,
                cover: resolvedCover,
                isPublished: raw?.isPublished ?? true,
                createdAt: raw?.createdAt,
                lastRead: nil,
                isFinished: false,
                isPriority: false,
                defaultFont: raw?.defaultFont,
                defaultTheme: raw?.defaultTheme,
                readerFont: nil,
                readerTheme: nil
            ))
        }
        return result.sorted { $0.slug < $1.slug }
    }

    private static func inferPageCount(outputDir: URL) -> Int {
        let enDir = outputDir.appendingPathComponent("en", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: enDir.path) else { return 0 }
        return files.filter { $0.hasPrefix("page_") && $0.hasSuffix(".html") }.count
    }

    private static func detectFallbackCoverRelativePath(outputDir: URL) -> String? {
        let candidates = [
            "assets/images/page_0001_cover_logo.png",
            "assets/cover.jpg",
            "assets/cover.png"
        ]
        for rel in candidates {
            if FileManager.default.fileExists(atPath: outputDir.appendingPathComponent(rel).path) {
                return rel
            }
        }
        return nil
    }

    // MARK: - Cached Highlights

    func saveCachedHighlights(_ highlights: [Highlight], slug: String, for account: OfflineAccountKey) {
        guard account.isValid, let url = highlightsFileURL(slug: slug, for: account) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(highlights) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func loadCachedHighlights(slug: String, for account: OfflineAccountKey) -> [Highlight] {
        guard account.isValid, let url = highlightsFileURL(slug: slug, for: account) else { return [] }
        let base: [Highlight]
        if let data = try? Data(contentsOf: url),
           let decoded = try? decoder.decode([Highlight].self, from: data) {
            base = decoded
        } else {
            base = []
        }
        return mergeHighlightsWithPending(base, slug: slug, for: account)
    }

    func mergeHighlightsWithPending(_ serverHighlights: [Highlight], slug: String, for account: OfflineAccountKey) -> [Highlight] {
        let ops = loadPendingOps(for: account).filter { $0.slug == slug }
        guard !ops.isEmpty else { return serverHighlights }

        var merged = serverHighlights
        for op in ops {
            switch op {
            case .upsertHighlight(_, let highlight):
                if let idx = merged.firstIndex(where: { $0.id == highlight.id }) {
                    merged[idx] = highlight
                } else {
                    merged.append(highlight)
                }
            case .deleteHighlight(_, let highlightId):
                merged.removeAll { $0.id == highlightId }
            case .saveProgress, .patchBookState:
                break
            }
        }
        return merged.sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Durable Pending Operations Queue

    func loadPendingOps(for account: OfflineAccountKey) -> [OfflinePendingOp] {
        guard account.isValid else { return [] }
        let url = pendingOpsFileURL(for: account)
        guard let data = try? Data(contentsOf: url),
              let ops = try? decoder.decode([OfflinePendingOp].self, from: data) else {
            return []
        }
        return ops
    }

    private func writePendingOps(_ ops: [OfflinePendingOp], for account: OfflineAccountKey) {
        guard account.isValid else { return }
        let url = pendingOpsFileURL(for: account)
        if ops.isEmpty {
            try? fm.removeItem(at: url)
            return
        }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(ops) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func enqueue(_ newOp: OfflinePendingOp, for account: OfflineAccountKey) {
        guard account.isValid else { return }
        var ops = loadPendingOps(for: account)

        switch newOp {
        case .upsertHighlight(let slug, let highlight):
            ops.removeAll {
                switch $0 {
                case .upsertHighlight(let s, let h):
                    return s == slug && h.id == highlight.id
                case .deleteHighlight(let s, let id):
                    return s == slug && id == highlight.id
                default:
                    return false
                }
            }
            ops.append(newOp)

        case .deleteHighlight(let slug, let highlightId):
            ops.removeAll {
                switch $0 {
                case .upsertHighlight(let s, let h):
                    return s == slug && h.id == highlightId
                case .deleteHighlight(let s, let id):
                    return s == slug && id == highlightId
                default:
                    return false
                }
            }
            ops.append(newOp)

        case .saveProgress(let slug, _, _, let incomingTs):
            if let existingIdx = ops.firstIndex(where: {
                if case .saveProgress(let s, _, _, _) = $0 { return s == slug }
                return false
            }), case .saveProgress(_, _, _, let existingTs) = ops[existingIdx], existingTs > incomingTs {
                return
            }
            ops.removeAll {
                if case .saveProgress(let s, _, _, _) = $0 { return s == slug }
                return false
            }
            ops.append(newOp)

        case .patchBookState(let slug, let isFinished, let isPriority, let readerFont, let readerTheme):
            var mergedFinished = isFinished
            var mergedPriority = isPriority
            var mergedFont = readerFont
            var mergedTheme = readerTheme
            if let existingIdx = ops.firstIndex(where: {
                if case .patchBookState(let s, _, _, _, _) = $0 { return s == slug }
                return false
            }), case .patchBookState(_, let oldF, let oldP, let oldFont, let oldTheme) = ops[existingIdx] {
                mergedFinished = isFinished ?? oldF
                mergedPriority = isPriority ?? oldP
                mergedFont = readerFont ?? oldFont
                mergedTheme = readerTheme ?? oldTheme
                ops.remove(at: existingIdx)
            }
            ops.append(.patchBookState(
                slug: slug,
                isFinished: mergedFinished,
                isPriority: mergedPriority,
                readerFont: mergedFont,
                readerTheme: mergedTheme
            ))
        }

        writePendingOps(ops, for: account)
    }

    /// Removes `op` from the queue only if the current stored op still matches `op` (so a newer
    /// concurrent edit written while an HTTP upload was in flight is never discarded).
    func removeExactPendingOp(_ op: OfflinePendingOp, for account: OfflineAccountKey) {
        guard account.isValid else { return }
        var ops = loadPendingOps(for: account)
        ops.removeAll { $0 == op }
        writePendingOps(ops, for: account)
    }

    func removePendingProgress(slug: String, upToLastRead lastRead: Int64?, for account: OfflineAccountKey) {
        guard account.isValid else { return }
        var ops = loadPendingOps(for: account)
        ops.removeAll { item in
            guard case .saveProgress(let s, _, _, let ts) = item, s == slug else { return false }
            guard let cutoff = lastRead else { return true }
            return ts <= cutoff
        }
        writePendingOps(ops, for: account)
    }

    func clearPendingOps(for account: OfflineAccountKey) {
        writePendingOps([], for: account)
    }
}

