import SwiftUI

struct AISettingsView: View {
    @Environment(\.dismiss) var dismiss
    let books: [Book]
    
    @ObservedObject private var cacheManager = BookCacheManager.shared
    
    @State private var aiProvider: String = "openai"
    @State private var aiBaseURL: String = "https://api.openai.com/v1"
    @State private var aiApiKey: String = ""
    @State private var aiModel: String = "gpt-4o-mini"
    @State private var bilingualLayoutMode: String = "en-vi"
    @State private var vocaBridgeOrigin: String = VocaService.defaultBridgeOrigin
    @State private var vocaBridgeToken: String = VocaService.defaultBridgeToken
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "0f172a").ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Header note
                        Text("Cấu hình API Key và nhà cung cấp dịch vụ AI để sử dụng tính năng Trợ lý AI (AI Agent) dịch thuật, giải thích và tóm tắt sách.")
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "94a3b8"))
                            .lineSpacing(4)
                            .padding(.bottom, 5)
                        
                        // Section 1: Provider Picker
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Nhà cung cấp")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white.opacity(0.9))
                            
                            HStack(spacing: 4) {
                                ForEach(["openai", "gemini", "custom"], id: \.self) { provider in
                                    let isSelected = aiProvider == provider
                                    let displayName = provider == "openai" ? "OpenAI" : (provider == "gemini" ? "Gemini" : "Custom")
                                    
                                    Button(action: {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                            aiProvider = provider
                                            if provider == "openai" {
                                                aiBaseURL = "https://api.openai.com/v1"
                                                aiModel = "gpt-4o-mini"
                                            } else if provider == "gemini" {
                                                aiBaseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
                                                aiModel = "gemini-1.5-flash"
                                            }
                                        }
                                    }) {
                                        Text(displayName)
                                            .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                            .foregroundColor(isSelected ? .white : .gray.opacity(0.8))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(isSelected ? Color.white.opacity(0.08) : Color.clear)
                                            )
                                    }
                                }
                            }
                            .padding(4)
                            .background(Color.white.opacity(0.03))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .padding()
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        
                        // Section 2: Input fields
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Base URL")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                                
                                HStack {
                                    TextField("Base URL", text: $aiBaseURL, prompt: Text("Nhập URL cơ sở...").foregroundColor(.gray.opacity(0.5)))
                                        .font(.system(size: 14))
                                        .foregroundColor(.white)
                                        .autocorrectionDisabled()
                                        .textInputAutocapitalization(.none)
                                    
                                    Button(action: {
                                        print("[Debug] Base URL paste button tapped")
                                        if let pasteboardString = UIPasteboard.general.string {
                                            print("[Debug] Pasteboard content: \(pasteboardString)")
                                            aiBaseURL = pasteboardString.trimmingCharacters(in: .whitespacesAndNewlines)
                                        } else {
                                            print("[Debug] Pasteboard is nil or empty")
                                        }
                                    }) {
                                        Image(systemName: "doc.on.clipboard")
                                            .font(.system(size: 14))
                                            .foregroundColor(Color(hex: "14b8a6"))
                                            .frame(width: 32, height: 32)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                                .padding(12)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("API Key")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                                
                                HStack {
                                    SecureField("API Key", text: $aiApiKey, prompt: Text("Nhập API Key của bạn...").foregroundColor(.gray.opacity(0.5)))
                                        .font(.system(size: 14))
                                        .foregroundColor(.white)
                                        .autocorrectionDisabled()
                                        .textInputAutocapitalization(.none)
                                    
                                    Button(action: {
                                        print("[Debug] API Key paste button tapped")
                                        if let pasteboardString = UIPasteboard.general.string {
                                            print("[Debug] Pasteboard content: \(pasteboardString)")
                                            aiApiKey = pasteboardString.trimmingCharacters(in: .whitespacesAndNewlines)
                                        } else {
                                            print("[Debug] Pasteboard is nil or empty")
                                        }
                                    }) {
                                        Image(systemName: "doc.on.clipboard")
                                            .font(.system(size: 14))
                                            .foregroundColor(Color(hex: "14b8a6"))
                                            .frame(width: 32, height: 32)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                                .padding(12)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Tên Model")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                                
                                HStack {
                                    TextField("Model Name", text: $aiModel, prompt: Text("Ví dụ: gpt-4o-mini").foregroundColor(.gray.opacity(0.5)))
                                        .font(.system(size: 14))
                                        .foregroundColor(.white)
                                        .autocorrectionDisabled()
                                        .textInputAutocapitalization(.none)
                                    
                                    Button(action: {
                                        print("[Debug] Model Name paste button tapped")
                                        if let pasteboardString = UIPasteboard.general.string {
                                            print("[Debug] Pasteboard content: \(pasteboardString)")
                                            aiModel = pasteboardString.trimmingCharacters(in: .whitespacesAndNewlines)
                                        } else {
                                            print("[Debug] Pasteboard is nil or empty")
                                        }
                                    }) {
                                        Image(systemName: "doc.on.clipboard")
                                            .font(.system(size: 14))
                                            .foregroundColor(Color(hex: "14b8a6"))
                                            .frame(width: 32, height: 32)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                                .padding(12)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
                            }
                        }
                        .padding()
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        
                        // Section: Voca Dictionary Bridge
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Voca Dictionary Bridge")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white.opacity(0.9))
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Voca Bridge URL")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                                TextField("https://voca-bridge.thaonv.online", text: $vocaBridgeOrigin)
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .padding(12)
                                    .background(Color.white.opacity(0.05))
                                    .cornerRadius(10)
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Voca API Token")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                                SecureField("Bearer token", text: $vocaBridgeToken)
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .padding(12)
                                    .background(Color.white.opacity(0.05))
                                    .cornerRadius(10)
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
                            }
                        }
                        .padding()
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        
                        // Section 3: Bilingual Layout Mode
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Bố cục song ngữ")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white.opacity(0.9))
                            
                            HStack(spacing: 8) {
                                LayoutOptionButton(mode: "en-vi", badge1: "EN", badge2: "VI", isVertical: false, selectedMode: $bilingualLayoutMode)
                                LayoutOptionButton(mode: "vi-en", badge1: "VI", badge2: "EN", isVertical: false, selectedMode: $bilingualLayoutMode)
                                LayoutOptionButton(mode: "en-over-vi", badge1: "EN", badge2: "VI", isVertical: true, selectedMode: $bilingualLayoutMode)
                                LayoutOptionButton(mode: "vi-over-en", badge1: "VI", badge2: "EN", isVertical: true, selectedMode: $bilingualLayoutMode)
                            }
                        }
                        .padding()
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        
                        // Section 4: Cache Management
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Quản lý bộ nhớ đệm")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white.opacity(0.9))
                            
                            let downloadedBooks = books.filter { cacheManager.isDownloaded(slug: $0.slug) }
                            
                            if downloadedBooks.isEmpty {
                                Text("Chưa có sách nào được tải về thiết bị.")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(hex: "94a3b8"))
                                    .padding(.vertical, 8)
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(downloadedBooks) { book in
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(book.title)
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundColor(.white)
                                                    .lineLimit(1)
                                                Text(book.author ?? "Unknown Author")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(Color(hex: "94a3b8"))
                                            }
                                            
                                            Spacer()
                                            
                                            Button(action: {
                                                withAnimation {
                                                    cacheManager.deleteCache(slug: book.slug)
                                                }
                                            }) {
                                                Image(systemName: "trash")
                                                    .font(.system(size: 13))
                                                    .foregroundColor(.red)
                                                    .frame(width: 28, height: 28)
                                                    .background(Color.red.opacity(0.1))
                                                    .clipShape(Circle())
                                            }
                                        }
                                        .padding(.vertical, 6)
                                        
                                        if book.id != downloadedBooks.last?.id {
                                            Divider().background(Color.white.opacity(0.06))
                                        }
                                    }
                                    
                                    Button(action: {
                                        withAnimation {
                                            for b in downloadedBooks {
                                                cacheManager.deleteCache(slug: b.slug)
                                            }
                                        }
                                    }) {
                                        Text("Xóa toàn bộ bộ nhớ đệm")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(.red)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(Color.red.opacity(0.08))
                                            .cornerRadius(10)
                                    }
                                    .padding(.top, 8)
                                }
                            }
                        }
                        .padding()
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        
                        // Save Button
                        Button(action: {
                            saveSettings()
                            dismiss()
                        }) {
                            Text("Lưu cấu hình")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    LinearGradient(
                                        colors: [Color(hex: "0d9488"), Color(hex: "14b8a6")],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .cornerRadius(14)
                                .shadow(color: Color(hex: "14b8a6").opacity(0.25), radius: 8, x: 0, y: 4)
                        }
                        .padding(.top, 10)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Cấu hình AI & Voca")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Hủy") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
            .toolbarBackground(Color(hex: "0f172a"), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .onAppear {
                loadSettings()
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private func loadSettings() {
        self.aiProvider = UserDefaults.standard.string(forKey: "aiProvider") ?? "openai"
        self.aiBaseURL = UserDefaults.standard.string(forKey: "aiBaseURL") ?? "https://api.openai.com/v1"
        self.aiApiKey = UserDefaults.standard.string(forKey: "aiApiKey") ?? ""
        self.aiModel = UserDefaults.standard.string(forKey: "aiModel") ?? "gpt-4o-mini"
        self.bilingualLayoutMode = UserDefaults.standard.string(forKey: "bilingualLayoutMode") ?? "en-vi"
        self.vocaBridgeOrigin = UserDefaults.standard.string(forKey: "vocaBridgeOrigin") ?? VocaService.defaultBridgeOrigin
        self.vocaBridgeToken = UserDefaults.standard.string(forKey: "vocaBridgeToken") ?? VocaService.defaultBridgeToken
    }
    
    private func saveSettings() {
        UserDefaults.standard.set(aiProvider, forKey: "aiProvider")
        UserDefaults.standard.set(aiBaseURL, forKey: "aiBaseURL")
        UserDefaults.standard.set(aiApiKey, forKey: "aiApiKey")
        UserDefaults.standard.set(aiModel, forKey: "aiModel")
        UserDefaults.standard.set(bilingualLayoutMode, forKey: "bilingualLayoutMode")
        UserDefaults.standard.set(vocaBridgeOrigin.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "vocaBridgeOrigin")
        UserDefaults.standard.set(vocaBridgeToken.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "vocaBridgeToken")
    }
}
