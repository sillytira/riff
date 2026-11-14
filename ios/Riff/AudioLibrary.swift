import AVFoundation
import Observation

struct LocalTrack: Codable, Identifiable {
    let id: UUID
    let name: String
    let filename: String
}

/// Owns sandbox copies: access to the original Files provider is needed only during import.
@MainActor @Observable
final class AudioLibrary: NSObject, AVAudioPlayerDelegate {
    private(set) var tracks: [LocalTrack] = []
    private(set) var current: LocalTrack?
    private(set) var isPlaying = false
    var error: String?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let manifest: URL

    override init() {
        let root = URL.documentsDirectory.appending(path: "Riff", directoryHint: .isDirectory)
        directory = root
        manifest = root.appending(path: "library.json")
        super.init()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifest.path) {
                tracks = try JSONDecoder().decode([LocalTrack].self, from: Data(contentsOf: manifest))
            }
        } catch { self.error = error.localizedDescription }
    }

    func importFiles(_ urls: [URL]) {
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

    func play(_ track: LocalTrack) {
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
