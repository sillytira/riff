import SwiftUI

@main
struct RiffApp: App {
    @State private var library = AudioLibrary()
    var body: some Scene {
        WindowGroup { LibraryView(library: library).tint(.purple) }
    }
}
