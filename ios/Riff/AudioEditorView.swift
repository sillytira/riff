import SwiftUI
import AVFoundation

actor WaveformReader {
    static let shared = WaveformReader()
    func peaks(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768) else { return [] }
        var peaks = [Float](repeating: 0, count: 256)
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let first = file.framePosition
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            for frame in 0..<Int(buffer.frameLength) {
                let bin = min(255, Int((first + AVAudioFramePosition(frame)) * 256 / file.length))
                for channel in 0..<Int(buffer.format.channelCount) { peaks[bin] = max(peaks[bin], abs(channels[channel][frame])) }
            }
        }
        return peaks
    }
}

struct AudioEditorView: View {
    let library: AudioLibrary
    @State private var start = 0.0
    @State private var end = 1.0
    @State private var duration = 1.0
    @State private var peaks: [Float] = []
    @State private var includeEffects = true
    @State private var exporting = false
    @State private var exported: URL?
    @State private var error: String?

    var body: some View {
        Group {
            if let track = library.current, let url = library.editableURL(for: track) {
                Form {
                    Section {
                        Text(track.name).font(.headline)
                        Canvas { context, size in
                            context.fill(Path(CGRect(x: size.width * start / duration, y: 0, width: size.width * (end - start) / duration, height: size.height)), with: .color(.purple.opacity(0.12)))
                            guard !peaks.isEmpty else { return }
                            var path = Path()
                            for (index, peak) in peaks.enumerated() {
                                let x = size.width * Double(index) / Double(peaks.count)
                                let height = size.height * Double(min(1, peak)) * 0.48
                                path.move(to: CGPoint(x: x, y: size.height / 2 - height))
                                path.addLine(to: CGPoint(x: x, y: size.height / 2 + height))
                            }
                            context.stroke(path, with: .color(.purple), lineWidth: 1)
                        }.frame(height: 120).accessibilityLabel("Waveform of \(track.name)")
                    }
                    Section("Selection") {
                        Text("Start: \(start, specifier: "%.2f") seconds").monospacedDigit()
                        Slider(value: Binding(get: { start }, set: { start = min($0, end - min(0.01, duration)) }), in: 0...duration).accessibilityLabel("Selection start")
                        Text("End: \(end, specifier: "%.2f") seconds").monospacedDigit()
                        Slider(value: Binding(get: { end }, set: { end = max($0, start + min(0.01, duration)) }), in: 0...duration).accessibilityLabel("Selection end")
                        Button("Preview selection start", systemImage: "play") { library.seek(to: start); if !library.isPlaying { library.togglePlayback() } }
                    }
                    Section {
                        Toggle("Apply current audio effects", isOn: $includeEffects)
                        Button("Save selection as WAV", systemImage: "waveform") { export(url: url, track: track) }.disabled(exporting)
                        if exporting { ProgressView("Rendering audio…") }
                        if let exported { ShareLink("Share exported audio", item: exported) }
                        if let error { Text(error).foregroundStyle(.red) }
                    } header: { Text("Export") } footer: { Text("The exported selection is saved as a new track. The original audio is preserved.") }
                }
                .task(id: track.id) {
                    do {
                        let file = try AVAudioFile(forReading: url)
                        duration = max(0.001, Double(file.length) / file.processingFormat.sampleRate)
                        start = 0
                        end = duration
                        peaks = try await WaveformReader.shared.peaks(url: url)
                    } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                }
            } else {
                ContentUnavailableView("Choose an offline audio file", systemImage: "waveform", description: Text("Play an imported or directly downloaded audio file to trim it and export effects."))
            }
        }.navigationTitle("Audio Editor")
    }

    private func export(url: URL, track: LocalTrack) {
        exporting = true
        error = nil
        let selectedStart = self.start, selectedEnd = self.end
        let settings = includeEffects ? library.effects : AudioEffectSettings()
        Task {
            do {
                let folder = FileManager.default.temporaryDirectory.appending(path: "RiffExports")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let output = folder.appending(path: UUID().uuidString + ".wav")
                try await AudioProcessor.shared.exportWAV(input: url, output: output, start: selectedStart, end: selectedEnd, settings: settings)
                try library.importEditedFile(output, original: track)
                exported = output
            } catch { self.error = error.localizedDescription }
            exporting = false
        }
    }
}
