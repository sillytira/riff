import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var library: AudioLibrary
    let playlists: PlaylistStore
    @State private var editingTrack: LocalTrack?
    @State private var removingTrack: LocalTrack?
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
                if !library.importFailures.isEmpty {
                    Section("Import issues") {
                        ForEach(library.importFailures) { failure in
                            Label(failure.message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        }
                        Button("Dismiss import issues") { library.dismissImportFailures() }
                    }
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
                            Button("Edit song details", systemImage: "pencil") { editingTrack = track }
                            if let url = library.editableURL(for: track) {
                                ShareLink(item: library.originalURL(for: track) ?? url) { Label("Share audio", systemImage: "square.and.arrow.up") }
                                Button("Reload file tags", systemImage: "arrow.clockwise") {
                                    do { try library.rescanMetadata(track) } catch { library.error = error.localizedDescription }
                                }
                            }
                            Button("Remove download", systemImage: "trash", role: .destructive) { removingTrack = track }
                            Button(library.isFavorite(.local(track.id)) ? "Remove from Favorites" : "Add to Favorites", systemImage: "heart") { library.toggleFavorite(.local(track.id)) }
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if library.activeImports > 0 { ProgressView("Importing audio…").padding().background(.regularMaterial, in: .capsule).padding() }
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
            .sheet(item: $editingTrack) { track in TrackDetailsView(track: track, library: library) }
            .confirmationDialog("Remove this download?", isPresented: Binding(get: { removingTrack != nil }, set: { if !$0 { removingTrack = nil } }), titleVisibility: .visible) {
                if let track = removingTrack {
                    Button("Remove download", role: .destructive) {
                        do { try library.removeTracks([track.id], playlists: playlists) } catch { library.error = error.localizedDescription }
                        removingTrack = nil
                    }.accessibilityIdentifier("confirm-remove-download")
                }
            } message: {
                Text("Riff’s saved copy will be removed. Songs with a source link remain available online in your playlists and Favorites.")
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await library.importFiles(urls) }
                case .failure(let error): library.error = error.localizedDescription
                }
            }
        }
    }
}
