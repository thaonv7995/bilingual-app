import Foundation
import Combine

protocol BackupTransport {
    var serverUrl: String { get }
    func fetchBackupManifest() async throws -> BackupManifest
    func exportBackupSnapshot(includeSecrets: Bool) async throws -> BackupSnapshot
    func downloadBookArchive(slug: String, to destinationURL: URL) async throws
    func uploadBookArchive(fileURL: URL) async throws -> String
    func restoreBackupSnapshot(_ restoreRequest: BackupRestoreRequest) async throws -> BackupRestoreResponse
}

extension APIService: BackupTransport {}

struct SyncRunResult: Equatable {
    let timestamp: Int
    let downloadedBooks: Int
    let skippedUnchangedBooks: Int
    let totalBooks: Int
    let snapshotFolder: String
    let failedBooks: [String]
}

struct RestoreExecutionResult: Equatable {
    let uploadedBooks: [String]
    let failedBookUploads: [String]
    let response: BackupRestoreResponse
}

@MainActor
final class BackupManager: ObservableObject {
    static let shared = BackupManager()

    private enum PrefKey {
        static let vaultPath = "bilingual.mac.vaultPath"
        static let scheduleInterval = "bilingual.mac.syncIntervalSeconds"
        static let syncOnLaunch = "bilingual.mac.syncOnLaunch"
        static let includeSecrets = "bilingual.mac.backupIncludeSecrets"
        static let maxSnapshots = "bilingual.mac.maxRetainedSnapshots"
    }

    @Published var vaultURL: URL {
        didSet {
            defaults.set(vaultURL.path, forKey: PrefKey.vaultPath)
            reloadVaultState()
        }
    }

    @Published var scheduleInterval: SyncScheduleInterval {
        didSet {
            defaults.set(scheduleInterval.rawValue, forKey: PrefKey.scheduleInterval)
            restartScheduler()
        }
    }

    @Published var syncOnLaunch: Bool {
        didSet { defaults.set(syncOnLaunch, forKey: PrefKey.syncOnLaunch) }
    }

    @Published var includeSecrets: Bool {
        didSet { defaults.set(includeSecrets, forKey: PrefKey.includeSecrets) }
    }

    @Published var maxRetainedSnapshots: Int {
        didSet { defaults.set(max(1, min(100, maxRetainedSnapshots)), forKey: PrefKey.maxSnapshots) }
    }

    @Published private(set) var isSyncing: Bool = false
    @Published private(set) var syncPhase: String = ""
    @Published private(set) var syncProgress: Double = 0
    @Published private(set) var lastSyncResult: SyncRunResult?
    @Published private(set) var lastError: String?
    @Published private(set) var wipeGuardTriggered: Bool = false

    @Published private(set) var vaultIndex: LocalVaultIndex = LocalVaultIndex()
    @Published private(set) var latestSnapshot: BackupSnapshot?
    @Published private(set) var snapshots: [LocalSnapshotRecord] = []

    private let defaults: UserDefaults
    private var transport: BackupTransport?
    private var schedulerTimer: Timer?

