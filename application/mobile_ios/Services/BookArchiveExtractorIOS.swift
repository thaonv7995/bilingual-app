import Foundation
import Compression

enum BookArchiveIOSError: LocalizedError {
    case invalidSlug(String)
    case missingArchive(URL)
    case invalidArchive(String)
    case unsafeArchiveEntry(String)
    case missingOutputDirectory
    case unsupportedCompression(UInt16, String)
    case decompressionFailed(String)
    case checksumMismatch(String)

    var errorDescription: String? {
        switch self {
        case .invalidSlug(let slug):
            return "Tên định danh sách (slug) không hợp lệ: \(slug)"
        case .missingArchive(let url):
            return "Không tìm thấy gói sách .bkb tại \(url.lastPathComponent)"
        case .invalidArchive(let detail):
            return "Gói sách .bkb không hợp lệ: \(detail)"
        case .unsafeArchiveEntry(let entry):
            return "Phát hiện đường dẫn nguy hiểm trong gói .bkb: \(entry)"
        case .missingOutputDirectory:
            return "Gói sách .bkb không chứa thư mục output/"
        case .unsupportedCompression(let method, let entry):
            return "Định dạng nén ZIP không được hỗ trợ (\(method)) cho \(entry)"
        case .decompressionFailed(let entry):
            return "Giải nén thất bại tệp \(entry)"
        case .checksumMismatch(let entry):
            return "Kiểm tra CRC-32 thất bại cho tệp \(entry)"
        }
    }
}

/// Pure-Swift `.bkb` (ZIP) extractor for iOS/iPadOS using Apple's `Compression` framework.
///
/// Validates every archive entry against path-traversal, symbolic-link, zip-bomb, and CRC-32
/// errors before atomically swapping `output/` and `manifest.json` while preserving `drawings/`.
enum BookArchiveExtractorIOS {
    private static let slugRegex = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
    private static let maxSingleEntryBytes: UInt64 = 256 * 1024 * 1024
    private static let maxTotalUncompressedBytes: UInt64 = 1024 * 1024 * 1024

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    struct CentralDirectoryEntry {
        let path: String
        let compressionMethod: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
        let isSymlink: Bool
        let isDirectory: Bool
    }

    static func validateSlug(_ slug: String) throws -> String {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        guard !trimmed.isEmpty,
              !trimmed.contains(".."),
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              slugRegex.firstMatch(in: trimmed, range: range) != nil
        else {
            throw BookArchiveIOSError.invalidSlug(slug)
        }
        return trimmed
    }

