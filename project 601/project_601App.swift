import SwiftUI

@main
struct project_601App: App {
    init() {
        // MemoryManager registers its memory-warning observer in its init;
        // without this touch the singleton never exists and the app has no
        // response to memory pressure at all.
        _ = MemoryManager.shared
    }

    @ViewBuilder
    private var rootView: some View {
        #if HELP_ME_AIM_SHOT_LOG
        // Dev-install test aid only: `-roomScan N` opens the room census.
        if RoomScan.requestedSeconds > 0 {
            RoomScanView()
        } else {
            ContentView()
        }
        #else
        ContentView()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
