import SwiftUI

struct AISettingsView: View {
    @Environment(\.dismiss) var dismiss
    let books: [Book]

    @ObservedObject private var cacheManager = BookCacheManager.shared
    /// Voca is configured server-side now, so the section needs to know whether there is a
    /// session at all — without one there is nothing to read or write.
    @ObservedObject private var api = APIService.shared

    @State private var aiProvider: String = "openai"
    @State private var aiBaseURL: String = "https://api.openai.com/v1"
    @State private var aiApiKey: String = ""
    @State private var aiModel: String = "gpt-4o-mini"
    @State private var bilingualLayoutMode: String = "en-vi"
    /// Mirrors the server's `vocaOrigin`; `defaultOrigin` is only the value offered when the
    /// server has none. The key field stays EMPTY on purpose — the server never returns it.
    @State private var vocaApiOrigin: String = VocaService.defaultOrigin
    @State private var vocaApiKey: String = ""
    @State private var vocaConfiguredOnServer: Bool = false
    @State private var isLoadingVocaSettings: Bool = false
    @State private var vocaSectionNote: String? = nil
    @State private var vocaHealthStatus: String? = nil
    @State private var vocaHealthOK: Bool = false
    @State private var isCheckingVocaHealth: Bool = false
    @State private var isSavingSettings: Bool = false
    /// `auto | voca | device` — see `VocaAudioSource`. Kept as the raw string like every other
    /// preference in this view.
    @State private var audioSource: String = VocaAudioSource.auto.rawValue
    /// Read once in `loadSettings` — `AVSpeechSynthesisVoice.speechVoices()` is too heavy to
    /// call from `body`. Optimistic default so the hint never flickers.
    @State private var deviceVoiceReady: Bool = true

    // Companion Voice Settings
    @State private var realtimeApiKey: String = ""
    @State private var realtimeModel: String = "gpt-realtime-mini"
    @State private var realtimeVoice: String = "marin"
    @State private var companionAutoUpdateContext: Bool = true
    @State private var companionLanguage: String = "vi"
    @State private var companionAgentName: String = "Jarvis"
    
