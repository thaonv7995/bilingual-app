import Foundation

enum BackupScope: String, Codable {
    case adminFull = "admin_full"
    case personal = "personal"

    var label: String {
        switch self {
        case .adminFull: return "Full Server Snapshot (Admin)"
        case .personal: return "Personal Backup (Tài khoản cá nhân)"
        }
    }
}

enum RestoreMode: String, Codable, CaseIterable, Identifiable {
    case merge = "merge"
    case overwrite = "overwrite"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .merge: return "Merge (Không phá huỷ)"
        case .overwrite: return "Overwrite (Khôi phục giống hệt Snapshot)"
        }
    }

    var description: String {
        switch self {
        case .merge:
            return "Thêm sách, user, highlight, quyền và cài đặt còn thiếu lên server. Giữ lại tiến độ đọc mới hơn trên server."
        case .overwrite:
            return "Khôi phục toàn bộ trạng thái server giống bản backup (vẫn bảo vệ tài khoản Admin đang thực hiện khôi phục)."
        }
    }
}

enum SyncScheduleInterval: Int, Codable, CaseIterable, Identifiable {
    case manual = 0
    case every15Min = 900
    case everyHour = 3600
    case every6Hours = 21600
    case every24Hours = 86400

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .manual: return "Thủ công"
        case .every15Min: return "Mỗi 15 phút"
        case .everyHour: return "Mỗi 1 giờ"
        case .every6Hours: return "Mỗi 6 giờ"
        case .every24Hours: return "Mỗi 24 giờ"
        }
    }
}

struct BackupCounts: Codable, Equatable {
    let books: Int
    let users: Int
    let permissions: Int
    let highlights: Int
    let readingProgress: Int
    let userBookStates: Int
    let userSettings: Int
    let apiKeys: Int
}

struct ManifestBookEntry: Codable, Identifiable, Equatable {
    var id: String { slug }
    let slug: String
    let title: String
    let author: String
    let format: String?
    let pageCount: Int
    let coverPath: String
    let isPublished: Bool
    let defaultFont: String
    let defaultTheme: String
    let createdAt: Int
    let hasOutputDir: Bool
    let outputFileCount: Int
    let outputSizeBytes: Int
    let contentFingerprint: String

    var resolvedFormat: String {
        let f = (format ?? "bkb").lowercased()
        return (f == "pdf" || f == "epub") ? f : "bkb"
    }

    init(
        slug: String,
        title: String,
        author: String,
        format: String? = "bkb",
        pageCount: Int,
        coverPath: String,
        isPublished: Bool,
        defaultFont: String,
        defaultTheme: String,
        createdAt: Int,
        hasOutputDir: Bool,
        outputFileCount: Int,
        outputSizeBytes: Int,
        contentFingerprint: String
    ) {
        self.slug = slug
        self.title = title
        self.author = author
        self.format = format
        self.pageCount = pageCount
        self.coverPath = coverPath
        self.isPublished = isPublished
        self.defaultFont = defaultFont
        self.defaultTheme = defaultTheme
        self.createdAt = createdAt
        self.hasOutputDir = hasOutputDir
        self.outputFileCount = outputFileCount
        self.outputSizeBytes = outputSizeBytes
        self.contentFingerprint = contentFingerprint
    }
}

struct BackupManifest: Codable, Equatable {
    let version: Int
    let generatedAt: Int
    let scope: String
    let username: String
    let counts: BackupCounts
    let books: [ManifestBookEntry]
}

struct SnapshotUser: Codable, Equatable, Identifiable {
    var id: String { username }
    let username: String
    let passwordHash: String
    let isAdmin: Bool
}

struct SnapshotPermission: Codable, Equatable {
    let username: String
    let bookSlug: String
}

struct SnapshotApiKey: Codable, Equatable {
    let name: String
    let isActive: Bool
    let createdAt: Int
    let keyValue: String?
}

struct SnapshotHighlight: Codable, Identifiable, Equatable {
    let id: String
    let bookSlug: String
    let username: String
    let page: Int
    let lang: String
    let color: String
    let text: String
    let startOffset: Int
    let endOffset: Int
    let paragraphIndex: Int
    let anchorJson: String?
    let note: String
    let createdAt: Int

