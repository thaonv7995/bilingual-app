import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "Tất cả"
    case priority = "Ưu tiên"
    case finished = "Đã đọc"
    case offlineReady = "Đã lưu Offline"

    var id: String { rawValue }
}

struct LibraryView: View {
    let onOpenBook: (Book) -> Void
    let onOpenSettings: (SettingsTab) -> Void

    @ObservedObject private var api = APIService.shared
    @ObservedObject private var backup = BackupManager.shared

    @State private var searchText: String = ""
    @State private var selectedFilter: LibraryFilter = .all
    @State private var isLoadingBooks: Bool = false
    @State private var rotationDegrees: Double = 0
    @State private var progressUpdateCounter: Int = 0
    @State private var hideFinishedBooks: Bool = UserDefaults.standard.object(forKey: "hideFinishedBooks") as? Bool ?? true
    @State private var statusBanner: String?
    @State private var coverCache: [String: NSImage] = [:]

    private let columns = [
        GridItem(.adaptive(minimum: 165, maximum: 210), spacing: 22)
    ]

    private var sourceBooks: [Book] {
        if api.isOfflineMode && api.books.isEmpty {
            let uname = api.currentUser?.username ?? backup.latestSnapshot?.exportedBy ?? ""
            let isAdmin = api.currentUser?.isAdmin ?? (backup.latestSnapshot?.scope == BackupScope.adminFull.rawValue)
            return backup.offlineBooks(forUsername: uname, isAdmin: isAdmin)
        }
        return api.books
    }

