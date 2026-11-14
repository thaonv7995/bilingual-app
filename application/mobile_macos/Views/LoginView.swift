import SwiftUI

struct LoginView: View {
    @ObservedObject private var api = APIService.shared
    @ObservedObject private var backup = BackupManager.shared

    @State private var serverUrl: String = APIService.shared.serverUrl
    @State private var username: String = UserDefaults.standard.string(forKey: "savedUsername") ?? ""
    @State private var password: String = ""
    @State private var rememberMe: Bool = UserDefaults.standard.bool(forKey: "isRememberMe")
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    private let keychainPasswordKey = "bilingual.savedPassword"

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "0f172a"), Color(hex: "1e1b4b"), Color(hex: "0f172a")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 26) {
                VStack(spacing: 10) {
                    Image(systemName: "book.closed.circle.fill")
                        .resizable()
                        .frame(width: 72, height: 72)
                        .foregroundStyle(Color(hex: "6366f1"))
                        .shadow(color: Color(hex: "6366f1").opacity(0.35), radius: 14, x: 0, y: 8)

                    Text("Bilingual Reader")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Đọc sách song ngữ tinh gọn trên macOS")
                        .font(.subheadline)
                        .foregroundStyle(Color(hex: "94a3b8"))
                }

                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Địa chỉ Server")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color(hex: "94a3b8"))
                        TextField("https://book.thaonv.online", text: $serverUrl)
                            .textFieldStyle(.plain)
                            .padding(11)
                            .background(Color(hex: "0f172a"))
                            .cornerRadius(10)
                            .foregroundStyle(.white)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "334155"), lineWidth: 1))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tài khoản")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color(hex: "94a3b8"))
                        TextField("username", text: $username)
                            .textFieldStyle(.plain)
                            .padding(11)
                            .background(Color(hex: "0f172a"))
                            .cornerRadius(10)
                            .foregroundStyle(.white)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "334155"), lineWidth: 1))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mật khẩu")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color(hex: "94a3b8"))
                        SecureField("••••••••", text: $password)
                            .textFieldStyle(.plain)
                            .padding(11)
                            .background(Color(hex: "0f172a"))
                            .cornerRadius(10)
                            .foregroundStyle(.white)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "334155"), lineWidth: 1))
                            .onSubmit { performLogin() }
                    }

                    Button {
                        rememberMe.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: rememberMe ? "checkmark.square.fill" : "square")
                                .foregroundStyle(rememberMe ? Color(hex: "6366f1") : Color(hex: "94a3b8"))
                                .font(.system(size: 16))
                            Text("Lưu thông tin đăng nhập")
                                .font(.subheadline)
                                .foregroundStyle(Color(hex: "94a3b8"))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.macInteractive(cornerRadius: 6))

                    if let err = errorMessage {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(Color(hex: "f87171"))
                    }

                    Button {
                        performLogin()
                    } label: {
                        HStack(spacing: 8) {
                            if isLoading { ProgressView().controlSize(.small).tint(.white) }
                            Text(isLoading ? "Đang kết nối…" : "Đăng nhập")
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(hex: "6366f1"))
                        .foregroundStyle(.white)
                        .cornerRadius(10)
                        .shadow(color: Color(hex: "6366f1").opacity(0.35), radius: 10, x: 0, y: 5)
                    }
                    .buttonStyle(.macInteractive(cornerRadius: 10))
                    .disabled(isLoading || serverUrl.isEmpty || username.isEmpty || password.isEmpty)

                    if let snap = backup.latestSnapshot {
                        Divider().background(Color.white.opacity(0.1)).padding(.vertical, 2)
                        Button {
                            api.enterOfflineVaultSession(
                                username: snap.exportedBy,
                                isAdmin: snap.scope == BackupScope.adminFull.rawValue
                            )
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "externaldrive.fill.badge.checkmark")
                                    .foregroundStyle(Color(hex: "2dd4bf"))
                                Text("Đọc ngoại tuyến từ Backup (\(snap.books.count) sách)")
                                    .font(.subheadline.weight(.medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.06))
                            .foregroundStyle(.white)
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1), lineWidth: 1))
                        }
                        .buttonStyle(.macInteractive(cornerRadius: 10))
                    }
                }
                .padding(24)
                .frame(width: 420)
                .background(Color(hex: "1e293b").opacity(0.82))
                .cornerRadius(20)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.07), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.35), radius: 22, x: 0, y: 12)
            }
            .padding(40)
        }
        .onAppear {
            if rememberMe, password.isEmpty {
                password = KeychainHelper.standard.get(forKey: keychainPasswordKey) ?? ""
            }
        }
    }

    private func performLogin() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                try await api.login(url: serverUrl, username: username, password: password)
                await MainActor.run {
                    UserDefaults.standard.set(rememberMe, forKey: "isRememberMe")
                    if rememberMe {
                        UserDefaults.standard.set(username, forKey: "savedUsername")
                        KeychainHelper.standard.save(password, forKey: keychainPasswordKey)
                    } else {
                        UserDefaults.standard.removeObject(forKey: "savedUsername")
                        KeychainHelper.standard.delete(forKey: keychainPasswordKey)
                    }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
