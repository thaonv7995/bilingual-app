import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "Đọc sách & AI"
    case voca = "Từ điển Voca"
    case backup = "Sao lưu & Khôi phục"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "book.pages"
        case .voca: return "character.book.closed"
        case .backup: return "externaldrive.badge.timemachine"
        }
    }
}

struct SettingsViewMac: View {
    @Environment(\.dismiss) private var dismiss

    let initialTab: SettingsTab
    @Binding var preselectedSnapshot: LocalSnapshotRecord?

    @ObservedObject private var api = APIService.shared
    @ObservedObject private var backup = BackupManager.shared

    @State private var activeTab: SettingsTab
    @State private var backupSubMode: Int = 0 // 0 = Backup Vault, 1 = Khôi phục Server

    @State private var aiProvider: String = UserDefaults.standard.string(forKey: "aiProvider") ?? "openai"
    @State private var aiBaseURL: String = UserDefaults.standard.string(forKey: "aiBaseURL") ?? "https://api.openai.com/v1"
    @State private var aiApiKey: String = UserDefaults.standard.string(forKey: "aiApiKey") ?? ""
    @State private var aiModel: String = UserDefaults.standard.string(forKey: "aiModel") ?? "gpt-4o-mini"
    @State private var bilingualLayoutMode: String = UserDefaults.standard.string(forKey: "bilingualLayoutMode") ?? "en-vi"
    @State private var hideFinishedBooks: Bool = UserDefaults.standard.object(forKey: "hideFinishedBooks") as? Bool ?? true

    @State private var vocaOrigin: String = VocaService.defaultOrigin
    @State private var vocaToken: String = ""
    @State private var audioSource: String = VocaAudioSource.current.rawValue
    @State private var vocaConfigured: Bool = false

    @State private var statusMessage: String?
    @State private var isSaving: Bool = false