    private var filteredBooks: [Book] {
        _ = progressUpdateCounter
        let ordered = BookSort.sortedShelf(sourceBooks) { slug in
            cachedLastRead(for: slug)
        }

        let inCollection = ordered.filter { book in
            switch selectedFilter {
            case .all:
                return !hideFinishedBooks || book.isFinished != true
            case .priority:
                return book.isPriority == true
            case .finished:
                return book.isFinished == true
            case .offlineReady:
                return backup.hasOfflineBook(slug: book.slug)
            }
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return inCollection }
        return inCollection.filter { book in
            book.title.lowercased().contains(q)
                || (book.author ?? "").lowercased().contains(q)
                || book.slug.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            bookshelfHeader

            if backup.wipeGuardTriggered {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(hex: "fbbf24"))
                    Text("Cảnh báo Backup: Server đang trả về 0 sách. Đã giữ nguyên dữ liệu cục bộ.")
                        .font(.caption)
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        onOpenSettings(.backup)
                    } label: {
                        Text("Mở Sao lưu & Khôi phục")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(hex: "38bdf8"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color(hex: "38bdf8").opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.macInteractive(cornerRadius: 6))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(Color(hex: "f59e0b").opacity(0.14))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let msg = statusBanner {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(Color(hex: "38bdf8"))
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { statusBanner = nil }
                    } label: {
                        Text("Đóng")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color(hex: "94a3b8"))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.macInteractive(cornerRadius: 6))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color(hex: "38bdf8").opacity(0.12))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)

            if isLoadingBooks && sourceBooks.isEmpty {
                Spacer()
                ProgressView("Đang tải tủ sách…")
                    .tint(.white)
                    .foregroundStyle(Color(hex: "94a3b8"))
                Spacer()
            } else if filteredBooks.isEmpty {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 52))
                        .foregroundStyle(Color(hex: "475569"))
                    Text(sourceBooks.isEmpty ? "Tủ sách trống hoặc chưa được cấp quyền" : "Không có sách trong mục này")
                        .font(.headline)
                        .foregroundStyle(Color(hex: "94a3b8"))
                    if api.isOfflineMode {
                        Text("Kết nối Server và vào Cài đặt → Sao lưu & Khôi phục để tải sách ngoại tuyến.")
                            .font(.caption)
                            .foregroundStyle(Color(hex: "64748b"))
                    }
                }
                .transition(.opacity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 26) {
                        ForEach(Array(filteredBooks.enumerated()), id: \.element.id) { idx, book in
                            BookCardMac(
                                book: book,
                                entranceIndex: idx,
                                isBackedUp: backup.hasOfflineBook(slug: book.slug),
                                coverImage: loadCachedOrLocalCover(book: book),
                                progressRevision: progressUpdateCounter,
                                onOpen: { onOpenBook(book) },
                                onTogglePriority: { togglePriority(book) },
                                onToggleFinished: { toggleFinished(book) }
                            )
                        }
                    }
                    .padding(24)
                    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: filteredBooks.map(\.slug))
                }
            }
        }
        .background(Color(hex: "0f172a"))
        .animation(.easeInOut(duration: 0.22), value: backup.wipeGuardTriggered)
        .animation(.easeInOut(duration: 0.22), value: statusBanner != nil)
        .task {
            await refreshLibrary()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ReadingProgressUpdated"))) { _ in
            hideFinishedBooks = UserDefaults.standard.object(forKey: "hideFinishedBooks") as? Bool ?? true
            progressUpdateCounter += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BookStateUpdated"))) { _ in
            Task { await refreshLibrary() }
        }
        .onChange(of: isLoadingBooks) { _, loading in
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

    // MARK: - iPad-style Top Toolbar

    private var bookshelfHeader: some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(hex: "818cf8"))

                Text("Tủ Sách Song Ngữ")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                if api.isOfflineMode {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(hex: "f59e0b"))
                            .frame(width: 6, height: 6)
                        Text("Ngoại tuyến")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: "fbbf24"))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(hex: "f59e0b").opacity(0.14), in: Capsule())
                    .overlay(Capsule().stroke(Color(hex: "f59e0b").opacity(0.35), lineWidth: 1))
                }
            }

            Spacer(minLength: 12)

            // Search Field (exact iPad style)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))

                TextField("Tìm sách hoặc tác giả", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.macCircle())
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 310, height: 34)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )

            Spacer(minLength: 12)

            // Action Circle Buttons (exact iPad style)
            HStack(spacing: 10) {
                Menu {
                    Picker("Hiển thị", selection: $selectedFilter) {
                        ForEach(LibraryFilter.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selectedFilter == .all ? .white.opacity(0.9) : Color(hex: "38bdf8"))
                        .frame(width: 34, height: 34)
                        .background(selectedFilter == .all ? Color.white.opacity(0.06) : Color(hex: "38bdf8").opacity(0.14))
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(selectedFilter == .all ? Color.white.opacity(0.12) : Color(hex: "38bdf8").opacity(0.35), lineWidth: 1)
                        )
                        .macHoverHighlight(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 34, height: 34)
                .help("Lọc sách: \(selectedFilter.rawValue)")

                if api.currentUser?.isAdmin == true && !api.isOfflineMode {
                    Button {
                        pickAndUploadBKB()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.macCircle())
                    .help("Thêm sách .bkb lên Server")
                }

                Button {
                    Task { await refreshLibrary() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .rotationEffect(.degrees(rotationDegrees))
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.06))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.macCircle())
                .disabled(isLoadingBooks)
                .help("Làm mới tủ sách")

                Button {
                    onOpenSettings(.general)
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))

                        if backup.wipeGuardTriggered {
                            Circle()
                                .fill(Color(hex: "ef4444"))
                                .frame(width: 8, height: 8)
                                .offset(x: 1, y: -1)
                        }
                    }
                }
                .buttonStyle(.macCircle())
                .help("Cài đặt & Sao lưu")

                Menu {
                    if let user = api.currentUser {
                        Text("\(user.username) (\(user.isAdmin ? "Admin" : "Reader"))")
                        Divider()
                    }
                    if api.isOfflineMode {
                        Button("Kết nối lại Server") {
                            Task {
                                await api.verifyToken()
                                await refreshLibrary()
                            }
                        }
                    }
                    Button("Sao lưu & Khôi phục Server…") {
                        onOpenSettings(.backup)
                    }
                    Divider()
                    Button("Đăng xuất", role: .destructive) {
                        api.logout()
                    }
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: "ef4444"))
                        .frame(width: 34, height: 34)
                        .background(Color(hex: "ef4444").opacity(0.1))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color(hex: "ef4444").opacity(0.25), lineWidth: 1))
                        .macHoverHighlight(Circle(), hoverColor: Color(hex: "ef4444").opacity(0.14))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 34, height: 34)
                .help("Tài khoản & Kết nối")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Color(hex: "0f172a"))
    }

    // MARK: - Data & Helpers

    private func cachedLastRead(for slug: String) -> Int? {
        guard let data = UserDefaults.standard.data(forKey: "progress_\(slug)"),
              let prog = try? JSONDecoder().decode(ReadingProgress.self, from: data) else {
            return nil
        }
        return prog.lastRead
    }

    private func refreshLibrary() async {
        isLoadingBooks = true
        defer { isLoadingBooks = false }
        do {
            try await api.fetchBooks()
            await api.fetchAppConfig()
            let fetched = api.books
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
            Task {
                for book in fetched {
                    _ = await api.fetchReadingProgress(slug: book.slug)
                }
                await MainActor.run {
                    progressUpdateCounter += 1
                }
            }
        } catch {
            if api.isOfflineMode || !backup.snapshots.isEmpty {
                statusBanner = "Không thể kết nối server — đang hiển thị sách từ bản lưu ngoại tuyến."
            } else {
                statusBanner = "Lỗi tải thư viện: \(error.localizedDescription)"
            }
        }
    }

    private func loadCachedOrLocalCover(book: Book) -> NSImage? {
        if let img = coverCache[book.slug] { return img }
        if let localURL = backup.localCoverURL(slug: book.slug, coverPath: book.cover),
           let img = NSImage(contentsOf: localURL) {
            DispatchQueue.main.async { coverCache[book.slug] = img }
            return img
        }
        if let coverPath = book.cover, !coverPath.isEmpty, !api.isOfflineMode {
            Task {
                if let data = await api.fetchBookCoverData(coverPath: coverPath),
                   let img = NSImage(data: data) {
                    await MainActor.run { coverCache[book.slug] = img }
                }
            }
        }
        return nil
    }

    private func togglePriority(_ book: Book) {
        guard !api.isOfflineMode else { return }
        let next = !(book.isPriority == true)
        Task {
            await api.updateBookState(slug: book.slug, isPriority: next)
            await MainActor.run { progressUpdateCounter += 1 }
        }
    }

    private func toggleFinished(_ book: Book) {
        guard !api.isOfflineMode else { return }
        let next = !(book.isFinished == true)
        Task {
            await api.updateBookState(slug: book.slug, isFinished: next)
            await MainActor.run { progressUpdateCounter += 1 }
        }
    }

    private func pickAndUploadBKB() {
        let panel = NSOpenPanel()
        panel.title = "Chọn file sách .bkb để tải lên Server"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let slug = try await api.uploadBookArchive(fileURL: url)
                statusBanner = "Đã thêm sách '\(slug)' lên server thành công."
                try await api.fetchBooks()
            } catch {
                statusBanner = "Lỗi upload .bkb: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - iPad-style Book Cover Card

private struct BookCardMac: View {
    let book: Book
    let entranceIndex: Int
    let isBackedUp: Bool
    let coverImage: NSImage?
    let progressRevision: Int
    let onOpen: () -> Void
    let onTogglePriority: () -> Void
    let onToggleFinished: () -> Void

    @State private var isHovering: Bool = false
    @State private var isAppeared: Bool = false
    @State private var progress: ReadingProgress?

    private var pageTotal: Int {
        max(1, book.pageCount ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                Color(hex: "1e293b")

                GeometryReader { geo in
                    if let coverImage {
                        Image(nsImage: coverImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .scaleEffect(isHovering ? 1.05 : 1.0)
                            .clipped()
                            .animation(.spring(response: 0.36, dampingFraction: 0.82), value: isHovering)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "book.fill")
                                .font(.largeTitle)
                                .foregroundStyle(Color(hex: "6366f1"))
                            Text(book.title)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .padding(.horizontal, 12)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
            .aspectRatio(154.0 / 220.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.author ?? "Unknown Author")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)

                    HStack(alignment: .firstTextBaseline) {
                        if let progress {
                            Text("Trang \(progress.page)/\(pageTotal)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(hex: "2dd4bf"))
                        } else {
                            Text("\(pageTotal) trang")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.9))
                        }

                        Spacer()

                        if let ts = progress?.lastRead ?? book.lastRead {
                            Text(formatTime(ts))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }

                    if let progress {
                        let ratio = min(1.0, max(0.0, Double(progress.page) / Double(pageTotal)))
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.22))
                                    .frame(height: 3)
                                Capsule()
                                    .fill(Color(hex: "2dd4bf"))
                                    .frame(width: geo.size.width * CGFloat(ratio), height: 3)
                                    .animation(.easeOut(duration: 0.35), value: ratio)
                            }
                        }
                        .frame(height: 3)
                        .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 26)
                .padding(.bottom, 10)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.65), .black.opacity(0.94)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .overlay(alignment: .topTrailing) {
                if isBackedUp {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "2dd4bf"))
                        .padding(4)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(7)
                        .help("Đã lưu bản đọc ngoại tuyến")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isHovering ? Color(hex: "93c5fd").opacity(0.85) : Color.white.opacity(0.08),
                        lineWidth: isHovering ? 1.5 : 1
                    )
            )
            .shadow(
                color: isHovering ? Color(hex: "38bdf8").opacity(0.18) : Color.black.opacity(0.35),
                radius: isHovering ? 16 : 8,
                x: 0,
                y: isHovering ? 8 : 5
            )
            .scaleEffect(isHovering ? 1.02 : 1.0)
            .offset(y: isHovering ? -5 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isHovering)
            .onHover { hovering in isHovering = hovering }
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)

            // Title + Priority Star below cover
            HStack(alignment: .top, spacing: 6) {
                Text(book.title)
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Spacer(minLength: 0)

                Button(action: onTogglePriority) {
                    Image(systemName: book.isPriority == true ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(book.isPriority == true ? Color(hex: "fbbf24") : .white.opacity(0.5))
                        .scaleEffect(book.isPriority == true ? 1.12 : 1.0)
                        .animation(.spring(response: 0.26, dampingFraction: 0.6), value: book.isPriority == true)
                        .frame(width: 30, height: 30)
                        .background(Color.white.opacity(0.04), in: Circle())
                }
                .buttonStyle(.macCircle())
                .help(book.isPriority == true ? "Bỏ ưu tiên" : "Ưu tiên đọc")
            }
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
        }
        .opacity(isAppeared ? 1 : 0)
        .offset(y: isAppeared ? 0 : 12)
        .contextMenu {
            Button("Mở đọc sách", action: onOpen)
            Button(book.isPriority == true ? "Bỏ ưu tiên" : "Ưu tiên đọc", action: onTogglePriority)
            Button(book.isFinished == true ? "Đánh dấu chưa hoàn thành" : "Đánh dấu đã đọc xong", action: onToggleFinished)
        }
        .onAppear {
            loadLocalProgress()
            if !isAppeared {
                let delay = Double(min(entranceIndex, 10)) * 0.028
                withAnimation(.spring(response: 0.42, dampingFraction: 0.84).delay(delay)) {
                    isAppeared = true
                }
            }
        }
        .onChange(of: progressRevision) { _, _ in loadLocalProgress() }
    }

    private func loadLocalProgress() {
        if let data = UserDefaults.standard.data(forKey: "progress_\(book.slug)"),
           let decoded = try? JSONDecoder().decode(ReadingProgress.self, from: data) {
            progress = decoded
        } else {
            progress = nil
        }
    }

    private func formatTime(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let diff = max(0, Int(Date().timeIntervalSince(date)))
        if diff < 60 { return "Vừa xong" }
        if diff < 3600 { return "\(diff / 60) phút" }
        if diff < 86400 { return "\(diff / 3600) giờ" }
        if diff < 604800 { return "\(diff / 86400) ngày" }
        let df = DateFormatter()
        df.dateFormat = "dd/MM"
        return df.string(from: date)
    }
}
