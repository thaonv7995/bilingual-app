import SwiftUI

struct BookshelfView: View {
    @StateObject private var api = APIService.shared
    @State private var books: [Book] = []
    @State private var isLoading = false
    @State private var selectedBook: Book?
    @State private var showSettings = false
    @State private var rotationDegrees: Double = 0.0
    @State private var progressUpdateCounter: Int = 0
    
    // Adaptive grid columns for iPhone/iPad layouts
    let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)
    ]
    
    /// The library ordering rule, shared by the web app and this shelf:
    ///
    ///   Tier 1 — books the user has read (`effectiveLastRead > 0`), most recently read first.
    ///   Tier 2 — books never read, most recently imported first (`createdAt` descending).
    ///
    /// Tier 1 always sits above tier 2, so opening any book moves it to position 1. Reading
    /// activity beats import recency outright; the two are deliberately *not* blended with a
    /// `max()`, which would let a book imported a minute ago outrank one read five minutes ago.
    ///
    /// Ties break on `createdAt` DESC, then `bookId` DESC (autoincrement = import order), then
    /// `slug` ASC — the exact tuple the backend sorts by (`_shelf_key` in api/routes/books.py)
    /// and the web app's `compareBooks` (features/library/bookOrder.ts). The order is total, so
    /// it never depends on what the server or the database happened to hand back.
    private var sortedBooks: [Book] {
        // Dependency on the re-render trigger. Mutating the @State is what actually invalidates
        // the body; this keeps the relationship visible at the point it matters.
        _ = progressUpdateCounter
        guard !books.isEmpty else { return [] }

        return books
            .map { book in (book: book, lastRead: effectiveLastRead(for: book)) }
            .sorted { lhs, rhs in
                let lhsHasBeenRead = lhs.lastRead > 0
                let rhsHasBeenRead = rhs.lastRead > 0
                if lhsHasBeenRead != rhsHasBeenRead {
                    return lhsHasBeenRead  // tier 1 above tier 2
                }
                // Tier 1: most recently read first. Both are 0 inside tier 2, so this is a no-op there.
                if lhs.lastRead != rhs.lastRead {
                    return lhs.lastRead > rhs.lastRead
                }
                // Tier 2 (and read-at-the-same-second ties): newest import first. Applied in BOTH
                // tiers, matching the backend tuple and the web comparator — restricting it to
                // unread books would order tier-1 ties by slug while the other two used createdAt.
                let lhsCreatedAt = lhs.book.createdAt ?? 0
                let rhsCreatedAt = rhs.book.createdAt ?? 0
                if lhsCreatedAt != rhsCreatedAt {
                    return lhsCreatedAt > rhsCreatedAt
                }
                // Import order. This is what carries rows whose `createdAt` is NULL (imported
                // before the backend had the column) — without it they would collapse to
                // alphabetical, losing the newest-import-first rule on any pre-existing library.
                let lhsId = lhs.book.bookId ?? 0
                let rhsId = rhs.book.bookId ?? 0
                if lhsId != rhsId {
                    return lhsId > rhsId
                }
                return lhs.book.slug < rhs.book.slug
            }
            .map(\.book)
    }

    /// Newest known read time for a book: the server's value, or the locally cached
    /// `progress_<slug>` entry when that is fresher. The local cache is what makes a
    /// just-finished book jump to the top before the next fetch lands; the server value wins
    /// whenever it is newer, e.g. after reading the same book on another device.
    private func effectiveLastRead(for book: Book) -> Int64 {
        var lastRead = book.lastRead ?? 0
        if let data = UserDefaults.standard.data(forKey: "progress_\(book.slug)"),
           let progress = try? JSONDecoder().decode(ReadingProgress.self, from: data),
           let cachedLastRead = progress.lastRead {
            lastRead = max(lastRead, cachedLastRead)
        }
        return lastRead
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "0f172a").ignoresSafeArea()
                
                if isLoading {
                    ProgressView("Đang tải danh sách sách...")
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .foregroundColor(.white)
                } else if books.isEmpty {
                    VStack(spacing: 15) {
                        Image(systemName: "book.closed")
                            .resizable()
                            .frame(width: 60, height: 60)
                            .foregroundColor(Color(hex: "475569"))
                        Text("Tủ sách trống hoặc chưa được cấp quyền")
                            .font(.headline)
                            .foregroundColor(Color(hex: "94a3b8"))
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 25) {
                            ForEach(sortedBooks) { book in
                                BookCard(book: book, onSelect: {
                                    selectedBook = book
                                })
                            }
                        }
                        .padding(20)
                    }
                    .refreshable {
                        await loadBooks()
                    }
                }
            }
            .navigationTitle("Tủ Sách Song Ngữ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 10) {
                        Button(action: {
                            showSettings = true
                        }) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(0.9))
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(0.06))
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                )
                        }
                        
                        Button(action: {
                            Task { await loadBooks() }
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white.opacity(0.9))
                                .rotationEffect(.degrees(rotationDegrees))
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(0.06))
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                )
                        }
                        
                        Button(action: {
                            api.logout()
                        }) {
                            Image(systemName: "power")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Color(hex: "ef4444"))
                                .frame(width: 32, height: 32)
                                .background(Color(hex: "ef4444").opacity(0.1))
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(Color(hex: "ef4444").opacity(0.25), lineWidth: 1)
                                )
                        }
                    }
                }
            }
            .fullScreenCover(item: $selectedBook) { book in
                ReaderView(book: book)
            }
            .sheet(isPresented: $showSettings) {
                AISettingsView(books: books)
                    .applySheetBackground(Color(hex: "0f172a"))
            }
            .onAppear {
                Task { await loadBooks() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReadingProgressUpdated"))) { _ in
                progressUpdateCounter += 1
            }
            .onChange(of: selectedBook) { newValue in
                // When user returns from reader (selectedBook becomes nil),
                // trigger re-sort so the just-read book appears first
                if newValue == nil {
                    progressUpdateCounter += 1
                }
            }
            .onChange(of: isLoading) { loading in
                if loading {
                    withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                        rotationDegrees = 360
                    }
                } else {
                    withAnimation(.spring()) {
                        rotationDegrees = 0
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private func loadBooks() async {
        await MainActor.run { isLoading = true }
        do {
            let fetched = try await api.fetchBooks()
            await MainActor.run {
                self.books = fetched
                self.isLoading = false
            }
            
            // Sync progress for each book from server in background
            Task {
                for book in fetched {
                    do {
                        let serverProgress = try await api.fetchProgress(slug: book.slug)
                        var shouldSave = true
                        if let cachedData = UserDefaults.standard.data(forKey: "progress_\(book.slug)"),
                           let cached = try? JSONDecoder().decode(ReadingProgress.self, from: cachedData) {
                            let cachedTime = cached.lastRead ?? 0
                            let serverTime = serverProgress.lastRead ?? 0
                            if serverTime < cachedTime {
                                shouldSave = false
                            }
                        }
                        if shouldSave {
                            if let data = try? JSONEncoder().encode(serverProgress) {
                                UserDefaults.standard.set(data, forKey: "progress_\(book.slug)")
                            }
                        }
                    } catch {
                        print("Failed to sync progress for \(book.slug): \(error)")
                    }
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: NSNotification.Name("ReadingProgressUpdated"), object: nil)
                }
            }
            
            // Auto-download all books that are not downloaded yet sequentially
            Task { @MainActor in
                for book in fetched {
                    let status = BookCacheManager.shared.downloadStatus[book.slug] ?? .notDownloaded
                    if status == .notDownloaded {
                        await BookCacheManager.shared.downloadBook(slug: book.slug, api: api)
                    }
                }
            }
        } catch {
            print("Failed to fetch books: \(error)")
            await MainActor.run { self.isLoading = false }
        }
    }
}

struct BookCard: View {
    let book: Book
    let onSelect: () -> Void
    @StateObject private var api = APIService.shared
    @ObservedObject private var cacheManager = BookCacheManager.shared
    
    @State private var progress: ReadingProgress? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Book Cover Wrapper
            ZStack {
                Color(hex: "1e293b")
                
                let localCoverURL = BookCacheManager.shared.localBookDir(slug: book.slug)
                    .appendingPathComponent("output")
                    .appendingPathComponent(book.coverPath ?? "")
                
                GeometryReader { geo in
                    if cacheManager.isDownloaded(slug: book.slug),
                       !(book.coverPath ?? "").isEmpty,
                       FileManager.default.fileExists(atPath: localCoverURL.path),
                       let uiImage = UIImage(contentsOfFile: localCoverURL.path) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    } else if let coverPath = book.cover, let coverUrl = URL(string: "\(api.serverUrl)/\(coverPath)") {
                        AsyncImage(url: coverUrl) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            ProgressView().tint(.white)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    } else {
                        // Fallback Text Cover
                        VStack(spacing: 8) {
                            Image(systemName: "book.fill")
                                .font(.largeTitle)
                                .foregroundColor(Color(hex: "6366f1"))
                            Text(book.title)
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 10)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            .aspectRatio(154.0/220.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(
                // Bottom Gradient & Information Overlay
                VStack {
                    Spacer()
                    
                    VStack(alignment: .leading, spacing: 4) {
                        // Author
                        Text(book.author ?? "Unknown Author")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)
                        
                        // Progress
                        HStack(alignment: .firstTextBaseline) {
                            if let progress = progress {
                                Text("Trang \(progress.page)/\(book.pageCount)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color(hex: "2dd4bf"))
                            } else {
                                Text("\(book.pageCount) trang")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white.opacity(0.9))
                            }
                            
                            Spacer()
                            
                            if let progress = progress, let lastRead = progress.lastRead {
                                Text(formatTime(lastRead))
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                        
                        // Progress Bar
                        if let progress = progress {
                            let percent = Double(progress.page) / Double(book.pageCount)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.white.opacity(0.2))
                                        .frame(height: 3)
                                    
                                    Capsule()
                                        .fill(Color(hex: "2dd4bf"))
                                        .frame(width: geo.size.width * CGFloat(min(percent, 1.0)), height: 3)
                                }
                            }
                            .frame(height: 3)
                            .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 24)
                    .padding(.bottom, 10)
                    .background(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.65), .black.opacity(0.95)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            )
            .overlay(
                downloadStatusOverlay,
                alignment: .topTrailing
            )
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect()
            }
            
            // Book Titles
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect()
            }
        }
        .onAppear {
            loadLocalProgress()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReadingProgressUpdated"))) { _ in
            loadLocalProgress()
        }
    }
    
    private func loadLocalProgress() {
        if let data = UserDefaults.standard.data(forKey: "progress_\(book.slug)"),
           let decoded = try? JSONDecoder().decode(ReadingProgress.self, from: data) {
            self.progress = decoded
        } else {
            self.progress = nil
        }
    }
    
    private func formatTime(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let now = Date()
        let diff = Int(now.timeIntervalSince(date))
        
        if diff < 60 {
            return "Vừa xong"
        } else if diff < 3600 {
            return "\(diff / 60) phút"
        } else if diff < 86400 {
            return "\(diff / 3600) giờ"
        } else if diff < 604800 {
            return "\(diff / 86400) ngày"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "dd/MM"
            return formatter.string(from: date)
        }
    }
    
    private var downloadStatusOverlay: some View {
        let status = cacheManager.downloadStatus[book.slug] ?? .notDownloaded
        let progress = cacheManager.downloadProgress[book.slug] ?? 0.0
        
        return Group {
            if status == .downloading {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.25), lineWidth: 2)
                        .frame(width: 28, height: 28)
                    
                    Circle()
                        .trim(from: 0.0, to: CGFloat(progress))
                        .stroke(Color(hex: "38bdf8"), lineWidth: 2)
                        .frame(width: 28, height: 28)
                        .rotationEffect(Angle(degrees: -90))
                    
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 28, height: 28)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
                .padding(8)
            }
        }
    }
}

extension View {
    @ViewBuilder
    func applySheetBackground(_ color: Color) -> some View {
        if #available(iOS 16.4, *) {
            self.presentationBackground(color)
        } else {
            self
        }
    }
}
