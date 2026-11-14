import SwiftUI
import AppKit

struct BackupVaultView: View {
    let onSelectSnapshotForRestore: (LocalSnapshotRecord) -> Void

    @ObservedObject private var api = APIService.shared
    @ObservedObject private var backup = BackupManager.shared

    @State private var subTab: Int = 0
    @State private var orphanPruneNote: String?

    private var totalBkbBytes: Int64 {
        backup.vaultIndex.booksBySlug.values.reduce(0) { $0 + $1.bkbSizeBytes }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sourceOfTruthBanner

                if backup.wipeGuardTriggered {
                    wipeProtectionBanner
                }

                if let err = backup.lastError, !backup.wipeGuardTriggered {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(err).font(.callout)
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }

                summaryCardsRow
                syncControlsCard
                vaultStorageCard
                snapshotsAndBooksSection
            }
            .padding(24)
        }
        .navigationTitle("Backup Vault")
    }

    private var sourceOfTruthBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.timemachine")
                .font(.title2)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Chế độ Backup chuẩn: Server = Source of Truth")
                    .font(.headline)
                Text("Mỗi lần đồng bộ, Mac tự động kéo dữ liệu & gói sách .bkb từ server về làm bản sao lưu ngoại tuyến, lưu tối đa \(backup.maxRetainedSnapshots) snapshot lịch sử.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var wipeProtectionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.title2)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Cảnh báo bảo vệ dữ liệu: Server trả về 0 sách!")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(backup.lastError ?? "Đã tạm dừng ghi đè backup cục bộ để bảo vệ sách đang lưu trên Mac.")
                    .font(.caption)
            }
            Spacer()
            if let latest = backup.snapshots.first {
                Button("Khôi phục Server ngay") {
                    onSelectSnapshotForRestore(latest)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            Button("Vẫn ghi nhận 0 sách") {
                Task { await backup.syncFromServer(forceAllowEmptyServer: true) }
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private var summaryCardsRow: some View {
        HStack(spacing: 14) {
            StatCardMac(
                title: "Sách .bkb trong Vault",
                value: "\(backup.vaultIndex.booksBySlug.count)",
                subtitle: ByteCountFormatter.string(fromByteCount: totalBkbBytes, countStyle: .file),
                icon: "books.vertical.fill",
                tint: .indigo
            )
            StatCardMac(
                title: "Snapshots lịch sử",
                value: "\(backup.snapshots.count) / \(backup.maxRetainedSnapshots)",
                subtitle: backup.latestSnapshot?.scope == BackupScope.adminFull.rawValue ? "Admin Full" : "Personal",
                icon: "clock.arrow.circlepath",
                tint: .teal
            )
            StatCardMac(
                title: "Lần đồng bộ cuối",
                value: formattedUnixTime(backup.vaultIndex.lastSyncAt),
                subtitle: backup.vaultIndex.lastUsername.map { "User: \($0)" } ?? "Chưa đồng bộ",
                icon: "checkmark.shield.fill",
                tint: .green
            )
        }
    }

    private var syncControlsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Đồng bộ từ Server (Pull -> Mac)").font(.headline)
                    Text(backup.syncPhase.isEmpty ? "Sẵn sàng đồng bộ tăng trưởng (chỉ tải lại .bkb khi nội dung thay đổi)." : backup.syncPhase)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await backup.syncFromServer() }
                } label: {
                    HStack(spacing: 6) {
                        if backup.isSyncing { ProgressView().controlSize(.small) }
                        Text(backup.isSyncing ? "Đang đồng bộ…" : "Sync từ Server ngay")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(backup.isSyncing || !api.isAuthenticated)
            }

            if backup.isSyncing {
                ProgressView(value: backup.syncProgress)
            } else if let res = backup.lastSyncResult {
                Text("Kết quả gần nhất: tải mới \(res.downloadedBooks) sách, bỏ qua \(res.skippedUnchangedBooks) sách không đổi, lưu snapshot `\(res.snapshotFolder)`.")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Divider()

            HStack(spacing: 24) {
                Picker("Lịch tự động Sync", selection: $backup.scheduleInterval) {
                    ForEach(SyncScheduleInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }
                .frame(width: 260)

                Stepper("Giữ tối đa \(backup.maxRetainedSnapshots) snapshots", value: $backup.maxRetainedSnapshots, in: 1...50)
                    .frame(width: 240)
            }

            HStack(spacing: 24) {
                Toggle("Tự động Sync khi mở app", isOn: $backup.syncOnLaunch)
                Toggle("Bao gồm API Secrets (LLM / Voca / TTS Keys) trong Snapshot", isOn: $backup.includeSecrets)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var vaultStorageCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Thư mục lưu Backup Vault").font(.subheadline.weight(.semibold))
                Text(backup.vaultURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let note = orphanPruneNote {
                    Text(note).font(.caption).foregroundStyle(.blue)
                }
            }
            Spacer()
            Button("Dọn .bkb thừa") {
                let removed = backup.pruneOrphanBookArchives()
                orphanPruneNote = removed.isEmpty
                    ? "Không có file .bkb thừa nào (tất cả đều được snapshot tham chiếu)."
                    : "Đã dọn \(removed.count) sách không còn trong bất kỳ snapshot nào."
            }
            Button("Mở trong Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([backup.vaultURL])
            }
            Button("Đổi thư mục…") {
                chooseVaultDirectory()
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var snapshotsAndBooksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Chi tiết Vault", selection: $subTab) {
                Text("Lịch sử Snapshots (\(backup.snapshots.count))").tag(0)
                Text("Kho sách .bkb cục bộ (\(backup.vaultIndex.booksBySlug.count))").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 420)

            if subTab == 0 {
                if backup.snapshots.isEmpty {
                    ContentUnavailableView("Chưa có Snapshot nào", systemImage: "tray", description: Text("Nhấn 'Sync từ Server ngay' để tạo bản sao lưu đầu tiên."))
                } else {
                    VStack(spacing: 8) {
                        ForEach(backup.snapshots) { rec in
                            HStack(spacing: 12) {
                                Image(systemName: rec.scope == BackupScope.adminFull.rawValue ? "server.rack" : "person.crop.circle")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(rec.folderName).font(.subheadline.monospaced().weight(.semibold))
                                        Text(rec.scope == BackupScope.adminFull.rawValue ? "Admin Full" : "Personal")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.15), in: Capsule())
                                        if rec.includesSecrets {
                                            Text("Có Secrets")
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.orange.opacity(0.18), in: Capsule())
                                        }
                                    }
                                    Text("\(rec.bookCount) sách • \(rec.userCount) users • \(rec.highlightCount) highlights • \(ByteCountFormatter.string(fromByteCount: rec.fileSizeBytes, countStyle: .file))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Khôi phục lên Server…") {
                                    onSelectSnapshotForRestore(rec)
                                }
                                .buttonStyle(.bordered)
                                Button(role: .destructive) {
                                    backup.deleteSnapshot(rec)
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(width: 28, height: 28)
                                        .background(Color.red.opacity(0.08), in: Circle())
                                }
                                .buttonStyle(.macCircle(hoverColor: Color.red.opacity(0.18)))
                            }
                            .padding(12)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
                        }
                    }
                }
            } else {
                let entries = backup.vaultIndex.booksBySlug.values.sorted { $0.slug < $1.slug }
                if entries.isEmpty {
                    ContentUnavailableView("Chưa có sách .bkb", systemImage: "books.vertical", description: Text("Các file .bkb và thư mục đọc ngoại tuyến sẽ xuất hiện ở đây sau khi đồng bộ."))
                } else {
                    VStack(spacing: 8) {
                        ForEach(entries) { entry in
                            HStack(spacing: 12) {
                                Image(systemName: "doc.zipper").foregroundStyle(.indigo)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title).font(.subheadline.weight(.semibold))
                                    Text("slug: \(entry.slug) • SHA-256: \(entry.bkbSha256.prefix(16))… • \(ByteCountFormatter.string(fromByteCount: entry.bkbSizeBytes, countStyle: .file))")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(backup.hasOfflineBook(slug: entry.slug) ? "✓ Đọc Offline" : "Thiếu output/")
                                    .font(.caption)
                                    .foregroundStyle(backup.hasOfflineBook(slug: entry.slug) ? .green : .orange)
                            }
                            .padding(10)
                            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
                        }
                    }
                }
            }
        }
    }

    private func chooseVaultDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Chọn thư mục lưu Backup Vault"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            backup.vaultURL = url
        }
    }

    private func formattedUnixTime(_ ts: Int?) -> String {
        guard let ts, ts > 0 else { return "Chưa có" }
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

private struct StatCardMac: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

