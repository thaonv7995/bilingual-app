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
    @State private var hideFinishedBooks: Bool = true
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
    @State private var visibleCachedBookCount: Int = 3
    /// `auto | voca | device` — see `VocaAudioSource`. Kept as the raw string like every other
    /// preference in this view.
    @State private var audioSource: String = VocaAudioSource.auto.rawValue

    // Audio Provider Settings (server-side)
    @State private var audioProvider: String = "device"
    @State private var audioVoice: String = ""
    @State private var audioVoiceEn: String = ""
    @State private var audioVoiceVi: String = ""
    @State private var speechSpeed: String = "1.0"
    @State private var azureApiKey: String = ""
    @State private var elevenLabsApiKey: String = ""

    @State private var hasAzureKey: Bool = false
    @State private var hasElevenLabsKey: Bool = false
    @State private var isTestingVoiceEn: Bool = false
    @State private var isTestingVoiceVi: Bool = false
    @State private var testVoiceError: String? = nil
    /// Read once in `loadSettings` — `AVSpeechSynthesisVoice.speechVoices()` is too heavy to
    /// call from `body`. Optimistic default so the hint never flickers.
    @State private var deviceVoiceReady: Bool = true

    /// Same three values, and the same wording, as the web app's "Nguồn phát âm".
    private let audioSourceOptions: [(id: String, label: String, desc: String)] = [
        (VocaAudioSource.auto.rawValue, "Tự động", "Voca trước, lỗi thì giọng máy"),
        (VocaAudioSource.voca.rawValue, "Chỉ Voca", "Báo lỗi nếu không có audio"),
        (VocaAudioSource.device.rawValue, "Giọng máy", "Nhanh, chạy ngoại tuyến"),
    ]

    /// New Audiobook/TTS providers (stored server-side and shared by Web + iOS)
    private let audioProviderOptions: [(id: String, label: String)] = [
        ("device", "iOS Offline"),
        ("azure", "Azure Speech"),
        ("openai", "OpenAI TTS"),
        ("elevenlabs", "ElevenLabs")
    ]

    private var audioProviderSummary: String {
        switch audioProvider {
        case "azure":
            return hasAzureKey ? "Azure key đã cấu hình" : "Chưa cấu hình Azure key"
        case "elevenlabs":
            return hasElevenLabsKey ? "ElevenLabs key đã cấu hình" : "Chưa cấu hình ElevenLabs key"
        case "openai":
            return "Sử dụng OpenAI TTS"
        default:
            return "Sử dụng AVSpeechSynthesizer trên thiết bị"
        }
    }

    private var audioProviderDisplayName: String {
        audioProviderOptions.first(where: { $0.id == audioProvider })?.label ?? "Unknown"
    }

    private var audioSettingsDescription: String {
        """
        Audio Provider: \(audioProviderDisplayName)

        \(audioProviderSummary)
        """
    }

    private var shouldShowAzureFields: Bool {
        audioProvider == "azure"
    }

    private var shouldShowElevenLabsFields: Bool {
        audioProvider == "elevenlabs"
    }

    private var shouldShowCloudVoiceFields: Bool {
        audioProvider != "device"
    }

    private var providerStatusText: String {
        switch audioProvider {
        case "azure":
            return hasAzureKey ? "✅ Azure Speech đã sẵn sàng" : "⚠️ Chưa cấu hình Azure Speech Key"
        case "elevenlabs":
            return hasElevenLabsKey ? "✅ ElevenLabs đã sẵn sàng" : "⚠️ Chưa cấu hình ElevenLabs Key"
        case "openai":
            return "✅ Sử dụng OpenAI TTS thông qua AI provider hiện tại"
        default:
            return deviceVoiceReady ? "✅ Voice thiết bị khả dụng" : "⚠️ Không tìm thấy voice phù hợp trên thiết bị"
        }
    }

    private var audiobookSectionTitle: String {
        "Audiobook & Voice"
    }

    private var audiobookSectionSubtitle: String {
        providerStatusText
    }

    private var voicePlaceholderText: String {
        switch audioProvider {
        case "azure":
            return "en-US-JennyNeural"
        case "elevenlabs":
            return "Rachel"
        case "openai":
            return "alloy"
        default:
            return "Default Device Voice"
        }
    }

    private var voiceEnPlaceholderText: String {
        switch audioProvider {
        case "azure":
            return "en-US-JennyNeural"
        case "elevenlabs":
            return "21m00Tcm4TlvDq8ikWAM (Rachel)"
        case "openai":
            return "alloy, echo, nova..."
        default:
            return "Default Device Voice"
        }
    }

    private var voiceViPlaceholderText: String {
        switch audioProvider {
        case "azure":
            return "vi-VN-HoaiMyNeural hoặc vi-VN-NamMinhNeural"
        case "elevenlabs":
            return "Voice ID tiếng Việt"
        case "openai":
            return "alloy, shimmer..."
        default:
            return "Default Device Voice"
        }
    }

    private var audioProviderHelpText: String {
        switch audioProvider {
        case "azure":
            return "Sử dụng Azure Speech cho audiobook chất lượng cao."
        case "elevenlabs":
            return "Sử dụng ElevenLabs với voice cloning và expressive speech."
        case "openai":
            return "Sử dụng OpenAI Text-To-Speech."
        default:
            return "Đọc bằng giọng hệ thống của iPhone, hoạt động offline."
        }
    }

    private var audioProviderConfigured: Bool {
        switch audioProvider {
        case "azure":
            return hasAzureKey
        case "elevenlabs":
            return hasElevenLabsKey
        default:
            return true
        }
    }

    private var audioProviderBadgeText: String {
        audioProviderConfigured ? "READY" : "SETUP REQUIRED"
    }

    private var audioProviderBadgeColor: Color {
        audioProviderConfigured ? .green : .orange
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "0f172a").ignoresSafeArea()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Header note
                        Text("Cấu hình AI, giọng đọc và hiển thị.")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "94a3b8"))
                            .lineSpacing(2)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Thư viện")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white.opacity(0.9))
                            Toggle(isOn: $hideFinishedBooks) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Ẩn sách đã đọc")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.white.opacity(0.9))
                                    Text("Sách đã hoàn thành chỉ hiện trong bộ lọc Đã đọc")
                                        .font(.system(size: 10))
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(Color(hex: "14b8a6"))
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        
                        // Section 1: Provider Picker
                        VStack(alignment: .leading, spacing: 8) {
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
                        .padding(12)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
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
                        VStack(alignment: .leading, spacing: 8) {
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
                        .padding(12)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )

                        // Section: Audiobook & Voice Provider
                        if api.isAudiobookEnabled {
                            VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 13))
                                    .foregroundColor(Color(hex: "14b8a6"))
                                Text("Audiobook & Voice")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white.opacity(0.9))

                                Spacer()

                                Text(audioProviderBadgeText)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(audioProviderBadgeColor)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(audioProviderBadgeColor.opacity(0.12))
                                    .clipShape(Capsule())
                            }

                            Text(providerStatusText)
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "94a3b8"))

                            Text(audioProviderHelpText)
                                .font(.system(size: 10))
                                .foregroundColor(.gray)

                            HStack(spacing: 6) {
                                Circle()
                                    .fill(audioProviderConfigured ? Color.green : Color.orange)
                                    .frame(width: 8, height: 8)

                                Text(audioProviderConfigured ? "Provider đã được cấu hình" : "Provider chưa được cấu hình hoàn chỉnh")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(audioProviderConfigured ? .green : .orange)

                                Spacer()

                                Text(audioProviderBadgeText)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(audioProviderBadgeColor)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(audioProviderBadgeColor.opacity(0.12))
                                    .clipShape(Capsule())
                            }

                            Menu {
                                ForEach(audioProviderOptions, id: \.id) { option in
                                    Button {
                                        audioProvider = option.id
                                    } label: {
                                        if audioProvider == option.id {
                                            Label(option.label, systemImage: "checkmark")
                                        } else {
                                            Text(option.label)
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(
                                        audioProviderOptions.first(where: { $0.id == audioProvider })?.label
                                            ?? "Chọn provider"
                                    )
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.9))
                                    .lineLimit(1)

                                    Spacer(minLength: 8)

                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(Color(hex: "94a3b8"))
                                        .padding(.trailing, 2)
                                }
                                .padding(.leading, 11)
                                .padding(.trailing, 8)
                                .frame(height: 36)
                                .background(Color.white.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9)
                                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                )
                                .cornerRadius(9)
                            }
                            .buttonStyle(.plain)

                            Text(audioSettingsDescription)
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "94a3b8"))
                                .padding(.top, 2)

                            if shouldShowCloudVoiceFields {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Voice Tiếng Anh (English Voice ID)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.gray)

                                    TextField(voiceEnPlaceholderText, text: $audioVoiceEn)
                                        .padding(12)
                                        .background(Color.white.opacity(0.05))
                                        .cornerRadius(10)
                                        .foregroundColor(.white)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Voice Tiếng Việt (Vietnamese Voice ID)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.gray)

                                    TextField(voiceViPlaceholderText, text: $audioVoiceVi)
                                        .padding(12)
                                        .background(Color.white.opacity(0.05))
                                        .cornerRadius(10)
                                        .foregroundColor(.white)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Speed")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.gray)

                                    TextField("1.0", text: $speechSpeed)
                                        .padding(12)
                                        .background(Color.white.opacity(0.05))
                                        .cornerRadius(10)
                                        .foregroundColor(.white)
                                }
                            }

                            if shouldShowAzureFields {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Azure Speech Key")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.gray)

                                    SecureField("Azure Key", text: $azureApiKey)
                                        .padding(12)
                                        .background(Color.white.opacity(0.05))
                                        .cornerRadius(10)
                                        .foregroundColor(.white)
                                }
                            }

                            if shouldShowElevenLabsFields {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("ElevenLabs Key")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.gray)

                                    SecureField("ElevenLabs Key", text: $elevenLabsApiKey)
                                        .padding(12)
                                        .background(Color.white.opacity(0.05))
                                        .cornerRadius(10)
                                        .foregroundColor(.white)
                                }
                            }

                            if audioProvider != "device" {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Preview Cấu hình")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.gray)

                                    Text("Provider: \(audioProviderDisplayName)\nVoice EN: \(audioVoiceEn.isEmpty ? voiceEnPlaceholderText : audioVoiceEn)\nVoice VI: \(audioVoiceVi.isEmpty ? voiceViPlaceholderText : audioVoiceVi)\nSpeed: \(speechSpeed)")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "94a3b8"))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(10)
                                        .background(Color.white.opacity(0.03))
                                        .cornerRadius(10)
                                }
                            }

                            HStack(spacing: 8) {
                                Button(action: {
                                    Task {
                                        isTestingVoiceEn = true
                                        testVoiceError = nil
                                        defer { isTestingVoiceEn = false }
                                        do {
                                            let v = audioVoiceEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                ? audioVoice.trimmingCharacters(in: .whitespacesAndNewlines)
                                                : audioVoiceEn.trimmingCharacters(in: .whitespacesAndNewlines)
                                            try await AudioProviderFactory.shared.preview(
                                                provider: audioProvider,
                                                voice: v,
                                                speed: speechSpeed.trimmingCharacters(in: .whitespacesAndNewlines),
                                                lang: "en-US"
                                            )
                                        } catch {
                                            testVoiceError = error.localizedDescription
                                        }
                                    }
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: isTestingVoiceEn ? "waveform" : "play.circle.fill")
                                        Text(isTestingVoiceEn ? "Đang phát..." : "Thử Voice EN")
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .foregroundColor(.white)
                                    .padding(.vertical, 10)
                                    .background(Color(hex: "14b8a6").opacity(0.2))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color(hex: "14b8a6").opacity(0.4), lineWidth: 1)
                                    )
                                    .cornerRadius(10)
                                }
                                .disabled(isTestingVoiceEn || isTestingVoiceVi)

                                Button(action: {
                                    Task {
                                        isTestingVoiceVi = true
                                        testVoiceError = nil
                                        defer { isTestingVoiceVi = false }
                                        do {
                                            let v = audioVoiceVi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                ? audioVoice.trimmingCharacters(in: .whitespacesAndNewlines)
                                                : audioVoiceVi.trimmingCharacters(in: .whitespacesAndNewlines)
                                            try await AudioProviderFactory.shared.preview(
                                                provider: audioProvider,
                                                voice: v,
                                                speed: speechSpeed.trimmingCharacters(in: .whitespacesAndNewlines),
                                                lang: "vi-VN"
                                            )
                                        } catch {
                                            testVoiceError = error.localizedDescription
                                        }
                                    }
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: isTestingVoiceVi ? "waveform" : "play.circle.fill")
                                        Text(isTestingVoiceVi ? "Đang phát..." : "Thử Voice VI")
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .foregroundColor(.white)
                                    .padding(.vertical, 10)
                                    .background(Color(hex: "0284c7").opacity(0.2))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color(hex: "0284c7").opacity(0.4), lineWidth: 1)
                                    )
                                    .cornerRadius(10)
                                }
                                .disabled(isTestingVoiceEn || isTestingVoiceVi)
                            }

                            if let err = testVoiceError {
                                Text(err)
                                    .font(.system(size: 11))
                                    .foregroundColor(.red)
                                    .padding(.top, 2)
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        }

                        /*
                        // Companion Voice (Realtime) đã được loại bỏ.
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
                        .padding(12)
                        .background(Color.white.opacity(0.04))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        */
                        
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
                            let visibleDownloadedBooks = Array(downloadedBooks.prefix(visibleCachedBookCount))
                            
                            if downloadedBooks.isEmpty {
                                Text("Chưa có sách nào được tải về thiết bị.")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(hex: "94a3b8"))
                                    .padding(.vertical, 8)
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(visibleDownloadedBooks) { book in
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
                                        
                                        if book.id != visibleDownloadedBooks.last?.id {
                                            Divider().background(Color.white.opacity(0.06))
                                        }
                                    }

                                    if visibleDownloadedBooks.count < downloadedBooks.count {
                                        Button(action: {
                                            withAnimation {
                                                visibleCachedBookCount = min(
                                                    visibleCachedBookCount + 3,
                                                    downloadedBooks.count
                                                )
                                            }
                                        }) {
                                            HStack(spacing: 6) {
                                                Image(systemName: "chevron.down")
                                                    .font(.system(size: 10, weight: .bold))
                                                Text("Xem thêm (\(downloadedBooks.count - visibleDownloadedBooks.count))")
                                                    .font(.system(size: 12, weight: .semibold))
                                            }
                                            .foregroundColor(Color(hex: "38bdf8"))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 8)
                                            .background(Color(hex: "38bdf8").opacity(0.08))
                                            .cornerRadius(8)
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
            .toolbarColorScheme(.dark, for: .navigationBar)
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
                Task { await loadSettingsFromServer() }
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
        self.hideFinishedBooks = UserDefaults.standard.object(forKey: "hideFinishedBooks") as? Bool ?? true
        // Unknown/absent value falls back to `auto` through the enum, never to a raw string.
        self.audioSource = VocaAudioSource.current.rawValue
        self.deviceVoiceReady = DeviceSpeech.shared.isAvailable
        // Voca is NOT read from the device any more — see `loadVocaFromServer`.
    }
    
    /// Loads the canonical settings shared by Web and Mobile.
    ///
    /// Public preferences are returned in full. Secret fields remain empty because
    /// the server exposes only availability flags for stored credentials.
    @MainActor
    private func loadSettingsFromServer() async {
        guard api.isAuthenticated else {
            vocaConfiguredOnServer = false
            vocaSectionNote = "Đăng nhập để tải và đồng bộ cài đặt từ server."
            return
        }
        isLoadingVocaSettings = true
        defer { isLoadingVocaSettings = false }
        await api.fetchAppConfig()
        do {
            let settings = try await api.fetchServerSettings()

            aiProvider = settings.provider
            aiBaseURL = settings.baseURL
            aiModel = settings.model
            bilingualLayoutMode = settings.layoutMode
            hideFinishedBooks = settings.hideFinishedBooks

            audioProvider = settings.audioProvider
            audioSource = settings.audioSource
            audioVoice = settings.audioVoice
            audioVoiceEn = settings.audioVoiceEn.isEmpty
                ? settings.audioVoice
                : settings.audioVoiceEn
            audioVoiceVi = settings.audioVoiceVi
            speechSpeed = settings.speechSpeed
            hasAzureKey = settings.hasAzureKey
            hasElevenLabsKey = settings.hasElevenLabsKey

            vocaConfiguredOnServer = settings.hasVocaToken
            vocaApiOrigin = settings.vocaOrigin.isEmpty
                ? VocaService.defaultOrigin
                : settings.vocaOrigin
            vocaApiKey = ""
            vocaSectionNote = "Cài đặt đang được đồng bộ từ server."
            VocaService.noteConfiguration(
                hasVocaToken: settings.hasVocaToken
            )
        } catch {
            let server = api.serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            vocaSectionNote =
                "Không tải được cài đặt từ \(server): \(error.localizedDescription)"
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

    /// Saves the complete cross-platform settings contract on the server.
    ///
    /// UserDefaults is no longer the persistence layer for shared settings.
    /// A failed server write keeps this screen open.
    @MainActor
    private func saveSettings() async -> String? {
        let llm = aiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = VocaService.normalizedOrigin(vocaApiOrigin)
        let originToSend = origin.isEmpty ? VocaService.defaultOrigin : origin
        let typedVocaKey = vocaApiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard api.isAuthenticated else {
            return "Chưa đăng nhập nên không thể lưu cài đặt lên server."
        }

        do {
            let vEn = audioVoiceEn.trimmingCharacters(in: .whitespacesAndNewlines)
            let vVi = audioVoiceVi.trimmingCharacters(in: .whitespacesAndNewlines)
            let vFallback = !vEn.isEmpty ? vEn : audioVoice.trimmingCharacters(in: .whitespacesAndNewlines)

            let saved = try await api.saveServerSettings(
                provider: aiProvider,
                baseURL: aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                model: aiModel.trimmingCharacters(in: .whitespacesAndNewlines),
                llmApiKey: llm.isEmpty ? nil : llm,
                audioProvider: api.isAudiobookEnabled ? audioProvider : nil,
                audioSource: (VocaAudioSource(rawValue: audioSource) ?? .auto).rawValue,
                audioVoice: api.isAudiobookEnabled ? vFallback : nil,
                audioVoiceEn: api.isAudiobookEnabled ? vEn : nil,
                audioVoiceVi: api.isAudiobookEnabled ? vVi : nil,
                ttsModel: api.isAudiobookEnabled ? vEn : nil,
                speechSpeed: api.isAudiobookEnabled ? speechSpeed : nil,
                azureApiKey: api.isAudiobookEnabled && !azureApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? azureApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil,
                elevenLabsApiKey: api.isAudiobookEnabled && !elevenLabsApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? elevenLabsApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil,
                layoutMode: bilingualLayoutMode,
                hideFinishedBooks: hideFinishedBooks,
                vocaOrigin: originToSend,
                vocaToken: typedVocaKey.isEmpty ? nil : typedVocaKey
            )

            aiProvider = saved.provider
            aiBaseURL = saved.baseURL
            aiModel = saved.model
            bilingualLayoutMode = saved.layoutMode
            hideFinishedBooks = saved.hideFinishedBooks
            audioProvider = saved.audioProvider
            audioSource = saved.audioSource
            audioVoice = saved.audioVoice
            audioVoiceEn = saved.audioVoiceEn
            audioVoiceVi = saved.audioVoiceVi
            speechSpeed = saved.speechSpeed
            hasAzureKey = saved.hasAzureKey
            hasElevenLabsKey = saved.hasElevenLabsKey
            vocaConfiguredOnServer = saved.hasVocaToken

            if api.isAudiobookEnabled {
                AudiobookManager.shared.configure(
                    provider: saved.audioProvider,
                    voice: saved.audioVoice,
                    speed: saved.speechSpeed,
                    voiceEn: saved.audioVoiceEn,
                    voiceVi: saved.audioVoiceVi
                )
            }
        } catch {
            return "Không lưu được cài đặt lên server. Kiểm tra kết nối rồi thử lại."
        }

        // Reflect what was actually sent, and drop anything cached from the old config: a new
        // key/origin can mean a different Voca account entirely.
        vocaApiOrigin = originToSend
        vocaApiKey = ""
        VocaService.noteConfiguration(hasVocaToken: vocaConfiguredOnServer)
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