    init(initialTab: SettingsTab = .general, preselectedSnapshot: Binding<LocalSnapshotRecord?>) {
        self.initialTab = initialTab
        self._preselectedSnapshot = preselectedSnapshot
        self._activeTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar matching iPad dark Settings modal
            HStack {
                Text("Cài đặt")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text("Xong")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "38bdf8"))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(hex: "38bdf8").opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.macInteractive(cornerRadius: 7))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(hex: "0b0f19"))

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)

            HStack(spacing: 0) {
                // Category Column inside Settings
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(SettingsTab.allCases) { tab in
                        let selected = activeTab == tab
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                activeTab = tab
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(selected ? Color(hex: "38bdf8") : Color(hex: "94a3b8"))
                                    .frame(width: 18)
                                Text(tab.rawValue)
                                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                                    .foregroundStyle(selected ? .white : Color(hex: "cbd5e1"))
                                Spacer()
                                if tab == .backup && backup.wipeGuardTriggered {
                                    Circle()
                                        .fill(Color(hex: "ef4444"))
                                        .frame(width: 7, height: 7)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(selected ? Color(hex: "38bdf8").opacity(0.14) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(selected ? Color(hex: "38bdf8").opacity(0.35) : Color.clear, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.macInteractive(cornerRadius: 9))
                    }

                    Spacer()

                    if let user = api.currentUser {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(user.username)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(api.serverUrl)
                                .font(.caption2.monospaced())
                                .foregroundStyle(Color(hex: "64748b"))
                                .lineLimit(1)
                        }
                        .padding(10)
                    }
                }
                .padding(14)
                .frame(width: 220)
                .background(Color(hex: "0b0f19").opacity(0.65))

                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 0.5)

                // Detail Column
                Group {
                    switch activeTab {
                    case .general:
                        generalAndAISettingsView
                    case .voca:
                        vocaSettingsView
                    case .backup:
                        backupAndRestoreSettingsView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 880, minHeight: 620)
        .background(Color(hex: "0f172a"))
        .task { await loadFromServer() }
    }

    // MARK: - Tab 1: Đọc sách & AI

    private var generalAndAISettingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                darkCard(title: "Chế độ đọc & Kệ sách") {
                    Picker("Thứ tự cột khi đọc Song ngữ", selection: $bilingualLayoutMode) {
                        Text("English | Tiếng Việt").tag("en-vi")
                        Text("Tiếng Việt | English").tag("vi-en")
                    }
                    .pickerStyle(.segmented)

                    Toggle(isOn: $hideFinishedBooks) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ẩn sách đã đọc xong khỏi mục Tất cả")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                            Text("Sách đã hoàn thành vẫn xem được trong bộ lọc Đã đọc")
                                .font(.caption)
                                .foregroundStyle(Color(hex: "94a3b8"))
                        }
                    }
                    .tint(Color(hex: "14b8a6"))
                }

                darkCard(title: "AI Companion Agent") {
                    HStack(spacing: 8) {
                        ForEach(["openai", "gemini", "custom"], id: \.self) { prov in
                            let selected = aiProvider == prov
                            let label = prov == "openai" ? "OpenAI" : (prov == "gemini" ? "Gemini" : "Custom")
                            Button {
                                aiProvider = prov
                                if prov == "openai" {
                                    aiBaseURL = "https://api.openai.com/v1"
                                    aiModel = "gpt-4o-mini"
                                } else if prov == "gemini" {
                                    aiBaseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
                                    aiModel = "gemini-2.0-flash"
                                }
                            } label: {
                                Text(label)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(selected ? .white : Color(hex: "94a3b8"))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(selected ? Color.white.opacity(0.1) : Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.macInteractive(cornerRadius: 8))
                        }
                    }

                    labeledDarkInput("Base URL", text: $aiBaseURL)
                    labeledDarkInput("Model", text: $aiModel)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("API Key")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(hex: "94a3b8"))
                        SecureField("Để trống nếu dùng key đang lưu trên Server", text: $aiApiKey)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(Color(hex: "0b0f19"))
                            .cornerRadius(8)
                            .foregroundStyle(.white)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    }
                }

                darkCard(title: "Tính năng thử nghiệm") {
                    HStack {
                        Text("Sách nói (Audiobook / Read-Aloud)")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                        Spacer()
                        Text(api.isAudiobookEnabled ? "Đang bật trên Server" : "Đã tắt (ENABLE_AUDIOBOOK=false)")
                            .font(.caption)
                            .foregroundStyle(Color(hex: "94a3b8"))
                    }
                }

                saveFooterBar
            }
            .padding(24)
        }
    }

    // MARK: - Tab 2: Từ điển Voca 2.0

    private var vocaSettingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                darkCard(title: "Từ điển Voca 2.0 (Đồng bộ trên Server)") {
                    labeledDarkInput("Voca Origin", text: $vocaOrigin)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Voca API Token")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(hex: "94a3b8"))
                        SecureField(
                            vocaConfigured ? "Đã lưu token trên server (nhập mới để thay đổi)" : "Nhập voca_...",
                            text: $vocaToken
                        )
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(Color(hex: "0b0f19"))
                        .cornerRadius(8)
                        .foregroundStyle(.white)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nguồn phát âm")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(hex: "94a3b8"))
                        Picker("Nguồn phát âm", selection: $audioSource) {
                            Text("Tự động (Voca → Giọng máy)").tag("auto")
                            Text("Chỉ Voca").tag("voca")
                            Text("Giọng máy macOS (Offline)").tag("device")
                        }
                        .pickerStyle(.segmented)
                    }
                }

                saveFooterBar
            }
            .padding(24)
        }
    }

    // MARK: - Tab 3: Sao lưu & Khôi phục Server

    private var backupAndRestoreSettingsView: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Chế độ Backup", selection: $backupSubMode) {
                    Text("Backup Vault (Server → Mac)").tag(0)
                    Text("Khôi phục Server (Mac → Server)").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 460)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)

            if backupSubMode == 0 {
                BackupVaultView { record in
                    preselectedSnapshot = record
                    backupSubMode = 1
                }
            } else {
                RestoreWizardView(preselectedSnapshot: $preselectedSnapshot)
            }
        }
    }

    // MARK: - Shared UI Helpers

    private var saveFooterBar: some View {
        HStack {
            if let status = statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(status.contains("✓") ? Color(hex: "2dd4bf") : Color(hex: "f87171"))
            }
            Spacer()
            Button {
                save()
            } label: {
                HStack(spacing: 6) {
                    if isSaving { ProgressView().controlSize(.small).tint(.white) }
                    Text("Lưu & Đồng bộ cài đặt")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(hex: "6366f1"))
                .foregroundStyle(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.macInteractive(cornerRadius: 8))
            .disabled(isSaving)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func darkCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13.5, weight: .bold))
                .foregroundStyle(.white)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func labeledDarkInput(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(hex: "94a3b8"))
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .padding(10)
                .background(Color(hex: "0b0f19"))
                .cornerRadius(8)
                .foregroundStyle(.white)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
        }
    }

    private func loadFromServer() async {
        await api.fetchAppConfig()
        guard api.isAuthenticated, !api.isOfflineMode else { return }
        do {
            let s = try await api.fetchServerSettings()
            await MainActor.run {
                aiProvider = s.provider
                aiBaseURL = s.baseURL
                aiModel = s.model
                bilingualLayoutMode = s.layoutMode
                hideFinishedBooks = s.hideFinishedBooks
                vocaOrigin = s.vocaOrigin.isEmpty ? VocaService.defaultOrigin : s.vocaOrigin
                vocaConfigured = s.hasVocaToken
                audioSource = s.audioSource
            }
        } catch {}
    }

    private func save() {
        UserDefaults.standard.set(aiProvider, forKey: "aiProvider")
        UserDefaults.standard.set(aiBaseURL, forKey: "aiBaseURL")
        UserDefaults.standard.set(aiApiKey, forKey: "aiApiKey")
        UserDefaults.standard.set(aiModel, forKey: "aiModel")
        UserDefaults.standard.set(bilingualLayoutMode, forKey: "bilingualLayoutMode")
        UserDefaults.standard.set(hideFinishedBooks, forKey: "hideFinishedBooks")
        NotificationCenter.default.post(name: NSNotification.Name("ReadingProgressUpdated"), object: nil)
        let normalizedAudio = VocaAudioSource(rawValue: audioSource) ?? .auto
        UserDefaults.standard.set(normalizedAudio.rawValue, forKey: VocaAudioSource.defaultsKey)

        let trimmedVocaKey = vocaToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedVocaKey.isEmpty && !VocaService.isValidAPIKeyFormat(trimmedVocaKey) {
            statusMessage = "Voca token phải bắt đầu bằng voca_"
            return
        }

        guard api.isAuthenticated, !api.isOfflineMode else {
            statusMessage = "✓ Đã lưu cục bộ (chưa đồng bộ server vì đang ngoại tuyến)."
            return
        }

        isSaving = true
        Task {
            do {
                let updated = try await api.saveServerSettings(
                    provider: aiProvider,
                    baseURL: aiBaseURL,
                    model: aiModel,
                    llmApiKey: aiApiKey.isEmpty ? nil : aiApiKey,
                    audioSource: audioSource,
                    layoutMode: bilingualLayoutMode,
                    hideFinishedBooks: hideFinishedBooks,
                    vocaOrigin: VocaService.normalizedOrigin(vocaOrigin),
                    vocaToken: trimmedVocaKey.isEmpty ? nil : trimmedVocaKey
                )
                await MainActor.run {
                    isSaving = false
                    vocaConfigured = updated.hasVocaToken
                    VocaService.noteConfiguration(hasVocaToken: updated.hasVocaToken)
                    statusMessage = "✓ Đã lưu & đồng bộ cài đặt lên Server."
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    statusMessage = "Lỗi lưu server: \(error.localizedDescription)"
                }
            }
        }
    }
}
