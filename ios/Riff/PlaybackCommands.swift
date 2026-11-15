import MediaPlayer
import UIKit

@MainActor
final class PlaybackCommands {
    private weak var library: AudioLibrary?
    private var artworkURL: String?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private var handlers: [(MPRemoteCommand, Any)] = []

    init(library: AudioLibrary) {
        self.library = library
        let center = MPRemoteCommandCenter.shared()
        handlers.append((center.playCommand, center.playCommand.addTarget { @Sendable [weak library] _ in
            Task { @MainActor in if let library, !library.isPlaying { library.togglePlayback() } }
            return .success
        }))
        handlers.append((center.pauseCommand, center.pauseCommand.addTarget { @Sendable [weak library] _ in
            Task { @MainActor in if let library, library.isPlaying { library.togglePlayback() } }
            return .success
        }))
        handlers.append((center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { @Sendable [weak library] _ in
            Task { @MainActor in library?.togglePlayback() }
            return .success
        }))
        handlers.append((center.nextTrackCommand, center.nextTrackCommand.addTarget { @Sendable [weak library] _ in
            Task { @MainActor in library?.next() }
            return .success
        }))
        handlers.append((center.previousTrackCommand, center.previousTrackCommand.addTarget { @Sendable [weak library] _ in
            Task { @MainActor in library?.previous() }
            return .success
        }))
        handlers.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { @Sendable [weak library] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in library?.seek(to: position) }
            return .success
        }))
    }

    func clear() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkURL = nil
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func update() {
        guard let library, let title = library.playingTitle else { return }
        let url = library.current?.artworkURL ?? library.onlineCurrent?.artworkURL
        if url != artworkURL {
            artworkURL = url
            artwork = nil
            artworkTask?.cancel()
            if let url {
                artworkTask = Task { @MainActor [weak self] in
                    guard let data = try? await ArtworkCache.shared.imageData(for: url), !Task.isCancelled,
                          let image = UIImage(data: data), let self, self.artworkURL == url else { return }
                    self.artwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
                    self.update()
                }
            }
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: library.playingArtist,
            MPMediaItemPropertyPlaybackDuration: library.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: library.elapsed.isFinite ? library.elapsed : 0,
            MPNowPlayingInfoPropertyPlaybackRate: library.isPlaying ? Double(library.effects.rate) : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
