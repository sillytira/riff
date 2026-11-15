import AVFoundation
import Observation

struct LocalTrack: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let filename: String
    var artist: String? = nil
    var artworkURL: String? = nil
    var webpageURL: String? = nil
    var assetRelativePath: String? = nil
    var album: String? = nil
    var duration: Double? = nil
    var metadataIndexed: Bool? = nil
    var sourceProvider: String? = nil
    var playbackFilename: String? = nil
    var metadataCustomized: Bool? = nil
    var downloadJobID: UUID? = nil
    var codecPlayback: Bool? = nil

    var onlineEquivalent: OnlineTrack? {
        guard let webpageURL, let url = URL(string: webpageURL), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return OnlineTrack(id: webpageURL, title: name, artist: artist ?? "", webpageURL: webpageURL, artworkURL: artworkURL, duration: duration, provider: sourceProvider ?? "Generic", album: album)
    }
}

/// Owns sandbox copies: access to the original Files provider is needed only during import.
@MainActor @Observable
final class AudioLibrary: NSObject {
    private(set) var tracks: [LocalTrack] = []
    let listening: ListeningStore
    private(set) var current: LocalTrack?
    private(set) var isPlaying = false
    var error: String?
    private(set) var onlineCurrent: OnlineTrack?
    private(set) var isLoading = false
    private(set) var activeImports = 0
    var effects = AudioEffectSettings() {
        didSet {
            player?.settings = effects
            networkPlayer?.settings = effects
            if isPlaying { streamPlayer?.rate = effects.rate }
            if playingTitle != nil { commands.update() }
            persistEffects()
        }
    }
    var shuffleEnabled = false { didSet { persistPlaybackPreferences() } }
    var repeatMode: RepeatMode = .all { didSet { persistPlaybackPreferences() } }
    private(set) var playbackQueue = PlaybackQueue()
    enum RepeatMode: String, CaseIterable, Codable { case off, all, one }
    @ObservationIgnored private lazy var lifecycle = PlaybackLifecycle(library: self)
    @ObservationIgnored private lazy var commands = PlaybackCommands(library: self)
    @ObservationIgnored private var streamPlayer: AVPlayer?
    @ObservationIgnored private var networkPlayer: NativeStreamingPlayer?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var manifestIsReadable = true

    var lyricsKey: String? {
        if let current {
            if let source = current.webpageURL { return "source:" + source }
            return "local:" + current.id.uuidString
        }
        return onlineCurrent.map { "source:" + $0.webpageURL }
    }
    var playingSource: PlaylistSource? {
        if let current { return .local(current.id) }
        return onlineCurrent.map { .online($0) }
    }
    private func equivalentSources(for source: PlaylistSource) -> [PlaylistSource] {
        switch source {
        case .local(let id):
            guard let online = tracks.first(where: { $0.id == id })?.onlineEquivalent else { return [] }
            return [.online(online)] + equivalentSources(for: .online(online))
        case .file: return []
        case .online(let online):
            let key = downloadSourceKey(online.webpageURL)
            return tracks.filter { $0.webpageURL.map(downloadSourceKey) == key }.map { .local($0.id) }
        }
    }
    func isFavorite(_ source: PlaylistSource) -> Bool {
        listening.isFavorite(source, equivalents: equivalentSources(for: source))
    }
    func toggleFavorite(_ source: PlaylistSource) {
        listening.toggleFavorite(source, equivalents: equivalentSources(for: source))
        if let failure = listening.error { error = failure }
    }
    var playingTitle: String? { current?.name ?? onlineCurrent?.title }
    var playingArtist: String { current?.artist ?? onlineCurrent?.artist ?? "" }
    var elapsed: Double {
        let value = networkPlayer?.elapsed ?? streamPlayer?.currentTime().seconds ?? player?.currentTime ?? 0
        return value.isFinite ? max(0, value) : 0
    }
    var duration: Double {
        let value = networkPlayer?.duration ?? streamPlayer?.currentItem?.duration.seconds ?? player?.duration ?? 0
        if value.isFinite, value > 0 { return value }
        let metadata = current?.duration ?? onlineCurrent?.duration ?? 0
        return metadata.isFinite ? max(0, metadata) : 0
    }

