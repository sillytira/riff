import MediaPlayer

@MainActor
final class PlaybackCommands {
    private weak var library: AudioLibrary?
    private var handlers: [(MPRemoteCommand, Any)] = []

    init(library: AudioLibrary) {
        self.library = library
        let center = MPRemoteCommandCenter.shared()
        handlers.append((center.playCommand, center.playCommand.addTarget { [weak library] _ in
            Task { @MainActor in if let library, !library.isPlaying { library.togglePlayback() } }
            return .success
        }))
        handlers.append((center.pauseCommand, center.pauseCommand.addTarget { [weak library] _ in
            Task { @MainActor in if let library, library.isPlaying { library.togglePlayback() } }
            return .success
        }))
        handlers.append((center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { [weak library] _ in
            Task { @MainActor in library?.togglePlayback() }
            return .success
        }))
        handlers.append((center.nextTrackCommand, center.nextTrackCommand.addTarget { [weak library] _ in
            Task { @MainActor in library?.next() }
            return .success
        }))
        handlers.append((center.previousTrackCommand, center.previousTrackCommand.addTarget { [weak library] _ in
            Task { @MainActor in library?.previous() }
            return .success
        }))
        handlers.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { [weak library] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in library?.seek(to: position) }
            return .success
        }))
    }

    func update() {
        guard let library, let title = library.playingTitle else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: library.playingArtist,
            MPMediaItemPropertyPlaybackDuration: library.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: library.elapsed.isFinite ? library.elapsed : 0,
            MPNowPlayingInfoPropertyPlaybackRate: library.isPlaying ? 1 : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
    }
}
