import SwiftUI

struct ContentView: View {
    @ObservedObject private var api = APIService.shared
    @ObservedObject private var backup = BackupManager.shared

    @State private var activeBook: Book?
    @State private var showSettings: Bool = false
    @State private var settingsInitialTab: SettingsTab = .general
    @State private var restorePreselectedSnapshot: LocalSnapshotRecord?
    @State private var didAttemptLaunchSync: Bool = false

    var body: some View {
        ZStack {
            Color(hex: "0f172a").ignoresSafeArea()

            if api.isVerifyingSession {
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                    Text("Đang mở Tủ sách Song ngữ…")
                        .font(.subheadline)
                        .foregroundStyle(Color(hex: "94a3b8"))
                }
                .transition(.opacity)
            } else if !api.isAuthenticated {
                LoginView()
                    .transition(.opacity)
            } else if let book = activeBook {
                ReaderViewMac(book: book) {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        activeBook = nil
                    }
                    NotificationCenter.default.post(name: NSNotification.Name("ReadingProgressUpdated"), object: nil)
                }
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.96).combined(with: .opacity),
                        removal: .scale(scale: 1.02).combined(with: .opacity)
                    )
                )
            } else {
                LibraryView(
                    onOpenBook: { book in
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                            activeBook = book
                        }
                    },
                    onOpenSettings: { tab in
                        settingsInitialTab = tab
                        showSettings = true
                    }
                )
                .transition(.opacity)
                .task(id: api.isAuthenticated) {
                    await triggerLaunchSyncIfNeeded()
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: api.isVerifyingSession)
        .animation(.easeInOut(duration: 0.25), value: api.isAuthenticated)
        .frame(minWidth: 960, minHeight: 660)
        .sheet(isPresented: $showSettings) {
            SettingsViewMac(
                initialTab: settingsInitialTab,
                preselectedSnapshot: $restorePreselectedSnapshot
            )
            .preferredColorScheme(.dark)
        }
    }

    private func triggerLaunchSyncIfNeeded() async {
        guard !didAttemptLaunchSync,
              api.isAuthenticated,
              !api.isOfflineMode,
              backup.syncOnLaunch else {
            return
        }
        didAttemptLaunchSync = true
        await backup.syncFromServer()
    }
}
