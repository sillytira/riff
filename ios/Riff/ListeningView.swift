import SwiftUI

struct ListeningView: View {
    let library: AudioLibrary
    let favorites: Bool
    @State private var clearHistory = false
    private var entries: [ListeningEntry] { favorites ? library.listening.favorites : library.listening.history }

    var body: some View {
        List(entries) { entry in
            Button {
                let queue = entries.map { PlaylistEntry(source: $0.source) }
                if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                    library.playPlaylist(queue, startingAt: queue[index].id)
                }
            } label: {
                HStack(spacing: 12) {
                    TrackArtwork(url: artwork(entry.source), size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(library.title(for: entry.source)).font(.headline)
                        Text(artist(entry.source)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.foregroundStyle(.primary)
            }
            .contextMenu {
                Button(library.listening.isFavorite(entry.source) ? "Remove from Favorites" : "Add to Favorites", systemImage: "heart") {
                    library.toggleFavorite(entry.source)
                }
            }
        }
        .navigationTitle(favorites ? "Favorites" : "Recently Played")
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(favorites ? "Your favorite music" : "Your listening history", systemImage: favorites ? "heart" : "clock", description: Text(favorites ? "Add songs to Favorites from the player or a song’s menu." : "Songs you play will appear here."))
            }
        }
        .toolbar {
            if !favorites && !entries.isEmpty { Button("Clear history", systemImage: "trash") { clearHistory = true } }
        }
        .confirmationDialog("Clear listening history?", isPresented: $clearHistory, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) {
                library.listening.clearHistory()
                if let error = library.listening.error { library.error = error }
            }
        }
    }
    private func artwork(_ source: PlaylistSource) -> String? {
        switch source {
        case .local(let id): library.tracks.first { $0.id == id }?.artworkURL
        case .online(let track): track.artworkURL
        }
    }
    private func artist(_ source: PlaylistSource) -> String {
        switch source {
        case .local(let id): library.tracks.first { $0.id == id }?.artist ?? ""
        case .online(let track): track.artist
        }
    }
}
