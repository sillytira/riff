import AVFoundation

private final class NotificationObservations: @unchecked Sendable {
    private let tokens: [NSObjectProtocol]
    init(_ tokens: [NSObjectProtocol]) { self.tokens = tokens }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

@MainActor
final class PlaybackLifecycle {
    private weak var library: AudioLibrary?
    private var shouldResume = false
    private var observations: NotificationObservations?

    init(library: AudioLibrary) {
        self.library = library
        let interruptions = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self, let library = self.library, let rawType,
                      let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
                if type == .began {
                    self.shouldResume = library.isPlaying
                    if library.isPlaying { library.togglePlayback() }
                } else {
                    let resume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                    if self.shouldResume && resume && !library.isPlaying { library.togglePlayback() }
                    self.shouldResume = false
                }
            }
        }
        let routes = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                guard let self, let library = self.library, let raw,
                      AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
                self.shouldResume = false
                if library.isPlaying { library.togglePlayback() }
            }
        }
        observations = NotificationObservations([interruptions, routes])
    }
}
