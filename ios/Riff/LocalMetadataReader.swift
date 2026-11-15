import AVFoundation

struct LocalMetadata: Sendable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let artwork: Data?
}

actor LocalMetadataReader {
    static let shared = LocalMetadataReader()
    func read(_ url: URL) async throws -> LocalMetadata {
        if ["ogg", "oga", "mka", "webm", "opus", "wma", "ape", "wv", "tta", "mpc", "mpc8", "dsf", "dff"].contains(url.pathExtension.lowercased()) {
            return try await readWithCodecs(url)
        }
        let asset = AVURLAsset(url: url)
        let items = try await asset.load(.commonMetadata)
        func item(_ identifier: AVMetadataIdentifier) -> AVMetadataItem? {
            AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first
        }
        let title = try await item(.commonIdentifierTitle)?.load(.stringValue)
        let artist = try await item(.commonIdentifierArtist)?.load(.stringValue)
        let album = try await item(.commonIdentifierAlbumName)?.load(.stringValue)
        let artwork = try await item(.commonIdentifierArtwork)?.load(.dataValue)
        let seconds = try await asset.load(.duration).seconds
        return LocalMetadata(title: title, artist: artist, album: album,
                             duration: seconds.isFinite && seconds > 0 ? seconds : nil, artwork: artwork)
    }
    private func readWithCodecs(_ url: URL) async throws -> LocalMetadata {
        let handle = try StreamDecoderHandle()
        let decoder = StreamDecoder(handle: handle)
        return try await withTaskCancellationHandler {
            _ = try await decoder.open(url: url, headers: [:], position: 0)
            return await decoder.metadata()
        } onCancel: { handle.cancel() }
    }

}