    func seek(to value: Double) {
        guard value.isFinite, duration > 0 else { return }
        let seconds = min(max(0, value), duration)
        if let networkPlayer { networkPlayer.seek(to: seconds); commands.update(); return }
        streamPlayer?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        player?.currentTime = seconds
        commands.update()
    }
    @ObservationIgnored private var player: NativeAudioPlayer?
    @ObservationIgnored private let directory: URL
    private struct MetadataJob { let id: UUID; let url: URL; let forceTags: Bool }
    @ObservationIgnored private var metadataJobs: [MetadataJob] = []
    @ObservationIgnored private var artworkRepairs: Set<UUID> = []
    @ObservationIgnored private var metadataCursor = 0
    @ObservationIgnored private var metadataWorker: Task<Void, Never>?
    @ObservationIgnored private let effectsFile: URL
    @ObservationIgnored private var effectsWritable = true
    private struct PlaybackPreferences: Codable {
        var shuffle: Bool
        var repeatMode: RepeatMode
    }
    @ObservationIgnored private let preferencesFile: URL
    @ObservationIgnored private var preferencesWritable = false
    @ObservationIgnored private let manifest: URL

    override convenience init() {
        self.init(root: URL.documentsDirectory.appending(path: "Riff", directoryHint: .isDirectory))
    }

