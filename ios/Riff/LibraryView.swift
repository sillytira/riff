import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var library: AudioLibrary
    @State private var importing = false
    @State private var query = ""

    private var matches: [LocalTrack] {
        query.isEmpty ? library.tracks : library.tracks.filter {
            $0.name.localizedStandardContains(query) || ($0.artist?.localizedStandardContains(query) ?? false) || ($0.album?.localizedStandardContains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { ListeningView(library: library, favorites: true) } label: { Label("Favorites", systemImage: "heart") }
                    NavigationLink { ListeningView(library: library, favorites: false) } label: { Label("Recently Played", systemImage: "clock") }
                }
                Section("Songs") {
                    if library.tracks.isEmpty {
                        ContentUnavailableView {
                            Label("Your music, with you", systemImage: "music.note.house")
                        } description: {
                            Text("Import audio from Files to start your offline library.")
                        } actions: {
                            Button("Import audio") { importing = true }.buttonStyle(.borderedProminent)
                        }.listRowBackground(Color.clear)
                    } else if matches.isEmpty {
                        ContentUnavailableView.search(text: query).listRowBackground(Color.clear)
                    }
                    ForEach(matches) { track in
                        Button { library.play(track) } label: {
                            HStack(spacing: 16) {
                                TrackArtwork(url: track.artworkURL, size: 52)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(track.name).font(.headline).foregroundStyle(.primary)
                                    if let artist = track.artist, !artist.isEmpty { Text(artist).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Image(systemName: "play.fill").foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .task(id: track.id) { library.prepareArtwork(for: track) }
                        .accessibilityIdentifier("local-track-" + track.id.uuidString)
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button(library.listening.isFavorite(.local(track.id)) ? "Remove from Favorites" : "Add to Favorites", systemImage: "heart") { library.toggleFavorite(.local(track.id)) }
                        }
                    }
                }
            }
            .navigationTitle("Riff")
            .searchable(text: $query, prompt: "Search your music")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import audio", systemImage: "plus") { importing = true }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): library.importFiles(urls)
                case .failure(let error): library.error = error.localizedDescription
                }
            }
        }
    }
}
