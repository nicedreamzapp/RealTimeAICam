// Live Cam, full screen (ported from Moonstone's LiveCameraView, 2026-11-04): the camera, a soft orb that shows
// listening / thinking / speaking, what it heard and what it is saying in big words, and few, big controls:
// Mode (Normal, Funny, Analyze, Coach, plus Speak up), Words on screen, Flip camera, Mute and one red Back.
// Matt 11/6: Words on screen off means no words at all, and its switch sits in the top bar, not the menu.
// Built for VoiceOver first: every control is labeled with a hint, the camera itself is hidden from VoiceOver,
// the two-finger double tap stops it talking and the escape scrub (two-finger Z) leaves.
// Matt 11/3 kept: no yellow "Probably guessing" sign on screen in any mode (the notice is only logged).
import AVFoundation
import SwiftUI

private struct LiveCamPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context _: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_: PreviewView, context _: Context) {}
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

struct LiveCamView: View {
    let onBack: () -> Void
    @StateObject private var call = LiveCallController()
    @ObservedObject private var appLang = AppLangObserver.shared
    @State private var showModes = false
    @State private var zoomStart: CGFloat?
    @State private var zoomLabel: CGFloat = 1
    @State private var typed = ""

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if let still = call.camera.stillFrame {
                    Image(decorative: still, scale: 1).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped().ignoresSafeArea()
                        .accessibilityHidden(true)
                } else {
                    LiveCamPreview(session: call.camera.session).ignoresSafeArea().accessibilityHidden(true)
                }
                if call.showCaption, abs(zoomLabel - 1) > 0.05 {
                    VStack {
                        Text(String(format: zoomLabel < 10 ? "%.1f×" : "%.0f×", zoomLabel))
                            .font(.footnote.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5).background(.black.opacity(0.45), in: Capsule())
                            .padding(.top, 80)
                        Spacer()
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
                LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea().accessibilityHidden(true)
                VStack(spacing: wide ? 10 : 16) {
                    topBar
                    Spacer(minLength: 0)
                    words(wide: wide)
                    if call.hearingStopped {
                        Text(L(LiveCamWords.cantHearNote))
                            .font(.callout.weight(.semibold)).foregroundStyle(.white).multilineTextAlignment(.center)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                            .opacity(call.showCaption ? 1 : 0.001)
                            .accessibilityIdentifier("liveCamCantHear")
                    }
                    if call.typedOnly || call.hearingStopped { typedBox }
                    orb(size: wide ? 96 : 120)
                    bottomBar
                }
                // The menu floats over the view, so Mute and Back never move or leave the screen.
                .overlay(alignment: .top) { if showModes { modeMenu.padding(.top, 76) } }
                .frame(maxWidth: 640)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
        }
        // Moonstone 11/2: spread two fingers to zoom in, pinch to zoom out, double-tap back to 1x, on the whole screen.
        .contentShape(Rectangle())
        .simultaneousGesture(MagnifyGesture()
            .onChanged { v in
                let start = zoomStart ?? call.camera.zoom
                if zoomStart == nil { zoomStart = start }
                let z = start * v.magnification
                call.camera.setZoom(z); zoomLabel = z
            }
            .onEnded { _ in zoomStart = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { zoomLabel = call.camera.zoom } })
        .simultaneousGesture(TapGesture(count: 2).onEnded { call.camera.setZoom(1); zoomLabel = 1 })
        .statusBarHidden()
        .accessibilityAction(.magicTap) { call.interrupt() }
        .accessibilityAction(.escape) { call.end() }
        .onAppear {
            call.onEnd = { onBack() }
            call.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                // Matt 11/6: no experimental warning at open; VoiceOver hears just the screen's name.
                UIAccessibility.post(notification: .screenChanged,
                                     argument: SpeechManager.voiceOverLine(L("Live Cam"), lang: AppLang.code))
            }
        }
        .onDisappear { call.end() }
    }

    // MARK: Top: mode and flip

    private var topBar: some View {
        HStack(spacing: 12) {
            // Matt 11/1 (Moonstone): a real dropdown. Tap the pill, the modes show, tap one, it stays until changed.
            Button { withAnimation(.easeOut(duration: 0.15)) { showModes.toggle() } } label: {
                HStack(spacing: 6) {
                    Text(L("Mode: %@", L(call.mode.label)))
                    Image(systemName: showModes ? "chevron.up" : "chevron.down").font(.caption.weight(.bold))
                }
                .font(.body.weight(.semibold))
                .padding(.horizontal, 18)
                .frame(minHeight: 56)
                .background(.black.opacity(0.45), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
            }
            .accessibilityLabel(L("Mode: %@", L(call.mode.label)))
            .accessibilityHint(L("Shows the modes and settings. You can also say funny mode, analyze mode, coach mode or normal mode."))
            Spacer(minLength: 0)
            Button { call.showCaption.toggle() } label: {
                Image(systemName: call.showCaption ? "captions.bubble.fill" : "captions.bubble").font(.title2.weight(.semibold))
                    .frame(width: 60, height: 60)
                    .background(call.showCaption ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.black.opacity(0.45)), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                    .foregroundStyle(call.showCaption ? .black : .white)
            }
            .accessibilityLabel(L("Words on screen"))
            .accessibilityValue(call.showCaption ? L("On") : L("Off"))
            .accessibilityAddTraits(.isToggle)
            .accessibilityHint(L("Shows what Live Cam says in big words. VoiceOver can read them either way"))
            .accessibilityIdentifier("liveCamWordsToggle")
            Button { call.flip() } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title2.weight(.semibold))
                    .frame(width: 60, height: 60).background(.black.opacity(0.45), in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
            }
            .accessibilityLabel(L("Flip camera"))
            .accessibilityHint(L("Switches between the back camera and the selfie camera"))
        }
        .foregroundStyle(.white)
        .padding(.top, 8)
    }

    private var modeMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(LiveMode.allCases, id: \.self) { m in
                Button {
                    call.setMode(m, tapped: true)
                    withAnimation(.easeOut(duration: 0.15)) { showModes = false }
                } label: {
                    HStack {
                        Text(L(m.label)).font(.body.weight(.semibold))
                        Spacer()
                        if m == call.mode { Image(systemName: "checkmark").font(.body.weight(.bold)) }
                    }
                    .padding(.horizontal, 16).frame(minHeight: 56).contentShape(Rectangle())
                }
                .accessibilityLabel(modeName(m))
                .accessibilityHint(modeHint(m))
                .accessibilityAddTraits(m == call.mode ? .isSelected : [])
                Divider().overlay(.white.opacity(0.2))
            }
            Toggle(isOn: $call.proactiveOn) { Text(L("Speak up when quiet")).font(.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true) }
                .padding(.horizontal, 16).padding(.vertical, 6).frame(minHeight: 56)
                .accessibilityHint(L("When on, Live Cam checks in after a long quiet and mentions new things it is sure it sees"))
        }
        .tint(.teal)
        .foregroundStyle(.white)
        .frame(maxWidth: 340)
        .background(.ultraThinMaterial.opacity(0.95), in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
        .transition(.opacity)
    }

    private func modeName(_ m: LiveMode) -> String {
        switch m {
        case .normal: L("Normal mode")
        case .funny: L("Funny mode")
        case .analyze: L("Analyze mode")
        case .coach: L("Coach mode")
        }
    }

    private func modeHint(_ m: LiveMode) -> String {
        switch m {
        case .normal: L("A friendly helper that answers what you ask")
        case .funny: L("Answers, then adds a joke")
        case .analyze: L("Digs into the how and why, and reads everything when you say analyze this")
        case .coach: L("Practical tips on whatever you want to get better at")
        }
    }

    // MARK: Middle: what it heard and what it says

    @ViewBuilder
    private func words(wide: Bool) -> some View {
        VStack(spacing: 8) {
            if call.showCaption, !call.heardText.isEmpty {
                Text(L("You: %@", call.heardText))
                    .font(.system(size: wide ? 17 : 19, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.9), radius: 4)
                    .accessibilityLabel(L("You said: %@", call.heardText))
                    .accessibilityIdentifier("liveCamHeard")
            }
            if !call.caption.isEmpty {
                Text(call.caption)
                    .font(.system(size: wide ? 22 : 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(wide ? 3 : 4).minimumScaleFactor(0.6)
                    .shadow(color: .black.opacity(0.9), radius: 6)
                    .opacity(call.showCaption && !call.captionIsIntro ? 1 : 0.001)   // hidden words stay readable by VoiceOver
                    .accessibilityLabel(call.caption)
                    .accessibilityValue(call.caption)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityIdentifier("liveCamCaption")
                    // The caption's own language (content may be in Your language, not the app's), like the app root does.
                    .environment(\.locale, Locale(identifier: call.captionLang))
            }
            if call.phase == .loading || call.phase == .starting {
                ProgressView().tint(.white).accessibilityLabel(L("Getting Live Cam ready"))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var typedBox: some View {
        HStack(spacing: 8) {
            TextField(L("Type a question"), text: $typed)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit { call.ask(typed: typed); typed = "" }
                .accessibilityIdentifier("liveCamTyped")
            Button(L("Ask")) { call.ask(typed: typed); typed = "" }
                .frame(minWidth: 56, minHeight: 44).foregroundStyle(.white)
        }
    }

    private func orb(size: CGFloat) -> some View {
        VStack(spacing: 6) {
            LiveOrb(phase: call.phase, level: call.micLevel, muted: call.micMuted, still: call.modelBusy)
                .frame(width: size, height: size)
                .onTapGesture { call.interrupt() }
                .accessibilityElement()
                .accessibilityLabel(orbLabel)
                .accessibilityHint(call.phase == .speaking || call.phase == .thinking ? L("Double tap to stop it talking and ask something else") : "")
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityAction { call.interrupt() }
            Text(statusLine).font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                .opacity(call.showCaption ? 1 : 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: Bottom: mute and the one way out

    private var bottomBar: some View {
        HStack(spacing: call.torchAvailable ? 28 : 40) {
            // Matt 11/6: "Live cam needs to have a flashlight... preferably at the bottom". One tap on, one tap off;
            // on the selfie camera it flips to the back camera first. Its word stays even with Words on screen off.
            if call.torchAvailable {
                Button { call.setFlashlight(!call.torchOn) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: call.torchOn ? "flashlight.on.fill" : "flashlight.off.fill").font(.system(size: 28, weight: .semibold))
                            .frame(width: 76, height: 76)
                            .background(call.torchOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.black.opacity(0.45)), in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                            .foregroundStyle(call.torchOn ? .black : .white)
                        Text(L("Flashlight")).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .frame(width: 84)
                }
                .accessibilityLabel(L("Flashlight"))
                .accessibilityValue(call.torchOn ? L("On") : L("Off"))
                .accessibilityAddTraits(.isToggle)
                .accessibilityIdentifier("liveCamFlashlight")
            }
            // Moonstone 11/1 Matt: "call it the mute button so it's obvious".
            Button { call.micMuted.toggle() } label: {
                VStack(spacing: 6) {
                    Image(systemName: call.micMuted ? "mic.slash.fill" : "mic.slash").font(.system(size: 28, weight: .semibold))
                        .frame(width: 76, height: 76)
                        .background(call.micMuted ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.black.opacity(0.45)), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                        .foregroundStyle(call.micMuted ? .black : .white)
                    Text(call.micMuted ? L("Unmute") : L("Mute")).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .accessibilityLabel(call.micMuted ? L("Unmute microphone") : L("Mute microphone"))
            .accessibilityHint(call.micMuted ? L("Live Cam starts listening again") : L("Live Cam stops listening until you unmute"))
            Button { call.end() } label: {
                VStack(spacing: 6) {
                    Image(systemName: "xmark").font(.system(size: 28, weight: .bold))
                        .frame(width: 76, height: 76).background(Color.red, in: Circle()).foregroundStyle(.white)
                    Text(L("Back")).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
            .accessibilityLabel(L("Back"))
            .accessibilityHint(L("Stops Live Cam and goes back to the home screen"))
        }
    }

    private var statusLine: String {
        switch call.phase {
        case .listening: call.micMuted ? L("Microphone muted") : (call.typedOnly || call.hearingStopped ? L("Type a question") : L("Listening · just talk"))
        case .thinking: L("Looking")
        case .speaking: L("Speaking")
        case .downloading, .loading, .starting: L("Getting ready")
        case .ended: L("Ended")
        case .failed: L("Not working")
        }
    }

    private var orbLabel: String {
        switch call.phase {
        case .listening: call.micMuted ? L("Microphone muted") : (call.hearingStopped ? L("Not listening. Type a question.") : L("Always listening. Just talk."))
        case .thinking: L("Looking")
        case .speaking: L("Speaking")
        case .downloading, .loading, .starting: L("Getting ready")
        case .ended: L("Ended")
        case .failed: L("Not working")
        }
    }
}

/// The soft animated orb (Moonstone): breathes while listening (with your voice), swirls while thinking,
/// pulses while speaking.
struct LiveOrb: View {
    let phase: LiveCallController.Phase
    let level: Float
    let muted: Bool
    var still = false

    var body: some View {
        // Never frozen (a stopped orb reads as a glitch): 30 fps, and a gentle 12 fps while the model works.
        TimelineView(.animation(minimumInterval: still || phase == .thinking ? 1.0 / 12 : 1.0 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let voice = max(0, min(1, Double(level + 50) / 40))
            let scale: Double = switch phase {
            case .listening: muted ? 0.75 : 0.8 + 0.5 * voice + 0.02 * sin(t * 2)
            case .thinking: 0.9 + 0.05 * sin(t * 6)
            case .speaking: 0.95 + 0.08 * abs(sin(t * 5))
            default: 0.85 + 0.03 * sin(t)
            }
            ZStack {
                Circle().fill(RadialGradient(colors: colors.map { $0.opacity(0.9) } + [.clear], center: .center, startRadius: 4, endRadius: 64))
                    .blur(radius: 10)
                Circle().fill(AngularGradient(colors: colors + [colors[0]], center: .center, angle: .degrees(t * (phase == .thinking ? 180 : 40))))
                    .frame(width: 70, height: 70).blur(radius: 6).opacity(0.85)
            }
            .scaleEffect(scale)
        }
    }

    private var colors: [Color] {
        switch phase {
        case .listening: muted ? [.gray, .white.opacity(0.4)] : [Color(red: 0.4, green: 0.7, blue: 1), .white, Color(red: 0.2, green: 0.4, blue: 1)]
        case .thinking: [.purple, Color(red: 0.4, green: 0.6, blue: 1), .white]
        case .speaking: [.white, Color(red: 0.5, green: 0.8, blue: 1), Color(red: 0.6, green: 0.5, blue: 1)]
        default: [.white.opacity(0.6), .gray]
        }
    }
}