    init(root: URL) {
        listening = ListeningStore(root: root)
        directory = root
        manifest = root.appending(path: "library.json")
        effectsFile = root.appending(path: "effects.json")
        preferencesFile = root.appending(path: "playback-preferences.json")
        super.init()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifest.path) {
                tracks = try JSONDecoder().decode([LocalTrack].self, from: Data(contentsOf: manifest))
            }
        } catch { self.error = error.localizedDescription; manifestIsReadable = false }
        do {
            if FileManager.default.fileExists(atPath: effectsFile.path) {
                let saved = try JSONDecoder().decode(AudioEffectSettings.self, from: Data(contentsOf: effectsFile))
                guard saved.gains.count == 10, saved.gains.allSatisfy({ $0.isFinite && abs($0) <= 12 }),
                      saved.rate.isFinite, (0.25...4).contains(saved.rate),
                      saved.pitch.isFinite, (-24...24).contains(saved.pitch),
                      saved.reverb.isFinite, (0...100).contains(saved.reverb),
                      saved.distortion.isFinite, (0...100).contains(saved.distortion) else {
                    throw ExtractionError(message: "Saved effects are invalid. Reset audio effects to recover them.")
                }
                effects = saved
            }
        } catch { self.error = error.localizedDescription; effectsWritable = false }
        do {
            if FileManager.default.fileExists(atPath: preferencesFile.path) {
                let saved = try JSONDecoder().decode(PlaybackPreferences.self, from: Data(contentsOf: preferencesFile))
                shuffleEnabled = saved.shuffle
                repeatMode = saved.repeatMode
            }
            preferencesWritable = true
        } catch { self.error = "Playback preferences could not be read. Their data was preserved." }
        for track in tracks where track.metadataIndexed != true && track.assetRelativePath == nil {
            enqueueMetadata(id: track.id, url: root.appending(path: track.playbackFilename ?? track.filename))
        }
    }

    private func persistPlaybackPreferences() {
        guard preferencesWritable else { return }
        do {
            let saved = PlaybackPreferences(shuffle: shuffleEnabled, repeatMode: repeatMode)
            try JSONEncoder().encode(saved).write(to: preferencesFile, options: .atomic)
        } catch { self.error = "Playback preferences could not be saved: " + error.localizedDescription }
    }

    private func enqueueMetadata(id: UUID, url: URL, forceTags: Bool = false) {
        metadataJobs.append(MetadataJob(id: id, url: url, forceTags: forceTags))
        guard metadataWorker == nil else { return }
        metadataWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.metadataCursor < self.metadataJobs.count {
                let job = self.metadataJobs[self.metadataCursor]
                self.metadataCursor += 1
                do {
                    let metadata = try await LocalMetadataReader.shared.read(job.url)
                    var artwork: String?
                    if let data = metadata.artwork { artwork = try? await ArtworkCache.shared.storeEmbedded(data, identity: job.id.uuidString) }
                    guard self.manifestIsReadable, let index = self.tracks.firstIndex(where: { $0.id == job.id }) else { continue }
                    var updated = self.tracks
                    if updated[index].metadataCustomized != true && (job.forceTags || updated[index].webpageURL == nil || updated[index].sourceProvider == "Generic") {
                        if let title = metadata.title, !title.isEmpty { updated[index].name = title }
                        if let artist = metadata.artist, !artist.isEmpty { updated[index].artist = artist }
                    }
                    if updated[index].metadataCustomized != true, (updated[index].artist ?? "").isEmpty, let artist = metadata.artist { updated[index].artist = artist }
                    if updated[index].artworkURL == nil { updated[index].artworkURL = artwork }
                    if job.forceTags && updated[index].metadataCustomized != true {
                        updated[index].artist = metadata.artist ?? ""
                        updated[index].album = metadata.album
                    } else if updated[index].album == nil { updated[index].album = metadata.album }
                    updated[index].duration = metadata.duration ?? updated[index].duration
                    updated[index].metadataIndexed = metadata.artwork == nil || artwork != nil
                    try JSONEncoder().encode(updated).write(to: self.manifest, options: .atomic)
                    self.tracks = updated
                    if self.current?.id == job.id { self.current = updated[index]; self.commands.update() }
                } catch {
                    // Keep the original playable entry and retry indexing on a later launch.
                }
            }
            self.metadataJobs.removeAll(keepingCapacity: true)
            self.metadataCursor = 0
            self.metadataWorker = nil
        }
    }

    func resetEffects() {
        effectsWritable = true
        effects = AudioEffectSettings()
    }

    private func persistEffects() {
        guard effectsWritable else { return }
        do { try JSONEncoder().encode(effects).write(to: effectsFile, options: .atomic) }
        catch { self.error = "Could not save audio effects: " + error.localizedDescription }
    }

    func importFiles(_ urls: [URL]) async {
        activeImports += 1
        defer { activeImports -= 1 }
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
                let validated = try await AudioFileValidator.shared.validate(destination)
                try Task.checkCancellation()
                var track = LocalTrack(id: id, name: source.deletingPathExtension().lastPathComponent, filename: filename)
                track.codecPlayback = validated.usesCodecs
                track.duration = validated.duration
                let updated = tracks + [track]
                try JSONEncoder().encode(updated).write(to: manifest, options: .atomic)
                tracks = updated
                enqueueMetadata(id: id, url: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                self.error = "Could not import \(source.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func importDownload(_ source: URL, media: ResolvedMedia, downloadJobID: UUID? = nil) async throws {
        guard manifestIsReadable else { throw ExtractionError(message: "The library index is unreadable; existing data was preserved.") }
        if let downloadJobID, tracks.contains(where: { $0.downloadJobID == downloadJobID }) { return }
        let id = UUID()
        let ext = (media.ext ?? "m4a").filter { $0.isLetter || $0.isNumber }
        let filename = id.uuidString + "." + ext
        let destination = directory.appending(path: filename)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            let validated = try await AudioFileValidator.shared.validate(destination)
            try Task.checkCancellation()
            if let downloadJobID, tracks.contains(where: { $0.downloadJobID == downloadJobID }) {
                try? FileManager.default.removeItem(at: destination)
                return
            }
            var track = LocalTrack(id: id, name: media.track.title, filename: filename, artist: media.track.artist,
                                   artworkURL: media.track.artworkURL, webpageURL: media.track.webpageURL.isEmpty ? nil : media.track.webpageURL)
            track.downloadJobID = downloadJobID
            track.codecPlayback = validated.usesCodecs
            track.album = media.track.album
            track.duration = media.track.duration ?? validated.duration
            track.sourceProvider = media.track.provider
            let updated = tracks + [track]
            try JSONEncoder().encode(updated).write(to: manifest, options: .atomic)
            tracks = updated
            enqueueMetadata(id: id, url: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func updateMetadata(_ id: UUID, title: String, artist: String, album: String) throws {
        guard manifestIsReadable else { throw ExtractionError(message: "The library index is unreadable; its data has been preserved.") }
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { throw ExtractionError(message: "This song is no longer in your library.") }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ExtractionError(message: "Give the song a title.") }
        var updated = tracks
        updated[index].name = title
        updated[index].artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        updated[index].album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        updated[index].metadataCustomized = true
        try JSONEncoder().encode(updated).write(to: manifest, options: .atomic)
        tracks = updated
        if current?.id == id { current = updated[index]; commands.update() }
    }

    func rescanMetadata(_ track: LocalTrack) throws {
        guard manifestIsReadable, let index = tracks.firstIndex(where: { $0.id == track.id }), let url = editableURL(for: track) else {
            throw ExtractionError(message: "The song’s file is unavailable for metadata indexing.")
        }
        var updated = tracks
        updated[index].metadataCustomized = false
        updated[index].metadataIndexed = false
        try JSONEncoder().encode(updated).write(to: manifest, options: .atomic)
        tracks = updated
        enqueueMetadata(id: track.id, url: url, forceTags: true)
    }

    func stop() {
        generation = UUID()
        monitor?.cancel()
        monitor = nil
        player?.stop()
        player = nil
        networkPlayer?.stop()
        networkPlayer = nil
        streamPlayer?.pause()
        streamPlayer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        current = nil
        onlineCurrent = nil
        isPlaying = false
        isLoading = false
        playbackQueue.currentID = nil
        commands.clear()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func removeTracks(_ ids: Set<UUID>, playlists: PlaylistStore? = nil) throws {
        guard manifestIsReadable else { throw ExtractionError(message: "The library index is unreadable; existing data was preserved.") }
        let removed = tracks.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        let files = try removed.flatMap { try ownedFiles(for: $0) }
        var replacements: [UUID: OnlineTrack] = [:]
        for track in removed { if let online = track.onlineEquivalent { replacements[track.id] = online } }
        let updated = tracks.filter { !ids.contains($0.id) }
        // Commit the index before reclaiming storage. An interrupted cleanup can
        // leave unused bytes, but never an entry whose audio was deleted first.
        try JSONEncoder().encode(updated).write(to: manifest, options: .atomic)
        tracks = updated
        playbackQueue.entries.removeAll { entry in
            if case .local(let id) = entry.source { return ids.contains(id) }
            return false
        }
        if let current, ids.contains(current.id) { stop() }
        listening.remapLocal(ids, replacements: replacements)
        playlists?.remapLocal(ids, replacements: replacements)
        var cleanupFailed = false
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            do { try FileManager.default.removeItem(at: file) } catch { cleanupFailed = true }
        }
        if cleanupFailed { error = "The songs were removed from the library, but some download storage could not be released." }
        else if let failure = listening.error ?? playlists?.error { error = failure }
    }

    private func ownedFiles(for track: LocalTrack) throws -> [URL] {
        if let relative = track.assetRelativePath {
            let home = URL(filePath: NSHomeDirectory()).resolvingSymlinksInPath()
            let asset = home.appending(path: relative).standardizedFileURL.resolvingSymlinksInPath()
            guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."),
                  asset.path.hasPrefix(home.path + "/"), asset.pathExtension == "movpkg", asset.lastPathComponent == track.filename else {
                throw ExtractionError(message: "The offline asset’s location is invalid; its files were preserved.")
            }
            return [asset]
        }
        var names = [track.filename]
        if let playbackFilename = track.playbackFilename { names.append(playbackFilename) }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        return try names.map { name in
            let file = root.appending(path: name).standardizedFileURL.resolvingSymlinksInPath()
            guard (name.hasPrefix(track.id.uuidString + ".") || name == track.id.uuidString + "-decoded.wav"),
                  name == file.lastPathComponent, file.path.hasPrefix(root.path + "/") else {
                throw ExtractionError(message: "The song’s storage location is invalid; its files were preserved.")
            }
            return file
        }
    }

    func offlineTrack(for source: String) -> LocalTrack? {
        guard !source.isEmpty else { return nil }
        let key = downloadSourceKey(source)
        return tracks.first { track in
            guard let url = track.webpageURL, downloadSourceKey(url) == key,
                  let files = try? ownedFiles(for: track), !files.isEmpty else { return false }
            return files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    func hasOfflineSource(_ source: String) -> Bool { offlineTrack(for: source) != nil }

    func originalURL(for track: LocalTrack) -> URL? {
        guard track.assetRelativePath == nil else { return nil }
        return directory.appending(path: track.filename)
    }

    func editableURL(for track: LocalTrack) -> URL? {
        guard track.assetRelativePath == nil else { return nil }
        return directory.appending(path: track.playbackFilename ?? track.filename)
    }

    func importEditedFile(_ source: URL, original: LocalTrack, playableCopy: URL? = nil) async throws {
        guard manifestIsReadable else { throw ExtractionError(message: "The library index is unreadable; existing data was preserved.") }
        let id = UUID()
        let ext = source.pathExtension.lowercased()
        guard ["wav", "mp3", "flac", "m4a", "opus"].contains(ext) else { throw ExtractionError(message: "Choose a supported audio export format.") }
        let filename = id.uuidString + "." + ext
        let destination = directory.appending(path: filename)
        let playbackName = playableCopy == nil ? nil : id.uuidString + "-decoded.wav"
        let playbackDestination = playbackName.map { directory.appending(path: $0) }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            if let playableCopy, let playbackDestination { try FileManager.default.copyItem(at: playableCopy, to: playbackDestination) }
            let validated = try await AudioFileValidator.shared.validate(playbackDestination ?? destination)
            try Task.checkCancellation()
            var edited = LocalTrack(id: id, name: original.name + " (edit)", filename: filename, artist: original.artist, artworkURL: original.artworkURL)
            edited.album = original.album
            edited.playbackFilename = playbackName
            edited.codecPlayback = validated.usesCodecs
            edited.duration = validated.duration
            let updated = tracks + [edited]
            try JSONEncoder().encode(updated).write(to: manifest, options: .atomic)
            tracks = updated
            enqueueMetadata(id: id, url: playbackDestination ?? destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if let playbackDestination { try? FileManager.default.removeItem(at: playbackDestination) }
            throw error
        }
    }

    func importHLSDownload(_ source: URL, media: ResolvedMedia, downloadJobID: UUID? = nil) async throws {
        guard manifestIsReadable else { throw ExtractionError(message: "The library index is unreadable; existing data was preserved.") }
        if let downloadJobID, tracks.contains(where: { $0.downloadJobID == downloadJobID }) { return }
        let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory).resolvingSymlinksInPath().path + "/"
        guard source.resolvingSymlinksInPath().path.hasPrefix(home) else {
            throw ExtractionError(message: "The offline asset is outside the application sandbox.")
        }
        let asset = AVURLAsset(url: source)
        guard try await asset.load(.isPlayable) else {
            throw ExtractionError(message: "The downloaded HLS asset is not playable.")
        }
        try Task.checkCancellation()
        if let downloadJobID, tracks.contains(where: { $0.downloadJobID == downloadJobID }) { return }
        var track = LocalTrack(id: UUID(), name: media.track.title, filename: source.lastPathComponent,
                               artist: media.track.artist, artworkURL: media.track.artworkURL,
                               webpageURL: media.track.webpageURL.isEmpty ? nil : media.track.webpageURL,
                               assetRelativePath: String(source.resolvingSymlinksInPath().path.dropFirst(home.count)))
        track.downloadJobID = downloadJobID
        track.album = media.track.album
        track.duration = media.track.duration
        track.sourceProvider = media.track.provider
        track.metadataIndexed = true
        let updated = tracks + [track]
        try JSONEncoder().encode(updated).write(to: manifest, options: .atomic)
        tracks = updated
    }

    func playOnline(_ track: OnlineTrack, queue: [OnlineTrack]? = nil, preserveQueue: Bool = false, startingAt position: Double = 0) async {
        _ = lifecycle
        if !preserveQueue {
            let entries = (queue ?? [track]).map { PlaylistEntry(source: .online($0)) }
            playbackQueue = PlaybackQueue(entries: entries, currentID: entries.first(where: {
                if case .online(let item) = $0.source { return item.webpageURL == track.webpageURL }
                return false
            })?.id)
        }
        if let saved = offlineTrack(for: track.webpageURL) {
            play(saved, preserveQueue: true, startingAt: position)
            return
        }
        let request = UUID()
        generation = request
        monitor?.cancel()
        player?.stop()
        player = nil
        networkPlayer?.stop()
        networkPlayer = nil
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
            onlineCurrent = track.enriched(with: media.track)
            try Task.checkCancellation()
            guard let url = URL(string: media.streamURL), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw ExtractionError(message: "The provider returned an invalid audio URL.")
            }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let streaming = try NativeStreamingPlayer(duration: onlineCurrent?.duration, settings: effects)
            streaming.onFinish = { [weak self] in
                guard let self, self.generation == request else { return }
                self.isPlaying = false
                self.commands.update()
                self.next(automatic: true)
            }
            streaming.onBuffering = { [weak self] value in
                guard let self, self.generation == request else { return }
                self.isLoading = value
                self.commands.update()
            }
            streaming.onError = { [weak self] error in
                guard let self, self.generation == request else { return }
                if self.isPlaying { self.error = error.localizedDescription }
                self.isPlaying = false
                self.commands.update()
            }
            networkPlayer = streaming
            try await streaming.prepare(url: url, headers: media.headers, position: position)
            guard generation == request else { streaming.stop(); return }
            isPlaying = true
            listening.record(.online(onlineCurrent ?? track), equivalents: equivalentSources(for: .online(track)))
            commands.update()
        } catch {
            if generation == request {
                isPlaying = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
                commands.update()
            }
        }
    }

    func play(_ track: LocalTrack, preserveQueue: Bool = false, startingAt position: Double = 0) {
        _ = lifecycle
        prepareArtwork(for: track)
        if !preserveQueue {
            playbackQueue = PlaybackQueue(entries: tracks.map { PlaylistEntry(id: $0.id, source: .local($0.id)) }, currentID: track.id)
        }
        generation = UUID()
        monitor?.cancel()
        networkPlayer?.stop()
        networkPlayer = nil
        player?.stop()
        player = nil
        current = nil
        isPlaying = false
        streamPlayer?.pause()
        streamPlayer = nil
        onlineCurrent = nil
        isLoading = false
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            if let relative = track.assetRelativePath {
                player?.stop()
                player = nil
                let source = URL(filePath: NSHomeDirectory()).appending(path: relative)
                let item = AVPlayerItem(url: source)
                streamPlayer = AVPlayer(playerItem: item)
                observeEnd(of: item)
                current = track
                item.audioTimePitchAlgorithm = .spectral
                streamPlayer?.playImmediately(atRate: effects.rate)
                isPlaying = true
                listening.record(.local(track.id), equivalents: equivalentSources(for: .local(track.id)))
                commands.update()
                return
            }
            if track.codecPlayback == true {
                try playDecoded(track, position: position)
                return
            }
            let next: NativeAudioPlayer
            do { next = try NativeAudioPlayer(contentsOf: directory.appending(path: track.playbackFilename ?? track.filename)) }
            catch { try playDecoded(track, position: position); return }
            next.settings = effects
            next.onFinish = { [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.commands.update()
                self.next(automatic: true)
            }
            guard next.prepareToPlay() else { throw PlaybackError.unavailable }
            player?.stop()
            player = next
            current = track
            if position > 0 { next.currentTime = position }
            isPlaying = next.play()
            if !isPlaying { throw PlaybackError.unavailable }
            listening.record(.local(track.id), equivalents: equivalentSources(for: .local(track.id)))
            commands.update()
        } catch { self.isPlaying = false; self.error = error.localizedDescription; commands.clear() }
    }

    private func playDecoded(_ track: LocalTrack, position: Double) throws {
        let request = generation
        let streaming = try NativeStreamingPlayer(duration: track.duration, settings: effects)
        let input = directory.appending(path: track.playbackFilename ?? track.filename)
        current = track
        isLoading = true
        networkPlayer = streaming
        streaming.onBuffering = { [weak self] value in
            guard let self, self.generation == request else { return }
            self.isLoading = value
            self.commands.update()
        }
        streaming.onFinish = { [weak self] in
            guard let self, self.generation == request else { return }
            self.isPlaying = false
            self.commands.update()
            self.next(automatic: true)
        }
        streaming.onError = { [weak self] error in
            guard let self, self.generation == request else { return }
            self.error = error.localizedDescription
            self.isPlaying = false
            self.commands.update()
        }
        monitor = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == request { self.isLoading = false; self.monitor = nil } }
            do {
                try await streaming.prepare(url: input, headers: [:], position: position)
                guard self.generation == request else { streaming.stop(); return }
                self.isPlaying = true
                self.listening.record(.local(track.id), equivalents: self.equivalentSources(for: .local(track.id)))
                self.commands.update()
            } catch {
                guard self.generation == request else { return }
                self.isPlaying = false
                if !(error is CancellationError) { self.error = error.localizedDescription }
                self.commands.update()
            }
        }
    }

    func prepareArtwork(for track: LocalTrack) {
        guard track.artworkURL == nil, let source = track.webpageURL, artworkRepairs.insert(track.id).inserted else { return }
        Task { @MainActor [weak self] in
            defer { self?.artworkRepairs.remove(track.id) }
            guard let url = try? await ArtworkLocator.shared.cover(for: source) else { return }
            _ = try? await ArtworkCache.shared.imageData(for: url)
            guard let self, self.manifestIsReadable,
                  let index = self.tracks.firstIndex(where: { $0.id == track.id }), self.tracks[index].artworkURL == nil else { return }
            var updated = self.tracks
            updated[index].artworkURL = url
            do {
                try JSONEncoder().encode(updated).write(to: self.manifest, options: .atomic)
                self.tracks = updated
                if self.current?.id == track.id { self.current = updated[index]; self.commands.update() }
            } catch { }
        }
    }

    func togglePlayback() {
        if let networkPlayer {
            if isPlaying { networkPlayer.pause(); isPlaying = false }
            else if networkPlayer.hasFailed, let track = current {
                play(track, preserveQueue: true, startingAt: networkPlayer.elapsed)
                return
            } else if networkPlayer.needsRefresh, let track = onlineCurrent {
                let position = networkPlayer.hasEnded ? 0 : networkPlayer.elapsed
                Task { await playOnline(track, preserveQueue: true, startingAt: position) }
                return
            } else {
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    try networkPlayer.resume()
                    isPlaying = true
                } catch { self.error = error.localizedDescription }
            }
            commands.update()
            return
        }
        if let streaming = streamPlayer {
            if isPlaying { streaming.pause() } else { streaming.playImmediately(atRate: effects.rate) }
            isPlaying.toggle()
            commands.update()
            return
        }
        guard let player else { return }
        if isPlaying { player.pause(); isPlaying = false }
        else {
            do { try AVAudioSession.sharedInstance().setActive(true) }
            catch { self.error = error.localizedDescription; return }
            isPlaying = player.play()
            if !isPlaying { error = "The audio output could not be restarted." }
        }
        commands.update()
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        let active = generation
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == active else { return }
                self.isPlaying = false
                self.commands.update()
                self.next(automatic: true)
            }
        }
    }

    func playPlaylist(_ entries: [PlaylistEntry], startingAt id: UUID) {
        guard let selected = entries.first(where: { $0.id == id }) else { return }
        playbackQueue = PlaybackQueue(entries: entries, currentID: id)
        playEntry(selected)
    }

    func moveQueue(from offsets: IndexSet, to destination: Int) {
        playbackQueue.entries = movingEntries(playbackQueue.entries, from: offsets, to: destination)
    }

    func removeQueue(offsets: IndexSet) {
        playbackQueue.entries = playbackQueue.entries.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
    }

    func title(for source: PlaylistSource) -> String {
        switch source {
        case .local(let id): tracks.first(where: { $0.id == id })?.name ?? "Unavailable local track"
        case .online(let track): track.title
        case .file(let reference): reference.title
        }
    }

    func matchingLocalFile(_ reference: LocalFileReference) -> LocalTrack? {
        let named = tracks.filter { $0.filename == reference.filename && !reference.filename.isEmpty }
        if named.count == 1 { return named[0] }
        let candidates = tracks.filter { track in
            track.name.localizedStandardCompare(reference.title) == .orderedSame &&
            (track.artist ?? "").localizedStandardCompare(reference.artist) == .orderedSame &&
            (reference.duration == nil || track.duration.map { abs($0 - reference.duration!) < 3 } == true)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func playEntry(_ entry: PlaylistEntry) {
        switch entry.source {
        case .local(let id):
            guard let track = tracks.first(where: { $0.id == id }) else { error = "This local track is no longer in your library."; return }
            play(track, preserveQueue: true)
        case .online(let track):
            Task { await playOnline(track, preserveQueue: true) }
        case .file(let reference):
            guard let track = matchingLocalFile(reference) else {
                error = "Import “" + reference.title + "” from Files to play this playlist entry. Local audio is not included in a playlist JSON file."
                return
            }
            play(track, preserveQueue: true)
        }
    }

    func previous() {
        if elapsed > 3 { seek(to: 0); return }
        if let selected = playbackQueue.previous(repeatMode: repeatMode.rawValue) { playEntry(selected) }
    }

    func next(automatic: Bool = false) {
        if let selected = playbackQueue.advance(automatic: automatic, shuffle: shuffleEnabled, repeatMode: repeatMode.rawValue) { playEntry(selected) }
    }

    enum PlaybackError: LocalizedError {
        case unavailable
        var errorDescription: String? { "This audio file could not be played." }
    }
}
