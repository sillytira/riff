import SwiftUI
import UniformTypeIdentifiers

struct LyricsView: View {
    let library: AudioLibrary
    @State private var document: LyricsDocument?
    @State private var error: String?
    @State private var loading = true
    @State private var importing = false
    @State private var importKey: String?
    @State private var lookupID = UUID()
    @State private var offset = 0.0
    @State private var searchTarget: LyricsSearchTarget?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private struct Request: Hashable { let key: String?; let title: String; let artist: String }

    var body: some View {
        VStack(spacing: 0) {
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
                if let source = document.source { Text(source).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                if !document.timingMatches { Text("These lyrics are from a different recording; timing may differ.").font(.caption).foregroundStyle(.secondary).padding() }
                if let error { Text(error).font(.caption).foregroundStyle(.secondary).padding() }
            } else if loading { ProgressView("Finding lyrics…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                ContentUnavailableView {
                    Label("Lyrics", systemImage: "quote.bubble")
                } description: {
                    Text(error ?? "Search for a recording or import an LRC file.")
                } actions: {
                    Button("Search lyrics") { openSearch() }.buttonStyle(.borderedProminent)
                    Button("Import LRC") { openImport() }.buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle("Lyrics")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Search lyrics", systemImage: "magnifyingglass") { openSearch() }
                    Button("Import LRC or text", systemImage: "square.and.arrow.down") { openImport() }
                    Button("Find online lyrics", systemImage: "arrow.clockwise") { Task { await load(force: true) } }
                } label: { Label("Lyrics options", systemImage: "ellipsis") }
            }
        }
        .task(id: Request(key: library.lyricsKey, title: library.playingTitle ?? "", artist: library.playingArtist)) { await load() }
        .onChange(of: offset) {
            guard document != nil, let key = library.lyricsKey else { return }
            let value = offset
            Task { try? await LyricsStore.shared.setOffset(value, key: key) }
        }
        .sheet(item: $searchTarget) { target in
            LyricsSearchView(target: target) { selected in save(selected, key: target.key) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, UTType(filenameExtension: "lrc") ?? .plainText]) { result in
            do {
                guard let key = importKey else { return }
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                var imported = LyricsDocument.parse(try String(contentsOf: url, encoding: .utf8))
                imported.source = "Imported lyrics"
                save(imported, key: key)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func openSearch() {
        guard let key = library.lyricsKey else { return }
        searchTarget = LyricsSearchTarget(key: key, title: library.playingTitle ?? "", artist: library.playingArtist, duration: library.duration)
    }
    private func openImport() {
        importKey = library.lyricsKey
        importing = importKey != nil
    }
    private func save(_ selected: LyricsDocument, key: String) {
        lookupID = UUID()
        Task {
            do { try await LyricsStore.shared.save(selected, key: key) }
            catch { self.error = "Lyrics could not be saved on this device." }
            guard library.lyricsKey == key else { return }
            document = selected
            offset = 0
            loading = false
        }
    }
    private func load(force: Bool = false) async {
        guard let key = library.lyricsKey else { loading = false; return }
        let id = UUID()
        lookupID = id
        loading = true
        error = nil
        document = nil
        offset = 0
        do {
            if !force, let stored = try? await LyricsStore.shared.read(key) {
                guard !Task.isCancelled, lookupID == id else { return }
                document = stored.document
                offset = stored.offset.isFinite ? stored.offset : 0
                loading = false
                return
            }
            let found = try await LyricsService.shared.lookup(title: library.playingTitle ?? "", artist: library.playingArtist, duration: library.duration)
            guard !Task.isCancelled, lookupID == id, library.lyricsKey == key else { return }
            try? await LyricsStore.shared.save(found, key: key)
            document = found
        } catch {
            guard !Task.isCancelled, lookupID == id else { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
}
