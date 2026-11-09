import SwiftUI

@main
struct project_601App: App {
    /// Portrait everywhere but Help Me Aim's camera (AppOrientation).
    @UIApplicationDelegateAdaptor(AppOrientation.self) private var orientation
    /// The app's language (AppLang): Spanish or English, follows Your language live.
    @ObservedObject private var appLang = AppLangObserver.shared

    init() {
        // MemoryManager registers its memory-warning observer in its init;
        // without this touch the singleton never exists and the app has no
        // response to memory pressure at all.
        _ = MemoryManager.shared
        // Screen stays awake whenever a camera runs (AppleVis user LaBoheme, 2026-11-07).
        ScreenAwake.install()
        #if DEBUG && targetEnvironment(simulator)
        SimulatorSilence.install()
        #endif
        #if DEBUG
        // `-rtcamFreshRatePrompt`: the rating prompt as on a new install.
        if ProcessInfo.processInfo.arguments.contains("-rtcamFreshRatePrompt") { RatePrompt.resetForTests() }
        #endif
        #if DEBUG
        DispatchQueue.main.async { _ = Self.pretendDownloadingIfAsked() }
        // `-rtcamOpenURL <url>`: the Share Extension's hand-over without the system's
        // "Open in" prompt, so the Simulator can test it unattended.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-rtcamOpenURL"), i + 1 < args.count, let url = URL(string: args[i + 1]) {
            DispatchQueue.main.async { SharedImageInbox.shared.handle(url) }
        }
        #endif
        // Rating prompt: never during the first launch.
        RatePrompt.noteLaunch()
        #if DEBUG
        // UI tests: `-rtcamFreshReadMode` forgets the saved Read mode, like a new install.
        if ProcessInfo.processInfo.arguments.contains("-rtcamFreshReadMode") {
            UserDefaults.standard.removeObject(forKey: ReadMode.storageKey)
        }
        // `-rtcamFreshYourLanguage`: like a new install for Your language (choice,
        // first-launch line, test packs, saved object names).
        if ProcessInfo.processInfo.arguments.contains("-rtcamFreshYourLanguage") {
            for k in [YourLanguage.key, YourLanguage.announcedKey, "fakeTranslatorPacks"] {
                UserDefaults.standard.removeObject(forKey: k)
            }
            try? FileManager.default.removeItem(at: ObjectLabelCache.directory)
        }
        #endif
    }

    #if DEBUG
    /// `-rtcamFakeDownloading <level>` with `-rtcamShowModels`: a download shown in progress.
    @MainActor
    private static func pretendDownloadingIfAsked() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-rtcamFakeDownloading"), i + 1 < args.count,
              let level = ModelLevel(rawValue: args[i + 1]) else { return false }
        VisionModelDownloader.shared.debugPretendDownloading(level)
        return true
    }
    #endif

    @ViewBuilder
    private var rootView: some View {
        #if HELP_ME_AIM_SHOT_LOG
        // Dev-install test aid only: `-roomScan N` opens the room census.
        if RoomScan.requestedSeconds > 0 {
            RoomScanView()
        } else if AimFake.word != nil {
            HelpMeAimView(voiceIdentifier: "", onBack: {})
        } else {
            ContentView()
        }
        #elseif DEBUG
        // Debug builds only: `-rtcamShowModels` opens Settings > Models on its own,
        // so the card can be screenshotted in a Simulator nobody is driving.
        if ProcessInfo.processInfo.arguments.contains("-rtcamShowModels") {
            VStack { ModelsCardView().padding(); ModelsChooserView() }
        } else if AimFake.word != nil {
            HelpMeAimView(voiceIdentifier: "", onBack: {})
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
                // Your language: one invisible host serves Apple's translator to every screen.
                .yourLanguageHost()
                // Volume all the way down: say so, on every screen (2026-11-04).
                .overlay(alignment: .top) { VolumeOffNote() }
                // Dates, numbers and system controls in the app's language too.
                .environment(\.locale, Locale(identifier: appLang.code))
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                // rtcam://shared-image?id=... from the Share Extension, cold launch included:
                // the picture waits in SharedImageInbox until ContentView opens it.
                .onOpenURL { url in SharedImageInbox.shared.handle(url) }
                // The link can fail to arrive (iOS may refuse an extension's open): a picture
                // still waiting in the App Group opens whenever the app comes to the front.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    SharedImageInbox.shared.checkFolder()
                }
                .task {
                    // 1.4.0: speed check once, then fetch this phone's level.
                    ModelSetup.shared.launch()
                    // Your language: ask Apple what's on the phone (never downloads), then,
                    // once on a first launch in a supported non-English language, say so.
                    await YourLanguage.shared.refresh()
                    if let line = YourLanguage.shared.firstLaunchLineIfDue() {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        NSLog("YourLanguage: first launch line")
                        #if DEBUG
                        SpeakLog.note("firstLaunch", line)
                        #endif
                        SpeechManager.shared.speak(line)
                    }
                    // On-phone photo test: only with the -rtcamPhotoTest launch argument.
                    if #available(iOS 17.0, *), PhotoSetTest.requested { await PhotoSetTest.run() }
                    if #available(iOS 17.0, *), PhotoSetTest.twoAtOnceRequested { await PhotoSetTest.runTwoAtOnce() }
                    if #available(iOS 17.0, *), PhotoSetTest.askTestRequested { await PhotoSetTest.runAskTest() }
                }
        }
    }
}
