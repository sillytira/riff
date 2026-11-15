import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @State private var signedIn = false
    @State private var sessionStored = false
    @State private var signingIn = false
    @State private var importingCookies = false
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                LabeledContent("YouTube", value: signedIn ? "Sign-in saved" : (sessionStored ? "Sign-in expired" : "Not signed in"))
                Button("Sign in to YouTube") { signingIn = true }
                Button("Import browser cookies") { importingCookies = true }
                if sessionStored {
                    Button("Sign out", role: .destructive) {
                        do {
                            try YouTubeCredentials.delete()
                            signedIn = false
                            sessionStored = false
                            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { }
                        } catch { self.error = error.localizedDescription }
                    }
                }
            } header: { Text("Accounts") } footer: {
                Text("Sign in if YouTube asks for verification. Your sign-in is saved securely and used for YouTube requests.")
            }
            Section("About") {
                LabeledContent("Riff", value: version)
                NavigationLink("Audio codec licenses") { CodecLicensesView() }
                Link("Source code", destination: URL(string: "https://github.com/sillytira/riff")!)
            }
        }
        .navigationTitle("Settings")
        .onAppear { refresh() }
        .sheet(isPresented: $signingIn) { YouTubeLoginView { refresh() } }
        .fileImporter(isPresented: $importingCookies, allowedContentTypes: [.plainText]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try YouTubeCredentials.save(CookieFile.filtered(Data(contentsOf: url)))
                refresh()
            } catch { self.error = error.localizedDescription }
        }
        .alert("Account error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return (info["CFBundleShortVersionString"] as? String ?? "Development") + " (" + (info["CFBundleVersion"] as? String ?? "1") + ")"
    }
    private func refresh() {
        let data = try? YouTubeCredentials.read()
        sessionStored = data != nil
        signedIn = data.map { CookieFile.hasYouTubeLogin($0) } ?? false
    }
}