    private let voiceOptions = ["marin", "cedar", "alloy", "echo", "shimmer", "verse", "coral", "sage"]
    private let languageOptions: [(id: String, label: String, desc: String)] = [
        ("vi", "Tiếng Việt", "AI nói tiếng Việt"),
        ("en", "English", "AI speaks English"),
        ("bilingual", "Song ngữ", "AI tự chọn theo user"),
    ]
    /// Same three values, and the same wording, as the web app's "Nguồn phát âm".
    private let audioSourceOptions: [(id: String, label: String, desc: String)] = [
        (VocaAudioSource.auto.rawValue, "Tự động", "Voca trước, lỗi thì giọng máy"),
        (VocaAudioSource.voca.rawValue, "Chỉ Voca", "Báo lỗi nếu không có audio"),
        (VocaAudioSource.device.rawValue, "Giọng máy", "Nhanh, chạy ngoại tuyến"),
    ]
    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "0f172a").ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Header note
                        Text("Cấu hình API Key và nhà cung cấp dịch vụ AI để sử dụng Companion Agent — phân tích, thảo luận và khám phá nội dung sách.")
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
                        
                        // Section: Voca Dictionary API — configured on the SERVER, per user.
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Voca Dictionary API")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white.opacity(0.9))

                            Text("Ứng dụng gọi Voca qua server sách; URL và API key được lưu trên server, không lưu trên máy. Dùng chung với bản web — cấu hình một lần là cả hai nơi cùng dùng.")
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "94a3b8"))
                                .lineSpacing(3)

                            if !api.isAuthenticated {
                                // No session, no proxy — and therefore no dictionary at all.
                                Label("Đăng nhập vào server sách trước, rồi mới cấu hình Voca.", systemImage: "lock.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "fbbf24"))
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if isLoadingVocaSettings {
                                HStack(spacing: 6) {
                                    ProgressView().scaleEffect(0.6).tint(.white)
                                    Text("Đang tải cấu hình từ server...")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "94a3b8"))
                                }
                            } else {
                                Label(
                                    vocaConfiguredOnServer ? "Đã cấu hình trên server" : "Chưa cấu hình trên server",
                                    systemImage: vocaConfiguredOnServer ? "checkmark.seal.fill" : "exclamationmark.circle"
                                )
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(vocaConfiguredOnServer ? Color(hex: "34d399") : Color(hex: "fbbf24"))
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Voca API URL")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                                TextField("https://voca.thaonv.online", text: $vocaApiOrigin)
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
                                Text("Voca API Key")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                                HStack {
                                    // Left blank on purpose: the server never returns the key.
                                    // Typing replaces it, leaving it empty keeps what is stored.
                                    SecureField(
                                        "voca_...",
                                        text: $vocaApiKey,
                                        prompt: Text(
                                            vocaConfiguredOnServer
                                                ? "Đã lưu trên server — nhập key mới để thay"
                                                : "voca_..."
                                        ).foregroundColor(.gray.opacity(0.5))
                                    )
                                        .font(.system(size: 14))
                                        .foregroundColor(.white)
                                        .autocorrectionDisabled()
                                        .textInputAutocapitalization(.never)

                                    Button(action: {
                                        if let s = UIPasteboard.general.string {
                                            vocaApiKey = s.trimmingCharacters(in: .whitespacesAndNewlines)
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

                                // Voca — and our own PUT /api/user/settings — reject a key
                                // pasted without its prefix.
                                if !vocaApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    && !VocaService.isValidAPIKeyFormat(vocaApiKey) {
                                    Text("API key phải bắt đầu bằng voca_")
                                        .font(.system(size: 10))
                                        .foregroundColor(Color(hex: "f87171"))
                                } else {
                                    Text("Key được lưu trên server và không bao giờ gửi lại về máy.")
                                        .font(.system(size: 10))
                                        .foregroundColor(Color(hex: "94a3b8"))
                                }
                            }

                            // GET /api/voca/health goes app -> server -> Voca, so it tests the
                            // whole real path with the config the SERVER is holding right now
                            // (it does not need a key, so it still isolates "URL sai").
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 10) {
                                    Button(action: { Task { await checkVocaHealth() } }) {
                                        HStack(spacing: 6) {
                                            if isCheckingVocaHealth {
                                                ProgressView().scaleEffect(0.7).tint(.white)
                                            } else {
                                                Image(systemName: "bolt.horizontal.circle")
                                                    .font(.system(size: 13))
                                            }
                                            Text("Kiểm tra kết nối")
                                                .font(.system(size: 12, weight: .bold))
                                        }
                                        .foregroundColor(.white)
                                        .padding(.vertical, 9)
                                        .padding(.horizontal, 14)
                                        .background(Color(hex: "14b8a6").opacity(0.25))
                                        .cornerRadius(10)
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "14b8a6").opacity(0.5), lineWidth: 1))
                                    }
                                    .disabled(isCheckingVocaHealth)

                                    if let status = vocaHealthStatus {
                                        Text(status)
                                            .font(.system(size: 11))
                                            .foregroundColor(vocaHealthOK ? Color(hex: "34d399") : Color(hex: "f87171"))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }

                                Text("Kiểm tra cấu hình đang lưu trên server (máy → server → Voca). Lưu trước rồi hãy kiểm tra.")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(hex: "94a3b8"))
                            }

                            if let note = vocaSectionNote {
                                Text(note)
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "f87171"))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .disabled(!api.isAuthenticated)
                        .opacity(api.isAuthenticated ? 1 : 0.55)
                        .padding()
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        
                        // Section: Nguồn phát âm — Voca's audio vs the device's own voice.
                        // Deliberately its OWN card rather than a row inside the Voca section
                        // above: that one is disabled without a session, and device speech is
                        // exactly what still works when there is no session and no network.
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(Color(hex: "14b8a6"))
                                Text("Nguồn phát âm")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white.opacity(0.9))
                            }

                            Text(
                                deviceVoiceReady
                                    ? "Giọng thiết bị chất lượng thấp hơn Voca nhưng miễn phí, chạy ngoại tuyến và luôn dùng được."
                                    : "Thiết bị này chưa có giọng đọc nào — chỉ dùng được nguồn Voca."
                            )
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "94a3b8"))
                            .lineSpacing(3)

                            HStack(spacing: 4) {
                                ForEach(audioSourceOptions, id: \.id) { option in
                                    let isSelected = audioSource == option.id
                                    Button(action: { audioSource = option.id }) {
                                        VStack(spacing: 2) {
                                            Text(option.label)
                                                .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                                                .foregroundColor(isSelected ? .white : .gray.opacity(0.8))
                                            Text(option.desc)
                                                .font(.system(size: 8))
                                                .foregroundColor(isSelected ? .white.opacity(0.7) : .gray.opacity(0.5))
                                                .multilineTextAlignment(.center)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(isSelected ? Color(hex: "14b8a6").opacity(0.25) : Color.clear)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(isSelected ? Color(hex: "14b8a6").opacity(0.6) : Color.white.opacity(0.06), lineWidth: 1)
                                        )
                                    }
                                }
                            }
                            .padding(4)
                            .background(Color.white.opacity(0.03))
                            .cornerRadius(12)
                        }
                        .padding()
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )

                        // Section: Companion Voice
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(spacing: 8) {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 13))
                                    .foregroundColor(Color(hex: "14b8a6"))
                                Text("AI Companion Voice")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white.opacity(0.9))
                            }
                            
                            Text("Cấu hình cho chế độ hội thoại giọng nói với AI Companion khi đọc sách.")
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "94a3b8"))
                                .lineSpacing(3)
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Realtime API Key")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                                HStack {
                                    SecureField("API Key", text: $realtimeApiKey, prompt: Text("Nhập Realtime API Key...").foregroundColor(.gray.opacity(0.5)))
                                        .font(.system(size: 14))
                                        .foregroundColor(.white)
                                        .autocorrectionDisabled()
                                        .textInputAutocapitalization(.none)
                                    Button(action: {
                                        if let s = UIPasteboard.general.string {
                                            realtimeApiKey = s.trimmingCharacters(in: .whitespacesAndNewlines)
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
                                Text("Realtime Model")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                                HStack {
                                    TextField("Model Name", text: $realtimeModel, prompt: Text("gpt-4o-mini-realtime-preview").foregroundColor(.gray.opacity(0.5)))
                                        .font(.system(size: 14))
                                        .foregroundColor(.white)
                                        .autocorrectionDisabled()
                                        .textInputAutocapitalization(.none)
                                    Button(action: {
                                        if let s = UIPasteboard.general.string {
                                            realtimeModel = s.trimmingCharacters(in: .whitespacesAndNewlines)
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
                                Text("Giọng AI")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                                
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6)], spacing: 6) {
                                    ForEach(voiceOptions, id: \.self) { voice in
                                        let isSelected = realtimeVoice == voice
                                        Button(action: { realtimeVoice = voice }) {
                                            Text(voice.capitalized)
                                                .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                                                .foregroundColor(isSelected ? .white : .gray.opacity(0.8))
                                                .frame(maxWidth: .infinity)
                                                .padding(.vertical, 8)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .fill(isSelected ? Color(hex: "14b8a6").opacity(0.25) : Color.white.opacity(0.04))
                                                )
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(isSelected ? Color(hex: "14b8a6").opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1)
                                                )
                                        }
                                    }
                                }
                            }
                            
                            // Agent Name
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Tên Agent")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                                Text("User có thể gọi tên này để ra lệnh cho AI")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(hex: "94a3b8"))
                                TextField("Jarvis", text: $companionAgentName, prompt: Text("Ví dụ: Jarvis, Luna, Sage...").foregroundColor(.gray.opacity(0.5)))
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.words)
                                    .padding(12)
                                    .background(Color.white.opacity(0.05))
                                    .cornerRadius(10)
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
                            }
                            
                            // Language
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Ngôn ngữ hội thoại")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.gray)
                                
                                HStack(spacing: 4) {
                                    ForEach(languageOptions, id: \.id) { lang in
                                        let isSelected = companionLanguage == lang.id
                                        Button(action: { companionLanguage = lang.id }) {
                                            VStack(spacing: 2) {
                                                Text(lang.label)
                                                    .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                                                    .foregroundColor(isSelected ? .white : .gray.opacity(0.8))
                                                Text(lang.desc)
                                                    .font(.system(size: 8))
                                                    .foregroundColor(isSelected ? .white.opacity(0.7) : .gray.opacity(0.5))
                                            }
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(isSelected ? Color(hex: "14b8a6").opacity(0.25) : Color.clear)
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .stroke(isSelected ? Color(hex: "14b8a6").opacity(0.6) : Color.white.opacity(0.06), lineWidth: 1)
                                            )
                                        }
                                    }
                                }
                                .padding(4)
                                .background(Color.white.opacity(0.03))
                                .cornerRadius(12)
                            }
                            
                            Toggle(isOn: $companionAutoUpdateContext) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Tự động cập nhật context")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.white.opacity(0.9))
                                    Text("Gửi nội dung trang mới cho AI khi lật trang")
                                        .font(.system(size: 10))
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(Color(hex: "14b8a6"))
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
                        
                        // Save Button. The secrets go to the server, so this can fail — the
                        // sheet only closes once the write actually landed.
                        Button(action: { save() }) {
                            HStack(spacing: 8) {
                                if isSavingSettings {
                                    ProgressView().scaleEffect(0.8).tint(.white)
                                }
                                Text(isSavingSettings ? "Đang lưu..." : "Lưu cấu hình")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white)
                            }
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
                        .disabled(isSavingSettings)
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
                Task { await loadVocaFromServer() }
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
        // Unknown/absent value falls back to `auto` through the enum, never to a raw string.
        self.audioSource = VocaAudioSource.current.rawValue
        self.deviceVoiceReady = DeviceSpeech.shared.isAvailable
        // Voca is NOT read from the device any more — see `loadVocaFromServer`.
        self.realtimeApiKey = UserDefaults.standard.string(forKey: "realtimeApiKey") ?? ""
        self.realtimeModel = UserDefaults.standard.string(forKey: "realtimeModel") ?? "gpt-realtime-mini"
        self.realtimeVoice = UserDefaults.standard.string(forKey: "realtimeVoice") ?? "marin"
        self.companionAutoUpdateContext = UserDefaults.standard.object(forKey: "companionAutoUpdateContext") as? Bool ?? true
        self.companionLanguage = UserDefaults.standard.string(forKey: "companionLanguage") ?? "vi"
        self.companionAgentName = UserDefaults.standard.string(forKey: "companionAgentName") ?? "Jarvis"
    }
    
    /// Reads the real Voca state from `GET /api/user/settings`: the origin comes back as
    /// stored, the key only as a boolean (`hasVocaToken`) — which is why the key field is
    /// never populated.
    @MainActor
    private func loadVocaFromServer() async {
        guard api.isAuthenticated else {
            vocaConfiguredOnServer = false
            return
        }
        isLoadingVocaSettings = true
        defer { isLoadingVocaSettings = false }
        do {
            let secrets = try await api.fetchServerSecrets()
            vocaConfiguredOnServer = secrets.hasVocaToken
            vocaApiOrigin = secrets.vocaOrigin.isEmpty ? VocaService.defaultOrigin : secrets.vocaOrigin
            vocaApiKey = ""
            vocaSectionNote = nil
            // The lookup path caches this answer for the session; keep the two in step.
            VocaService.noteConfiguration(hasVocaToken: secrets.hasVocaToken)
        } catch {
            vocaSectionNote = "Không tải được cấu hình Voca từ server. Kiểm tra kết nối rồi mở lại."
        }
    }

    private func save() {
        let typedVocaKey = vocaApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Both Voca and our own PUT reject a key without the prefix, so stop here rather than
        // send it and close the sheet on a 400.
        if !typedVocaKey.isEmpty && !VocaService.isValidAPIKeyFormat(typedVocaKey) {
            vocaSectionNote = "API key Voca phải bắt đầu bằng voca_. Sửa lại, hoặc để trống để giữ key đang lưu trên server."
            return
        }
        isSavingSettings = true
        Task {
            let failure = await saveSettings()
            isSavingSettings = false
            if let failure {
                vocaSectionNote = failure
            } else {
                dismiss()
            }
        }
    }

    /// Writes the device-local preferences, then pushes the secrets to the server.
    /// Returns a message when the server write failed (so the sheet stays open), `nil` on success.
    @MainActor
    private func saveSettings() async -> String? {
        UserDefaults.standard.set(aiProvider, forKey: "aiProvider")
        UserDefaults.standard.set(aiBaseURL, forKey: "aiBaseURL")
        UserDefaults.standard.set(aiApiKey, forKey: "aiApiKey")
        UserDefaults.standard.set(aiModel, forKey: "aiModel")
        UserDefaults.standard.set(bilingualLayoutMode, forKey: "bilingualLayoutMode")
        UserDefaults.standard.set(
            (VocaAudioSource(rawValue: audioSource) ?? .auto).rawValue,
            forKey: VocaAudioSource.defaultsKey
        )
        UserDefaults.standard.set(realtimeApiKey.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "realtimeApiKey")
        UserDefaults.standard.set(realtimeModel.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "realtimeModel")
        UserDefaults.standard.set(realtimeVoice, forKey: "realtimeVoice")
        UserDefaults.standard.set(companionAutoUpdateContext, forKey: "companionAutoUpdateContext")
        UserDefaults.standard.set(companionLanguage, forKey: "companionLanguage")
        UserDefaults.standard.set(companionAgentName.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "companionAgentName")

        // The secrets live in `user_settings` on the backend (see /api/user/settings) and are
        // attached by the /api/chat and /api/voca proxies. Nothing about the Voca key is
        // written to the device: it is not in UserDefaults and no longer in the Keychain.
        let llm = aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let rt = realtimeApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = VocaService.normalizedOrigin(vocaApiOrigin)
        let originToSend = origin.isEmpty ? VocaService.defaultOrigin : origin
        let typedVocaKey = vocaApiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard api.isAuthenticated else {
            // Local preferences are saved; the secrets have nowhere to go.
            return "Chưa đăng nhập nên chưa lưu được key lên server. Đăng nhập rồi lưu lại."
        }

        do {
            try await api.saveServerSecrets(
                llmApiKey: llm.isEmpty ? nil : llm,
                realtimeApiKey: rt.isEmpty ? nil : rt,
                vocaOrigin: originToSend,
                // Empty means "keep what is stored" — the field is blank whenever the user
                // has not typed a replacement.
                vocaToken: typedVocaKey.isEmpty ? nil : typedVocaKey
            )
        } catch {
            return "Không lưu được cấu hình lên server. Kiểm tra kết nối rồi thử lại."
        }

        // Reflect what was actually sent, and drop anything cached from the old config: a new
        // key/origin can mean a different Voca account entirely.
        vocaApiOrigin = originToSend
        vocaApiKey = ""
        if !typedVocaKey.isEmpty {
            vocaConfiguredOnServer = true
            VocaService.noteConfiguration(hasVocaToken: true)
        }
        VocaService.clearCardsCache()
        return nil
    }

    /// End-to-end probe (máy → server → Voca) of the configuration the SERVER holds.
    /// `/api/voca/health` needs no Voca key, so it still separates "URL sai" from "key sai".
    @MainActor
    private func checkVocaHealth() async {
        isCheckingVocaHealth = true
        vocaHealthStatus = nil
        defer { isCheckingVocaHealth = false }
        do {
            let health = try await VocaService.health()
            vocaHealthOK = true
            let version = health.version.map { " v\($0)" } ?? ""
            vocaHealthStatus = "Kết nối OK\(version)"
        } catch {
            vocaHealthOK = false
            vocaHealthStatus = error.localizedDescription
        }
    }
}
