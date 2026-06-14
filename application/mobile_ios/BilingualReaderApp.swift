import SwiftUI

@main
struct BilingualReaderApp: App {
    @StateObject private var api = APIService.shared
    
    var body: some Scene {
        WindowGroup {
            if api.isAuthenticated {
                BookshelfView()
            } else {
                LoginView()
            }
        }
    }
}