    static func validateArchiveEntries(_ entries: [String]) throws {
        for rawEntry in entries {
            let normalized = rawEntry.replacingOccurrences(of: "\\", with: "/")
            if normalized.isEmpty || normalized.hasPrefix("/") {
                throw BookArchiveIOSError.unsafeArchiveEntry(rawEntry)
            }
            let trimmed = normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
            let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if components.contains("") || components.contains(".") || components.contains("..") {
                throw BookArchiveIOSError.unsafeArchiveEntry(rawEntry)
            }
        }
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = crcTable[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    static func parseCentralDirectory(archiveData data: Data) throws -> [CentralDirectoryEntry] {
        guard let eocdOffset = findEOCDOffset(in: data) else {
            throw BookArchiveIOSError.invalidArchive("Không tìm thấy End of Central Directory")
        }

        let totalEntriesRaw = data.readUInt16LE(at: eocdOffset + 10)
        let centralDirOffsetRaw = data.readUInt32LE(at: eocdOffset + 16)

        var totalEntries = UInt64(totalEntriesRaw)
        var centralDirOffset = UInt64(centralDirOffsetRaw)

        // Support ZIP64 archives when 16-bit/32-bit fields overflow to 0xFFFF / 0xFFFFFFFF.
        if (totalEntriesRaw == 0xFFFF || centralDirOffsetRaw == 0xFFFFFFFF),
           eocdOffset >= 20,
           data.readUInt32LE(at: eocdOffset - 20) == 0x07064B50 {
            let zip64EOCDOffset = Int(data.readUInt64LE(at: eocdOffset - 12))
            guard zip64EOCDOffset >= 0,
                  zip64EOCDOffset + 56 <= data.count,
                  data.readUInt32LE(at: zip64EOCDOffset) == 0x06064B50 else {
                throw BookArchiveIOSError.invalidArchive("Header ZIP64 không hợp lệ")
            }
            totalEntries = data.readUInt64LE(at: zip64EOCDOffset + 32)
            centralDirOffset = data.readUInt64LE(at: zip64EOCDOffset + 48)
        }

        guard Int(centralDirOffset) <= data.count else {
            throw BookArchiveIOSError.invalidArchive("Offset Central Directory vượt kích thước tệp")
        }

        var cursor = Int(centralDirOffset)
        var entries: [CentralDirectoryEntry] = []
        entries.reserveCapacity(Int(min(totalEntries, 20000)))

        for _ in 0..<totalEntries {
            guard cursor + 46 <= data.count, data.readUInt32LE(at: cursor) == 0x02014B50 else {
                throw BookArchiveIOSError.invalidArchive("Central Directory header bị hỏng")
            }

            let versionMadeBy = data.readUInt16LE(at: cursor + 4)
            let flags = data.readUInt16LE(at: cursor + 8)
            let compressionMethod = data.readUInt16LE(at: cursor + 10)
            let entryCRC = data.readUInt32LE(at: cursor + 16)
            let compressed32 = data.readUInt32LE(at: cursor + 20)
            let uncompressed32 = data.readUInt32LE(at: cursor + 24)
            let nameLength = Int(data.readUInt16LE(at: cursor + 28))
            let extraLength = Int(data.readUInt16LE(at: cursor + 30))
            let commentLength = Int(data.readUInt16LE(at: cursor + 32))
            let externalAttributes = data.readUInt32LE(at: cursor + 38)
            let localOffset32 = data.readUInt32LE(at: cursor + 42)

            let nameStart = cursor + 46
            let extraStart = nameStart + nameLength
            let nextCursor = extraStart + extraLength + commentLength
            guard nextCursor <= data.count else {
                throw BookArchiveIOSError.invalidArchive("Central Directory bị cắt ngắn")
            }

            let nameData = data.subdata(in: nameStart..<extraStart)
            let isUTF8 = (flags & 0x0800) != 0
            let rawName = String(data: nameData, encoding: isUTF8 ? .utf8 : .isoLatin1)
                ?? String(decoding: nameData, as: UTF8.self)

            var compressedSize = UInt64(compressed32)
            var uncompressedSize = UInt64(uncompressed32)
            var localHeaderOffset = UInt64(localOffset32)

            if compressed32 == 0xFFFFFFFF || uncompressed32 == 0xFFFFFFFF || localOffset32 == 0xFFFFFFFF {
                let extraData = data.subdata(in: extraStart..<(extraStart + extraLength))
                applyZip64ExtraField(
                    extraData,
                    compressedSize: &compressedSize,
                    uncompressedSize: &uncompressedSize,
                    localHeaderOffset: &localHeaderOffset,
                    needUncompressed: uncompressed32 == 0xFFFFFFFF,
                    needCompressed: compressed32 == 0xFFFFFFFF,
                    needOffset: localOffset32 == 0xFFFFFFFF
                )
            }

            let unixCreator = (versionMadeBy >> 8) == 3
            let unixMode = (externalAttributes >> 16) & 0xF000
            let isSymlink = unixCreator && unixMode == 0xA000
            let normalizedName = rawName.replacingOccurrences(of: "\\", with: "/")
            let isDirectory = normalizedName.hasSuffix("/")

            entries.append(CentralDirectoryEntry(
                path: normalizedName,
                compressionMethod: compressionMethod,
                crc32: entryCRC,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset,
                isSymlink: isSymlink,
                isDirectory: isDirectory
            ))

            cursor = nextCursor
        }

        return entries
    }

    /// Safely extracts `output/` and `manifest.json` from a `.bkb` archive into `bookDir`,
    /// preserving any existing user drawings in `bookDir/drawings/`.
    static func extractBKB(archiveURL: URL, into bookDir: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: archiveURL.path) else {
            throw BookArchiveIOSError.missingArchive(archiveURL)
        }

        let archiveData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
        let entries = try parseCentralDirectory(archiveData: archiveData)

        for entry in entries where entry.isSymlink {
            throw BookArchiveIOSError.unsafeArchiveEntry(entry.path)
        }
        try validateArchiveEntries(entries.map(\.path))

        try fm.createDirectory(at: bookDir, withIntermediateDirectories: true)
        let stagingDir = bookDir.appendingPathComponent(".extract_staging_\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        let standardizedStageRoot = stagingDir.standardizedFileURL.path
        var totalUncompressed: UInt64 = 0

        for entry in entries {
            if entry.isDirectory {
                let dirURL = stagingDir.appendingPathComponent(String(entry.path.dropLast()), isDirectory: true)
                try ensureSafeDestination(dirURL, under: standardizedStageRoot, rawPath: entry.path)
                try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
                continue
            }

            guard entry.uncompressedSize <= maxSingleEntryBytes else {
                throw BookArchiveIOSError.unsafeArchiveEntry("\(entry.path) (vượt quá giới hạn dung lượng)")
            }
            totalUncompressed &+= entry.uncompressedSize
            guard totalUncompressed <= maxTotalUncompressedBytes else {
                throw BookArchiveIOSError.unsafeArchiveEntry("Gói sách vượt quá giới hạn dung lượng cho phép")
            }

            let fileData: Data = try autoreleasepool {
                let compressedSlice = try readEntryCompressedSlice(from: archiveData, entry: entry)
                let decoded: Data
                switch entry.compressionMethod {
                case 0:
                    guard compressedSlice.count == Int(entry.uncompressedSize) else {
                        throw BookArchiveIOSError.decompressionFailed(entry.path)
                    }
                    decoded = compressedSlice
                case 8:
                    decoded = try inflateRawDeflate(
                        compressedSlice,
                        expectedSize: Int(entry.uncompressedSize),
                        entryPath: entry.path
                    )
                default:
                    throw BookArchiveIOSError.unsupportedCompression(entry.compressionMethod, entry.path)
                }

                guard crc32(decoded) == entry.crc32 else {
                    throw BookArchiveIOSError.checksumMismatch(entry.path)
                }
                return decoded
            }

            let destURL = stagingDir.appendingPathComponent(entry.path)
            try ensureSafeDestination(destURL, under: standardizedStageRoot, rawPath: entry.path)
            try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileData.write(to: destURL, options: .atomic)
        }

        let stagedOutput = stagingDir.appendingPathComponent("output", isDirectory: true)
        guard fm.fileExists(atPath: stagedOutput.path) else {
            throw BookArchiveIOSError.missingOutputDirectory
        }

        let targetOutput = bookDir.appendingPathComponent("output", isDirectory: true)
        let backupOutput = bookDir.appendingPathComponent(".old_output_\(UUID().uuidString)", isDirectory: true)
        let hadPreviousOutput = fm.fileExists(atPath: targetOutput.path)

        if hadPreviousOutput {
            try fm.moveItem(at: targetOutput, to: backupOutput)
        }

        do {
            try fm.moveItem(at: stagedOutput, to: targetOutput)
            let stagedManifest = stagingDir.appendingPathComponent("manifest.json")
            if fm.fileExists(atPath: stagedManifest.path) {
                let targetManifest = bookDir.appendingPathComponent("manifest.json")
                if fm.fileExists(atPath: targetManifest.path) {
                    try fm.removeItem(at: targetManifest)
                }
                try fm.moveItem(at: stagedManifest, to: targetManifest)
            }
            if hadPreviousOutput {
                try? fm.removeItem(at: backupOutput)
            }
        } catch {
            if !fm.fileExists(atPath: targetOutput.path), hadPreviousOutput, fm.fileExists(atPath: backupOutput.path) {
                try? fm.moveItem(at: backupOutput, to: targetOutput)
            }
            throw error
        }
    }

    // MARK: - Private ZIP Helpers

    private static func findEOCDOffset(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let minOffset = max(0, data.count - 65557)
        var pos = data.count - 22
        while pos >= minOffset {
            if data[pos] == 0x50 && data[pos + 1] == 0x4B && data[pos + 2] == 0x05 && data[pos + 3] == 0x06 {
                let commentLength = Int(data.readUInt16LE(at: pos + 20))
                if pos + 22 + commentLength == data.count {
                    return pos
                }
            }
            pos -= 1
        }
        return nil
    }

    private static func applyZip64ExtraField(
        _ extra: Data,
        compressedSize: inout UInt64,
        uncompressedSize: inout UInt64,
        localHeaderOffset: inout UInt64,
        needUncompressed: Bool,
        needCompressed: Bool,
        needOffset: Bool
    ) {
        var pos = 0
        while pos + 4 <= extra.count {
            let headerID = extra.readUInt16LE(at: pos)
            let size = Int(extra.readUInt16LE(at: pos + 2))
            let fieldStart = pos + 4
            guard fieldStart + size <= extra.count else { break }

            if headerID == 0x0001 {
                var offset = fieldStart
                if needUncompressed, offset + 8 <= fieldStart + size {
                    uncompressedSize = extra.readUInt64LE(at: offset)
                    offset += 8
                }
                if needCompressed, offset + 8 <= fieldStart + size {
                    compressedSize = extra.readUInt64LE(at: offset)
                    offset += 8
                }
                if needOffset, offset + 8 <= fieldStart + size {
                    localHeaderOffset = extra.readUInt64LE(at: offset)
                }
                return
            }
            pos = fieldStart + size
        }
    }

    private static func readEntryCompressedSlice(from archiveData: Data, entry: CentralDirectoryEntry) throws -> Data {
        let offset = Int(entry.localHeaderOffset)
        guard offset >= 0,
              offset + 30 <= archiveData.count,
              archiveData.readUInt32LE(at: offset) == 0x04034B50 else {
            throw BookArchiveIOSError.invalidArchive("Local File Header không hợp lệ cho \(entry.path)")
        }

        let localNameLen = Int(archiveData.readUInt16LE(at: offset + 26))
        let localExtraLen = Int(archiveData.readUInt16LE(at: offset + 28))
        let dataStart = offset + 30 + localNameLen + localExtraLen
        let dataEnd = dataStart + Int(entry.compressedSize)

        guard dataStart >= 0, dataEnd <= archiveData.count else {
            throw BookArchiveIOSError.invalidArchive("Dữ liệu nén bị cắt ngắn cho \(entry.path)")
        }
        return archiveData.subdata(in: dataStart..<dataEnd)
    }

    private static func inflateRawDeflate(_ compressed: Data, expectedSize: Int, entryPath: String) throws -> Data {
        if expectedSize == 0 {
            return Data()
        }

        // Allocate 1 extra byte beyond `expectedSize` so `compression_decode_buffer`
        // cannot mistake a filled buffer for insufficient output capacity.
        let capacity = expectedSize + 1
        var output = Data(count: capacity)
        let decodedCount: Int = output.withUnsafeMutableBytes { dstRaw in
            compressed.withUnsafeBytes { srcRaw in
                guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                      let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    dstPtr,
                    capacity,
                    srcPtr,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard decodedCount == expectedSize else {
            throw BookArchiveIOSError.decompressionFailed(entryPath)
        }
        output.count = decodedCount
        return output
    }

    private static func ensureSafeDestination(_ url: URL, under rootPath: String, rawPath: String) throws {
        let resolved = url.standardizedFileURL.path
        guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else {
            throw BookArchiveIOSError.unsafeArchiveEntry(rawPath)
        }
    }
}

private extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func readUInt64LE(at offset: Int) -> UInt64 {
        UInt64(readUInt32LE(at: offset)) | (UInt64(readUInt32LE(at: offset + 4)) << 32)
    }
}

