import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Says so when the phone's volume is all the way down (2026-11-04, a Play review of the
/// Android app: "no voice output, complete silence"). If the volume is 0 at launch, VoiceOver
/// announces it and a note shows at the top; the note goes away by itself as soon as the
/// volume comes up, or when it is tapped.
@MainActor
final class VolumeWatcher: ObservableObject {
    static let line = "Volume is off. Turn it up to hear the app."

    @Published private(set) var isOff = false
    private var observation: NSKeyValueObservation?
    private var announced = false

    /// Debug builds: `-rtcamFakeVolumeZero` acts as if the volume were 0, since a Simulator's
    /// volume can't really be turned down.
    static var fakeZero: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-rtcamFakeVolumeZero")
        #else
        false
        #endif
    }

    func start() {
        guard observation == nil else { return }
        let session = AVAudioSession.sharedInstance()
        update(session.outputVolume)
        // Fires when the volume buttons move (once the app has used audio).
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let volume = change.newValue else { return }
            Task { @MainActor in self?.update(volume) }
        }
    }

    func hide() { isOff = false }

    private func update(_ volume: Float) {
        let off = Self.fakeZero || volume <= 0.0001
        isOff = off
        if off && !announced {
            announced = true
            // A beat later, so the first screen's own VoiceOver focus doesn't cut it off.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                UIAccessibility.post(notification: .announcement, argument: Self.line)
            }
        } else if !off {
            announced = false
        }
    }
}

struct VolumeOffNote: View {
    @StateObject private var watcher = VolumeWatcher()

    var body: some View {
        Group {
            if watcher.isOff {
                Button(action: { watcher.hide() }) {
                    Label(VolumeWatcher.line, systemImage: "speaker.slash.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(Color(red: 0.70, green: 0.15, blue: 0.12).opacity(0.92),
                                    in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                // Below every screen's top bar, so Back, Settings and the Language pill stay reachable.
                .padding(.top, 100)
                .accessibilityIdentifier("volumeOffNote")
                .accessibilityLabel(VolumeWatcher.line)
                .accessibilityHint("Double tap to hide this note")
                .transition(.opacity)
            }
        }
        .onAppear { watcher.start() }
    }
}
