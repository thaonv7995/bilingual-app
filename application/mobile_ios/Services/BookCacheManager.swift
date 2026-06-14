import Foundation

class BookCacheManager: ObservableObject {
    static let shared = BookCacheManager()
    
    @Published var downloadProgress: [String: Double] = [:] // slug -> progress (0.0 to 1.0)
    @Published var downloadStatus: [String: DownloadStatus] = [:] // slug -> status
    
    enum DownloadStatus: String {
        case notDownloaded
        case downloading
        case downloaded
    }
    
    private init() {
        scanDownloadedBooks()
    }
    
    var baseDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("books", isDirectory: true)
    }
    
    func localBookDir(slug: String) -> URL {
        baseDirectory.appendingPathComponent(slug, isDirectory: true)
    }
    
    func localOutputDir(slug: String) -> URL {
        localBookDir(slug: slug).appendingPathComponent("output", isDirectory: true)
    }
    
    func localPageURL(slug: String, lang: String, page: Int) -> URL? {
        let padPage = String(format: "%04d", page)
        let pagePath = "\(lang)/page_\(padPage).html"
        let fileURL = localOutputDir(slug: slug).appendingPathComponent(pagePath)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }
    
    func isDownloaded(slug: String) -> Bool {
        return downloadStatus[slug] == .downloaded
    }
    
    func scanDownloadedBooks() {
        let fileManager = FileManager.default
        let booksDir = baseDirectory
        
        guard fileManager.fileExists(atPath: booksDir.path) else { return }
        
        do {
            let contents = try fileManager.contentsOfDirectory(at: booksDir, includingPropertiesForKeys: nil)
            for url in contents {
                let slug = url.lastPathComponent
                let manifestURL = url.appendingPathComponent("manifest.json")
                if fileManager.fileExists(atPath: manifestURL.path) {
                    downloadStatus[slug] = .downloaded
                }
            }
        } catch {
            print("Failed to scan downloaded books: \(error)")
        }
    }
    
    func downloadBook(slug: String, api: APIService) {
        guard downloadStatus[slug] != .downloading else { return }
        
        downloadStatus[slug] = .downloading
        downloadProgress[slug] = 0.0
        
        Task {
            do {
                let serverUrl = api.serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // 1. Fetch manifest
                guard let manifestUrl = URL(string: "\(serverUrl)/api/books/\(slug)/manifest") else {
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
                    print("Manifest request unauthorized (401). Attempting token refresh...")
                    let newToken = try await api.performTokenRefresh()
                    var retryRequest = URLRequest(url: manifestUrl)
                    retryRequest.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    
                    let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
                    guard let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode == 200 else {
                        let code = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
                        print("Manifest request retry failed with status code: \(code)")
                        throw URLError(.badServerResponse)
                    }
                    finalData = retryData
                } else if httpResponse.statusCode != 200 {
                    print("Manifest request failed with status code: \(httpResponse.statusCode) for URL: \(manifestUrl)")
                    if let body = String(data: data, encoding: .utf8) {
                        print("Error details: \(body)")
                    }
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
                
                // Create local directory
                let outputDir = localOutputDir(slug: slug)
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true, attributes: nil)
                
                // Save manifest file locally to mark successful download
                let manifestLocalURL = localBookDir(slug: slug).appendingPathComponent("manifest.json")
                try finalData.write(to: manifestLocalURL)
                
                // 2. Download each file in batches
                var downloadedCount = 0
                let batchSize = 6
                
                for i in stride(from: 0, to: totalFiles, by: batchSize) {
                    let end = min(i + batchSize, totalFiles)
                    let batch = manifest.files[i..<end]
                    
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        for filePath in batch {
                            group.addTask {
                                let currentToken = api.token
                                let encodedPath = filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filePath
                                let fileUrlString = "\(serverUrl)/books/\(slug)/output/\(encodedPath)?token=\(currentToken)"
                                guard let fileUrl = URL(string: fileUrlString) else {
                                    throw URLError(.badURL)
                                }
                                
                                let (fileData, fileResponse) = try await URLSession.shared.data(from: fileUrl)
                                guard let httpFileResponse = fileResponse as? HTTPURLResponse else {
                                    throw URLError(.badServerResponse)
                                }
                                
                                if httpFileResponse.statusCode == 401 {
                                    print("File download unauthorized (401). Refreshing token and retrying...")
                                    let newToken = try await api.performTokenRefresh()
                                    let retryUrlString = "\(serverUrl)/books/\(slug)/output/\(encodedPath)?token=\(newToken)"
                                    guard let retryUrl = URL(string: retryUrlString) else {
                                        throw URLError(.badURL)
                                    }
                                    let (retryData, retryResponse) = try await URLSession.shared.data(from: retryUrl)
                                    guard let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode == 200 else {
                                        let code = (retryResponse as? HTTPURLResponse)?.statusCode ?? 0
                                        print("File download retry failed with status code: \(code) for URL: \(retryUrl)")
                                        throw URLError(.badServerResponse)
                                    }
                                    
                                    let destinationURL = outputDir.appendingPathComponent(filePath)
                                    let parentDir = destinationURL.deletingLastPathComponent()
                                    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
                                    try retryData.write(to: destinationURL)
                                } else if httpFileResponse.statusCode != 200 {
                                    print("File download failed with status code: \(httpFileResponse.statusCode) for URL: \(fileUrlString)")
                                    throw URLError(.badServerResponse)
                                } else {
                                    let destinationURL = outputDir.appendingPathComponent(filePath)
                                    let parentDir = destinationURL.deletingLastPathComponent()
                                    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: nil)
                                    try fileData.write(to: destinationURL)
                                }
                            }
                        }
                        
                        for try await _ in group {
                            downloadedCount += 1
                            let progress = Double(downloadedCount) / Double(totalFiles)
                            await MainActor.run {
                                self.downloadProgress[slug] = progress
                            }
                        }
                    }
                }
                
                await MainActor.run {
                    self.downloadStatus[slug] = .downloaded
                    self.downloadProgress[slug] = 1.0
                }
                
            } catch {
                print("Failed to download book: \(error)")
                await MainActor.run {
                    self.downloadStatus[slug] = .notDownloaded
                    self.downloadProgress[slug] = 0.0
                }
            }
        }
    }
    
    func deleteCache(slug: String) {
        let dir = localBookDir(slug: slug)
        try? FileManager.default.removeItem(at: dir)
        downloadStatus[slug] = .notDownloaded
        downloadProgress[slug] = 0.0
    }
}
