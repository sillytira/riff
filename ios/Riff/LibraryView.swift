import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var library: AudioLibrary
    @State private var importing = false
    @State private var query = ""

    private var matches: [LocalTrack] {
        query.isEmpty ? library.tracks : library.tracks.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(matches) { track in
                Button { library.play(track) } label: {
                    HStack(spacing: 16) {
                        Image(systemName: library.current?.id == track.id ? "waveform" : "music.note")
                            .font(.title2).frame(width: 44, height: 44)
                            .background(.purple.opacity(0.12), in: .rect(cornerRadius: 12))
                        Text(track.name).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "play.fill").foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
            }
            .overlay {
                if library.tracks.isEmpty {
                    ContentUnavailableView {
                        Label("Your music, with you", systemImage: "music.note.house")
                    } description: {
                        Text("Import audio from Files to start your offline library.")
                    } actions: {
                        Button("Import audio") { importing = true }.buttonStyle(.borderedProminent)
                    }
                } else if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Riff")
            .searchable(text: $query, prompt: "Search your music")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import audio", systemImage: "plus") { importing = true }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let track = library.current {
                    playerBar(track).padding(.horizontal).padding(.bottom, 8)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): library.importFiles(urls)
                case .failure(let error): library.error = error.localizedDescription
                }
            }
            .alert("Audio error", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                Button("OK") { library.error = nil }
            } message: { Text(library.error ?? "") }
        }
    }

    private func playerBar(_ track: LocalTrack) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform").font(.title2).accessibilityHidden(true)
            Text(track.name).font(.headline).lineLimit(1)
            Spacer(minLength: 0)
            Button(library.isPlaying ? "Pause" : "Play", systemImage: library.isPlaying ? "pause.fill" : "play.fill") {
                library.togglePlayback()
            }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
            Button("Next track", systemImage: "forward.end.fill") { library.next() }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
        }
        .padding(12)
        .modifier(PlayerSurface())
    }
}

private struct PlayerSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(.background, in: .rect(cornerRadius: 28))
        } else if #available(iOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 28))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: 28))
        }
    }
}
