import XCTest
@testable import BilingualReader

@MainActor
final class BackupVaultTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("bilingual_mac_tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try await super.tearDown()
    }

    func testSlugValidationRejectsTraversal() throws {
        XCTAssertEqual(try BookArchiveExtractor.validateSlug("atomic-habits"), "atomic-habits")
        XCTAssertEqual(try BookArchiveExtractor.validateSlug("book_v1.2"), "book_v1.2")

        for bad in ["", "../evil", "foo/bar", "foo\\bar", ".hidden", "book..slug"] {
            XCTAssertThrowsError(try BookArchiveExtractor.validateSlug(bad), "Expected failure for \(bad)")
        }
    }

    func testArchiveEntryValidationRejectsPathTraversal() {
        XCTAssertNoThrow(try BookArchiveExtractor.validateArchiveEntries([
            "manifest.json",
            "output/en/page_0001.html",
            "output/vi/page_0001.html",
        ]))
        XCTAssertThrowsError(try BookArchiveExtractor.validateArchiveEntries(["../evil.html"]))
        XCTAssertThrowsError(try BookArchiveExtractor.validateArchiveEntries(["/etc/passwd"]))
        XCTAssertThrowsError(try BookArchiveExtractor.validateArchiveEntries(["output/../../escape.txt"]))
    }

    func testSafeBKBExtractionAndChecksum() throws {
        let archiveURL = try makeSampleBKB(slug: "sample-book", versionTag: "v1")
        let destBookDir = tempRoot.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: destBookDir, withIntermediateDirectories: true)

        try BookArchiveExtractor.extractBKB(archiveURL: archiveURL, into: destBookDir)

        let htmlFile = destBookDir.appendingPathComponent("output/en/page_0001.html")
        XCTAssertTrue(FileManager.default.fileExists(atPath: htmlFile.path))
        let htmlContent = try String(contentsOf: htmlFile, encoding: .utf8)
        XCTAssertTrue(htmlContent.contains("v1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destBookDir.appendingPathComponent("manifest.json").path))

        let sha = try BookArchiveExtractor.sha256Hex(fileURL: archiveURL)
        XCTAssertEqual(sha.count, 64)
    }

    func testIncrementalPullSyncRetentionAndOfflineReconstruction() async throws {
        let bkbA1 = try makeSampleBKB(slug: "book-a", versionTag: "a1")
        let bkbA2 = try makeSampleBKB(slug: "book-a", versionTag: "a2")
        let bkbB1 = try makeSampleBKB(slug: "book-b", versionTag: "b1")

        let transport = MockBackupTransport(
            archivesBySlug: ["book-a": bkbA1, "book-b": bkbB1],
            manifest: makeManifest(exportedAt: 1000, fingerprints: ["book-a": "fp-a1", "book-b": "fp-b1"]),
            snapshot: makeSnapshot(exportedAt: 1000, fingerprints: ["book-a": "fp-a1", "book-b": "fp-b1"])
        )

        let suiteName = "bilingual.mac.test.\(UUID().uuidString)"
        let defs = UserDefaults(suiteName: suiteName)!
        defer { defs.removePersistentDomain(forName: suiteName) }

        let vaultURL = tempRoot.appendingPathComponent("vault", isDirectory: true)
        let manager = BackupManager(defaultVaultURL: vaultURL, defaults: defs, transport: transport, startTimer: false)
        manager.maxRetainedSnapshots = 2

        // Run 1: downloads both books
        let run1 = await manager.syncFromServer()
        XCTAssertEqual(run1?.downloadedBooks, 2)
        XCTAssertEqual(run1?.skippedUnchangedBooks, 0)
        XCTAssertEqual(transport.downloadedSlugs, ["book-a", "book-b"])
        XCTAssertNotNil(manager.localPageURL(slug: "book-a", lang: "en", page: 1))
        XCTAssertEqual(manager.snapshots.count, 1)

        // Verify offline reader reconstruction & non-admin permission filtering
        let adminBooks = manager.offlineBooks(forUsername: "admin", isAdmin: true)
        XCTAssertEqual(Set(adminBooks.map(\.slug)), ["book-a", "book-b"])
        let readerBooks = manager.offlineBooks(forUsername: "reader1", isAdmin: false)
        XCTAssertEqual(readerBooks.map(\.slug), ["book-a"])

        // Run 2: same fingerprints -> skips downloading .bkb archives!
        transport.downloadedSlugs.removeAll()
        transport.manifest = makeManifest(exportedAt: 2000, fingerprints: ["book-a": "fp-a1", "book-b": "fp-b1"])
        transport.snapshot = makeSnapshot(exportedAt: 2000, fingerprints: ["book-a": "fp-a1", "book-b": "fp-b1"])

        let run2 = await manager.syncFromServer()
        XCTAssertEqual(run2?.downloadedBooks, 0)
        XCTAssertEqual(run2?.skippedUnchangedBooks, 2)
        XCTAssertTrue(transport.downloadedSlugs.isEmpty)
        XCTAssertEqual(manager.snapshots.count, 2)

        // Run 3: book-a fingerprint changed -> only book-a downloads, retention prunes oldest snapshot to keep 2
        transport.downloadedSlugs.removeAll()
        transport.archivesBySlug["book-a"] = bkbA2
        transport.manifest = makeManifest(exportedAt: 3000, fingerprints: ["book-a": "fp-a2", "book-b": "fp-b1"])
        transport.snapshot = makeSnapshot(exportedAt: 3000, fingerprints: ["book-a": "fp-a2", "book-b": "fp-b1"])

        let run3 = await manager.syncFromServer()
        XCTAssertEqual(run3?.downloadedBooks, 1)
        XCTAssertEqual(run3?.skippedUnchangedBooks, 1)
        XCTAssertEqual(transport.downloadedSlugs, ["book-a"])
        XCTAssertEqual(manager.snapshots.count, 2)
        XCTAssertEqual(manager.snapshots.map(\.exportedAt), [3000, 2000])
    }

    func testWipeProtectionGuardStopsWhenServerSuddenlyReturnsZeroBooks() async throws {
        let bkbA = try makeSampleBKB(slug: "book-a", versionTag: "v1")
        let transport = MockBackupTransport(
            archivesBySlug: ["book-a": bkbA],
            manifest: makeManifest(exportedAt: 1000, fingerprints: ["book-a": "fp-a1"]),
            snapshot: makeSnapshot(exportedAt: 1000, fingerprints: ["book-a": "fp-a1"])
        )

        let suiteName = "bilingual.mac.wipe.\(UUID().uuidString)"
        let defs = UserDefaults(suiteName: suiteName)!
        defer { defs.removePersistentDomain(forName: suiteName) }

        let manager = BackupManager(
            defaultVaultURL: tempRoot.appendingPathComponent("vault_wipe", isDirectory: true),
            defaults: defs,
            transport: transport,
            startTimer: false
        )

        _ = await manager.syncFromServer()
        XCTAssertEqual(manager.vaultIndex.booksBySlug.count, 1)

        // Simulate accidental DB wipe on server (returns 0 books)
        transport.manifest = BackupManifest(
            version: 1,
            generatedAt: 2000,
            scope: "admin_full",
            username: "admin",
            counts: BackupCounts(books: 0, users: 1, permissions: 0, highlights: 0, readingProgress: 0, userBookStates: 0, userSettings: 0, apiKeys: 0),
            books: []
        )

        let blockedRun = await manager.syncFromServer()
        XCTAssertNil(blockedRun)
        XCTAssertTrue(manager.wipeGuardTriggered)
        XCTAssertEqual(manager.latestSnapshot?.books.count, 1)
    }

    func testEmergencyPushRestoreUploadsMissingBooksThenAppliesSnapshot() async throws {
        let bkbA = try makeSampleBKB(slug: "book-a", versionTag: "v1")
        let snap = makeSnapshot(exportedAt: 1000, fingerprints: ["book-a": "fp-a1", "book-b": "fp-b1"])
        let transport = MockBackupTransport(
            archivesBySlug: ["book-a": bkbA, "book-b": bkbA],
            manifest: makeManifest(exportedAt: 1000, fingerprints: ["book-a": "fp-a1"]),
            snapshot: makeSnapshot(exportedAt: 1000, fingerprints: ["book-a": "fp-a1"])
        )
        let suiteName = "bilingual.mac.restore.\(UUID().uuidString)"
        let defs = UserDefaults(suiteName: suiteName)!
        defer { defs.removePersistentDomain(forName: suiteName) }

        let manager = BackupManager(
            defaultVaultURL: tempRoot.appendingPathComponent("vault_restore", isDirectory: true),
            defaults: defs,
            transport: transport,
            startTimer: false
        )
        _ = await manager.syncFromServer()

        var selection = RestoreSelection()
        selection.mode = .overwrite
        selection.uploadMissingBooks = true
        selection.restoreSecrets = true

        let execResult = try await manager.executePushRestore(
            snapshot: snap,
            selection: selection,
            dryRunMissingSlugs: ["book-a"],
            onLog: { _ in }
        )

        XCTAssertEqual(execResult.uploadedBooks, ["book-a"])
        XCTAssertEqual(transport.uploadedSlugs, ["book-a"])
        XCTAssertEqual(transport.lastRestoreRequest?.mode, "overwrite")
        XCTAssertEqual(transport.lastRestoreRequest?.dryRun, false)
        XCTAssertTrue(transport.lastRestoreRequest?.restoreSecrets == true)
    }

    func testShelfSortingRuleParity() {
        let books = [
            Book(bookId: 1, slug: "unread-old", title: "Unread Old", createdAt: 100, isPriority: false),
            Book(bookId: 2, slug: "unread-new", title: "Unread New", createdAt: 200, isPriority: false),
            Book(bookId: 3, slug: "read-recent", title: "Read Recent", createdAt: 50, lastRead: 500, isPriority: false),
            Book(bookId: 4, slug: "priority-book", title: "Priority", createdAt: 10, isPriority: true),
        ]
        let sorted = BookSort.sortedShelf(books)
        XCTAssertEqual(sorted.map(\.slug), ["priority-book", "read-recent", "unread-new", "unread-old"])
    }

    // MARK: - Helpers

    private func makeSampleBKB(slug: String, versionTag: String) throws -> URL {
        let workDir = tempRoot.appendingPathComponent("src_\(slug)_\(versionTag)", isDirectory: true)
        let enDir = workDir.appendingPathComponent("output/en", isDirectory: true)
        let viDir = workDir.appendingPathComponent("output/vi", isDirectory: true)
        try FileManager.default.createDirectory(at: enDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: viDir, withIntermediateDirectories: true)

        try "{\"slug\":\"\(slug)\",\"title\":\"\(slug)\"}".write(
            to: workDir.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )
        try "<html><body><p>Hello \(versionTag)</p></body></html>".write(
            to: enDir.appendingPathComponent("page_0001.html"),
            atomically: true,
            encoding: .utf8
        )
        try "<html><body><p>Xin chào \(versionTag)</p></body></html>".write(
            to: viDir.appendingPathComponent("page_0001.html"),
            atomically: true,
            encoding: .utf8
        )

        let archiveURL = tempRoot.appendingPathComponent("\(slug)_\(versionTag).bkb")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = workDir
        proc.arguments = ["-qr", archiveURL.path, "manifest.json", "output"]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
        return archiveURL
    }

    private func makeManifest(exportedAt: Int, fingerprints: [String: String]) -> BackupManifest {
        let entries = fingerprints.keys.sorted().map { slug in
            ManifestBookEntry(
                slug: slug,
                title: slug.capitalized,
                author: "Tester",
                pageCount: 2,
                coverPath: "",
                isPublished: true,
                defaultFont: "default",
                defaultTheme: "default",
                createdAt: exportedAt,
                hasOutputDir: true,
                outputFileCount: 2,
                outputSizeBytes: 120,
                contentFingerprint: fingerprints[slug] ?? ""
            )
        }
        return BackupManifest(
            version: 1,
            generatedAt: exportedAt,
            scope: "admin_full",
            username: "admin",
            counts: BackupCounts(books: entries.count, users: 2, permissions: 1, highlights: 0, readingProgress: 1, userBookStates: 0, userSettings: 0, apiKeys: 0),
            books: entries
        )
    }

    private func makeSnapshot(exportedAt: Int, fingerprints: [String: String]) -> BackupSnapshot {
        let manifest = makeManifest(exportedAt: exportedAt, fingerprints: fingerprints)
        return BackupSnapshot(
            version: 1,
            exportedAt: exportedAt,
            scope: "admin_full",
            exportedBy: "admin",
            includesSecrets: false,
            books: manifest.books,
            users: [
                SnapshotUser(username: "admin", passwordHash: "h1", isAdmin: true),
                SnapshotUser(username: "reader1", passwordHash: "h2", isAdmin: false),
            ],
            permissions: [SnapshotPermission(username: "reader1", bookSlug: "book-a")],
            apiKeys: [],
            highlights: [],
            readingProgress: [SnapshotReadingProgress(username: "admin", bookSlug: "book-a", page: 1, viewMode: "split", lastRead: exportedAt)],
            userBookStates: [],
            userSettings: []
        )
    }
}

