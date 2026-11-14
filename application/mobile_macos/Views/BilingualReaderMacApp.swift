import SwiftUI

@main
struct BilingualReaderMacApp: App {
    @StateObject private var api = APIService.shared
    @StateObject private var backup = BackupManager.shared

    var body: some Scene {
        WindowGroup("Bilingual Reader") {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 840)

        MenuBarExtra {
            VStack(alignment: .leading, spacing: 6) {
                Text("Bilingual Reader").font(.headline)
                Text(api.isOfflineMode ? "Trạng thái: Ngoại tuyến" : "Server: Đang kết nối")
                    .font(.caption)
                Text("Vault: \(backup.vaultIndex.booksBySlug.count) sách • \(backup.snapshots.count) snapshots")
                    .font(.caption)
                if let ts = backup.vaultIndex.lastSyncAt {
                    Text("Sync cuối: \(formattedTime(ts))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Divider()
                Button(backup.isSyncing ? "Đang đồng bộ…" : "Sync Backup từ Server ngay") {
                    Task { await backup.syncFromServer() }
                }
                .disabled(backup.isSyncing || !api.isAuthenticated)
                Button("Mở thư mục Backup trong Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([backup.vaultURL])
                }
                Divider()
                Button("Thoát") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(6)
        } label: {
            Image(systemName: backup.isSyncing ? "arrow.triangle.2.circlepath" : (backup.wipeGuardTriggered ? "exclamationmark.triangle" : "books.vertical"))
        }
    }

    private func formattedTime(_ ts: Int) -> String {
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return df.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}
