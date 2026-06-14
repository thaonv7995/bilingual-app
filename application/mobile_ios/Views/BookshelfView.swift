import SwiftUI

struct BookshelfView: View {
    @StateObject private var api = APIService.shared
    @State private var books: [Book] = []
    @State private var isLoading = false
    @State private var selectedBook: Book?
    @State private var showAdminPortal = false
    
    // Adaptive grid columns for iPhone/iPad layouts
    let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 20)
    ]
    
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
                            ForEach(books) { book in
                                BookCard(book: book)
                                    .onTapGesture {
                                        selectedBook = book
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
            .navigationTitle("Tủ Sách Song Ngữ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        api.logout()
                    }) {
                        Text("Đăng xuất")
                            .foregroundColor(.red)
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        if api.isAdmin {
                            Button(action: {
                                showAdminPortal = true
                            }) {
                                Image(systemName: "slider.horizontal.3")
                                    .foregroundColor(.white)
                            }
                        }
                        
                        Button(action: {
                            Task { await loadBooks() }
                        }) {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.white)
                        }
                    }
                }
            }
            .fullScreenCover(item: $selectedBook) { book in
                ReaderView(book: book)
            }
            .sheet(isPresented: $showAdminPortal) {
                AdminPortalView()
            }
            .onAppear {
                Task { await loadBooks() }
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
        } catch {
            print("Failed to fetch books: \(error)")
            await MainActor.run { self.isLoading = false }
        }
    }
}

struct BookCard: View {
    let book: Book
    @StateObject private var api = APIService.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Book Cover Wrapper
            ZStack {
                Color(hex: "1e293b")
                    .aspectRatio(0.7, contentMode: .fit)
                    .cornerRadius(12)
                
                if let coverPath = book.cover, let coverUrl = URL(string: "\(api.serverUrl)/\(coverPath)") {
                    AsyncImage(url: coverUrl) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        ProgressView().tint(.white)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .cornerRadius(12)
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
                }
            }
            .frame(height: 220)
            .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
            
            // Book Titles
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                
                Text(book.author ?? "Unknown Author")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "94a3b8"))
                    .lineLimit(1)
                
                Text("\(book.pageCount) trang")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(hex: "6366f1"))
                    .padding(.top, 2)
            }
            .padding(.horizontal, 4)
        }
    }
}
