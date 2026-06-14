import SwiftUI

struct LoginView: View {
    @StateObject private var api = APIService.shared
    @State private var usernameInput = ""
    @State private var passwordInput = ""
    @State private var isLoading = false
    @State private var errorMessage = ""
    
    var body: some View {
        ZStack {
            // Elegant background gradient
            LinearGradient(gradient: Gradient(colors: [Color(hex: "0f172a"), Color(hex: "1e1b4b"), Color(hex: "0f172a")]),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            
            VStack(spacing: 30) {
                Spacer()
                
                // Logo & Header
                VStack(spacing: 12) {
                    Image(systemName: "book.closed.circle.fill")
                        .resizable()
                        .frame(width: 80, height: 80)
                        .foregroundColor(Color(hex: "6366f1"))
                        .shadow(color: Color(hex: "6366f1").opacity(0.3), radius: 15, x: 0, y: 10)
                    
                    Text("Bilingual Reader")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    Text("Đọc sách song ngữ đỉnh cao trên iOS")
                        .font(.subheadline)
                        .foregroundColor(Color(hex: "94a3b8"))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                
                // Form Container
                VStack(spacing: 18) {
                    // Server URL Input
                    VStack(alignment: .leading, spacing: 6) {
                        Text("IP Server")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(Color(hex: "94a3b8"))
                        
                        TextField("http://localhost:27099", text: $api.serverUrl)
                            .padding()
                            .background(Color(hex: "0f172a"))
                            .cornerRadius(10)
                            .foregroundColor(.white)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "334155"), lineWidth: 1))
                    }
                    
                    // Username Input
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tài khoản")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(Color(hex: "94a3b8"))
                        
                        TextField("username", text: $usernameInput)
                            .padding()
                            .background(Color(hex: "0f172a"))
                            .cornerRadius(10)
                            .foregroundColor(.white)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "334155"), lineWidth: 1))
                    }
                    
                    // Password Input
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mật khẩu")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundColor(Color(hex: "94a3b8"))
                        
                        SecureField("••••••••", text: $passwordInput)
                            .padding()
                            .background(Color(hex: "0f172a"))
                            .cornerRadius(10)
                            .foregroundColor(.white)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "334155"), lineWidth: 1))
                    }
                    
                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .padding(.top, 5)
                    }
                    
                    // Login Button
                    Button(action: {
                        performLogin()
                    }) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .padding(.trailing, 10)
                            }
                            Text("Đăng Nhập")
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(hex: "6366f1"))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .shadow(color: Color(hex: "6366f1").opacity(0.4), radius: 10, x: 0, y: 5)
                    }
                    .disabled(isLoading)
                    .padding(.top, 10)
                }
                .padding(24)
                .background(Color(hex: "1e293b").opacity(0.8))
                .cornerRadius(20)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.05), lineWidth: 1))
                .padding(.horizontal, 20)
                .shadow(color: Color.black.opacity(0.3), radius: 20, x: 0, y: 10)
                
                Spacer()
            }
        }
    }
    
    private func performLogin() {
        guard !usernameInput.isEmpty && !passwordInput.isEmpty else {
            errorMessage = "Vui lòng điền đầy đủ tài khoản và mật khẩu."
            return
        }
        
        isLoading = true
        errorMessage = ""
        
        Task {
            do {
                _ = try await api.login(usernameInput: usernameInput, passwordInput: passwordInput)
                await MainActor.run {
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

// Color Hex Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
