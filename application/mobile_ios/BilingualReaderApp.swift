import SwiftUI

@main
struct BilingualReaderApp: App {
    @StateObject private var api = APIService.shared
    
    var body: some Scene {
        WindowGroup {
            if api.isVerifyingSession {
                // Show a loading screen while verifying session with server
                ZStack {
                    Color(hex: "0f172a").ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "6366f1")))
                            .scaleEffect(1.2)
                        Text("Đang xác thực phiên...")
                            .font(.subheadline)
                            .foregroundColor(Color(hex: "94a3b8"))
                    }
                }
            } else if api.isAuthenticated {
                BookshelfView()
            } else {
                LoginView()
            }
        }
    }
}
