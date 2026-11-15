import SwiftUI

struct RootView: View {
    let library: AudioLibrary
    let playlists: PlaylistStore
    let downloads: DownloadManager
    @State private var showPlayer = false

    var body: some View {
        Group {
            if #available(iOS 26.1, *) {
                tabs.tabViewBottomAccessory(isEnabled: library.playingTitle != nil) { miniPlayer }
            } else if #available(iOS 26, *) {
                tabs.safeAreaInset(edge: .bottom) {
                    if library.playingTitle != nil { miniPlayer.glassEffect(.regular, in: .capsule).padding(.horizontal) }
                }
            } else {
                tabs.safeAreaInset(edge: .bottom) {
                    if library.playingTitle != nil { miniPlayer.background(.regularMaterial) }
                }
            }
        }
        .sheet(isPresented: $showPlayer) { NowPlayingView(library: library, downloads: downloads) }
        .alert("Riff", isPresented: Binding(get: { library.error != nil || downloads.error != nil }, set: { if !$0 { library.error = nil; downloads.error = nil } })) {
            Button("OK") { library.error = nil; downloads.error = nil }
        } message: { Text(library.error ?? downloads.error ?? "") }
    }

    private var tabs: some View {
        TabView {
            Tab("Library", systemImage: "music.note.house") { LibraryView(library: library, playlists: playlists) }
            Tab("Playlists", systemImage: "music.note.list") { PlaylistsView(store: playlists, library: library) }
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
            }.buttonStyle(.plain).accessibilityIdentifier("now-playing-open")
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
    @State private var clearing = false
    var body: some View {
        NavigationStack {
            List(downloads.jobs) { job in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(job.track.title).font(.headline)
                            Text(job.status).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if [.queued, .resolving, .downloading].contains(job.state) {
                            Button("Pause download", systemImage: "pause.circle") { downloads.pause(job.id) }.labelStyle(.iconOnly)
                            Button("Cancel", systemImage: "xmark.circle") { downloads.cancel(job.id) }.labelStyle(.iconOnly)
                        } else if [.paused, .failed, .cancelled].contains(job.state) {
                            Button(job.state == .paused ? "Resume download" : "Retry download", systemImage: "arrow.clockwise.circle") { downloads.resume(job.id) }.labelStyle(.iconOnly)
                            if job.state == .paused { Button("Cancel", systemImage: "xmark.circle") { downloads.cancel(job.id) }.labelStyle(.iconOnly) }
                        } else if job.state == .importing { ProgressView() }
                        else if job.state == .saved { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Saved offline") }
                    }
                    if job.state == .downloading || job.state == .paused {
                        ProgressView(value: job.progress).accessibilityLabel("Download progress")
                        if job.expected > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: job.received, countStyle: .file) + " of " + ByteCountFormatter.string(fromByteCount: job.expected, countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }.buttonStyle(.borderless)
            }
            .overlay {
                if downloads.jobs.isEmpty {
                    ContentUnavailableView("Your offline collection", systemImage: "arrow.down.circle", description: Text("Download tracks from Discover to listen without a connection."))
                }
            }
            .navigationTitle("Downloads")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Clear download history", systemImage: "trash") { clearing = true } } }
            .confirmationDialog("Clear completed download history?", isPresented: $clearing, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) { downloads.clearCompleted() }
            } message: { Text("Downloaded music stays in your library.") }
        }
    }
}

struct NowPlayingView: View {
    let library: AudioLibrary
    let downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 20) {
                        TrackArtwork(url: library.current?.artworkURL ?? library.onlineCurrent?.artworkURL,
                                     size: max(160, min(280, geometry.size.width - 48, geometry.size.height * 0.34)))
                            .padding(.top, 8)
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
                    transport
                    if #available(iOS 26, *) {
                        GlassEffectContainer(spacing: 12) { secondaryControls }
                    } else { secondaryControls }
                    if let track = library.onlineCurrent {
                        Button("Save offline", systemImage: "arrow.down.circle") { downloads.download(track, into: library) }
                            .buttonStyle(.bordered)
                    }
                    }.padding(.horizontal, 24).padding(.bottom, 20)
                }
            }
            .navigationTitle("Now Playing").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let source = library.playingSource {
                        Button(library.isFavorite(source) ? "Remove from Favorites" : "Add to Favorites", systemImage: library.isFavorite(source) ? "heart.fill" : "heart") {
                            library.toggleFavorite(source)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Close", systemImage: "chevron.down") { dismiss() } }
            }
        }
    }
    private var transport: some View {
        HStack(spacing: 36) {
            Button("Back 15 seconds", systemImage: "gobackward.15") { library.seek(to: library.elapsed - 15) }
                .frame(minWidth: 44, minHeight: 44)
            Button(library.isPlaying ? "Pause" : "Play", systemImage: library.isPlaying ? "pause.circle.fill" : "play.circle.fill") {
                library.togglePlayback()
            }.font(.system(size: 64)).frame(minWidth: 72, minHeight: 72)
            Button("Forward 15 seconds", systemImage: "goforward.15") { library.seek(to: library.elapsed + 15) }
                .frame(minWidth: 44, minHeight: 44)
        }.font(.title).labelStyle(.iconOnly)
    }

    private var secondaryControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Button("Previous", systemImage: "backward.end.fill") { library.previous() }
                Button("Next", systemImage: "forward.end.fill") { library.next() }
                Button("Shuffle", systemImage: "shuffle") { library.shuffleEnabled.toggle() }
                    .tint(library.shuffleEnabled ? Color.accentColor : Color.gray)
                    .accessibilityValue(library.shuffleEnabled ? "On" : "Off")
                Menu {
                    ForEach(AudioLibrary.RepeatMode.allCases, id: \.self) { mode in
                        Button(mode.rawValue.capitalized) { library.repeatMode = mode }
                    }
                } label: {
                    Label("Repeat: " + library.repeatMode.rawValue, systemImage: library.repeatMode == .one ? "repeat.1" : "repeat")
                }
                AudioRoutePicker().frame(width: 44, height: 44).accessibilityLabel("Audio output")
            }.labelStyle(.iconOnly)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                NavigationLink { AudioEditorView(library: library) } label: { Label("Audio Editor", systemImage: "waveform.path").frame(maxWidth: .infinity, minHeight: 32) }
                NavigationLink { EffectsView(library: library) } label: { Label("Audio Effects", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, minHeight: 32) }
                NavigationLink { QueueView(library: library) } label: { Label("Up Next", systemImage: "list.bullet").frame(maxWidth: .infinity, minHeight: 32) }
                NavigationLink { LyricsView(library: library) } label: { Label("Lyrics", systemImage: "quote.bubble").frame(maxWidth: .infinity, minHeight: 32) }
            }.font(.subheadline)
        }.modifier(PlayerActionsStyle())
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(seconds)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct PlayerActionsStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.buttonStyle(.glass).controlSize(.regular) }
        else { content.buttonStyle(.bordered).controlSize(.regular) }
    }
}
