import AVFoundation
import SwiftUI

struct HomeView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Binding var animationState: ContentView.AnimationState
    @Binding var mode: AppMode
    @State private var showInstructions = false
    /// The guide on screen is the automatic first-launch one (not opened with INFO).
    @State private var guideIsFirstLaunch = false
    /// Settings, Models included, right from home; it used to be only inside
    /// the reader screens (Matt, 2026-11-03).
    @State private var showSettings = false
    /// VoiceOver lands on Settings when the guide closes (first-time-user test, 2026-11-04).
    @AccessibilityFocusState private var settingsFocused: Bool
    @ObservedObject private var modelDownloader = VisionModelDownloader.shared
    /// Redraws the buttons when Your language switches the app between Spanish and English.
    @ObservedObject private var appLang = AppLangObserver.shared
    /// Last quarter (25/50/75/100) already spoken aloud, so each is said once.
    @State private var spokenDownloadQuarter = 0

    @StateObject var buttonDebouncer: ButtonPressDebouncer

    let onEnglishOCR: () -> Void
    let onObjectDetection: () -> Void
    let onReadMail: () -> Void
    let onHelpMeAim: () -> Void
    /// Live Cam: talk with the camera, it answers out loud (from Moonstone, 2026-11-03).
    var onLiveCam: () -> Void = {}
    let onVoiceChange: () -> Void
    let speechSynthesizer: AVSpeechSynthesizer

    // MARK: - Vision model download

    @ObservedObject private var modelSetup = ModelSetup.shared

    /// One small row under the buttons, shown only while a smarter level for
    /// this phone is downloading, or waiting for a tap because the phone is off
    /// Wi-Fi. Balanced ships inside the app, so What's this? always works.
    @ViewBuilder
    private var visionModelBanner: some View {
        if let level = modelDownloader.current {
            let verifying = modelDownloader.state(level) == .verifying
            let percent = Int((modelDownloader.progress * 100).rounded(.down))
            VStack(spacing: 4) {
                Text(verifying ? L("Checking the %@ model…", level.name)
                     : L("Downloading the %@ model… %ld%%", level.name, percent))
                    .font(.footnote.weight(.semibold))
                    .accessibilityHidden(true)
                ProgressView(value: modelDownloader.progress)
                    .tint(.white)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(verifying ? L("Checking the %@ model…", level.name)
                                        : L("Downloading the %@ model, %ld percent", level.name, percent))
                Button {
                    modelSetup.stop(level)
                    UIAccessibility.post(notification: .announcement,
                                         argument: L("Stopped. %@ won't download unless you choose it.", level.name))
                } label: {
                    Label(L("Stop download"), systemImage: "stop.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 12)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(10)
                }
                .accessibilityLabel(L("Stop downloading %@", level.name))
            }
            .padding(.bottom, 6)
        } else if let level = modelSetup.missingWanted.first {
            VStack(spacing: 4) {
                if case .failed(let why) = modelDownloader.state(level) {
                    Text(L("Download failed: %@", why))
                        .font(.footnote)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                }
                Button {
                    modelSetup.fetchWanted(automatic: false)
                } label: {
                    Text(L("Get the %@ model for this phone (%@, one time, Wi-Fi recommended)", level.name, level.sizeDescription))
                        .font(.footnote.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(10)
                }
                .accessibilityLabel(L("Get the %@ model for this phone", level.name))
                .accessibilityHint(L("%@, one time, Wi-Fi recommended. What's this? gets more accurate. It already works without it.", level.sizeDescription))
            }
            .padding(.bottom, 6)
        }
    }

    /// Speaks 25, 50, 75 and 100 percent, each once, through the app's voice.
    private func announceDownloadProgress(_ value: Double) {
        guard let level = modelDownloader.current else { return }
        let quarter = Int((value * 4).rounded(.down))
        guard quarter > spokenDownloadQuarter, quarter >= 1 else { return }
        spokenDownloadQuarter = quarter
        if quarter >= 4 {
            // "ready" is said by the downloader once the check passes.
        } else {
            SpeechManager.shared.speak(L("%@ model download %ld percent.", level.name, quarter * 25))
        }
    }

    var body: some View {
        // Use iPhone 14 Pro Max (390pt) as baseline
        let screenWidth = UIScreen.main.bounds.width
        let scale = min(screenWidth / 390, 1.0)

        return ZStack {
            splashBackground

            // Natural spacing that can never overlap: when the six buttons
            // don't fit the screen (iPhone SE), the page scrolls instead of
            // squeezing them together (Matt, 2026-11-03).
            // Centered on the whole screen, and as wide on both sides as the
            // side with the camera allows (iPhone Duo folded has an 84 pt
            // camera strip on one edge; centering in the safe area left the
            // tools lopsided, 2026-11-04).
            GeometryReader { outer in
                let leading = outer.safeAreaInsets.leading
                let trailing = outer.safeAreaInsets.trailing
                let usable = outer.size.width + leading + trailing - 2 * max(leading, trailing)
                // The unfolded iPhone Duo is a wide, short screen even in
                // portrait (951 x 669 pt): one column cut Live Cam off at the
                // bottom, so wide screens put the title on the left and the
                // tools on the right (2026-11-04). Phones keep the column.
                Group {
                    if usable > outer.size.height * 1.2 {
                        ViewThatFits(in: .vertical) {
                            homeWide(scale: 1.0)
                            ScrollView(showsIndicators: false) { homeWide(scale: 1.0) }
                        }
                    } else {
                        ViewThatFits(in: .vertical) {
                            homeColumn(scale: scale, screenWidth: min(screenWidth, usable))
                            ScrollView(showsIndicators: false) {
                                homeColumn(scale: scale, screenWidth: min(screenWidth, usable))
                            }
                        }
                    }
                }
                .frame(width: usable)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Slide back to the middle of the whole screen.
                .offset(x: (trailing - leading) / 2)
            }
        }
        .overlay {
            if showSettings {
                SettingsOverlayView(viewModel: viewModel, isPresented: $showSettings, mode: .home)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .sheet(isPresented: $showInstructions, onDismiss: guideClosed) {
            AppInstructionsView(selectedVoiceIdentifier: viewModel.selectedVoiceIdentifier)
                .onAppear {
                    if buttonDebouncer.canPress("HomeView-1") {
                        viewModel.pauseCameraAndProcessing()
                    }
                }
                .onDisappear {
                    if buttonDebouncer.canPress("HomeView-2") {
                        if mode == .objectDetection {
                            viewModel.resumeCameraAndProcessing()
                        }
                    }
                }
        }
        // A picture shared from another app opens over everything; the guide sheet and
        // Settings would hide it. A first-launch guide closed for it comes back next launch.
        .onReceive(SharedImageInbox.shared.$current) { shared in
            guard shared != nil else { return }
            showSettings = false
            if showInstructions {
                showInstructions = false
                // Only the automatic first-launch guide comes back next launch.
                if guideIsFirstLaunch { UserDefaults.standard.set(false, forKey: "hasShownInstructions") }
            }
        }
        .onChange(of: modelDownloader.progress) { _, value in
            announceDownloadProgress(value)
        }
        .onChange(of: modelDownloader.current) { _, new in
            if new != nil { spokenDownloadQuarter = 0 }
        }
        .onAppear {
            if !animationState.hasAnimatedOnce {
                animateInSequence()
                animationState.hasAnimatedOnce = true
            } else {
                animationState.showAll()
            }

            #if DEBUG
            // `-rtcamOpenSettings`: Settings open at launch, for Simulator checks.
            if ProcessInfo.processInfo.arguments.contains("-rtcamOpenSettings") { showSettings = true }
            #endif
            // Not over a shared picture (the app opened from the share sheet): next launch.
            if !UserDefaults.standard.bool(forKey: "hasShownInstructions"), !SharedImageInbox.shared.isBusy {
                showInstructions = true
                guideIsFirstLaunch = true
                UserDefaults.standard.set(true, forKey: "hasShownInstructions")
            }
        }
    }

    /// Done on the guide (first-time-user test, 2026-11-04): home came back in silence with
    /// focus on nothing. "Home" is said once, then VoiceOver lands on Settings, the first control.
    private func guideClosed() {
        guideIsFirstLaunch = false
        let voiceId = viewModel.selectedVoiceIdentifier
        let synth = speechSynthesizer
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(UICue.homeCueDelay * 1_000_000_000))
            // Still home (not straight into a tool, not a shared picture): otherwise say nothing.
            guard mode == .home, !showInstructions, !SharedImageInbox.shared.isBusy else { return }
            await UICue.say(UICue.home, stillWanted: {
                mode == .home && !showInstructions && !SharedImageInbox.shared.isBusy
            }) { text, lang in
                // The picked voice only for its own language, else the best voice for `lang`.
                let prepared = YourLanguageVoice.prepare(text, lang: lang, selected: voiceId)
                let utterance = AVSpeechUtterance(string: prepared.text)
                utterance.voice = prepared.voice
                utterance.rate = 0.5
                synth.speak(utterance)
            }
            guard UIAccessibility.isVoiceOverRunning else { return }
            try? await Task.sleep(nanoseconds: UInt64(UICue.homeFocusDelay * 1_000_000_000))
            guard mode == .home, !showInstructions, !SharedImageInbox.shared.isBusy else { return }
            settingsFocused = true
        }
    }

    // MARK: - View Components

    private var splashBackground: some View {
        GeometryReader { _ in
            Image("SplashScreen")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea(.all, edges: .all)
                .accessibilityHidden(true)
        }
    }

    private func englishOCRButton(scale: CGFloat, screenWidth: CGFloat) -> some View {
        Button(action: {
            guard buttonDebouncer.canPress("HomeView-3") else { return }
            onEnglishOCR()
        }) {
            HStack(spacing: 4 * scale) {
                // Read + Translate in one: English, or 17 languages into
                // English from the pill at the top (2026-11-03).
                Text("📖").font(.system(size: 32 * scale))
                OutlinedText(text: L("Read"), fontSize: 20 * scale)
                Text("🌍").font(.system(size: 26 * scale))
            }
            .padding(.vertical, 14 * scale)
            .frame(maxWidth: .infinity)
        }
        // Adaptive width with maxWidth capped at 340 * scale or screen width minus 36
        .frame(width: min(320 * scale, screenWidth - 64), alignment: .center)
        .contentShape(Capsule())
        .padding(.horizontal, 8 * scale)
        .background(
            ZStack {
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.white.opacity(0.23), Color.blue.opacity(0.50)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Capsule()
                    .fill(Color.white.opacity(0.13))
                    .frame(height: 24 * scale)
                    .offset(y: -18 * scale)
                Capsule().stroke(Color.white.opacity(0.80), lineWidth: 4.8 * scale)
                Capsule().stroke(Color.blue, lineWidth: 2.4 * scale)
                Capsule()
                    .fill(Color.black.opacity(0.12))
                    .blur(radius: 7 * scale)
                    .offset(y: 16 * scale)
            }
        )
        .shadow(color: Color.black.opacity(0.38), radius: 15 * scale, y: 5 * scale)
        .clipShape(Capsule())
        .opacity(animationState.button1 ? 1 : 0)
        .shadow(color: Color.blue.opacity(0.50), radius: 12 * scale)
        .scaleEffect(animationState.button1 ? 1 : 0.7)
        .animation(.easeOut(duration: 0.3), value: animationState.button1)
        .accessibilityLabel(L("Read"))
        .accessibilityHint(L("Reads text out loud. Pick another language at the top to translate it into English"))
        .accessibilityAddTraits(.isButton)
    }

    private func objectDetectionButton(scale: CGFloat, screenWidth: CGFloat) -> some View {
        Button(action: {
            guard buttonDebouncer.canPress("HomeView-5") else { return }
            onObjectDetection()
        }) {
            HStack(spacing: 4 * scale) {
                Text("🐶").font(.system(size: 35 * scale))
                OutlinedText(text: L("Object Detection"), fontSize: 20 * scale)
            }
            .padding(.vertical, 14 * scale)
            .frame(maxWidth: .infinity)
        }
        // Adaptive width with maxWidth capped at 340 * scale or screen width minus 36
        .frame(width: min(320 * scale, screenWidth - 64), alignment: .center)
        .contentShape(Capsule())
        .padding(.horizontal, 8 * scale)
        .background(
            ZStack {
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.white.opacity(0.23), Color.orange.opacity(0.50)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Capsule()
                    .fill(Color.white.opacity(0.13))
                    .frame(height: 24 * scale)
                    .offset(y: -18 * scale)
                Capsule().stroke(Color.white.opacity(0.80), lineWidth: 4.8 * scale)
                Capsule().stroke(Color.orange, lineWidth: 2.4 * scale)
                Capsule()
                    .fill(Color.black.opacity(0.12))
                    .blur(radius: 7 * scale)
                    .offset(y: 16 * scale)
            }
        )
        .shadow(color: Color.black.opacity(0.38), radius: 15 * scale, y: 5 * scale)
        .clipShape(Capsule())
        .opacity(animationState.button3 ? 1 : 0)
        .shadow(color: Color.orange.opacity(0.50), radius: 12 * scale)
        .scaleEffect(animationState.button3 ? 1 : 0.7)
        .animation(.easeOut(duration: 0.3), value: animationState.button3)
        .accessibilityLabel(L("Object Detection"))
        .accessibilityHint(L("Identify objects around you and hear them announced"))
        .accessibilityAddTraits(.isButton)
    }

    private func readMailButton(scale: CGFloat, screenWidth: CGFloat) -> some View {
        Button(action: {
            guard buttonDebouncer.canPress("HomeView-6") else { return }
            onReadMail()
        }) {
            HStack(spacing: 4 * scale) {
                Text(verbatim: "\u{1F4C4}").font(.system(size: 32 * scale))
                OutlinedText(text: L("What's this?"), fontSize: 20 * scale)
            }
            .padding(.vertical, 14 * scale)
            .frame(maxWidth: .infinity)
        }
        .frame(width: min(320 * scale, screenWidth - 64), alignment: .center)
        .contentShape(Capsule())
        .padding(.horizontal, 8 * scale)
        .background(
            ZStack {
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.white.opacity(0.23), Color.purple.opacity(0.50)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Capsule()
                    .fill(Color.white.opacity(0.13))
                    .frame(height: 24 * scale)
                    .offset(y: -18 * scale)
                Capsule().stroke(Color.white.opacity(0.80), lineWidth: 4.8 * scale)
                Capsule().stroke(Color.purple, lineWidth: 2.4 * scale)
                Capsule()
                    .fill(Color.black.opacity(0.12))
                    .blur(radius: 7 * scale)
                    .offset(y: 16 * scale)
            }
        )
        .shadow(color: Color.black.opacity(0.38), radius: 15 * scale, y: 5 * scale)
        .clipShape(Capsule())
        .opacity(animationState.button4 ? 1 : 0)
        .shadow(color: Color.purple.opacity(0.50), radius: 12 * scale)
        .scaleEffect(animationState.button4 ? 1 : 0.7)
        .animation(.easeOut(duration: 0.3), value: animationState.button4)
        .accessibilityLabel(L("What's this?"))
        .accessibilityHint(L("Point the camera at a page, a bill, a package, or a room to hear what it is"))
        .accessibilityAddTraits(.isButton)
    }

    /// Help Me Aim: say what you want a picture of and the app talks you into
    /// the shot, then takes it. Dennis Long asked for Pixel Guided Frame.
    private func helpMeAimButton(scale: CGFloat, screenWidth: CGFloat) -> some View {
        Button(action: {
            guard buttonDebouncer.canPress("HomeView-8") else { return }
            onHelpMeAim()
        }) {
            HStack(spacing: 4 * scale) {
                Text(verbatim: "\u{1F3AF}").font(.system(size: 32 * scale))
                OutlinedText(text: L("Help Me Aim"), fontSize: 20 * scale)
            }
            .padding(.vertical, 14 * scale)
            .frame(maxWidth: .infinity)
        }
        .frame(width: min(320 * scale, screenWidth - 64), alignment: .center)
        .contentShape(Capsule())
        .padding(.horizontal, 8 * scale)
        .background(
            ZStack {
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.white.opacity(0.23), Color.teal.opacity(0.50)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Capsule()
                    .fill(Color.white.opacity(0.13))
                    .frame(height: 24 * scale)
                    .offset(y: -18 * scale)
                Capsule().stroke(Color.white.opacity(0.80), lineWidth: 4.8 * scale)
                Capsule().stroke(Color.teal, lineWidth: 2.4 * scale)
                Capsule()
                    .fill(Color.black.opacity(0.12))
                    .blur(radius: 7 * scale)
                    .offset(y: 16 * scale)
            }
        )
        .shadow(color: Color.black.opacity(0.38), radius: 15 * scale, y: 5 * scale)
        .clipShape(Capsule())
        .opacity(animationState.button5 ? 1 : 0)
        .shadow(color: Color.teal.opacity(0.50), radius: 12 * scale)
        .scaleEffect(animationState.button5 ? 1 : 0.7)
        .animation(.easeOut(duration: 0.3), value: animationState.button5)
        .accessibilityLabel(L("Help Me Aim"))
        .accessibilityHint(L("Tell the camera what you want a picture of. It talks you into the shot, then takes the photo"))
        .accessibilityAddTraits(.isButton)
    }

    /// Live Cam: a live conversation with the camera. Ask out loud, it looks
    /// and answers, and keeps talking about what it sees.
    private func liveCamButton(scale: CGFloat, screenWidth: CGFloat) -> some View {
        Button(action: {
            guard buttonDebouncer.canPress("HomeView-9") else { return }
            onLiveCam()
        }) {
            HStack(spacing: 4 * scale) {
                Text(verbatim: "\u{1F4AC}").font(.system(size: 32 * scale))
                // Matt 11/4: Live Cam says it's experimental. The tag sits under the name, inside the
                // emoji's line height, so the button is no taller than the others.
                VStack(spacing: 0) {
                    OutlinedText(text: "Live Cam", fontSize: 20 * scale)
                    Text(L("EXPERIMENTAL"))
                        .font(.system(size: 9 * scale, weight: .heavy, design: .rounded))
                        .kerning(0.6 * scale)
                        .foregroundColor(.white)
                        .padding(.horizontal, 5 * scale)
                        .background(Capsule().fill(Color.pink.opacity(0.75)))
                }
            }
            .padding(.vertical, 14 * scale)
            .frame(maxWidth: .infinity)
        }
        .frame(width: min(320 * scale, screenWidth - 64), alignment: .center)
        .contentShape(Capsule())
        .padding(.horizontal, 8 * scale)
        .background(
            ZStack {
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.white.opacity(0.23), Color.pink.opacity(0.50)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Capsule()
                    .fill(Color.white.opacity(0.13))
                    .frame(height: 24 * scale)
                    .offset(y: -18 * scale)
                Capsule().stroke(Color.white.opacity(0.80), lineWidth: 4.8 * scale)
                Capsule().stroke(Color.pink, lineWidth: 2.4 * scale)
                Capsule()
                    .fill(Color.black.opacity(0.12))
                    .blur(radius: 7 * scale)
                    .offset(y: 16 * scale)
            }
        )
        .shadow(color: Color.black.opacity(0.38), radius: 15 * scale, y: 5 * scale)
        .clipShape(Capsule())
        .opacity(animationState.button5 ? 1 : 0)
        .shadow(color: Color.pink.opacity(0.50), radius: 12 * scale)
        .scaleEffect(animationState.button5 ? 1 : 0.7)
        .animation(.easeOut(duration: 0.3), value: animationState.button5)
        .accessibilityLabel(L("Live Cam, experimental"))
        .accessibilityHint(L("Talk with the camera. Ask out loud about what's in front of you and hear the answer"))
        .accessibilityAddTraits(.isButton)
    }

    private var voicePicker: some View {
        AnimatedVoicePicker(
            viewModel: viewModel,
            animateIn: animationState.picker,
            onVoiceChange: onVoiceChange,
            speechSynthesizer: speechSynthesizer
        )
        .onTapGesture {
            _ = buttonDebouncer.canPress("HomeView-6")
        }
    }

    private var settingsButton: some View {
        Button(action: {
            guard buttonDebouncer.canPress("HomeView-10") else { return }
            withAnimation { showSettings = true }
        }) {
            HStack(spacing: 6) {
                Text("⚙️").font(.system(size: 14))
                OutlinedText(text: L("Settings").uppercased(with: AppLang.locale), fontSize: 14)
            }
            .foregroundColor(.white)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
        }
        .background(
            ZStack {
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.white.opacity(0.23), Color.black.opacity(0.50)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Capsule().stroke(Color.white.opacity(0.80), lineWidth: 4.8)
                Capsule().stroke(Color.black, lineWidth: 2.4)
            }
        )
        .shadow(color: Color.black.opacity(0.38), radius: 12, y: 5)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Settings"))
        .accessibilityHint(L("Models, voice and other settings"))
        .accessibilityAddTraits(.isButton)
        .accessibilityFocused($settingsFocused)
    }

    private func homeColumn(scale: CGFloat, screenWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 18 * scale) {
                // Centered and first in the swipe order: Settings, Info, the
                // title, the five tools, the voice (2026-11-03).
                // Never wraps ("INF O / GUID E" on the folded Duo): each pill
                // keeps its natural width, and the pair may use the side margins.
                HStack(spacing: 10) {
                    settingsButton.fixedSize()
                    infoButton.fixedSize()
                }
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 10 * scale)
                heading
                VStack(spacing: 28 * scale) {
                    englishOCRButton(scale: scale, screenWidth: screenWidth)
                    objectDetectionButton(scale: scale, screenWidth: screenWidth)
                    readMailButton(scale: scale, screenWidth: screenWidth)
                    helpMeAimButton(scale: scale, screenWidth: screenWidth)
                    liveCamButton(scale: scale, screenWidth: screenWidth)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                visionModelBanner
                voicePicker
                    .padding(.top, 10)
            }
            .padding(.horizontal)
            .padding(.top, 14)
            .padding(.bottom, 30)
            Spacer(minLength: 0)
        }
    }

    /// The title pill, never wider than on the biggest phone.
    private var heading: some View {
        HeadingView(animateIn: animationState.heading)
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
    }

    /// Wide screens (unfolded iPhone Duo): Settings, Info and the title on the
    /// left, the five tools and the voice on the right. Swipe order is the same
    /// as the phone column: Settings, Info, the title, the tools, the voice.
    private func homeWide(scale: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 32) {
            VStack(spacing: 28) {
                HStack(spacing: 10) {
                    settingsButton.fixedSize()
                    infoButton.fixedSize()
                }
                .fixedSize()
                heading
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilitySortPriority(2)
            VStack(spacing: 18) {
                VStack(spacing: 28) {
                    englishOCRButton(scale: scale, screenWidth: 390)
                    objectDetectionButton(scale: scale, screenWidth: 390)
                    readMailButton(scale: scale, screenWidth: 390)
                    helpMeAimButton(scale: scale, screenWidth: 390)
                    liveCamButton(scale: scale, screenWidth: 390)
                }
                visionModelBanner
                voicePicker
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilitySortPriority(1)
        }
        .accessibilityElement(children: .contain)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxHeight: .infinity)
    }

    private var infoButton: some View {
        Button(action: {
            guard buttonDebouncer.canPress("HomeView-7") else { return }
            showInstructions = true
        }) {
            HStack(spacing: 6) {
                OutlinedText(text: L("INFO"), fontSize: 14)
                Text("💡").font(.system(size: 14))
                OutlinedText(text: L("GUIDE"), fontSize: 14)
            }
            .foregroundColor(.white)
            .padding(.vertical, 12)
            .padding(.horizontal, 18)
        }
        .background(
            ZStack {
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color.white.opacity(0.23), Color.black.opacity(0.50)]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Capsule()
                    .fill(Color.white.opacity(0.13))
                    .frame(height: 24)
                    .offset(y: -18)
                Capsule().stroke(Color.white.opacity(0.80), lineWidth: 4.8)
                Capsule().stroke(Color.black, lineWidth: 2.4)
                Capsule()
                    .fill(Color.black.opacity(0.12))
                    .blur(radius: 7)
                    .offset(y: 16)
            }
        )
        .shadow(color: Color.black.opacity(0.38), radius: 12, y: 5)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Info and guide"))
        .accessibilityHint(L("Opens the instructions, including a spoken audio tutorial"))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Helper Methods

    private func animateInSequence() {
        animationState.reset()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            animationState.splash = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            animationState.heading = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) {
            animationState.button1 = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.20) {
            animationState.button2 = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.70) {
            animationState.button3 = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.20) {
            animationState.button4 = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.70) {
            animationState.button5 = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.20) {
            animationState.picker = true
        }
    }
}
