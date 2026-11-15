import SwiftUI

enum InterfaceAppearance: String, CaseIterable {
    case system, light, dark
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

enum AccentChoice: String, CaseIterable {
    case purple, blue, pink, red, orange, green, teal, custom
    var title: String { rawValue.capitalized }
}

struct AppearancePreferences: DynamicProperty {
    @AppStorage("riff.appearance") var mode: InterfaceAppearance = .system
    @AppStorage("riff.accent") var accent: AccentChoice = .purple
    @AppStorage("riff.accent.red") var red = 0.65
    @AppStorage("riff.accent.green") var green = 0.25
    @AppStorage("riff.accent.blue") var blue = 0.95

    var customColor: Color { Color(red: red, green: green, blue: blue) }
    var tint: Color {
        switch accent {
        case .purple: .purple
        case .blue: .blue
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .green: .green
        case .teal: .teal
        case .custom: customColor
        }
    }
    func reset() {
        mode = .system; accent = .purple
        red = 0.65; green = 0.25; blue = 0.95
    }
}

struct AppearanceSettings: View {
    private var appearance = AppearancePreferences()
    @Environment(\.self) private var environment
    var body: some View {
        Section("Appearance") {
            Picker("Color scheme", selection: appearance.$mode) {
                ForEach(InterfaceAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).accessibilityIdentifier("appearance-mode")
            Picker("Accent color", selection: appearance.$accent) {
                ForEach(AccentChoice.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).accessibilityIdentifier("appearance-accent")
            if appearance.accent == .custom {
                ColorPicker("Custom accent", selection: Binding(get: { appearance.customColor }, set: { color in
                    let resolved = color.resolve(in: environment)
                    appearance.red = Double(resolved.red)
                    appearance.green = Double(resolved.green)
                    appearance.blue = Double(resolved.blue)
                }), supportsOpacity: false)
            }
            Button("Reset appearance") { appearance.reset() }
        }
    }
}
