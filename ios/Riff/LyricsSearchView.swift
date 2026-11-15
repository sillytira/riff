import SwiftUI

struct LyricsSearchTarget: Identifiable {
    let id = UUID()
    let key: String
    let title: String
    let artist: String
    let duration: Double
}

struct LyricsSearchView: View {
    let target: LyricsSearchTarget
    let onSelect: (LyricsDocument) -> Void
    // The initial track values seed fields the user can edit for this search session.
    @State private var title: String
    @State private var artist: String
    @State private var results: [LyricsMatch] = []
    @State private var busy = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    init(target: LyricsSearchTarget, onSelect: @escaping (LyricsDocument) -> Void) {
        self.target = target
        self.onSelect = onSelect
        _title = State(initialValue: target.title)
        _artist = State(initialValue: target.artist)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Find a recording") {
                    TextField("Song title", text: $title)
                    TextField("Artist", text: $artist)
                    Button("Search") { search() }.disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    if busy { ProgressView() }
                    if let error { Text(error).foregroundStyle(.secondary) }
                }
                Section("Matches") {
                    ForEach(results) { match in
                        Button {
                            onSelect(LyricsMatching.document(match, duration: target.duration))
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(match.trackName).font(.headline).foregroundStyle(.primary)
                                Text(match.artistName).foregroundStyle(.secondary)
                                if let duration = match.duration { Text("\(Int(duration)) seconds").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search lyrics")
            .onDisappear { searchTask?.cancel() }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
    private func search() {
        busy = true
        error = nil
        searchTask?.cancel()
        let searchTitle = title, searchArtist = artist
        searchTask = Task {
            do {
                let found = try await LyricsService.shared.search(title: searchTitle, artist: searchArtist)
                guard !Task.isCancelled else { return }
                results = found
                if results.isEmpty { error = "No matches. Try a shorter title or a different artist." }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
