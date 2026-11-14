import SwiftUI
import UniformTypeIdentifiers

struct LyricsView: View {
    let library: AudioLibrary
    @State private var document: LyricsDocument?
    @State private var error: String?
    @State private var loading = true
    @State private var importing = false
    @AppStorage("lyricsOffset") private var offset = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack {
            if let document {
                if document.lines.isEmpty {
                    ScrollView { Text(document.plainText).font(.title2).frame(maxWidth: .infinity, alignment: .leading).padding() }
                } else {
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        let active = document.activeLine(at: library.elapsed + offset)
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 24) {
                                    ForEach(document.lines) { line in
                                        Button { library.seek(to: line.time - offset) } label: {
                                            Text(line.text.isEmpty ? "♪" : line.text).font(.title2.bold())
                                                .foregroundStyle(line.id == active ? .primary : .secondary)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }.buttonStyle(.plain).id(line.id)
                                    }
                                }.padding()
                            }
                            .onChange(of: active) {
                                guard let active else { return }
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(active, anchor: .center) }
                            }
                        }
                    }
                    HStack {
                        Button("Earlier", systemImage: "minus") { offset -= 0.5 }
                        Text(String(format: "%+.1fs", offset)).monospacedDigit().accessibilityLabel("Lyrics offset \(offset) seconds")
                        Button("Later", systemImage: "plus") { offset += 0.5 }
                    }.buttonStyle(.bordered).padding()
                }
            } else if loading { ProgressView("Finding lyrics…") }
            else { ContentUnavailableView("Lyrics", systemImage: "quote.bubble", description: Text(error ?? "Import an LRC or text file.")) }
        }
        .navigationTitle("Lyrics")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Import lyrics", systemImage: "square.and.arrow.down") { importing = true } } }
        .task(id: library.playingTitle) {
            loading = true
            error = nil
            document = nil
            do {
                document = try await LyricsService.shared.lookup(title: library.playingTitle ?? "", artist: library.playingArtist, duration: library.duration)
            } catch { self.error = error.localizedDescription }
            loading = false
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, UTType(filenameExtension: "lrc") ?? .plainText]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                document = .parse(try String(contentsOf: url, encoding: .utf8))
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
