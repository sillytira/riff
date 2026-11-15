import SwiftUI

struct TrackDetailsView: View {
    let track: LocalTrack
    let library: AudioLibrary
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(track: LocalTrack, library: AudioLibrary) {
        self.track = track
        self.library = library
        _title = State(initialValue: track.name)
        _artist = State(initialValue: track.artist ?? "")
        _album = State(initialValue: track.album ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TrackArtwork(url: track.artworkURL, size: 100).frame(maxWidth: .infinity)
                }.listRowBackground(Color.clear)
                Section {
                    TextField("Title", text: $title).accessibilityIdentifier("song-title")
                    TextField("Artist", text: $artist).accessibilityIdentifier("song-artist")
                    TextField("Album", text: $album).accessibilityIdentifier("song-album")
                } header: { Text("Song details") } footer: { Text("These details are saved in your Riff library.") }
            }
            .navigationTitle("Song details").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try library.updateMetadata(track.id, title: title, artist: artist, album: album)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert("Could not save song details", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }
}
