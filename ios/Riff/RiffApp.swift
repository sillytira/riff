import SwiftUI

@main
struct RiffApp: App {
    @State private var library = AudioLibrary()
    var body: some Scene {
        WindowGroup { RootView(library: library).tint(.purple) }
    }
}
