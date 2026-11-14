import Foundation
import SwiftUI

struct BackupBookManifestItem: Codable, Equatable, Identifiable {
    var id: String { slug }
    let slug: String
    let title: String
    let author: String
    let pageCount: Int
    let coverPath: String
    let isPublished: Bool
    let defaultFont: String
    let defaultTheme: String
    let createdAt: Int64
    let hasOutputDir: Bool
    let outputFileCount: Int
    let outputSizeBytes: Int64
    let contentFingerprint: String
}

struct BackupManifestResponse: Codable, Equatable {
    let version: Int
    let generatedAt: Int64
    let scope: String
    let username: String
    let books: [BackupBookManifestItem]
}

struct LocalBookCacheMeta: Codable, Equatable {
    let slug: String
    let contentFingerprint: String
    let cachedAt: Int64
    let sizeBytes: Int64
}

@MainActor
class BookCacheManager: ObservableObject {
    static let shared = BookCacheManager()

    private enum PrefKey {
        static let autoCacheBooks = "autoCacheBooks"
    }

    @Published var downloadProgress: [String: Double] = [:] // slug -> progress (0.0 to 1.0)
    @Published var downloadStatus: [String: DownloadStatus] = [:] // slug -> status
    @Published var downloadErrors: [String: String] = [:] // slug -> error message
    @Published var cachedSizes: [String: Int64] = [:] // slug -> bytes on disk
    @Published var cachedFingerprints: [String: String] = [:] // slug -> last synced server fingerprint
    @Published var serverManifestBySlug: [String: BackupBookManifestItem] = [:]
    @Published var pendingSyncCount: Int = 0
    @Published var autoCacheBooks: Bool {
        didSet {
            UserDefaults.standard.set(autoCacheBooks, forKey: PrefKey.autoCacheBooks)
        }
    }

    enum DownloadStatus: String {
        case notDownloaded
        case downloading
        case downloaded
    }

    let syncStore = OfflineSyncStore()
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var activeURLSessions: [String: URLSession] = [:]

    private init() {
        self.autoCacheBooks = UserDefaults.standard.object(forKey: PrefKey.autoCacheBooks) as? Bool ?? true
        scanDownloadedBooks()
    }

