import SwiftUI
import UIKit

@MainActor
final class RiffModel {
    let library: AudioLibrary
    let playlists: PlaylistStore
    let downloads: DownloadManager
    init() {
        let library = AudioLibrary()
        self.library = library
        playlists = PlaylistStore()
        downloads = DownloadManager(library: library)
    }
}

@MainActor
final class RiffAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        BackgroundSessionEvents.shared.register(identifier, completion: completionHandler)
    }
}

@main
struct RiffApp: App {
    @UIApplicationDelegateAdaptor(RiffAppDelegate.self) private var delegate
    @State private var model = RiffModel()
    private var appearance = AppearancePreferences()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView(library: model.library, playlists: model.playlists, downloads: model.downloads)
                .onOpenURL { url in
                    if url.isFileURL { Task { await model.library.importFiles([url]) } }
                }
                .tint(appearance.tint)
                .preferredColorScheme(appearance.mode.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.downloads.reconnect() } }
                }
        }
    }
}
