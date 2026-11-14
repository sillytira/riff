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
}
