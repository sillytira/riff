import SwiftUI

struct RootView: View {
    let library: AudioLibrary
    @State private var downloads = DownloadManager()
    @State private var showPlayer = false

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                tabs.tabViewBottomAccessory {
                    if library.playingTitle != nil { miniPlayer }
                }
            } else {
                tabs.safeAreaInset(edge: .bottom) {
                    if library.playingTitle != nil { miniPlayer.background(.regularMaterial) }
                }
            }
        }
        .sheet(isPresented: $showPlayer) { NowPlayingView(library: library, downloads: downloads) }
        .alert("Playback error", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK") { library.error = nil }
        } message: { Text(library.error ?? "") }
    }

    private var tabs: some View {
        TabView {
            Tab("Library", systemImage: "music.note.house") { LibraryView(library: library) }
            Tab("Discover", systemImage: "magnifyingglass") { SearchView(library: library, downloads: downloads) }
            Tab("Downloads", systemImage: "arrow.down.circle") { DownloadsView(downloads: downloads) }
        }
    }

    private var miniPlayer: some View {
        HStack(spacing: 12) {
            Button { showPlayer = true } label: {
                HStack(spacing: 12) {
                    TrackArtwork(url: library.current?.artworkURL ?? library.onlineCurrent?.artworkURL, size: 40)
                    VStack(alignment: .leading) {
                        Text(library.playingTitle ?? "Riff").font(.headline).lineLimit(1)
                        Text(library.playingArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.foregroundStyle(.primary)
            }.buttonStyle(.plain)
            if library.isLoading { ProgressView() }
            else {
                Button(library.isPlaying ? "Pause" : "Play", systemImage: library.isPlaying ? "pause.fill" : "play.fill") {
                    library.togglePlayback()
                }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            }
        }.padding(.horizontal).padding(.vertical, 8)
    }
}

struct DownloadsView: View {
    let downloads: DownloadManager
    var body: some View {
        NavigationStack {
            List(downloads.jobs) { job in
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(job.track.title).font(.headline)
                        Text(job.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if job.isActive {
                        Button("Cancel", systemImage: "xmark.circle") { downloads.cancel(job.id) }.labelStyle(.iconOnly)
                    } else if job.status == "Saved offline" {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Saved offline")
                    }
                }
            }
            .overlay {
                if downloads.jobs.isEmpty {
                    ContentUnavailableView("Your offline collection", systemImage: "arrow.down.circle", description: Text("Download tracks from Discover to listen without a connection."))
                }
            }
            .navigationTitle("Downloads")
        }
    }
}

struct NowPlayingView: View {
    let library: AudioLibrary
    let downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    TrackArtwork(url: library.current?.artworkURL ?? library.onlineCurrent?.artworkURL, size: 280)
                        .padding(.top, 20)
                    VStack(spacing: 8) {
                        Text(library.playingTitle ?? "Riff").font(.title2.bold()).multilineTextAlignment(.center)
                        Text(library.playingArtist).foregroundStyle(.secondary)
                    }
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        VStack {
                            Slider(value: Binding(get: { min(max(0, library.elapsed), max(1, library.duration)) }, set: { library.seek(to: $0) }), in: 0...max(1, library.duration))
                                .disabled(library.duration == 0).accessibilityLabel("Playback position")
                            HStack {
                                Text(time(library.elapsed))
                                Spacer()
                                Text(time(library.duration))
                            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 32) {
                        Button("Back 15 seconds", systemImage: "gobackward.15") { library.seek(to: library.elapsed - 15) }
                        Button(library.isPlaying ? "Pause" : "Play", systemImage: library.isPlaying ? "pause.circle.fill" : "play.circle.fill") {
                            library.togglePlayback()
                        }.font(.system(size: 64))
                        Button("Forward 15 seconds", systemImage: "goforward.15") { library.seek(to: library.elapsed + 15) }
                    }.font(.title).labelStyle(.iconOnly)
                    if let track = library.onlineCurrent {
                        Button("Save offline", systemImage: "arrow.down.circle") { downloads.download(track, into: library) }
                            .buttonStyle(.bordered)
                    }
                }.padding()
            }
            .navigationTitle("Now Playing").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close", systemImage: "chevron.down") { dismiss() } } }
        }
    }
    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
