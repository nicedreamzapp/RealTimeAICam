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
                    fullScreen(still)
                } else {
                    LiveCamPreview(session: call.camera.session).ignoresSafeArea().accessibilityHidden(true)
                }
                // No snapshot, ever (Matt 10/31, 11/8, 11/9: "it's gotta be invisible", "not in any mode"):
                // the preview never freezes or flashes when a frame goes to the model.
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
                    // Typing only when it can't listen (no mic or speech permission, recognition stopped, mic off in
                    // Settings); otherwise it always listens (Matt 11/09).
                    if call.typedOnly || call.hearingStopped || call.micMuted { typedBox }
                    // Matt 11/6, a live camera: zoom pills like the Camera app's, just above the controls.
                    zoomPills
                    orb(size: wide ? 84 : (geo.size.height < 700 ? 96 : 120))
                    bottomBar(width: geo.size.width)
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

    /// A still filling the whole screen exactly like the live preview (aspect fill, past the safe areas).
    private func fullScreen(_ image: CGImage) -> some View {
        GeometryReader { g in
            Image(decorative: image, scale: 1).resizable().scaledToFill()
                .frame(width: g.size.width, height: g.size.height).clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
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
            // Words on screen are always on here; the switch lives in Settings > Live Cam (Matt 11/09 layout).
            Button { call.flip(); zoomLabel = 1 } label: {   // a flip starts at 1x again (review 11/6)
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
                .accessibilityHint(L("When on, Live Cam checks in after a long quiet. New things it sees are always told."))
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

    private func words(wide: Bool) -> some View {
        // Matt 11/6: captions like FaceTime's Live Captions, a rounded see-through bubble with the words left-aligned.
        let bubble = call.showCaption && (!call.caption.isEmpty || !call.heardText.isEmpty)
        return VStack(alignment: .leading, spacing: 6) {
            if call.showCaption, !call.heardText.isEmpty {
                Text(L("You: %@", call.heardText))
                    .font(.system(size: wide ? 15 : 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.leading).lineLimit(2).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(L("You said: %@", call.heardText))
                    .accessibilityIdentifier("liveCamHeard")
            }
            if !call.caption.isEmpty {
                Text(call.caption)
                    .font(.system(size: wide ? 20 : 22, weight: .semibold))
                    .foregroundStyle(.white).multilineTextAlignment(.leading).lineLimit(wide ? 3 : 4).minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(call.showCaption ? 1 : 0.001)   // hidden words stay readable by VoiceOver
                    .accessibilityLabel(call.caption)
                    .accessibilityValue(call.caption)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityIdentifier("liveCamCaption")
                    // The caption's own language (content may be in Your language, not the app's), like the app root does.
                    .environment(\.locale, Locale(identifier: call.captionLang))
            }
            if call.phase == .loading || call.phase == .starting {
                ProgressView().tint(.white).accessibilityLabel(L("Getting Live Cam ready"))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, bubble ? 16 : 0).padding(.vertical, bubble ? 12 : 0)
        .background {
            if bubble {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black.opacity(0.25)))
            }
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    // MARK: Zoom pills (the Camera app's 0.5, 1, 2)

    private var zoomStops: [CGFloat] { (call.camera.minZoom < 0.9 ? [0.5] : []) + [1, 2] }

    private var zoomPills: some View {
        let stops = zoomStops
        // The pill showing the zoom now: the nearest stop at or below it, like the Camera app ("1.4×" on the 1).
        let active = stops.last { $0 <= zoomLabel + 0.01 } ?? stops[0]
        return HStack(spacing: 6) {
            ForEach(stops, id: \.self) { z in
                let on = z == active
                Button {
                    call.camera.setZoom(z); zoomLabel = z
                } label: {
                    Text(on ? Self.zoomText(zoomLabel) : Self.zoomText(z, short: true))
                        .font(.system(size: on ? 14 : 12, weight: .bold))
                        .foregroundStyle(on ? LiveOrb.lookColor : .white)
                        .frame(width: on ? 44 : 36, height: on ? 44 : 36)
                        .background(.black.opacity(0.5), in: Circle())
                        .frame(width: 48, height: 48).contentShape(Circle())
                }
                .accessibilityLabel(L("Zoom %@", Self.zoomText(z)))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .background(.black.opacity(0.25), in: Capsule())
        .animation(.easeOut(duration: 0.15), value: active)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveCamZoom")
    }

    static func zoomText(_ z: CGFloat, short: Bool = false) -> String {
        if short { return z < 1 ? ".5" : String(format: "%.0f", z) }
        return String(format: z < 10 && abs(z - z.rounded()) > 0.05 ? "%.1f×" : "%.0f×", z)
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
                .accessibilityIdentifier("liveCamOrb-" + orbState)   // identifiers are never spoken
            Text(statusLine).font(.footnote.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                .opacity(call.showCaption ? 1 : 0)
                .accessibilityHidden(true)
        }
    }

    // MARK: Bottom: mute and the one way out

    /// The round buttons' size and spacing for a row of `count` at this width: 76 pt where it fits, smaller (never
    /// under 58) on a narrow screen, so the row always fits (review 11/6: it overflowed at 320 pt).
    static func bottomRow(width: CGFloat, count: Int) -> (size: CGFloat, spacing: CGFloat) {
        let n = CGFloat(count), avail = min(width, 640) - 32
        let d = max(58, min(76, (avail - (n - 1) * 12) / n - 8))
        let spacing = max(6, min(40, (avail - n * (d + 8)) / max(1, n - 1)))
        return (d, spacing)
    }

    private func bottomBar(width: CGFloat) -> some View {
        let (d, spacing) = Self.bottomRow(width: width, count: call.torchAvailable ? 3 : 2)
        return HStack(spacing: spacing) {
            // Matt 11/6: "Live cam needs to have a flashlight... preferably at the bottom". One tap on, one tap off;
            // on the selfie camera it flips to the back camera first. Its word stays even with Words on screen off.
            if call.torchAvailable {
                Button { call.setFlashlight(!call.torchOn) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: call.torchOn ? "flashlight.on.fill" : "flashlight.off.fill").font(.system(size: d * 0.37, weight: .semibold))
                            .frame(width: d, height: d)
                            .background(call.torchOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.black.opacity(0.45)), in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                            .foregroundStyle(call.torchOn ? .black : .white)
                        Text(L("Flashlight")).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    .frame(width: d + 8)
                }
                .accessibilityLabel(L("Flashlight"))
                .accessibilityValue(call.torchOn ? L("On") : L("Off"))
                .accessibilityAddTraits(.isToggle)
                .accessibilityIdentifier("liveCamFlashlight")
            }
            // Quiet (Matt 11/09): no voice, words on screen instead. It keeps watching and listening. The mic
            // switch moved to Settings > Live Cam.
            Button { call.quiet.toggle() } label: {
                VStack(spacing: 6) {
                    Image(systemName: call.quiet ? "text.bubble.fill" : "speaker.slash.fill").font(.system(size: d * 0.37, weight: .semibold))
                        .frame(width: d, height: d)
                        .background(Color.white, in: Circle())
                        .overlay(Circle().stroke(call.quiet ? LiveOrb.lookColor : .white.opacity(0.35), lineWidth: call.quiet ? 4 : 1))
                        .foregroundStyle(.black)
                    Text(call.quiet ? L("Quiet on") : L("Quiet")).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.6).frame(width: d + 8)
                }
            }
            .accessibilityLabel(L("Quiet"))
            .accessibilityValue(call.quiet ? L("On") : L("Off"))
            .accessibilityAddTraits(.isToggle)
            .accessibilityHint(L("Show words instead of speaking"))
            .accessibilityIdentifier("liveCamQuiet")
            // No Ask button: Live Cam always listens (Matt 11/09: "there is an ask button i not want that, it
            // should be listen always").
            Button { call.end() } label: {
                VStack(spacing: 6) {
                    Image(systemName: "xmark").font(.system(size: d * 0.37, weight: .bold))
                        .frame(width: d, height: d).background(Color.red, in: Circle()).foregroundStyle(.white)
                    Text(L("Back")).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.6).frame(width: d + 8)
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

    /// For the UI tests: which of the three looks the orb has (in the identifier only; the label says it in words).
    private var orbState: String { "\(LiveOrb.look(call.phase, muted: call.micMuted))" }

    private var orbLabel: String {
        switch call.phase {
        case .listening: call.micMuted ? L("Microphone muted") : (call.hearingStopped ? L("Not listening. Type a question.") : L("Your turn"))
        case .thinking: L("Looking")
        case .speaking: L("Speaking")
        case .downloading, .loading, .starting: L("Getting ready")
        case .ended: L("Ended")
        case .failed: L("Not working")
        }
    }
}

/// The orb (Matt 11/6: "some sort of indicator showing that it's thinking or analyzing, or when it'll let you talk
/// next"). Three states nobody can confuse, by shape, motion and color, with no words needed (Words on screen off):
///   your turn: an open green ring that grows and thickens with your voice, a dot in the middle
///   looking:   two yellow arcs spinning like a camera focusing
///   talking:   a solid white disc with sound bars moving
/// Muted is a gray dashed ring; getting ready a dim breathing disc.
struct LiveOrb: View {
    let phase: LiveCallController.Phase
    let level: Float
    let muted: Bool
    var still = false

    enum Look: Equatable { case yourTurn, looking, talking, muted, waiting }
    static func look(_ phase: LiveCallController.Phase, muted: Bool) -> Look {
        switch phase {
        case .listening: muted ? .muted : .yourTurn
        case .thinking: .looking
        case .speaking: .talking
        default: .waiting
        }
    }
    static let turnColor = Color(red: 0.3, green: 0.9, blue: 0.5)
    static let lookColor = Color(red: 1, green: 0.82, blue: 0.2)

    var body: some View {
        // Never frozen (a stopped orb reads as a glitch): 30 fps, and a gentle 12 fps while the model works.
        TimelineView(.animation(minimumInterval: still ? 1.0 / 12 : 1.0 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let voice = max(0, min(1, Double(level + 50) / 40))
            GeometryReader { g in
                let d = min(g.size.width, g.size.height)
                ZStack {
                    switch Self.look(phase, muted: muted) {
                    case .yourTurn:
                        Circle().fill(.black.opacity(0.3)).frame(width: d * 0.9, height: d * 0.9)
                        Circle().stroke(Self.turnColor, lineWidth: d * (0.04 + 0.08 * voice))
                            .frame(width: d * (0.62 + 0.3 * voice), height: d * (0.62 + 0.3 * voice))
                            .shadow(color: Self.turnColor.opacity(0.6), radius: 6 + 10 * voice)
                        Circle().fill(Self.turnColor).frame(width: d * 0.12, height: d * 0.12)
                            .scaleEffect(1 + 0.08 * sin(t * 2.4))
                    case .looking:
                        Circle().fill(.black.opacity(0.3)).frame(width: d * 0.9, height: d * 0.9)
                        Circle().stroke(.white.opacity(0.18), lineWidth: d * 0.05).frame(width: d * 0.7, height: d * 0.7)
                        ForEach(0 ..< 2, id: \.self) { i in
                            Circle().trim(from: 0, to: 0.22)
                                .stroke(Self.lookColor, style: StrokeStyle(lineWidth: d * 0.06, lineCap: .round))
                                .frame(width: d * 0.7, height: d * 0.7)
                                .rotationEffect(.degrees(t * 320 + Double(i) * 180))
                        }
                    case .talking:
                        Circle().fill(.white).frame(width: d * 0.74, height: d * 0.74)
                            .shadow(color: .white.opacity(0.5), radius: 10)
                        HStack(spacing: d * 0.045) {
                            ForEach(0 ..< 5, id: \.self) { i in
                                Capsule().fill(Color(red: 0.15, green: 0.35, blue: 0.9))
                                    .frame(width: d * 0.06, height: d * (0.1 + 0.26 * abs(sin(t * 5.5 + Double(i) * 0.9))))
                            }
                        }
                    case .muted:
                        Circle().stroke(.gray, style: StrokeStyle(lineWidth: d * 0.04, dash: [d * 0.06, d * 0.05]))
                            .frame(width: d * 0.62, height: d * 0.62)
                        Image(systemName: "mic.slash.fill").font(.system(size: d * 0.22, weight: .semibold)).foregroundStyle(.gray)
                    case .waiting:
                        Circle().fill(.white.opacity(0.25)).frame(width: d * 0.5, height: d * 0.5)
                            .scaleEffect(0.9 + 0.08 * sin(t * 1.5))
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
                .animation(.easeOut(duration: 0.2), value: Self.look(phase, muted: muted))
            }
        }
    }
}
