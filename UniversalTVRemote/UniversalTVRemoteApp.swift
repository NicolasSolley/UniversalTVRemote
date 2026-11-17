import SwiftUI

@main
struct UniversalTVRemoteApp: App {
    init() {
        // v1.0.54: clay was removed — move anyone still on it to teal.
        PadTheme.migrateIfNeeded()
    }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