    var baseDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("books", isDirectory: true)
    }

    func localBookDir(slug: String) -> URL {
        let safeSlug = (try? BookArchiveExtractorIOS.validateSlug(slug)) ?? slug
        return baseDirectory.appendingPathComponent(safeSlug, isDirectory: true)
    }

    func localOutputDir(slug: String) -> URL {
        localBookDir(slug: slug).appendingPathComponent("output", isDirectory: true)
    }

    func localPageURL(slug: String, lang: String, page: Int) -> URL? {
        guard let safeSlug = try? BookArchiveExtractorIOS.validateSlug(slug),
              ["en", "vi"].contains(lang) else {
            return nil
        }
        let padPage = String(format: "%04d", page)
        let pagePath = "\(lang)/page_\(padPage).html"
        let fileURL = localOutputDir(slug: safeSlug).appendingPathComponent(pagePath)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Resolves a locally cached cover image (either inside extracted `output/` or cached
    /// standalone thumbnail) so covers render offline even before full archive completion.
    func localCoverURL(slug: String, coverPath: String?) -> URL? {
        guard let safeSlug = try? BookArchiveExtractorIOS.validateSlug(slug) else { return nil }
        let fm = FileManager.default
        let outputDir = localOutputDir(slug: safeSlug)

        if let coverPath, !coverPath.isEmpty {
            var rel = coverPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let prefix = "books/\(safeSlug)/output/"
            if rel.hasPrefix(prefix) {
                rel = String(rel.dropFirst(prefix.count))
            }
            if !rel.isEmpty, !rel.contains("..") {
                let candidate = outputDir.appendingPathComponent(rel)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        let cachedThumb = localBookDir(slug: safeSlug).appendingPathComponent("cover_cache.img")
        if fm.fileExists(atPath: cachedThumb.path) {
            return cachedThumb
        }

        for fallback in [
            "assets/images/page_0001_cover_logo.png",
            "assets/cover.jpg",
            "assets/cover.png"
        ] {
            let candidate = outputDir.appendingPathComponent(fallback)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    func saveCachedCoverData(slug: String, data: Data) {
        guard let safeSlug = try? BookArchiveExtractorIOS.validateSlug(slug), !data.isEmpty else { return }
        let dir = localBookDir(slug: safeSlug)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("cover_cache.img")
        try? data.write(to: target, options: .atomic)
    }

    func isDownloaded(slug: String) -> Bool {
        downloadStatus[slug] == .downloaded
    }

    func needsUpdate(slug: String) -> Bool {
        guard isDownloaded(slug: slug),
              let localFingerprint = cachedFingerprints[slug], !localFingerprint.isEmpty,
              let serverFingerprint = serverManifestBySlug[slug]?.contentFingerprint, !serverFingerprint.isEmpty else {
            return false
        }
        return localFingerprint != serverFingerprint
    }

    var totalCacheBytes: Int64 {
        cachedSizes.values.reduce(0, +)
    }

    var downloadedCount: Int {
        downloadStatus.values.filter { $0 == .downloaded }.count
    }

    func formattedSize(forSlug slug: String) -> String {
        let bytes = cachedSizes[slug] ?? 0
        return bytes > 0 ? Self.formatByteCount(bytes) : ""
    }

    func formattedTotalCacheSize() -> String {
        Self.formatByteCount(totalCacheBytes)
    }

    static func formatByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func scanDownloadedBooks() {
        let fm = FileManager.default
        let booksDir = baseDirectory
        guard fm.fileExists(atPath: booksDir.path) else { return }

        do {
            let contents = try fm.contentsOfDirectory(at: booksDir, includingPropertiesForKeys: nil)
            var slugsNeedingSizeScan: [String] = []
            for url in contents where !url.lastPathComponent.hasPrefix(".") {
                let slug = url.lastPathComponent
                let manifestURL = url.appendingPathComponent("manifest.json")
                let metaURL = url.appendingPathComponent("cache_meta.json")
                let outputDir = url.appendingPathComponent("output", isDirectory: true)

                guard fm.fileExists(atPath: outputDir.path),
                      fm.fileExists(atPath: manifestURL.path) || fm.fileExists(atPath: metaURL.path) else {
                    continue
                }

                if downloadStatus[slug] != .downloading {
                    downloadStatus[slug] = .downloaded
                    downloadProgress[slug] = 1.0
                }

                if let metaData = try? Data(contentsOf: metaURL),
                   let meta = try? JSONDecoder().decode(LocalBookCacheMeta.self, from: metaData) {
                    if meta.sizeBytes > 0 {
                        cachedSizes[slug] = meta.sizeBytes
                    } else {
                        slugsNeedingSizeScan.append(slug)
                    }
                    if !meta.contentFingerprint.isEmpty {
                        cachedFingerprints[slug] = meta.contentFingerprint
                    }
                } else {
                    slugsNeedingSizeScan.append(slug)
                }
            }

            if !slugsNeedingSizeScan.isEmpty {
                let rootDir = baseDirectory
                let slugsToScan = slugsNeedingSizeScan
                Task.detached(priority: .utility) {
                    let computed: [(String, Int64)] = slugsToScan.map { slug in
                        let bookDir = rootDir.appendingPathComponent(slug, isDirectory: true)
                        return (slug, Self.computeDirectorySizeSync(bookDir))
                    }
                    await MainActor.run {
                        for (slug, size) in computed {
                            self.cachedSizes[slug] = size
                        }
                    }
                }
            }
        } catch {
            print("Failed to scan downloaded books: \(error)")
        }
    }

    nonisolated private static func computeDirectorySizeSync(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    func updateServerManifest(_ manifest: BackupManifestResponse) {
        var map: [String: BackupBookManifestItem] = [:]
        for item in manifest.books {
            map[item.slug] = item
        }
        serverManifestBySlug = map
    }

    // MARK: - Download & Extraction

    func downloadBook(
        slug: String,
        api: APIService,
        expectedFingerprint: String? = nil,
        forceRedownload: Bool = false
    ) async {
        guard let safeSlug = try? BookArchiveExtractorIOS.validateSlug(slug) else { return }
        if !forceRedownload, isDownloaded(slug: safeSlug), !needsUpdate(slug: safeSlug) {
            return
        }
        guard downloadStatus[safeSlug] != .downloading else { return }

        let hadExistingCache = hasCompleteLocalBook(slug: safeSlug)
        downloadErrors.removeValue(forKey: safeSlug)
        downloadStatus[safeSlug] = .downloading
        downloadProgress[safeSlug] = 0.0

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.activeTasks.removeValue(forKey: safeSlug)
                self.activeURLSessions.removeValue(forKey: safeSlug)
            }

            do {
                let serverUrl = api.normalizedServerUrl
                let downloadedArchive = try await self.fetchBKBArchive(
                    slug: safeSlug,
                    serverUrl: serverUrl,
                    api: api
                )

                if let archiveURL = downloadedArchive {
                    defer { try? FileManager.default.removeItem(at: archiveURL) }
                    try Task.checkCancellation()
                    self.downloadProgress[safeSlug] = 0.92

                    let destBookDir = self.localBookDir(slug: safeSlug)
                    try await Task.detached(priority: .userInitiated) {
                        try BookArchiveExtractorIOS.extractBKB(archiveURL: archiveURL, into: destBookDir)
                    }.value
                } else {
                    // Defensive fallback when an older backend lacks `.bkb` package download
                    try await self.downloadBookViaLegacyManifest(slug: safeSlug, serverUrl: serverUrl, api: api)
                }

                try Task.checkCancellation()

                let bookDir = self.localBookDir(slug: safeSlug)
                let sizeBytes = await Task.detached(priority: .utility) {
                    Self.computeDirectorySizeSync(bookDir)
                }.value

                let fingerprint = expectedFingerprint
                    ?? self.serverManifestBySlug[safeSlug]?.contentFingerprint
                    ?? ""
                let meta = LocalBookCacheMeta(
                    slug: safeSlug,
                    contentFingerprint: fingerprint,
                    cachedAt: Int64(Date().timeIntervalSince1970),
                    sizeBytes: sizeBytes
                )
                if let metaData = try? JSONEncoder().encode(meta) {
                    try? metaData.write(
                        to: bookDir.appendingPathComponent("cache_meta.json"),
                        options: .atomic
                    )
                }

                self.cachedSizes[safeSlug] = sizeBytes
                if !fingerprint.isEmpty {
                    self.cachedFingerprints[safeSlug] = fingerprint
                }
                self.downloadErrors.removeValue(forKey: safeSlug)
                self.downloadStatus[safeSlug] = .downloaded
                self.downloadProgress[safeSlug] = 1.0
            } catch is CancellationError {
                self.downloadStatus[safeSlug] = hadExistingCache ? .downloaded : .notDownloaded
                self.downloadProgress[safeSlug] = hadExistingCache ? 1.0 : 0.0
            } catch {
                print("Failed to download book \(safeSlug): \(error)")
                self.downloadErrors[safeSlug] = error.localizedDescription
                self.downloadStatus[safeSlug] = hadExistingCache ? .downloaded : .notDownloaded
                self.downloadProgress[safeSlug] = hadExistingCache ? 1.0 : 0.0
            }
        }

        activeTasks[safeSlug] = task
        await task.value
    }

    func cancelDownload(slug: String) {
        activeURLSessions[slug]?.invalidateAndCancel()
        activeURLSessions.removeValue(forKey: slug)
        activeTasks[slug]?.cancel()
        activeTasks.removeValue(forKey: slug)
    }

    func downloadAllMissing(books: [Book], api: APIService) async {
        for book in books {
            if Task.isCancelled { break }
            let status = downloadStatus[book.slug] ?? .notDownloaded
            if status == .notDownloaded || needsUpdate(slug: book.slug) {
                let fp = serverManifestBySlug[book.slug]?.contentFingerprint
                await downloadBook(
                    slug: book.slug,
                    api: api,
                    expectedFingerprint: fp,
                    forceRedownload: needsUpdate(slug: book.slug)
                )
            }
        }
    }

    func deleteCache(slug: String) {
        cancelDownload(slug: slug)
        let dir = localBookDir(slug: slug)
        try? FileManager.default.removeItem(at: dir)
        downloadStatus[slug] = .notDownloaded
        downloadProgress[slug] = 0.0
        cachedSizes.removeValue(forKey: slug)
        cachedFingerprints.removeValue(forKey: slug)
        downloadErrors.removeValue(forKey: slug)
    }

    func clearAllCache(forSlugs slugs: [String]? = nil) {
        if let slugs {
            for slug in slugs {
                deleteCache(slug: slug)
            }
            return
        }
        for slug in Array(downloadStatus.keys) {
            deleteCache(slug: slug)
        }
    }

    private func hasCompleteLocalBook(slug: String) -> Bool {
        let dir = localBookDir(slug: slug)
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("output").path)
            && (fm.fileExists(atPath: dir.appendingPathComponent("manifest.json").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("cache_meta.json").path))
    }

    /// Downloads `.bkb` package using `URLSessionDownloadDelegate`. Returns `nil` only when the
    /// server indicates `/download` is unavailable (404/405/501) so caller can use file manifest.
    private func fetchBKBArchive(slug: String, serverUrl: String, api: APIService) async throws -> URL? {
        guard let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(serverUrl)/api/books/\(encodedSlug)/download") else {
            throw URLError(.badURL)
        }

        let estimatedTotal = max(Int64(0), serverManifestBySlug[slug]?.outputSizeBytes ?? 0)
        for attempt in 0..<2 {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(api.token)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 300

            let (statusCode, tempURL) = try await downloadFileWithProgress(
                request: request,
                slug: slug,
                fallbackExpectedBytes: estimatedTotal
            )

            if statusCode == 401 && attempt == 0 {
                if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
                _ = try await api.performTokenRefresh()
                continue
            }

            if [404, 405, 501].contains(statusCode) {
                if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
                return nil
            }

            guard statusCode == 200, let tempURL else {
                if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
                throw NSError(
                    domain: "BookCacheManager",
                    code: statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Tải gói .bkb thất bại (HTTP \(statusCode))"]
                )
            }
            return tempURL
        }

        throw URLError(.userAuthenticationRequired)
    }

    private func downloadFileWithProgress(
        request: URLRequest,
        slug: String,
        fallbackExpectedBytes: Int64
    ) async throws -> (Int, URL?) {
        final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<(Int, URL?), Error>?
            let onProgress: @MainActor (Double) -> Void
            let fallbackExpectedBytes: Int64

            init(
                fallbackExpectedBytes: Int64,
                onProgress: @escaping @MainActor (Double) -> Void
            ) {
                self.fallbackExpectedBytes = fallbackExpectedBytes
                self.onProgress = onProgress
            }

            func setContinuation(_ cont: CheckedContinuation<(Int, URL?), Error>) {
                lock.lock()
                continuation = cont
                lock.unlock()
            }

            private func takeContinuation() -> CheckedContinuation<(Int, URL?), Error>? {
                lock.lock()
                let cont = continuation
                continuation = nil
                lock.unlock()
                return cont
            }

            func urlSession(
                _ session: URLSession,
                downloadTask: URLSessionDownloadTask,
                didWriteData bytesWritten: Int64,
                totalBytesWritten: Int64,
                totalBytesExpectedToWrite: Int64
            ) {
                let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : fallbackExpectedBytes
                let fraction: Double
                if expected > 0 {
                    fraction = min(0.89, Double(totalBytesWritten) / Double(expected) * 0.89)
                } else {
                    fraction = min(0.85, Double(totalBytesWritten) / (10.0 * 1024.0 * 1024.0) * 0.5)
                }
                Task { @MainActor in
                    self.onProgress(fraction)
                }
            }

            func urlSession(
                _ session: URLSession,
                downloadTask: URLSessionDownloadTask,
                didFinishDownloadingTo location: URL
            ) {
                let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
                let stableTemp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bkb_dl_\(UUID().uuidString).bkb")
                do {
                    if FileManager.default.fileExists(atPath: stableTemp.path) {
                        try FileManager.default.removeItem(at: stableTemp)
                    }
                    try FileManager.default.moveItem(at: location, to: stableTemp)
                    takeContinuation()?.resume(returning: (status, stableTemp))
                } catch {
                    takeContinuation()?.resume(throwing: error)
                }
            }

            func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
                guard let error else { return }
                takeContinuation()?.resume(throwing: error)
            }
        }

        let delegate = Delegate(fallbackExpectedBytes: fallbackExpectedBytes) { [weak self] progress in
            self?.downloadProgress[slug] = max(self?.downloadProgress[slug] ?? 0, progress)
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        activeURLSessions[slug] = session
        defer {
            session.finishTasksAndInvalidate()
            activeURLSessions.removeValue(forKey: slug)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.setContinuation(continuation)
                let task = session.downloadTask(with: request)
                task.resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private func downloadBookViaLegacyManifest(slug: String, serverUrl: String, api: APIService) async throws {
        guard let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let manifestUrl = URL(string: "\(serverUrl)/api/books/\(encodedSlug)/manifest") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: manifestUrl)
        request.setValue("Bearer \(api.token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        var finalData = data
        if httpResponse.statusCode == 401 {
            let newToken = try await api.performTokenRefresh()
            var retryRequest = URLRequest(url: manifestUrl)
            retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
            guard let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            finalData = retryData
        } else if httpResponse.statusCode != 200 {
            throw URLError(.badServerResponse)
        }

        struct ManifestResponse: Codable {
            let files: [String]
        }

        let manifest = try JSONDecoder().decode(ManifestResponse.self, from: finalData)
        let totalFiles = manifest.files.count
        guard totalFiles > 0 else {
            throw NSError(domain: "BookCacheManager", code: 400, userInfo: [NSLocalizedDescriptionKey: "Book has no files"])
        }

        let destBookDir = localBookDir(slug: slug)
        let stagingDir = destBookDir.appendingPathComponent(".manifest_staging_\(UUID().uuidString)", isDirectory: true)
        let stagingOutputDir = stagingDir.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingOutputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        var downloadedCount = 0
        let batchSize = 6
        for i in stride(from: 0, to: totalFiles, by: batchSize) {
            try Task.checkCancellation()
            let end = min(i + batchSize, totalFiles)
            let batch = manifest.files[i..<end]

            try await withThrowingTaskGroup(of: Void.self) { group in
                for filePath in batch {
                    let currentToken = api.token
                    group.addTask {
                        let encodedPath = filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filePath
                        let fileUrlString = "\(serverUrl)/books/\(encodedSlug)/output/\(encodedPath)?token=\(currentToken)"
                        guard let fileUrl = URL(string: fileUrlString) else {
                            throw URLError(.badURL)
                        }

                        var (fileData, fileResponse) = try await URLSession.shared.data(from: fileUrl)
                        if (fileResponse as? HTTPURLResponse)?.statusCode == 401 {
                            let newToken = try await api.performTokenRefresh()
                            let retryUrlString = "\(serverUrl)/books/\(encodedSlug)/output/\(encodedPath)?token=\(newToken)"
                            guard let retryUrl = URL(string: retryUrlString) else { throw URLError(.badURL) }
                            (fileData, fileResponse) = try await URLSession.shared.data(from: retryUrl)
                        }

                        guard let httpFile = fileResponse as? HTTPURLResponse, httpFile.statusCode == 200 else {
                            throw URLError(.badServerResponse)
                        }

                        let destinationURL = stagingOutputDir.appendingPathComponent(filePath)
                        try FileManager.default.createDirectory(
                            at: destinationURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try fileData.write(to: destinationURL, options: .atomic)
                    }
                }

                for try await _ in group {
                    downloadedCount += 1
                    downloadProgress[slug] = Double(downloadedCount) / Double(totalFiles)
                }
            }
        }

        let targetOutput = localOutputDir(slug: slug)
        if FileManager.default.fileExists(atPath: targetOutput.path) {
            try FileManager.default.removeItem(at: targetOutput)
        }
        try FileManager.default.createDirectory(at: destBookDir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: stagingOutputDir, to: targetOutput)
        try finalData.write(to: destBookDir.appendingPathComponent("manifest.json"), options: .atomic)
    }

    // MARK: - Per-Account Offline Store Bridge

    func accountKey(serverUrl: String, username: String) -> OfflineAccountKey {
        OfflineAccountKey(serverUrl: serverUrl, username: username)
    }

    func hasAnyOfflineBooks(serverUrl: String, username: String) -> Bool {
        let key = accountKey(serverUrl: serverUrl, username: username)
        if !syncStore.loadCachedBooks(for: key).isEmpty {
            return true
        }
        return !syncStore.hasSavedLibraryFile(for: key) && downloadedCount > 0
    }

    func reconcileAndSaveBooks(_ serverBooks: [Book], serverUrl: String, username: String) -> [Book] {
        let key = accountKey(serverUrl: serverUrl, username: username)
        let merged = syncStore.reconcileAndSaveBooks(serverBooks, for: key)
        refreshPendingCount(serverUrl: serverUrl, username: username)
        return merged
    }

    func loadCachedBooks(serverUrl: String, username: String) -> [Book] {
        let key = accountKey(serverUrl: serverUrl, username: username)
        let saved = syncStore.loadCachedBooks(for: key)
        if !saved.isEmpty || syncStore.hasSavedLibraryFile(for: key) {
            return saved
        }
        return OfflineSyncStore.reconstructFallbackBooks(from: baseDirectory)
    }

    func saveCachedHighlights(_ highlights: [Highlight], slug: String, serverUrl: String, username: String) {
        let key = accountKey(serverUrl: serverUrl, username: username)
        syncStore.saveCachedHighlights(highlights, slug: slug, for: key)
    }

    func loadCachedHighlights(slug: String, serverUrl: String, username: String) -> [Highlight] {
        let key = accountKey(serverUrl: serverUrl, username: username)
        return syncStore.loadCachedHighlights(slug: slug, for: key)
    }

    func mergeHighlightsWithPending(_ serverHighlights: [Highlight], slug: String, serverUrl: String, username: String) -> [Highlight] {
        let key = accountKey(serverUrl: serverUrl, username: username)
        return syncStore.mergeHighlightsWithPending(serverHighlights, slug: slug, for: key)
    }

    func enqueuePendingOp(_ op: OfflinePendingOp, serverUrl: String, username: String) {
        let key = accountKey(serverUrl: serverUrl, username: username)
        syncStore.enqueue(op, for: key)
        refreshPendingCount(serverUrl: serverUrl, username: username)
    }

    func loadPendingOps(serverUrl: String, username: String) -> [OfflinePendingOp] {
        let key = accountKey(serverUrl: serverUrl, username: username)
        return syncStore.loadPendingOps(for: key)
    }

    func removeExactPendingOp(_ op: OfflinePendingOp, serverUrl: String, username: String) {
        let key = accountKey(serverUrl: serverUrl, username: username)
        syncStore.removeExactPendingOp(op, for: key)
        refreshPendingCount(serverUrl: serverUrl, username: username)
    }

    func removePendingProgress(slug: String, upToLastRead lastRead: Int64?, serverUrl: String, username: String) {
        let key = accountKey(serverUrl: serverUrl, username: username)
        syncStore.removePendingProgress(slug: slug, upToLastRead: lastRead, for: key)
        refreshPendingCount(serverUrl: serverUrl, username: username)
    }

    func refreshPendingCount(serverUrl: String, username: String) {
        let key = accountKey(serverUrl: serverUrl, username: username)
        let count = syncStore.loadPendingOps(for: key).count
        if pendingSyncCount != count {
            pendingSyncCount = count
        }
    }
}
