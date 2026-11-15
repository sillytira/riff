import SwiftUI
import UniformTypeIdentifiers

struct PlaylistsView: View {
    @Bindable var store: PlaylistStore
    let library: AudioLibrary
    @State private var newName = ""
    @State private var creating = false
    @State private var importURL = ""
    @State private var importing = false
    @State private var busy = false
    @State private var importingFile = false
    @State private var exportingFile = false
    @State private var exportDocument = PlaylistFileDocument(data: Data())
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.playlists) { playlist in
                    NavigationLink {
                        PlaylistDetailView(id: playlist.id, store: store, library: library)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playlist.name).font(.headline)
                                Text("\(playlist.entries.count) tracks").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "music.note.list").frame(width: 44, height: 44) }
                    }
                }.onDelete { offsets in store.delete(Set(offsets.compactMap { store.playlists.indices.contains($0) ? store.playlists[$0].id : nil })) }
            }
            .overlay {
                if busy { ProgressView("Importing playlist…") }
                else if store.playlists.isEmpty { ContentUnavailableView("Your collections", systemImage: "music.note.list", description: Text("Create a playlist or import a public playlist link.")) }
            }
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("New playlist", systemImage: "plus") { newName = ""; creating = true }
                        Button("Import public link", systemImage: "link") { importURL = ""; importing = true }
                        Button("Import playlist JSON", systemImage: "doc.badge.plus") { importingFile = true }
                        Button("Export all playlists", systemImage: "square.and.arrow.up") {
                            do {
                                exportDocument = PlaylistFileDocument(data: try PortablePlaylists.write(store.playlists, library: library))
                                exportingFile = true
                            } catch { store.error = error.localizedDescription }
                        }.disabled(store.playlists.isEmpty)
                    } label: { Label("Add playlist", systemImage: "plus") }
                }
            }
            .fileImporter(isPresented: $importingFile, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= PortablePlaylists.maximumBytes else { throw ExtractionError(message: "The playlist file is larger than 8 MB.") }
                    _ = try store.importFile(Data(contentsOf: url, options: .mappedIfSafe))
                } catch { store.error = error.localizedDescription }
            }
            .fileExporter(isPresented: $exportingFile, document: exportDocument, contentType: .json, defaultFilename: "riff-playlists") { result in
                if case .failure(let error) = result { store.error = error.localizedDescription }
            }
            .alert("New playlist", isPresented: $creating) {
                TextField("Name", text: $newName)
                Button("Create") { store.create(name: newName) }
                Button("Cancel", role: .cancel) { }
            }
            .alert("Import public playlist", isPresented: $importing) {
                TextField("Playlist URL", text: $importURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Import") { importPlaylist() }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Paste a public playlist URL from a supported provider.") }
            .alert("Playlist error", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
                Button("OK") { store.error = nil }
            } message: { Text(store.error ?? "") }
        }
    }
    private func importPlaylist() {
        let url = importURL
        busy = true
        Task {
            do {
                let playlist = try await MediaExtractor.shared.playlist(url)
                guard !playlist.tracks.isEmpty else { throw ExtractionError(message: "No public tracks were found in this playlist.") }
                store.create(name: playlist.title, entries: playlist.tracks.map { PlaylistEntry(source: .online($0)) })
            } catch { store.error = error.localizedDescription }
            busy = false
        }
    }
}

struct PlaylistDetailView: View {
    let id: UUID
    @Bindable var store: PlaylistStore
    let library: AudioLibrary
    @State private var adding = false
    @State private var renaming = false
    @State private var name = ""
    @State private var exporting = false
    @State private var exportDocument = PlaylistFileDocument(data: Data())
    private var playlist: SavedPlaylist? { store.playlists.first { $0.id == id } }
    var body: some View {
        List {
            if let playlist {
                ForEach(playlist.entries) { entry in
                    Button { library.playPlaylist(playlist.entries, startingAt: entry.id) } label: {
                        HStack {
                            Text(library.title(for: entry.source)).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "play.fill")
                        }.padding(.vertical, 8)
                    }
                }
                .onDelete { store.remove(from: id, offsets: $0) }
                .onMove { store.move(in: id, from: $0, to: $1) }
            }
        }
        .overlay {
            if playlist?.entries.isEmpty ?? true { ContentUnavailableView("Add some music", systemImage: "music.note", description: Text("Use Add tracks to choose music from your offline library.")) }
        }
        .navigationTitle(playlist?.name ?? "Playlist")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add tracks", systemImage: "plus") { adding = true }
                    Button("Rename", systemImage: "pencil") { name = playlist?.name ?? ""; renaming = true }
                    Button("Export as JSON", systemImage: "square.and.arrow.up") {
                        guard let playlist else { return }
                        do {
                            exportDocument = PlaylistFileDocument(data: try PortablePlaylists.write([playlist], library: library))
                            exporting = true
                        } catch { store.error = error.localizedDescription }
                    }
                } label: { Label("Playlist actions", systemImage: "ellipsis") }
            }
        }
        .sheet(isPresented: $adding) { AddPlaylistTracksView(id: id, store: store, library: library) }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "riff-playlist") { result in
            if case .failure(let error) = result { store.error = error.localizedDescription }
        }
        .alert("Rename playlist", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Save") { store.rename(id, to: name) }
            Button("Cancel", role: .cancel) { }
        }
    }
}

private struct AddPlaylistTracksView: View {
    let id: UUID
    let store: PlaylistStore
    let library: AudioLibrary
    @State private var selected: Set<UUID> = []
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(library.tracks) { track in
                Button {
                    if selected.contains(track.id) { selected.remove(track.id) } else { selected.insert(track.id) }
                } label: {
                    HStack {
                        Text(track.name).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: selected.contains(track.id) ? "checkmark.circle.fill" : "circle")
                    }
                }
            }
            .navigationTitle("Add tracks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        store.append(library.tracks.filter { selected.contains($0.id) }.map { PlaylistEntry(source: .local($0.id)) }, to: id)
                        dismiss()
                    }.disabled(selected.isEmpty)
                }
            }
        }
    }
}

struct QueueView: View {
    let library: AudioLibrary
    var body: some View {
        List {
            ForEach(library.playbackQueue.entries) { entry in
                Button { library.playPlaylist(library.playbackQueue.entries, startingAt: entry.id) } label: {
                    HStack {
                        Text(library.title(for: entry.source)).foregroundStyle(.primary)
                        Spacer()
                        if entry.id == library.playbackQueue.currentID { Image(systemName: "waveform") }
                    }
                }
            }.onDelete { library.removeQueue(offsets: $0) }
                .onMove { library.moveQueue(from: $0, to: $1) }
        }
        .navigationTitle("Up Next")
        .toolbar { EditButton() }
    }
}
