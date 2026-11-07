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
/// - anything else that needs the screen on (a Live Cam call, the on-phone
///   photo tests) takes a named hold and releases it.
/// The screen stays awake while at least one camera runs or one hold is held,
/// so ending a Live Cam call never re-enables auto-lock under a running camera.
/// iOS ignores the flag while the app is in the background, so backgrounding
/// restores normal auto-lock on its own.
@MainActor
enum ScreenAwake {
    private final class WeakSession {
        weak var session: AVCaptureSession?
        init(_ s: AVCaptureSession) { session = s }
    }

    private static var holds = Set<String>()
    private static var running: [ObjectIdentifier: WeakSession] = [:]
    private static var observers: [NSObjectProtocol] = []

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
    }

    /// Keep the screen on for `reason` until `release(reason)`. Holding twice is one hold.
    static func hold(_ reason: String) {
        holds.insert(reason)
        apply()
    }

    static func release(_ reason: String) {
        holds.remove(reason)
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
        running = running.filter { $0.value.session?.isRunning == true }
        let awake = !holds.isEmpty || !running.isEmpty
        if UIApplication.shared.isIdleTimerDisabled != awake {
            UIApplication.shared.isIdleTimerDisabled = awake
            NSLog("ScreenAwake: \(awake ? "on" : "off") (cameras \(running.count), holds \(holds.sorted()))")
        }
    }
}
