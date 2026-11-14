import AVFoundation
import Observation

struct LocalTrack: Codable, Identifiable {
    let id: UUID
    let name: String
    let filename: String
    var artist: String? = nil
    var artworkURL: String? = nil
    var webpageURL: String? = nil
}

/// Owns sandbox copies: access to the original Files provider is needed only during import.
@MainActor @Observable
final class AudioLibrary: NSObject, AVAudioPlayerDelegate {
    private(set) var tracks: [LocalTrack] = []
    private(set) var current: LocalTrack?
    private(set) var isPlaying = false
    var error: String?
    private(set) var onlineCurrent: OnlineTrack?
    private(set) var isLoading = false
    @ObservationIgnored private var streamPlayer: AVPlayer?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var manifestIsReadable = true

    var playingTitle: String? { current?.name ?? onlineCurrent?.title }
    var playingArtist: String { current?.artist ?? onlineCurrent?.artist ?? "" }
    var elapsed: Double { streamPlayer?.currentTime().seconds ?? player?.currentTime ?? 0 }
    var duration: Double {
        let value = streamPlayer?.currentItem?.duration.seconds ?? player?.duration ?? 0
        return value.isFinite ? max(0, value) : 0
    }

    func seek(to value: Double) {
        let seconds = min(max(0, value), duration)
        streamPlayer?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        player?.currentTime = seconds
    }
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let manifest: URL

    override convenience init() {
        self.init(root: URL.documentsDirectory.appending(path: "Riff", directoryHint: .isDirectory))
    }

    init(root: URL) {
        directory = root
        manifest = root.appending(path: "library.json")
        super.init()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifest.path) {
                tracks = try JSONDecoder().decode([LocalTrack].self, from: Data(contentsOf: manifest))
            }
        } catch { self.error = error.localizedDescription; manifestIsReadable = false }
    }

    func importFiles(_ urls: [URL]) {
        guard manifestIsReadable else { error = "The library index could not be read. Its original data has been preserved."; return }
        for source in urls {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let id = UUID()
            let filename = id.uuidString + "." + source.pathExtension
            let destination = directory.appending(path: filename)
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                // Validate decodability before committing an entry to the library.
                _ = try AVAudioPlayer(contentsOf: destination)
                let track = LocalTrack(id: id, name: source.deletingPathExtension().lastPathComponent, filename: filename)
                let updated = tracks + [track]
                try JSONEncoder().encode(updated).write(to: manifest, options: .atomic)
                tracks = updated
            } catch {
                try? FileManager.default.removeItem(at: destination)
                self.error = "Could not import \(source.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func importDownload(_ source: URL, media: ResolvedMedia) throws {
        guard manifestIsReadable else { throw ExtractionError(message: "The library index is unreadable; existing data was preserved.") }
        let id = UUID()
        let ext = (media.ext ?? "m4a").filter { $0.isLetter || $0.isNumber }
        let filename = id.uuidString + "." + ext
        let destination = directory.appending(path: filename)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            _ = try AVAudioPlayer(contentsOf: destination)
            let track = LocalTrack(id: id, name: media.track.title, filename: filename, artist: media.track.artist,
                                   artworkURL: media.track.artworkURL, webpageURL: media.track.webpageURL)
            let updated = tracks + [track]
            try JSONEncoder().encode(updated).write(to: manifest, options: .atomic)
            tracks = updated
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func playOnline(_ track: OnlineTrack) async {
        let request = UUID()
        generation = request
        monitor?.cancel()
        player?.stop()
        streamPlayer?.pause()
        streamPlayer = nil
        current = nil
        onlineCurrent = track
        isLoading = true
        isPlaying = false
        defer { if generation == request { isLoading = false } }
        do {
            let media = try await MediaExtractor.shared.resolve(track.webpageURL)
            guard generation == request else { return }
            try Task.checkCancellation()
            guard let url = URL(string: media.streamURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw ExtractionError(message: "The provider returned an invalid audio URL.")
            }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": media.headers])
            let item = AVPlayerItem(asset: asset)
            let streaming = AVPlayer(playerItem: item)
            streamPlayer = streaming
            streaming.play()
            isPlaying = true
            monitor = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self, self.generation == request else { return }
                    if item.status == .failed {
                        self.error = item.error?.localizedDescription ?? "The audio stream failed."
                        self.isPlaying = false
                        return
                    }
                    if item.status == .readyToPlay, self.duration > 0, self.elapsed >= self.duration - 0.1 {
                        self.isPlaying = false
                        return
                    }
                }
            }
        } catch {
            if generation == request { self.error = error.localizedDescription }
        }
    }

    func play(_ track: LocalTrack) {
        generation = UUID()
        monitor?.cancel()
        streamPlayer?.pause()
        streamPlayer = nil
        onlineCurrent = nil
        isLoading = false
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let next = try AVAudioPlayer(contentsOf: directory.appending(path: track.filename))
            next.delegate = self
            guard next.prepareToPlay() else { throw PlaybackError.unavailable }
            player?.stop()
            player = next
            current = track
            isPlaying = next.play()
            if !isPlaying { throw PlaybackError.unavailable }
        } catch { self.error = error.localizedDescription }
    }

    func togglePlayback() {
        if let streaming = streamPlayer {
            if isPlaying { streaming.pause() } else { streaming.play() }
            isPlaying.toggle()
            return
        }
        guard let player else { return }
        if isPlaying { player.pause(); isPlaying = false }
        else { isPlaying = player.play() }
    }

    func next() {
        guard let current, let index = tracks.firstIndex(where: { $0.id == current.id }), !tracks.isEmpty else { return }
        play(tracks[(index + 1) % tracks.count])
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            if flag { self.next() }
        }
    }

    enum PlaybackError: LocalizedError {
        case unavailable
        var errorDescription: String? { "This audio file could not be played." }
    }
}
