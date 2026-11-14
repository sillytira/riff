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
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): library.importFiles(urls)
                case .failure(let error): library.error = error.localizedDescription
                }
            }
        }
    }
}
