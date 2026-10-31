import SwiftUI

/// Talk to the camera. The whole screen is the camera with the 601 detector
/// running on it; two big controls sit on top: one that stops the answer and
/// listens now, and End Talk. With VoiceOver: a two-finger double tap (magic
/// tap) does the first, a two-finger scrub (escape) does the second, so Stop
/// is always one gesture away wherever focus is.
struct TalkView: View {
    @ObservedObject var viewModel: CameraViewModel
    let onBack: () -> Void
    @StateObject private var talk = TalkController()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CameraView(viewModel: viewModel)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                LinearGradient(colors: [.black.opacity(0.75), .clear, .black.opacity(0.8)],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                VStack(spacing: 16) {
                    status
                    Spacer(minLength: 8)
                    talkButton(height: max(160, geo.size.height * 0.30))
                    endButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 28)
            }
        }
        .accessibilityAction(.magicTap) { talk.interrupt() }
        .accessibilityAction(.escape) { talk.end() }
        .onAppear {
            viewModel.forceReconfigureSession()
            talk.start(camera: viewModel, onEnd: onBack)
        }
        .onDisappear {
            talk.stop()
            if viewModel.ocrDelegate === talk.frames { viewModel.ocrDelegate = nil }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(talk.phase.words)
                .font(.system(size: 38, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .minimumScaleFactor(0.5)
                .accessibilityAddTraits(.updatesFrequently)
            if !talk.heard.isEmpty {
                Text("You: \(talk.heard)")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(3)
            }
            if !talk.spokenAnswer.isEmpty {
                Text(talk.spokenAnswer)
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .lineLimit(6)
            }
            if let s = talk.lastSpeed {
                Text("First words \(String(format: "%.1f", s)) seconds after you stopped talking")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var talkButtonTitle: String {
        switch talk.phase {
        case .listening: "Listening. Just talk."
        case .thinking, .answering: "Tap to stop and ask"
        default: "Tap to ask"
        }
    }

    private func talkButton(height: CGFloat) -> some View {
        Button { talk.interrupt() } label: {
            VStack(spacing: 10) {
                Image(systemName: talk.phase == .listening ? "waveform" : "hand.raised.fill")
                    .font(.system(size: 54, weight: .bold))
                Text(talkButtonTitle)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(RoundedRectangle(cornerRadius: 28).fill(Color.blue.opacity(0.85)))
        }
        .accessibilityLabel("Talk. \(talk.phase.words)")
        .accessibilityHint("Ask about what the camera sees, out loud. Double tap to stop an answer and ask something new. Two finger scrub ends Talk.")
    }

    private var endButton: some View {
        Button { talk.end() } label: {
            Text("End Talk")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 76)
                .background(RoundedRectangle(cornerRadius: 22).fill(Color.red.opacity(0.85)))
        }
        .accessibilityLabel("End Talk")
        .accessibilityHint("Stops listening and goes back to the home screen")
    }
}