private final class MockBackupTransport: BackupTransport {
    var serverUrl: String = "https://mock.local"
    var archivesBySlug: [String: URL]
    var manifest: BackupManifest
    var snapshot: BackupSnapshot
    var downloadedSlugs: [String] = []
    var uploadedSlugs: [String] = []
    var lastRestoreRequest: BackupRestoreRequest?

    init(archivesBySlug: [String: URL], manifest: BackupManifest, snapshot: BackupSnapshot) {
        self.archivesBySlug = archivesBySlug
        self.manifest = manifest
        self.snapshot = snapshot
    }

    func fetchBackupManifest() async throws -> BackupManifest {
        manifest
    }

    func exportBackupSnapshot(includeSecrets: Bool) async throws -> BackupSnapshot {
        snapshot
    }

    func downloadBookArchive(slug: String, to destinationURL: URL) async throws {
        downloadedSlugs.append(slug)
        guard let src = archivesBySlug[slug] else {
            throw NSError(domain: "Mock", code: 404)
        }
        try FileManager.default.copyItem(at: src, to: destinationURL)
    }

    func uploadBookArchive(fileURL: URL) async throws -> String {
        let slug = fileURL.deletingPathExtension().lastPathComponent
        uploadedSlugs.append(slug)
        return slug
    }

    func restoreBackupSnapshot(_ restoreRequest: BackupRestoreRequest) async throws -> BackupRestoreResponse {
        lastRestoreRequest = restoreRequest
        let empty = RestoreEntitySummary(created: 0, updated: 0, unchanged: 0, skipped: 0, deleted: 0)
        return BackupRestoreResponse(
            ok: true,
            dryRun: restoreRequest.dryRun,
            mode: restoreRequest.mode,
            scope: "admin_full",
            summary: RestoreSummary(
                books: RestoreBooksSummary(updated: 1, unchanged: 0, missingFiles: []),
                users: empty,
                permissions: empty,
                apiKeys: empty,
                highlights: empty,
                readingProgress: empty,
                userBookStates: empty,
                userSettings: empty
            ),
            warnings: []
        )
    }
}

