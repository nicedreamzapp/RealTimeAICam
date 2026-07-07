import SwiftUI

@main
struct project_601App: App {
    init() {
        // MemoryManager registers its memory-warning observer in its init;
        // without this touch the singleton never exists and the app has no
        // response to memory pressure at all.
        _ = MemoryManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