    private convenience init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
        let defaultVault = docs.appendingPathComponent("BilingualReaderBackup", isDirectory: true)
        self.init(defaultVaultURL: defaultVault, defaults: .standard, transport: nil, startTimer: true)
    }

    init(
        defaultVaultURL: URL,
        defaults: UserDefaults = .standard,
        transport: BackupTransport? = nil,
        startTimer: Bool = false
    ) {
        self.defaults = defaults
        self.transport = transport

        let savedPath = defaults.string(forKey: PrefKey.vaultPath)
        self.vaultURL = savedPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultVaultURL

        let rawInterval = defaults.object(forKey: PrefKey.scheduleInterval) as? Int ?? SyncScheduleInterval.everyHour.rawValue
        self.scheduleInterval = SyncScheduleInterval(rawValue: rawInterval) ?? .everyHour
        self.syncOnLaunch = defaults.object(forKey: PrefKey.syncOnLaunch) as? Bool ?? true
        self.includeSecrets = defaults.object(forKey: PrefKey.includeSecrets) as? Bool ?? false
        self.maxRetainedSnapshots = max(1, defaults.object(forKey: PrefKey.maxSnapshots) as? Int ?? 10)

        try? ensureVaultStructure()
        reloadVaultState()
        if startTimer {
            restartScheduler()
        }
    }

    private func resolvedTransport() -> BackupTransport {
        transport ?? APIService.shared
    }

    // MARK: - Vault Directories

    var latestDir: URL { vaultURL.appendingPathComponent("latest", isDirectory: true) }
    var snapshotsDir: URL { vaultURL.appendingPathComponent("snapshots", isDirectory: true) }
    var booksDir: URL { vaultURL.appendingPathComponent("books", isDirectory: true) }

    var latestIndexURL: URL { latestDir.appendingPathComponent("index.json") }
    var latestManifestURL: URL { latestDir.appendingPathComponent("manifest.json") }
    var latestSnapshotURL: URL { latestDir.appendingPathComponent("snapshot.json") }

    func bookRootDir(slug: String) -> URL {
        booksDir.appendingPathComponent(slug, isDirectory: true)
    }

    func localBKBURL(slug: String) -> URL {
        bookRootDir(slug: slug).appendingPathComponent("\(slug).bkb")
    }

    func localSourceURL(slug: String, format: String) -> URL {
        let ext = (format == "pdf" || format == "epub") ? format : "bkb"
        return bookRootDir(slug: slug).appendingPathComponent("\(slug).\(ext)")
    }

    func localOutputDir(slug: String) -> URL {
        bookRootDir(slug: slug).appendingPathComponent("output", isDirectory: true)
    }

    func localPageURL(slug: String, lang: String, page: Int) -> URL? {
        guard let safeSlug = try? BookArchiveExtractor.validateSlug(slug),
              ["en", "vi"].contains(lang) else {
            return nil
        }
        let file = localOutputDir(slug: safeSlug)
            .appendingPathComponent(lang, isDirectory: true)
            .appendingPathComponent(String(format: "page_%04d.html", page))
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    func localCoverURL(slug: String, coverPath: String?) -> URL? {
        guard let safeSlug = try? BookArchiveExtractor.validateSlug(slug) else { return nil }
        let fm = FileManager.default
        if let coverPath, !coverPath.isEmpty {
            var rel = coverPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let prefix = "books/\(safeSlug)/output/"
            if rel.hasPrefix(prefix) {
                rel = String(rel.dropFirst(prefix.count))
            }
            if !rel.contains("..") {
                let file = localOutputDir(slug: safeSlug).appendingPathComponent(rel)
                if fm.fileExists(atPath: file.path) { return file }
            }
        }
        let cachedCover = bookRootDir(slug: safeSlug).appendingPathComponent("cover_cache.img")
        if fm.fileExists(atPath: cachedCover.path) { return cachedCover }
        return nil
    }

    func hasOfflineBook(slug: String, format: String? = nil) -> Bool {
        let fm = FileManager.default
        let resolvedFmt = format ?? vaultIndex.booksBySlug[slug]?.resolvedFormat ?? "bkb"
        if resolvedFmt == "pdf" || resolvedFmt == "epub" {
            return fm.fileExists(atPath: localSourceURL(slug: slug, format: resolvedFmt).path)
        }
        if fm.fileExists(atPath: localOutputDir(slug: slug).path) {
            return true
        }
        return fm.fileExists(atPath: localSourceURL(slug: slug, format: "pdf").path)
            || fm.fileExists(atPath: localSourceURL(slug: slug, format: "epub").path)
    }

    func ensureVaultStructure() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        try fm.createDirectory(at: latestDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: booksDir, withIntermediateDirectories: true)
    }

    func reloadVaultState() {
        let decoder = JSONDecoder()
        if let idxData = try? Data(contentsOf: latestIndexURL),
           let idx = try? decoder.decode(LocalVaultIndex.self, from: idxData) {
            self.vaultIndex = idx
        } else {
            self.vaultIndex = LocalVaultIndex()
        }

        if let snapData = try? Data(contentsOf: latestSnapshotURL),
           let snap = try? decoder.decode(BackupSnapshot.self, from: snapData) {
            self.latestSnapshot = snap
        } else {
            self.latestSnapshot = nil
        }

        self.snapshots = scanSnapshots()
    }

    private func scanSnapshots() -> [LocalSnapshotRecord] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: snapshotsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        var records: [LocalSnapshotRecord] = []
        for dir in dirs {
            let snapFile = dir.appendingPathComponent("snapshot.json")
            guard fm.fileExists(atPath: snapFile.path),
                  let data = try? Data(contentsOf: snapFile),
                  let snap = try? decoder.decode(BackupSnapshot.self, from: data) else {
                continue
            }
            let attrs = try? fm.attributesOfItem(atPath: snapFile.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? Int64(data.count)
            records.append(
                LocalSnapshotRecord(
                    id: dir.lastPathComponent,
                    folderName: dir.lastPathComponent,
                    directoryURL: dir,
                    snapshotURL: snapFile,
                    exportedAt: snap.exportedAt,
                    scope: snap.scope,
                    includesSecrets: snap.includesSecrets,
                    bookCount: snap.books.count,
                    userCount: snap.users.count,
                    highlightCount: snap.highlights.count,
                    fileSizeBytes: size
                )
            )
        }
        return records.sorted {
            if $0.exportedAt != $1.exportedAt { return $0.exportedAt > $1.exportedAt }
            return $0.folderName > $1.folderName
        }
    }

    func loadSnapshot(from record: LocalSnapshotRecord) throws -> BackupSnapshot {
        let data = try Data(contentsOf: record.snapshotURL)
        return try JSONDecoder().decode(BackupSnapshot.self, from: data)
    }

    // MARK: - Scheduler

    func restartScheduler() {
        schedulerTimer?.invalidate()
        schedulerTimer = nil
        guard scheduleInterval != .manual else { return }
        let interval = TimeInterval(scheduleInterval.rawValue)
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isSyncing, APIService.shared.isAuthenticated else { return }
                await self.syncFromServer()
            }
        }
    }

    // MARK: - Normal Pull Sync (Server = Source of Truth)

    @discardableResult
    func syncFromServer(forceAllowEmptyServer: Bool = false) async -> SyncRunResult? {
        guard !isSyncing else { return nil }
        isSyncing = true
        lastError = nil
        wipeGuardTriggered = false
        syncProgress = 0
        syncPhase = "Đang kiểm tra trạng thái Backup từ server…"

        defer {
            isSyncing = false
        }

        let client = resolvedTransport()

        do {
            try ensureVaultStructure()
            let manifest = try await client.fetchBackupManifest()

            // Wipe-protection guard: if local Vault has books and server suddenly returns 0 books,
            // refuse to overwrite local canonical snapshot automatically.
            if !forceAllowEmptyServer && !vaultIndex.booksBySlug.isEmpty && manifest.books.isEmpty {
                wipeGuardTriggered = true
                lastError = "Phát hiện server đang có 0 sách trong khi Mac Vault đang lưu \(vaultIndex.booksBySlug.count) sách. Đã tạm dừng ghi đè backup để bảo vệ dữ liệu!"
                syncPhase = "Tạm dừng để bảo vệ dữ liệu"
                return nil
            }

            var updatedIndex = vaultIndex
            var downloaded = 0
            var skipped = 0
            var failedBooks: [String] = []
            let total = manifest.books.count
            let now = Int(Date().timeIntervalSince1970)

            for (idx, entry) in manifest.books.enumerated() {
                let stepPrefix = "(\(idx + 1)/\(max(1, total)))"
                syncProgress = Double(idx) / Double(max(1, total + 1))

                guard let safeSlug = try? BookArchiveExtractor.validateSlug(entry.slug) else {
                    failedBooks.append(entry.slug)
                    continue
                }

                let fmt = entry.resolvedFormat
                let archiveDest = localSourceURL(slug: safeSlug, format: fmt)
                let outputDest = localOutputDir(slug: safeSlug)
                let existing = updatedIndex.booksBySlug[safeSlug]
                let hasLocalContent = (fmt == "bkb")
                    ? (FileManager.default.fileExists(atPath: archiveDest.path) && FileManager.default.fileExists(atPath: outputDest.path))
                    : FileManager.default.fileExists(atPath: archiveDest.path)
                let alreadyUpToDate = existing != nil
                    && existing?.resolvedFormat == fmt
                    && !entry.contentFingerprint.isEmpty
                    && existing?.contentFingerprint == entry.contentFingerprint
                    && hasLocalContent

                if alreadyUpToDate {
                    skipped += 1
                    syncPhase = "\(stepPrefix) Bỏ qua '\(entry.title)' (không thay đổi)"
                    continue
                }

                syncPhase = "\(stepPrefix) Đang tải '\(entry.title)' (.\(fmt))…"
                let tempFile = vaultURL.appendingPathComponent(".tmp_\(safeSlug)_\(UUID().uuidString).\(fmt)")
                defer { try? FileManager.default.removeItem(at: tempFile) }

                do {
                    let bookFolder = bookRootDir(slug: safeSlug)
                    try FileManager.default.createDirectory(at: bookFolder, withIntermediateDirectories: true)
                    try await client.downloadBookArchive(slug: safeSlug, to: tempFile)

                    syncPhase = fmt == "bkb"
                        ? "\(stepPrefix) Đang giải nén & kiểm tra SHA-256 '\(entry.title)'…"
                        : "\(stepPrefix) Đang lưu & kiểm tra SHA-256 '\(entry.title)'…"
                    let fileResult = try await Task.detached(priority: .utility) {
                        let fm = FileManager.default
                        if fmt == "bkb" {
                            try BookArchiveExtractor.extractBKB(archiveURL: tempFile, into: bookFolder)
                        }

                        if fm.fileExists(atPath: archiveDest.path) {
                            try fm.removeItem(at: archiveDest)
                        }
                        try fm.moveItem(at: tempFile, to: archiveDest)

                        let sha = try BookArchiveExtractor.sha256Hex(fileURL: archiveDest)
                        let attrs = try? fm.attributesOfItem(atPath: archiveDest.path)
                        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                        return (sha: sha, size: size)
                    }.value

                    if fmt != "bkb", !entry.coverPath.isEmpty {
                        let fullCoverPath = entry.coverPath.hasPrefix("books/")
                            ? entry.coverPath
                            : "books/\(safeSlug)/output/\(entry.coverPath)"
                        if let coverData = await APIService.shared.fetchBookCoverData(coverPath: fullCoverPath), !coverData.isEmpty {
                            try? coverData.write(to: bookFolder.appendingPathComponent("cover_cache.img"), options: .atomic)
                        }
                    }

                    updatedIndex.booksBySlug[safeSlug] = LocalBookIndexEntry(
                        slug: safeSlug,
                        title: entry.title,
                        format: fmt,
                        contentFingerprint: entry.contentFingerprint,
                        bkbSizeBytes: fileResult.size,
                        bkbSha256: fileResult.sha,
                        downloadedAt: now,
                        extractedAt: now
                    )
                    downloaded += 1
                } catch {
                    failedBooks.append("\(safeSlug): \(error.localizedDescription)")
                }
            }

            syncPhase = "Đang tải Snapshot cơ sở dữ liệu (Users, Highlights, Progress, Settings)…"
            syncProgress = Double(total) / Double(max(1, total + 1))
            let snapshot = try await client.exportBackupSnapshot(includeSecrets: includeSecrets)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let snapshotFolderName = nextSnapshotFolderName(for: snapshot.exportedAt)
            let snapshotFolderURL = snapshotsDir.appendingPathComponent(snapshotFolderName, isDirectory: true)
            try FileManager.default.createDirectory(at: snapshotFolderURL, withIntermediateDirectories: true)

            let snapshotData = try encoder.encode(snapshot)
            try snapshotData.write(to: snapshotFolderURL.appendingPathComponent("snapshot.json"), options: .atomic)
            try snapshotData.write(to: latestSnapshotURL, options: .atomic)

            let manifestData = try encoder.encode(manifest)
            try manifestData.write(to: latestManifestURL, options: .atomic)

            updatedIndex.lastSyncAt = now
            updatedIndex.lastServerUrl = client.serverUrl
            updatedIndex.lastScope = snapshot.scope
            updatedIndex.lastUsername = manifest.username
            updatedIndex.lastManifest = manifest

            let indexData = try encoder.encode(updatedIndex)
            try indexData.write(to: latestIndexURL, options: .atomic)

            enforceRetentionPolicy()
            reloadVaultState()

            syncProgress = 1.0
            syncPhase = failedBooks.isEmpty
                ? "Đồng bộ hoàn tất"
                : "Hoàn tất với \(failedBooks.count) sách lỗi"

            let runResult = SyncRunResult(
                timestamp: now,
                downloadedBooks: downloaded,
                skippedUnchangedBooks: skipped,
                totalBooks: total,
                snapshotFolder: snapshotFolderName,
                failedBooks: failedBooks
            )
            lastSyncResult = runResult
            if !failedBooks.isEmpty {
                lastError = "Một số sách chưa tải được: \(failedBooks.joined(separator: "; "))"
            }
            return runResult
        } catch {
            lastError = "Lỗi đồng bộ: \(error.localizedDescription)"
            syncPhase = "Đồng bộ thất bại"
            return nil
        }
    }

    private func nextSnapshotFolderName(for timestamp: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let base = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        var candidate = base
        var suffix = 1
        while FileManager.default.fileExists(atPath: snapshotsDir.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// Prunes snapshots exceeding `maxRetainedSnapshots`, preserving `.bkb` files referenced by any retained snapshot.
    func enforceRetentionPolicy() {
        let current = scanSnapshots()
        guard current.count > maxRetainedSnapshots else { return }
        let toDelete = current.dropFirst(maxRetainedSnapshots)
        for rec in toDelete {
            try? FileManager.default.removeItem(at: rec.directoryURL)
        }
    }

    func deleteSnapshot(_ record: LocalSnapshotRecord) {
        try? FileManager.default.removeItem(at: record.directoryURL)
        reloadVaultState()
    }

    /// Removes `.bkb` book directories on disk only if NO snapshot (neither `latest` nor `snapshots/*`) references them.
    @discardableResult
    func pruneOrphanBookArchives() -> [String] {
        var referenced = Set<String>()
        if let latest = latestSnapshot {
            referenced.formUnion(latest.books.map(\.slug))
        }
        for rec in scanSnapshots() {
            if let snap = try? loadSnapshot(from: rec) {
                referenced.formUnion(snap.books.map(\.slug))
            }
        }

        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: booksDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var removed: [String] = []
        var updatedIndex = vaultIndex
        for dir in dirs {
            let slug = dir.lastPathComponent
            if !referenced.contains(slug) {
                try? fm.removeItem(at: dir)
                updatedIndex.booksBySlug.removeValue(forKey: slug)
                removed.append(slug)
            }
        }
        if !removed.isEmpty, let data = try? JSONEncoder().encode(updatedIndex) {
            try? data.write(to: latestIndexURL, options: .atomic)
            reloadVaultState()
        }
        return removed
    }

    // MARK: - Offline Vault Reconstruction (when Server is Down)

    func offlineBooks(forUsername username: String, isAdmin: Bool = true) -> [Book] {
        guard let snap = latestSnapshot else { return [] }
        let permittedSlugs: Set<String>?
        if !isAdmin && snap.scope == BackupScope.adminFull.rawValue {
            permittedSlugs = Set(
                snap.permissions
                    .filter { $0.username == username }
                    .map(\.bookSlug)
            )
        } else {
            permittedSlugs = nil
        }

        let progressMap = Dictionary(
            snap.readingProgress
                .filter { $0.username == username }
                .map { ($0.bookSlug, $0) },
            uniquingKeysWith: { a, b in a.lastRead >= b.lastRead ? a : b }
        )
        let stateMap = Dictionary(
            snap.userBookStates
                .filter { $0.username == username }
                .map { ($0.bookSlug, $0) },
            uniquingKeysWith: { _, latest in latest }
        )

        let assembled = snap.books.compactMap { entry -> Book? in
            if let allowed = permittedSlugs, !allowed.contains(entry.slug) {
                return nil
            }
            guard hasOfflineBook(slug: entry.slug, format: entry.resolvedFormat) else { return nil }
            let prog = progressMap[entry.slug]
            let st = stateMap[entry.slug]
            return Book(
                bookId: entry.slug.hashValue,
                slug: entry.slug,
                title: entry.title,
                author: entry.author,
                pageCount: entry.pageCount,
                cover: entry.coverPath,
                format: entry.resolvedFormat,
                sourceUrl: entry.resolvedFormat == "bkb" ? nil : "books/\(entry.slug)/source",
                isPublished: entry.isPublished,
                createdAt: entry.createdAt,
                lastRead: prog?.lastRead,
                isFinished: st?.isFinished ?? false,
                onShelf: st?.onShelf ?? false,
                isPriority: st?.isPriority ?? false,
                defaultFont: entry.defaultFont,
                defaultTheme: entry.defaultTheme,
                readerFont: st?.readerFont ?? "",
                readerTheme: st?.readerTheme ?? ""
            )
        }
        return BookSort.sortedShelf(assembled)
    }

    func offlineHighlights(forUsername username: String, slug: String) -> [Highlight] {
        guard let snap = latestSnapshot else { return [] }
        return snap.highlights
            .filter { $0.bookSlug == slug && ($0.username == username || $0.username.isEmpty) }
            .map {
                Highlight(
                    id: $0.id,
                    page: $0.page,
                    lang: $0.lang,
                    color: $0.color,
                    text: $0.text,
                    startOffset: $0.startOffset,
                    endOffset: $0.endOffset,
                    paragraphIndex: $0.paragraphIndex,
                    anchorJson: $0.anchorJson,
                    note: $0.note,
                    createdAt: $0.createdAt
                )
            }
    }

    func offlineProgress(forUsername username: String, slug: String) -> ReadingProgress? {
        guard let snap = latestSnapshot,
              let p = snap.readingProgress.first(where: { $0.username == username && $0.bookSlug == slug }) else {
            return nil
        }
        return ReadingProgress(
            page: p.page,
            viewMode: p.viewMode,
            locator: p.locator,
            progression: p.progression,
            lastRead: p.lastRead
        )
    }

    // MARK: - Emergency Push Restore (Mac -> Server)

    func preflightDryRun(snapshot: BackupSnapshot, selection: RestoreSelection) async throws -> BackupRestoreResponse {
        let req = buildRestoreRequest(snapshot: snapshot, selection: selection, dryRun: true)
        return try await resolvedTransport().restoreBackupSnapshot(req)
    }

    func executePushRestore(
        snapshot: BackupSnapshot,
        selection: RestoreSelection,
        dryRunMissingSlugs: [String],
        onLog: @escaping (String) -> Void
    ) async throws -> RestoreExecutionResult {
        let client = resolvedTransport()
        let slugsToUpload: [String]
        if selection.overwriteExistingBooks {
            slugsToUpload = snapshot.books.map(\.slug)
        } else if selection.uploadMissingBooks {
            slugsToUpload = dryRunMissingSlugs
        } else {
            slugsToUpload = []
        }

        var uploaded: [String] = []
        var failedUploads: [String] = []

        let formatBySlug = Dictionary(uniqueKeysWithValues: snapshot.books.map { ($0.slug, $0.resolvedFormat) })
        if !slugsToUpload.isEmpty {
            onLog("Bắt đầu tải lên \(slugsToUpload.count) tệp sách (.bkb/.pdf/.epub)…")
            for (idx, slug) in slugsToUpload.enumerated() {
                let fmt = formatBySlug[slug] ?? vaultIndex.booksBySlug[slug]?.resolvedFormat ?? "bkb"
                let archive = localSourceURL(slug: slug, format: fmt)
                guard FileManager.default.fileExists(atPath: archive.path) else {
                    onLog("[\(idx + 1)/\(slugsToUpload.count)] Bỏ qua '\(slug)': không có file .\(fmt) trong Mac Vault.")
                    failedUploads.append(slug)
                    continue
                }
                do {
                    onLog("[\(idx + 1)/\(slugsToUpload.count)] Đang upload \(slug).\(fmt)…")
                    _ = try await client.uploadBookArchive(fileURL: archive)
                    uploaded.append(slug)
                    onLog("✓ Upload thành công '\(slug)'.")
                } catch {
                    failedUploads.append(slug)
                    onLog("✗ Lỗi upload '\(slug)': \(error.localizedDescription)")
                }
            }
        } else {
            onLog("Không cần upload thêm tệp sách.")
        }

        onLog("Đang đẩy dữ liệu Database (Users, Permissions, Highlights, Progress, States, Settings) lên server [mode=\(selection.mode.rawValue)]…")
        let req = buildRestoreRequest(snapshot: snapshot, selection: selection, dryRun: false)
        let response = try await client.restoreBackupSnapshot(req)
        onLog("✓ Khôi phục Database hoàn tất!")

        return RestoreExecutionResult(
            uploadedBooks: uploaded,
            failedBookUploads: failedUploads,
            response: response
        )
    }

    private func buildRestoreRequest(
        snapshot: BackupSnapshot,
        selection: RestoreSelection,
        dryRun: Bool
    ) -> BackupRestoreRequest {
        BackupRestoreRequest(
            snapshot: snapshot,
            mode: selection.mode.rawValue,
            dryRun: dryRun,
            restoreUsers: selection.restoreUsers,
            restorePermissions: selection.restorePermissions,
            restoreBooksMetadata: selection.restoreBooksMetadata,
            restoreApiKeys: selection.restoreApiKeys,
            restoreHighlights: selection.restoreHighlights,
            restoreProgress: selection.restoreProgress,
            restoreStates: selection.restoreStates,
            restoreSettings: selection.restoreSettings,
            restoreSecrets: selection.restoreSecrets,
            preferSnapshotProgress: selection.preferSnapshotProgress
        )
    }
}
