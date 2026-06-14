import SwiftUI
import WebKit

struct AdminPortalView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var api = APIService.shared
    @State private var isLoading = true
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(hex: "0f172a").ignoresSafeArea()
                
                AdminWebView(urlString: "\(api.serverUrl)/admin", token: api.token, isLoading: $isLoading)
                    .edgesIgnoringSafeArea(.bottom)
                
                if isLoading {
                    ProgressView("Đang tải Admin Portal...")
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .foregroundColor(.white)
                        .scaleEffect(1.5)
                }
            }
            .navigationTitle("Admin Portal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Đóng") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct AdminWebView: UIViewRepresentable {
    let urlString: String
    let token: String
    @Binding var isLoading: Bool
    
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let contentController = WKUserContentController()
        
        // Inject Admin Token into LocalStorage at document start
        let scriptSource = """
        localStorage.setItem('bilingual.admin.token', '\(token)');
        localStorage.setItem('bilingual.reader.token', '\(token)');
        localStorage.setItem('bilingual.reader.isAdmin', 'true');
        """
        let userScript = WKUserScript(source: scriptSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        contentController.addUserScript(userScript)
        
        configuration.userContentController = contentController
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        
        #if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif
        
        return webView
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if let url = URL(string: urlString) {
            let request = URLRequest(url: url)
            if uiView.url != url {
                uiView.load(request)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: AdminWebView
        
        init(_ parent: AdminWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}
