import AVFoundation
import UIKit

/// Keeps the screen awake while any camera is running, so iOS auto-lock never
/// locks the phone in the middle of a task.
///
/// Asked for by AppleVis user LaBoheme (2026-11-07): with the 30-second
/// auto-lock, the screen locked mid-task (Help Me Aim) because a blind user
/// can easily go more than 30 seconds without touching the screen.
///
/// One place owns `UIApplication.shared.isIdleTimerDisabled`:
/// - every AVCaptureSession in the app (main camera, Read, Help Me Aim, Live Cam)
///   is tracked through its start/stop notifications, so no camera owner needs
///   its own code;
/// - anything else that needs the screen on (a Live Cam call, a model answering
///   while the camera is paused, the on-phone photo tests) takes a named hold
///   and releases it. Holds are counted, so two at once under one name both
///   have to be released.
/// The screen stays awake while at least one camera runs or one hold is held,
/// so ending a Live Cam call never re-enables auto-lock under a running camera.
/// iOS ignores the flag while the app is in the background, so backgrounding
/// restores normal auto-lock on its own.
///
/// A missed stop notification must never pin the screen on, so while the flag
/// is on the real state is re-checked every 30 seconds and whenever the app
/// comes back to the front.
@MainActor
enum ScreenAwake {
    private final class WeakSession {
        weak var session: AVCaptureSession?
        init(_ s: AVCaptureSession) { session = s }
    }

    private static var holds: [String: Int] = [:]
    private static var running: [ObjectIdentifier: WeakSession] = [:]
    private static var observers: [NSObjectProtocol] = []
    private static var recheckTimer: Timer?

    /// Start watching every camera session (called once at launch).
    static func install() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        for name in [AVCaptureSession.didStartRunningNotification, AVCaptureSession.didStopRunningNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { n in
                guard let session = n.object as? AVCaptureSession else { return }
                MainActor.assumeIsolated { cameraChanged(session) }
            })
        }
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { apply() }
        })
    }

    /// Keep the screen on for `reason` until a matching `release(reason)`.
    static func hold(_ reason: String) {
        holds[reason, default: 0] += 1
        apply()
    }

    static func release(_ reason: String) {
        if let n = holds[reason], n > 1 { holds[reason] = n - 1 } else { holds[reason] = nil }
        apply()
    }

    /// Whether the screen is being kept awake right now (tests).
    static var isKeepingAwake: Bool { UIApplication.shared.isIdleTimerDisabled }

    /// Reads the session's real state rather than trusting the notification's
    /// name, so a start and stop that land out of order still end up right.
    private static func cameraChanged(_ session: AVCaptureSession) {
        let id = ObjectIdentifier(session)
        if session.isRunning { running[id] = WeakSession(session) } else { running[id] = nil }
        apply()
    }

    private static func apply() {
        // Drops sessions that stopped or went away without a stop notification.
        running = running.filter { $0.value.session?.isRunning == true }
        let awake = !holds.isEmpty || !running.isEmpty
        if awake, recheckTimer == nil {
            recheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                MainActor.assumeIsolated { apply() }
            }
        } else if !awake {
            recheckTimer?.invalidate()
            recheckTimer = nil
        }
        if UIApplication.shared.isIdleTimerDisabled != awake {
            UIApplication.shared.isIdleTimerDisabled = awake
            NSLog("ScreenAwake: \(awake ? "on" : "off") (cameras \(running.count), holds \(holds.keys.sorted()))")
        }
    }
}
