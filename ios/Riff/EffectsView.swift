import SwiftUI

struct EffectsView: View {
    @Bindable var library: AudioLibrary
    @State private var simple = false
    var body: some View {
        Form {
            if library.current?.assetRelativePath != nil {
                Section { Text("Download a direct audio file to use EQ, pitch, reverb and distortion. Playback speed also works while streaming.").foregroundStyle(.secondary) }
            }
            Section("Playback") {
                control("Speed", value: $library.effects.rate, range: 0.25...4, suffix: "×")
                control("Pitch", value: $library.effects.pitch, range: -12...12, suffix: " st")
            }
            Section("Equalizer") {
                Toggle("Simple three-band EQ", isOn: $simple)
                if simple {
                    groupedBand("Bass", indices: 0..<3)
                    groupedBand("Mid", indices: 3..<7)
                    groupedBand("Treble", indices: 7..<10)
                } else {
                    ForEach(AudioEffectSettings.frequencies, id: \.self) { frequency in
                        let index = AudioEffectSettings.frequencies.firstIndex(of: frequency)!
                        control(frequency >= 1000 ? "\(Int(frequency / 1000)) kHz" : "\(Int(frequency)) Hz", value: $library.effects.gains[index], range: -12...12, suffix: " dB")
                    }
                }
                Menu("Presets") {
                    Button("Flat") { library.effects.gains = Array(repeating: 0, count: 10) }
                    Button("Bass boost") { library.effects.gains = [6, 5, 4, 2, 0, 0, 0, 0, 0, 0] }
                    Button("Vocal clarity") { library.effects.gains = [-3, -2, -1, 0, 2, 4, 3, 2, 0, -1] }
                    Button("Rock") { library.effects.gains = [4, 3, 1, 0, -1, 1, 2, 3, 4, 4] }
                }
            }
            Section("Space and texture") {
                control("Reverb", value: $library.effects.reverb, range: 0...100, suffix: "%")
                control("Distortion", value: $library.effects.distortion, range: 0...100, suffix: "%")
            }
            Button("Reset all effects") { library.resetEffects() }
        }.navigationTitle("Audio Effects")
    }
    private func control(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, suffix: String) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(String(format: "%.1f", value.wrappedValue) + suffix).foregroundStyle(.secondary).monospacedDigit() }
            Slider(value: value, in: range).accessibilityLabel(title)
        }
    }
    private func groupedBand(_ title: String, indices: Range<Int>) -> some View {
        control(title, value: Binding(get: {
            indices.map { library.effects.gains[$0] }.reduce(0, +) / Float(indices.count)
        }, set: { value in
            for index in indices { library.effects.gains[index] = value }
        }), range: -12...12, suffix: " dB")
    }
}
