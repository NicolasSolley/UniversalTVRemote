import SwiftUI

@main
struct UniversalTVRemoteApp: App {
    init() {
        // v1.0.54: clay was removed — move anyone still on it to teal.
        PadTheme.migrateIfNeeded()
        // v1.0.58: Glow trail was renamed to Line — move anyone
        // still on "glow" to "line".
        TrailStyle.migrateIfNeeded()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
