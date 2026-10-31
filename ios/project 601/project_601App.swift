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
        #elseif DEBUG
        // Debug builds only: `-rtcamShowModels` opens Settings > Models on its own,
        // so the card can be screenshotted in a Simulator nobody is driving.
        if ProcessInfo.processInfo.arguments.contains("-rtcamShowModels") {
            VStack { ModelsCardView().padding(); ModelsChooserView() }
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
                .task {
                    #if DEBUG
                    // Debug builds only: `-rtcamOpenTalk` opens Talk, for simulator screenshots.
                    if ProcessInfo.processInfo.arguments.contains("-rtcamOpenTalk") { ShortcutRouter.shared.open(.talk) }
                    #endif
                    // 1.4.0: speed check once, then fetch this phone's level.
                    ModelSetup.shared.launch()
                    // On-phone photo test: only with the -rtcamPhotoTest launch argument.
                    if #available(iOS 17.0, *), PhotoSetTest.requested { await PhotoSetTest.run() }
                    if #available(iOS 17.0, *), PhotoSetTest.twoAtOnceRequested { await PhotoSetTest.runTwoAtOnce() }
                    // Talk timing test: only with the -rtcamTalkTest launch argument.
                    if #available(iOS 17.0, *), TalkSelfTest.requested { await TalkSelfTest.run() }
                }
        }
    }
}
