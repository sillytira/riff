import SwiftUI

struct CodecLicensesView: View {
    private let entries = [("FFmpeg", "FFmpeg-LGPL-2.1"), ("LAME", "LAME-LGPL"), ("Opus", "Opus-BSD")]
    var body: some View {
        List(entries, id: \.1) { entry in
            NavigationLink(entry.0) { CodecLicenseText(name: entry.0, resource: entry.1) }
        }.navigationTitle("Audio codec licenses")
    }
}

private struct CodecLicenseText: View {
    let name: String
    let resource: String
    @State private var text = ""
    var body: some View {
        ScrollView { Text(text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
            .navigationTitle(name)
            .task {
                do {
                    guard let url = Bundle.main.url(forResource: resource, withExtension: "txt", subdirectory: "Licenses") else { throw CocoaError(.fileNoSuchFile) }
                    text = try String(contentsOf: url, encoding: .utf8)
                } catch { text = "Could not open this license: " + error.localizedDescription }
            }
    }
}
