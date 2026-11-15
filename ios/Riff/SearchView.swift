import SwiftUI
import UIKit

struct SearchView: View {
    let library: AudioLibrary
    let downloads: DownloadManager
    @State private var query = ""
    @State private var provider = "youtube"
    @State private var results: [OnlineTrack] = []
    @State private var loading = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchID = UUID()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Music provider", selection: $provider) {
                    Text("YT Music").tag("ytmusic").accessibilityLabel("YouTube Music")
                    Text("YouTube").tag("youtube")
                    Text("SoundCloud").tag("soundcloud")
                }.pickerStyle(.segmented).padding()
                List(results) { track in
                    HStack(spacing: 12) {
                        Button { Task { await library.playOnline(track, queue: results) } } label: {
                            HStack(spacing: 12) {
                                TrackArtwork(url: track.artworkURL, size: 52)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(track.title).font(.headline).lineLimit(2)
                                    Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }.foregroundStyle(.primary)
                        }.buttonStyle(.plain)
                        Button("Download", systemImage: "arrow.down.circle") { downloads.download(track, into: library) }
                            .buttonStyle(.borderless).labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }.listRowBackground(Color.clear)
                    .contextMenu {
                        Button(library.listening.isFavorite(.online(track)) ? "Remove from Favorites" : "Add to Favorites", systemImage: "heart") { library.toggleFavorite(.online(track)) }
                    }
                }
                .overlay {
                    if loading { ProgressView("Searching…") }
                    else if let error {
                        ContentUnavailableView { Label("Search unavailable", systemImage: "wifi.exclamationmark") }
                            description: { Text(error) }
                            actions: { Button("Try again") { search() } }
                    } else if results.isEmpty {
                        ContentUnavailableView("Find your next favorite", systemImage: "magnifyingglass", description: Text("Search for music or paste a public track URL."))
                    }
                }
            }
            .navigationTitle("Discover")
            .searchable(text: $query, prompt: "Songs, artists, or a track URL")
            .onSubmit(of: .search) { search() }
            .onChange(of: provider) { if !query.isEmpty { search() } }
        }
    }

    private func search() {
        searchTask?.cancel()
        let id = UUID()
        searchID = id
        loading = true
        error = nil
        results = []
        let term = query
        let source = provider
        searchTask = Task {
            do {
                let tracks = try await MediaExtractor.shared.search(term, provider: source)
                guard !Task.isCancelled, searchID == id else { return }
                results = tracks
            } catch {
                guard !Task.isCancelled, searchID == id else { return }
                self.error = error.localizedDescription
            }
            if searchID == id { loading = false }
        }
    }
}

struct TrackArtwork: View {
    let url: String?
    let size: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var imageData: Data?
    private struct Request: Hashable { let url: String?; let pixels: Int }
    var body: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.purple.opacity(0.7), .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: size * 0.3)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: min(24, size * 0.18)))
        .accessibilityHidden(true)
        .task(id: Request(url: url, pixels: Int(size * displayScale))) {
            imageData = nil
            guard let url else { return }
            let data = try? await ArtworkCache.shared.imageData(for: url, pixelSize: Int(size * displayScale))
            guard !Task.isCancelled else { return }
            imageData = data
        }
    }
}
