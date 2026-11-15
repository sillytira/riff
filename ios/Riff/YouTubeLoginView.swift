import SwiftUI
import WebKit

struct YouTubeLoginView: View {
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Group {
                if #available(iOS 26, *) { ModernYouTubeLoginPage() }
                else { LegacyYouTubeLoginPage() }
            }
            .navigationTitle("YouTube sign-in").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save sign-in") { save() }.disabled(saving) }
            }
            .alert("Sign-in", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    private func save() {
        saving = true
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            let result = Result { try CookieFile.fromBrowser(cookies) }
            Task { @MainActor in
                do {
                    try YouTubeCredentials.save(result.get())
                    onSaved()
                    dismiss()
                } catch { self.error = error.localizedDescription }
                saving = false
            }
        }
    }
}

private let youtubeSignInURL = URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F")!

@available(iOS 26, *)
private struct ModernYouTubeLoginPage: View {
    @State private var page: WebPage
    init() {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .default()
        _page = State(initialValue: WebPage(configuration: configuration))
    }
    var body: some View {
        WebView(page).task { _ = page.load(youtubeSignInURL) }
    }
}

private struct LegacyYouTubeLoginPage: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: youtubeSignInURL))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}
