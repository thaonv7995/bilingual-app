import Foundation
import CryptoKit

enum BookArchiveError: LocalizedError {
    case invalidSlug(String)
    case missingArchive(URL)
    case unsafeArchiveEntry(String)
    case missingOutputDirectory
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSlug(let s): return "Tên định danh sách (slug) không hợp lệ: \(s)"
        case .missingArchive(let url): return "Không tìm thấy file .bkb tại \(url.path)"
        case .unsafeArchiveEntry(let entry): return "Phát hiện đường dẫn nguy hiểm trong gói .bkb: \(entry)"
        case .missingOutputDirectory: return "Gói .bkb không chứa thư mục output/"
        case .processFailed(let msg): return "Giải nén gói .bkb thất bại: \(msg)"
        }
    }
}

enum BookArchiveExtractor {
    private static let slugRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")

    static func validateSlug(_ slug: String) throws -> String {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        guard !trimmed.isEmpty,
              !trimmed.contains(".."),
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              slugRegex.firstMatch(in: trimmed, range: range) != nil
        else {
            throw BookArchiveError.invalidSlug(slug)
        }
        return trimmed
    }

    static func sha256Hex(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 65536)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func listArchiveEntries(archiveURL: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw BookArchiveError.missingArchive(archiveURL)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-Z", "-1", archiveURL.path]

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BookArchiveError.processFailed(errText)
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: outputData, encoding: .utf8) ?? ""
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func validateArchiveEntries(_ entries: [String]) throws {
        for rawEntry in entries {
            let normalized = rawEntry.replacingOccurrences(of: "\\", with: "/")
            if normalized.hasPrefix("/") {
                throw BookArchiveError.unsafeArchiveEntry(rawEntry)
            }
            let components = normalized.split(separator: "/").map(String.init)
            if components.contains("..") || components.contains(".") {
                throw BookArchiveError.unsafeArchiveEntry(rawEntry)
            }
        }
    }

    /// Safely extracts `output/` and `manifest.json` from a `.bkb` archive into `bookDir`.
    static func extractBKB(archiveURL: URL, into bookDir: URL) throws {
        let fm = FileManager.default
        let entries = try listArchiveEntries(archiveURL: archiveURL)
        try validateArchiveEntries(entries)

        let stagingDir = bookDir.appendingPathComponent(".extract_staging_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-qq", "-o", archiveURL.path, "-d", stagingDir.path]
        let stderr = Pipe()
        proc.standardError = stderr
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BookArchiveError.processFailed(errText)
        }

        // Reject any symbolic links unpacked from the archive
        if let enumerator = fm.enumerator(
            at: stagingDir,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let vals = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                if vals.isSymbolicLink == true {
                    throw BookArchiveError.unsafeArchiveEntry(fileURL.lastPathComponent)
                }
            }
        }

        let stagedOutput = stagingDir.appendingPathComponent("output", isDirectory: true)
        guard fm.fileExists(atPath: stagedOutput.path) else {
            throw BookArchiveError.missingOutputDirectory
        }

        let targetOutput = bookDir.appendingPathComponent("output", isDirectory: true)
        if fm.fileExists(atPath: targetOutput.path) {
            try fm.removeItem(at: targetOutput)
        }
        try fm.moveItem(at: stagedOutput, to: targetOutput)

        let stagedManifest = stagingDir.appendingPathComponent("manifest.json")
        if fm.fileExists(atPath: stagedManifest.path) {
            let targetManifest = bookDir.appendingPathComponent("manifest.json")
            if fm.fileExists(atPath: targetManifest.path) {
                try fm.removeItem(at: targetManifest)
            }
            try fm.moveItem(at: stagedManifest, to: targetManifest)
        }
    }
}

