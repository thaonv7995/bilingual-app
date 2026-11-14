import SwiftUI

struct RestoreWizardView: View {
    @Binding var preselectedSnapshot: LocalSnapshotRecord?

    @ObservedObject private var api = APIService.shared
    @ObservedObject private var backup = BackupManager.shared

    @State private var selectedSnapshotId: String = ""
    @State private var loadedSnapshot: BackupSnapshot?
    @State private var selection = RestoreSelection()

    @State private var targetServerURL: String = APIService.shared.serverUrl
    @State private var serverCheckStatus: String?
    @State private var isCheckingServer: Bool = false

    @State private var isRunningDryRun: Bool = false
    @State private var dryRunResult: BackupRestoreResponse?
    @State private var dryRunError: String?

    @State private var showConfirmAlert: Bool = false
    @State private var isRestoring: Bool = false
    @State private var logs: [String] = []
    @State private var restoreResult: RestoreExecutionResult?

    private var isAdminSession: Bool {
        api.currentUser?.isAdmin == true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                emergencyBanner

                if backup.snapshots.isEmpty {
                    ContentUnavailableView(
                        "Chưa có bản Backup nào trong Mac Vault",
                        systemImage: "externaldrive.badge.xmark",
                        description: Text("Hãy đồng bộ từ server khi hệ thống hoạt động bình thường trước khi thực hiện khôi phục.")
                    )
                } else {
                    sourceSnapshotCard
                    targetServerCard
                    restoreOptionsCard
                    dryRunAndExecuteCard
                }
            }
            .padding(24)
        }
        .navigationTitle("Khôi phục Server (Emergency Push)")
        .onAppear { syncSelectionFromPreselected() }
        .onChange(of: preselectedSnapshot?.id) { _, _ in syncSelectionFromPreselected() }
        .alert("Xác nhận đẩy Backup từ Mac lên Server?", isPresented: $showConfirmAlert) {
            Button("Huỷ", role: .cancel) {}
            Button("Xác nhận Push Restore", role: selection.mode == .overwrite ? .destructive : .none) {
                executeRestore()
            }
        } message: {
            if selection.mode == .overwrite {
                Text("Chế độ OVERWRITE sẽ ghi đè dữ liệu trên server (\(api.serverUrl)) để khớp bản backup '\(selectedSnapshotId)'. Tài khoản admin hiện tại vẫn được giữ an toàn. Tiếp tục?")
            } else {
                Text("Chế độ MERGE sẽ tải lên sách .bkb thiếu và gộp dữ liệu còn thiếu từ bản backup '\(selectedSnapshotId)' lên server (\(api.serverUrl)).")
            }
        }
    }

    private var emergencyBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.to.line.circle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Đẩy Backup từ Mac lên Server (Chỉ chạy thủ công khi Server gặp sự cố)")
                    .font(.headline)
                Text("Luồng chuẩn vẫn lấy Server làm Source of Truth. Chức năng này giúp khôi phục sách (.bkb), users, phân quyền, highlights và tiến độ khi server mất dữ liệu hoặc dựng mới.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private var sourceSnapshotCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1. Chọn bản Snapshot nguồn trên Mac").font(.headline)

            Picker("Snapshot", selection: $selectedSnapshotId) {
                ForEach(backup.snapshots) { rec in
                    Text("\(rec.folderName) — \(rec.bookCount) sách, \(rec.userCount) users, \(rec.highlightCount) highlights")
                        .tag(rec.id)
                }
            }
            .onChange(of: selectedSnapshotId) { _, _ in
                loadSelectedSnapshot()
            }

            if let snap = loadedSnapshot {
                HStack(spacing: 16) {
                    Label("Scope: \(snap.scope)", systemImage: "scope")
                    Label("Sách: \(snap.books.count)", systemImage: "book")
                    Label("Users: \(snap.users.count)", systemImage: "person.2")
                    Label("Highlights: \(snap.highlights.count)", systemImage: "highlighter")
                    Label("Secrets: \(snap.includesSecrets ? "Có" : "Không")", systemImage: "key")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var targetServerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2. Kiểm tra Server đích").font(.headline)
            HStack {
                TextField("https://book.thaonv.online", text: $targetServerURL)
                    .textFieldStyle(.roundedBorder)
                Button("Áp dụng & Ping") {
                    api.serverUrl = targetServerURL
                    isCheckingServer = true
                    Task {
                        let ok = await api.pingServer()
                        if ok { await api.verifyToken() }
                        await MainActor.run {
                            isCheckingServer = false
                            serverCheckStatus = ok
                                ? "✓ Server đang phản hồi (\(api.currentUser?.username ?? "chưa đăng nhập"), Admin: \(isAdminSession ? "Có" : "Không"))"
                                : "✗ Không kết nối được tới server này"
                        }
                    }
                }
                .disabled(isCheckingServer)
            }
            if let status = serverCheckStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(status.hasPrefix("✓") ? .green : .red)
            }
            if !isAdminSession {
                Text("Bạn đang đăng nhập bằng tài khoản thường: chỉ có thể khôi phục Highlights, Progress, Book States và Settings cá nhân.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var restoreOptionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3. Tuỳ chọn chế độ & thành phần khôi phục").font(.headline)

            Picker("Chế độ khôi phục", selection: $selection.mode) {
                ForEach(RestoreMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: selection.mode) { _, _ in dryRunResult = nil }

            Text(selection.mode.description)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Upload file .bkb bị thiếu lên server", isOn: $selection.uploadMissingBooks)
                        .disabled(!isAdminSession)
                    Toggle("Ghi đè lại cả sách .bkb đã có trên server", isOn: $selection.overwriteExistingBooks)
                        .disabled(!isAdminSession)
                    Toggle("Metadata & giao diện mặc định sách", isOn: $selection.restoreBooksMetadata)
                        .disabled(!isAdminSession)
                    Toggle("Users & Password Hash", isOn: $selection.restoreUsers)
                        .disabled(!isAdminSession)
                    Toggle("Phân quyền đọc sách (Permissions)", isOn: $selection.restorePermissions)
                        .disabled(!isAdminSession)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Highlights & Ghi chú", isOn: $selection.restoreHighlights)
                    Toggle("Tiến độ đọc (Reading Progress)", isOn: $selection.restoreProgress)
                    Toggle("Trạng thái kệ & Font/Màu từng sách", isOn: $selection.restoreStates)
                    Toggle("Cài đặt AI / Voca / Giao diện", isOn: $selection.restoreSettings)
                    Toggle("Khôi phục cả API Secrets (nếu snapshot có)", isOn: $selection.restoreSecrets)
                        .disabled(loadedSnapshot?.includesSecrets != true)
                    Toggle("API Keys hệ thống", isOn: $selection.restoreApiKeys)
                        .disabled(!isAdminSession || loadedSnapshot?.includesSecrets != true)
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var dryRunAndExecuteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("4. Xem trước Diff (Dry-Run) & Thực thi").font(.headline)
                Spacer()
                Button {
                    runDryRun()
                } label: {
                    HStack {
                        if isRunningDryRun { ProgressView().controlSize(.small) }
                        Text("Kiểm tra Diff trước (Dry-Run)")
                    }
                }
                .disabled(loadedSnapshot == nil || isRunningDryRun || isRestoring)

                Button {
                    showConfirmAlert = true
                } label: {
                    HStack {
                        if isRestoring { ProgressView().controlSize(.small) }
                        Text("Đẩy Backup lên Server")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(selection.mode == .overwrite ? .red : .accentColor)
                .disabled(dryRunResult == nil || isRestoring || isRunningDryRun)
            }

            if let err = dryRunError {
                Text("Lỗi kiểm tra Diff: \(err)").font(.caption).foregroundStyle(.red)
            }

            if let dry = dryRunResult {
                dryRunSummaryView(dry)
            }

            if !logs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nhật ký thực thi:").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption.monospaced())
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .padding(10)
                    .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func dryRunSummaryView(_ resp: BackupRestoreResponse) -> some View {
        let s = resp.summary
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                DiffChip(label: "Sách .bkb thiếu trên server", value: "\(s.books.missingFiles.count)", tint: s.books.missingFiles.isEmpty ? .green : .orange)
                DiffChip(label: "Users (+/upd/del)", value: "+\(s.users.created)/\(s.users.updated ?? 0)/-\(s.users.deleted)", tint: .blue)
                DiffChip(label: "Permissions", value: "+\(s.permissions.created)/-\(s.permissions.deleted)", tint: .indigo)
                DiffChip(label: "Highlights", value: "+\(s.highlights.created)/\(s.highlights.updated ?? 0)/-\(s.highlights.deleted)", tint: .teal)
                DiffChip(label: "Progress", value: "+\(s.readingProgress.created)/\(s.readingProgress.updated ?? 0)", tint: .green)
            }
            if !s.books.missingFiles.isEmpty {
                Text("Sách cần upload .bkb: \(s.books.missingFiles.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(resp.warnings, id: \.self) { warn in
                Text("⚠︎ \(warn)").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func syncSelectionFromPreselected() {
        if let pre = preselectedSnapshot {
            selectedSnapshotId = pre.id
        } else if selectedSnapshotId.isEmpty, let first = backup.snapshots.first {
            selectedSnapshotId = first.id
        }
        loadSelectedSnapshot()
    }

    private func loadSelectedSnapshot() {
        dryRunResult = nil
        dryRunError = nil
        guard let rec = backup.snapshots.first(where: { $0.id == selectedSnapshotId }) else {
            loadedSnapshot = nil
            return
        }
        loadedSnapshot = try? backup.loadSnapshot(from: rec)
        if !isAdminSession {
            selection.uploadMissingBooks = false
            selection.overwriteExistingBooks = false
            selection.restoreBooksMetadata = false
            selection.restoreUsers = false
            selection.restorePermissions = false
            selection.restoreApiKeys = false
        }
    }

    private func runDryRun() {
        guard let snap = loadedSnapshot else { return }
        isRunningDryRun = true
        dryRunError = nil
        Task {
            do {
                let res = try await backup.preflightDryRun(snapshot: snap, selection: selection)
                await MainActor.run {
                    dryRunResult = res
                    isRunningDryRun = false
                }
            } catch {
                await MainActor.run {
                    dryRunError = error.localizedDescription
                    isRunningDryRun = false
                }
            }
        }
    }

    private func executeRestore() {
        guard let snap = loadedSnapshot, let dry = dryRunResult else { return }
        isRestoring = true
        logs = []
        Task {
            do {
                let result = try await backup.executePushRestore(
                    snapshot: snap,
                    selection: selection,
                    dryRunMissingSlugs: dry.summary.books.missingFiles
                ) { line in
                    Task { @MainActor in logs.append(line) }
                }
                await MainActor.run {
                    restoreResult = result
                    isRestoring = false
                    if result.failedBookUploads.isEmpty {
                        logs.append("✓ Hoàn tất toàn bộ khôi phục! Server hiện lại là Source of Truth.")
                    } else {
                        logs.append("⚠︎ Hoàn tất kèm \(result.failedBookUploads.count) sách upload lỗi: \(result.failedBookUploads.joined(separator: ", "))")
                    }
                }
                _ = try? await api.fetchBooks()
            } catch {
                await MainActor.run {
                    isRestoring = false
                    logs.append("✗ Lỗi thực thi khôi phục: \(error.localizedDescription)")
                }
            }
        }
    }
}

private struct DiffChip: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.monospaced().weight(.bold)).foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
