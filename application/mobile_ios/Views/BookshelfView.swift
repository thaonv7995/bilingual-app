import SwiftUI

struct BookshelfView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private enum CollectionFilter: String, CaseIterable, Identifiable {
        case all = "Tất cả"
        case priority = "Ưu tiên"
        case finished = "Đã đọc"
        case offlineReady = "Đã lưu Offline"
        var id: String { rawValue }
    }

    @StateObject private var api = APIService.shared
    @ObservedObject private var cacheManager = BookCacheManager.shared
    @State private var books: [Book] = []
    @State private var isLoading = false
    @State private var selectedBook: Book?
    @State private var offlineUnavailableBook: Book?
    @State private var showSettings = false
    @State private var rotationDegrees: Double = 0.0
    @State private var progressUpdateCounter: Int = 0
    @State private var collectionFilter: CollectionFilter = .all
    @State private var hideFinished = UserDefaults.standard.object(forKey: "hideFinishedBooks") as? Bool ?? true
    @State private var searchText = ""
    @State private var autoDownloadTask: Task<Void, Never>?
    
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

        let ordered = books
            .map { book in (book: book, lastRead: effectiveLastRead(for: book)) }
            .sorted { lhs, rhs in
                let lhsPriority = lhs.book.isPriority == true
                let rhsPriority = rhs.book.isPriority == true
                if lhsPriority != rhsPriority {
                    return lhsPriority
                }
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

        let inCollection = ordered.filter { book in
            switch collectionFilter {
            case .all: return !hideFinished || book.isFinished != true
            case .priority: return book.isPriority == true
            case .finished: return book.isFinished == true
            case .offlineReady: return cacheManager.isDownloaded(slug: book.slug)
            }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return inCollection }
        return inCollection.filter { book in
            book.title.lowercased().contains(query)
                || (book.author ?? "").lowercased().contains(query)
        }
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

    private var offlineReadyCount: Int {
        books.filter { cacheManager.isDownloaded(slug: $0.slug) }.count
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "0f172a").ignoresSafeArea()
                
                if isLoading && books.isEmpty {
                    ProgressView("Đang tải danh sách sách...")
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .foregroundColor(.white)
                } else if books.isEmpty {
                    VStack(spacing: 15) {
                        Image(systemName: api.isOfflineMode ? "wifi.slash" : "book.closed")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 56, height: 56)
                            .foregroundColor(Color(hex: api.isOfflineMode ? "f59e0b" : "475569"))
                        Text(api.isOfflineMode
                             ? "Đang ngoại tuyến và chưa có sách nào lưu trên thiết bị"
                             : "Tủ sách trống hoặc chưa được cấp quyền")
                            .font(.headline)
                            .foregroundColor(Color(hex: "94a3b8"))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                        if api.isOfflineMode {
                            Button("Thử kết nối lại") {
                                Task {
                                    await api.verifySession()
                                    await loadBooks()
                                }
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Color(hex: "6366f1"))
                            .cornerRadius(10)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        offlineStatusBanner

                        ScrollView {
                            VStack(spacing: 16) {
                                if sortedBooks.isEmpty {
                                    Text("Không có sách trong mục này")
                                        .foregroundColor(Color(hex: "94a3b8"))
                                        .padding(.top, 50)
                                } else {
                                    LazyVGrid(columns: columns, spacing: 25) {
                                        ForEach(sortedBooks) { book in
                                            let isCached = cacheManager.isDownloaded(slug: book.slug)
                                            let status = cacheManager.downloadStatus[book.slug] ?? .notDownloaded
                                            BookCard(
                                                book: book,
                                                isOfflineUnavailable: api.isOfflineMode && !isCached,
                                                onSelect: { openBook(book) },
                                                onTogglePriority: {
                                                    updateState(book, key: "isPriority", value: book.isPriority != true)
                                                }
                                            )
                                            .contextMenu {
                                                Button("Mở đọc sách") {
                                                    openBook(book)
                                                }
                                                Button(book.isPriority == true ? "Bỏ ưu tiên" : "Ưu tiên đọc") {
                                                    updateState(book, key: "isPriority", value: book.isPriority != true)
                                                }
                                                Button(book.isFinished == true ? "Đánh dấu chưa hoàn thành" : "Đánh dấu đã đọc xong") {
                                                    updateState(book, key: "isFinished", value: book.isFinished != true)
                                                }
                                                Divider()
                                                if status == .downloading {
                                                    Button("Hủy tải xuống", role: .destructive) {
                                                        cacheManager.cancelDownload(slug: book.slug)
                                                    }
                                                } else if isCached {
                                                    if !api.isOfflineMode {
                                                        Button(cacheManager.needsUpdate(slug: book.slug) ? "Cập nhật bản mới" : "Tải lại từ server") {
                                                            Task {
                                                                await cacheManager.downloadBook(
                                                                    slug: book.slug,
                                                                    api: api,
                                                                    forceRedownload: true
                                                                )
                                                            }
                                                        }
                                                    }
                                                    Button("Xóa bản lưu offline", role: .destructive) {
                                                        cacheManager.deleteCache(slug: book.slug)
                                                    }
                                                } else if !api.isOfflineMode {
                                                    Button("Tải về đọc offline") {
                                                        Task {
                                                            await cacheManager.downloadBook(slug: book.slug, api: api)
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(20)
                        }
                        .refreshable {
                            await loadBooks()
                        }
                    }
                }
            }
            .navigationTitle("Tủ Sách Song Ngữ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .modifier(CompactLibrarySearchModifier(
                text: $searchText,
                enabled: horizontalSizeClass != .regular
            ))
            .toolbar {
                if horizontalSizeClass == .regular {
                    ToolbarItem(placement: .principal) {
                        LibraryToolbarSearchField(text: $searchText)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 10) {
                        Menu {
                            Picker("Hiển thị", selection: $collectionFilter) {
                                ForEach(CollectionFilter.allCases) { filter in
                                    Text(filter.rawValue).tag(filter)
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(collectionFilter == .all ? .white.opacity(0.9) : Color(hex: "38bdf8"))
                                .frame(width: 32, height: 32)
                                .background(collectionFilter == .all ? Color.white.opacity(0.06) : Color(hex: "38bdf8").opacity(0.12))
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(collectionFilter == .all ? Color.white.opacity(0.12) : Color(hex: "38bdf8").opacity(0.3), lineWidth: 1)
                                )
                        }
                        .accessibilityLabel("Lọc sách: \(collectionFilter.rawValue)")

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
                hideFinished = UserDefaults.standard.object(forKey: "hideFinishedBooks") as? Bool ?? true
                Task { await loadBooks() }
            }
            .onChange(of: showSettings) { isShowing in
                if !isShowing {
                    hideFinished = UserDefaults.standard.object(forKey: "hideFinishedBooks") as? Bool ?? true
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReadingProgressUpdated"))) { _ in
                progressUpdateCounter += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BookStateUpdated"))) { _ in
                Task { await loadBooks() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NetworkConnectivityRestored"))) { _ in
                Task { await loadBooks() }
            }
            .alert(
                "Sách chưa được lưu offline",
                isPresented: Binding(
                    get: { offlineUnavailableBook != nil },
                    set: { if !$0 { offlineUnavailableBook = nil } }
                ),
                presenting: offlineUnavailableBook
            ) { _ in
                Button("Đóng", role: .cancel) {}
            } message: { book in
                Text("\"\(book.title)\" chưa được tải về thiết bị. Hãy kết nối mạng để tải sách trước khi đọc ngoại tuyến.")
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

    @ViewBuilder
    private var offlineStatusBanner: some View {
        if api.isOfflineMode {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(hex: "f59e0b"))
                        .frame(width: 6, height: 6)
                    Text("Ngoại tuyến")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(hex: "fbbf24"))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(hex: "f59e0b").opacity(0.16), in: Capsule())

                Text("\(offlineReadyCount)/\(books.count) sách sẵn sàng")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "cbd5e1"))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button {
                    Task {
                        await api.verifySession()
                        await loadBooks()
                    }
                } label: {
                    Text("Thử kết nối")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "93c5fd"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(hex: "3b82f6").opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(hex: "f59e0b").opacity(0.1))
        } else if cacheManager.pendingSyncCount > 0 {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "38bdf8"))
                Text("Có \(cacheManager.pendingSyncCount) thay đổi đọc ngoại tuyến đang chờ đồng bộ")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "cbd5e1"))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    Task {
                        await api.syncPendingOfflineOperations()
                        await loadBooks()
                    }
                } label: {
                    Text("Đồng bộ")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "5eead4"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(hex: "14b8a6").opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color(hex: "38bdf8").opacity(0.1))
        }
    }

    private func openBook(_ book: Book) {
        if api.isOfflineMode && !cacheManager.isDownloaded(slug: book.slug) {
            offlineUnavailableBook = book
            return
        }
        selectedBook = book
    }

    private func updateState(_ book: Book, key: String, value: Bool) {
        if let idx = books.firstIndex(where: { $0.slug == book.slug }) {
            if key == "isPriority" { books[idx].isPriority = value }
            if key == "isFinished" { books[idx].isFinished = value }
        }
        Task {
            do {
                _ = try await api.updateBookState(slug: book.slug, patch: [key: value])
                if !api.isOfflineMode {
                    await loadBooks()
                }
            } catch {
                print("Failed to update book state for \(book.slug): \(error)")
            }
        }
    }
    
    private func loadBooks() async {
        await MainActor.run {
            if self.books.isEmpty {
                let cached = cacheManager.loadCachedBooks(
                    serverUrl: api.normalizedServerUrl,
                    username: api.username
                )
                if !cached.isEmpty {
                    self.books = cached
                }
            }
            isLoading = true
        }
        do {
            let fetched = try await api.fetchBooks()
            await MainActor.run {
                self.books = fetched
                self.isLoading = false
                for book in fetched {
                    let rawFont = (book.readerFont ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let rawTheme = (book.readerTheme ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let normFont = rawFont.isEmpty ? "" : ReaderAppearance.getFont(rawFont).id
                    let normTheme = rawTheme.isEmpty
                        ? ""
                        : ReaderAppearance.serializeThemeDescriptor(
                            ReaderAppearance.parseThemeDescriptor(rawTheme)
                        )
                    ReaderAppearance.saveLocalOverride(
                        slug: book.slug,
                        readerFont: normFont,
                        readerTheme: normTheme
                    )
                }
            }

            // Refresh backup manifest in background so incremental updates know contentFingerprint & sizes.
            Task {
                _ = try? await api.fetchBackupManifest()
            }
            
            // Sync progress for each book cleanly both ways in background
            Task {
                for book in fetched {
                    do {
                        let serverProgress = try await api.fetchProgress(slug: book.slug)
                        var cachedLocal: ReadingProgress?
                        if let cachedData = UserDefaults.standard.data(forKey: "progress_\(book.slug)"),
                           let cached = try? JSONDecoder().decode(ReadingProgress.self, from: cachedData) {
                            cachedLocal = cached
                        }

                        let cachedTime = cachedLocal?.lastRead ?? 0
                        let serverTime = serverProgress.lastRead ?? 0
                        if let cachedLocal, cachedTime > serverTime {
                            await api.saveProgress(
                                slug: book.slug,
                                page: cachedLocal.page,
                                viewMode: cachedLocal.viewMode,
                                lastRead: cachedTime
                            )
                        } else if let data = try? JSONEncoder().encode(serverProgress) {
                            UserDefaults.standard.set(data, forKey: "progress_\(book.slug)")
                        }
                    } catch {
                        print("Failed to sync progress for \(book.slug): \(error)")
                    }
                }
                await MainActor.run {
                    NotificationCenter.default.post(name: NSNotification.Name("ReadingProgressUpdated"), object: nil)
                }
            }
            
            // Auto-download missing or updated books sequentially when enabled
            if cacheManager.autoCacheBooks {
                await MainActor.run {
                    autoDownloadTask?.cancel()
                    autoDownloadTask = Task { @MainActor in
                        await cacheManager.downloadAllMissing(books: fetched, api: api)
                    }
                }
            }
        } catch {
            print("Failed to fetch books (falling back to offline cache): \(error)")
            await MainActor.run {
                let cached = cacheManager.loadCachedBooks(
                    serverUrl: api.normalizedServerUrl,
                    username: api.username
                )
                if !cached.isEmpty {
                    self.books = cached
                }
                self.isLoading = false
            }
        }
    }
}

private struct CompactLibrarySearchModifier: ViewModifier {
    @Binding var text: String
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(
                text: $text,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Tìm sách hoặc tác giả"
            )
        } else {
            content
        }
    }
}

private struct LibraryToolbarSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            TextField("Tìm sách hoặc tác giả", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(.white)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Xóa tìm kiếm")
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 320, height: 36)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

struct BookCard: View {
    let book: Book
    var isOfflineUnavailable: Bool = false
    let onSelect: () -> Void
    let onTogglePriority: () -> Void
    @StateObject private var api = APIService.shared
    @ObservedObject private var cacheManager = BookCacheManager.shared
    
    @State private var progress: ReadingProgress? = nil
    @State private var remoteCoverImage: UIImage? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Book Cover Wrapper
            ZStack {
                Color(hex: "1e293b")
                
                GeometryReader { geo in
                    if let localURL = cacheManager.localCoverURL(slug: book.slug, coverPath: book.coverPath),
                       let uiImage = UIImage(contentsOfFile: localURL.path) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    } else if let remoteCoverImage {
                        Image(uiImage: remoteCoverImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
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
                            let percent = Double(progress.page) / Double(max(1, book.pageCount))
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
            .opacity(isOfflineUnavailable ? 0.55 : 1.0)
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect()
            }
            
            // Book Titles
            HStack(alignment: .top, spacing: 6) {
                Text(book.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(isOfflineUnavailable ? .white.opacity(0.65) : .white)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button(action: onTogglePriority) {
                    Image(systemName: book.isPriority == true ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(book.isPriority == true ? Color(hex: "fbbf24") : .white.opacity(0.55))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(book.isPriority == true ? "Bỏ ưu tiên" : "Ưu tiên đọc")
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
        .task(id: "\(book.slug)|\(api.isOfflineMode)") {
            await loadRemoteCoverIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReadingProgressUpdated"))) { _ in
            loadLocalProgress()
        }
    }

    private func loadRemoteCoverIfNeeded() async {
        guard remoteCoverImage == nil,
              cacheManager.localCoverURL(slug: book.slug, coverPath: book.coverPath) == nil,
              !api.isOfflineMode,
              let cover = book.cover else {
            return
        }
        let cleanCover = cover.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanCover.isEmpty,
              let coverUrl = URL(string: "\(api.normalizedServerUrl)/\(cleanCover)") else {
            return
        }
        var request = URLRequest(url: coverUrl)
        request.timeoutInterval = 12.0
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let img = UIImage(data: data) else {
            return
        }
        cacheManager.saveCachedCoverData(slug: book.slug, data: data)
        await MainActor.run {
            self.remoteCoverImage = img
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
            } else if status == .downloaded {
                Image(systemName: cacheManager.needsUpdate(slug: book.slug) ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: cacheManager.needsUpdate(slug: book.slug) ? "38bdf8" : "2dd4bf"))
                    .padding(4)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Circle())
                    .padding(7)
            } else if api.isOfflineMode {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "fbbf24"))
                    .padding(5)
                    .background(Color.black.opacity(0.65))
                    .clipShape(Circle())
                    .padding(7)
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