    init(
        id: String,
        bookSlug: String,
        username: String,
        page: Int,
        lang: String,
        color: String,
        text: String,
        startOffset: Int,
        endOffset: Int,
        paragraphIndex: Int,
        anchorJson: String? = nil,
        note: String,
        createdAt: Int
    ) {
        self.id = id
        self.bookSlug = bookSlug
        self.username = username
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

struct SnapshotReadingProgress: Codable, Equatable {
    let username: String
    let bookSlug: String
    let page: Int
    let viewMode: String
    let locator: String?
    let progression: Double?
    let lastRead: Int

    init(
        username: String,
        bookSlug: String,
        page: Int,
        viewMode: String,
        locator: String? = nil,
        progression: Double? = nil,
        lastRead: Int
    ) {
        self.username = username
        self.bookSlug = bookSlug
        self.page = page
        self.viewMode = viewMode
        self.locator = locator
        self.progression = progression
        self.lastRead = lastRead
    }
}

struct SnapshotUserBookState: Codable, Equatable {
    let username: String
    let bookSlug: String
    let isFinished: Bool
    let onShelf: Bool
    let isPriority: Bool
    let readerFont: String
    let readerTheme: String
}

struct SnapshotUserSettings: Codable, Equatable {
    let username: String
    let aiProvider: String
    let aiBaseUrl: String
    let aiModel: String
    let realtimeModel: String
    let realtimeVoice: String
    let audioProvider: String
    let audioSource: String
    let audioVoice: String
    let audioVoiceEn: String
    let audioVoiceVi: String
    let ttsModel: String
    let speechSpeed: String
    let layoutMode: String
    let hideFinishedBooks: Bool
    let vocaOrigin: String
    let updatedAt: Int
    let hasLlmKey: Bool
    let hasRealtimeKey: Bool
    let hasAzureKey: Bool
    let hasElevenLabsKey: Bool
    let hasVocaToken: Bool
    let llmApiKey: String?
    let realtimeApiKey: String?
    let azureApiKey: String?
    let elevenlabsApiKey: String?
    let vocaToken: String?
}

struct BackupSnapshot: Codable, Equatable {
    let version: Int
    let exportedAt: Int
    let scope: String
    let exportedBy: String
    let includesSecrets: Bool
    let books: [ManifestBookEntry]
    let users: [SnapshotUser]
    let permissions: [SnapshotPermission]
    let apiKeys: [SnapshotApiKey]
    let highlights: [SnapshotHighlight]
    let readingProgress: [SnapshotReadingProgress]
    let userBookStates: [SnapshotUserBookState]
    let userSettings: [SnapshotUserSettings]
}

struct RestoreSelection: Codable, Equatable {
    var mode: RestoreMode = .merge
    var uploadMissingBooks: Bool = true
    var overwriteExistingBooks: Bool = false
    var restoreBooksMetadata: Bool = true
    var restoreUsers: Bool = true
    var restorePermissions: Bool = true
    var restoreHighlights: Bool = true
    var restoreProgress: Bool = true
    var restoreStates: Bool = true
    var restoreSettings: Bool = true
    var restoreSecrets: Bool = false
    var restoreApiKeys: Bool = false
    var preferSnapshotProgress: Bool = false
}

struct BackupRestoreRequest: Codable {
    let snapshot: BackupSnapshot
    let mode: String
    let dryRun: Bool
    let restoreUsers: Bool
    let restorePermissions: Bool
    let restoreBooksMetadata: Bool
    let restoreApiKeys: Bool
    let restoreHighlights: Bool
    let restoreProgress: Bool
    let restoreStates: Bool
    let restoreSettings: Bool
    let restoreSecrets: Bool
    let preferSnapshotProgress: Bool
}

struct RestoreBooksSummary: Codable, Equatable {
    let updated: Int
    let unchanged: Int
    let missingFiles: [String]
}

struct RestoreEntitySummary: Codable, Equatable {
    let created: Int
    let updated: Int?
    let unchanged: Int?
    let skipped: Int?
    let deleted: Int
}

struct RestoreSummary: Codable, Equatable {
    let books: RestoreBooksSummary
    let users: RestoreEntitySummary
    let permissions: RestoreEntitySummary
    let apiKeys: RestoreEntitySummary
    let highlights: RestoreEntitySummary
    let readingProgress: RestoreEntitySummary
    let userBookStates: RestoreEntitySummary
    let userSettings: RestoreEntitySummary
}

struct BackupRestoreResponse: Codable, Equatable {
    let ok: Bool
    let dryRun: Bool
    let mode: String
    let scope: String
    let summary: RestoreSummary
    let warnings: [String]
}

struct LocalBookIndexEntry: Codable, Equatable, Identifiable {
    var id: String { slug }
    let slug: String
    var title: String
    var format: String?
    var contentFingerprint: String
    var bkbSizeBytes: Int64
    var bkbSha256: String
    var downloadedAt: Int
    var extractedAt: Int

    var resolvedFormat: String {
        let f = (format ?? "bkb").lowercased()
        return (f == "pdf" || f == "epub") ? f : "bkb"
    }

    init(
        slug: String,
        title: String,
        format: String? = "bkb",
        contentFingerprint: String,
        bkbSizeBytes: Int64,
        bkbSha256: String,
        downloadedAt: Int,
        extractedAt: Int
    ) {
        self.slug = slug
        self.title = title
        self.format = format
        self.contentFingerprint = contentFingerprint
        self.bkbSizeBytes = bkbSizeBytes
        self.bkbSha256 = bkbSha256
        self.downloadedAt = downloadedAt
        self.extractedAt = extractedAt
    }
}

struct LocalVaultIndex: Codable, Equatable {
    var version: Int = 1
    var lastSyncAt: Int?
    var lastServerUrl: String?
    var lastScope: String?
    var lastUsername: String?
    var lastManifest: BackupManifest?
    var booksBySlug: [String: LocalBookIndexEntry] = [:]
}

struct LocalSnapshotRecord: Identifiable, Equatable {
    let id: String
    let folderName: String
    let directoryURL: URL
    let snapshotURL: URL
    let exportedAt: Int
    let scope: String
    let includesSecrets: Bool
    let bookCount: Int
    let userCount: Int
    let highlightCount: Int
    let fileSizeBytes: Int64
}

