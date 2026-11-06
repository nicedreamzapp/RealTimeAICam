import UIKit

/// What the app says while Your language downloads (2026-11-05, real iPhone 12). Apple's
/// download window waits for a tap a blind person may not know about, while the app used to
/// say "Still downloading" every 15 s for 7.5 minutes until Apple gave up. Now: once the window
/// is up, where its button is; while it stays up, that it waits for a tap (often at first,
/// then once a minute); once it has gone, the plain progress line; if Apple ends without the
/// language after the window was up, that it closed and how to try again.
/// Pure, so the timing is unit tested; `DownloadSheetWatch` says whether the window is up.
struct DownloadGuide {
    enum Line: Equatable {
        case sheetOpened, sheetWaiting, stillDownloading
        case ready, sheetClosed, failed
    }

    /// Reminder gaps while the window stays up: three at 15 s, then one a minute.
    static func waitingGap(after reminders: Int) -> TimeInterval { reminders < 3 ? 15 : 60 }
    /// With no window (already allowed, or a background download): the old 15 s line.
    static let stillGap: TimeInterval = 15

    /// Seconds that keep counting while the phone sleeps (a lock mid-download).
    static func clock() -> TimeInterval { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

    private(set) var sheetSeen = false
    private var sheetUp = false
    private var reminders = 0
    private var lastLineAt: TimeInterval

    /// `start`: when the "Downloading" line was said.
    init(start: TimeInterval) { lastLineAt = start }

    /// Called about once a second while the download runs.
    mutating func tick(sheetShowing: Bool, now: TimeInterval) -> Line? {
        if sheetShowing {
            sheetUp = true
            if !sheetSeen {
                sheetSeen = true
                lastLineAt = now
                return .sheetOpened
            }
            guard now - lastLineAt >= Self.waitingGap(after: reminders) else { return nil }
            reminders += 1
            lastLineAt = now
            return .sheetWaiting
        }
        // The window just went (tapped and finished, or closed): a fresh 15 s before any
        // progress line, so "still downloading" never lands on the moment it closes.
        if sheetUp {
            sheetUp = false
            lastLineAt = now
            return nil
        }
        // No window (or it has gone and Apple keeps downloading in the background): the
        // plain progress line, 15 s after the last thing said.
        guard now - lastLineAt >= Self.stillGap else { return nil }
        lastLineAt = now
        return .stillDownloading
    }

    /// The last line once Apple's prepare returns.
    func finished(ok: Bool) -> Line {
        if ok { return .ready }
        return sheetSeen ? .sheetClosed : .failed
    }

    static func text(_ line: Line, code: String) -> String {
        switch line {
        case .sheetOpened: return YourLanguageRules.sheetOpenedLine(code)
        case .sheetWaiting: return YourLanguageRules.sheetWaitingLine(code)
        case .stillDownloading: return YourLanguageRules.stillDownloadingLine(code)
        case .ready: return YourLanguageRules.readyLine(code)
        case .sheetClosed: return YourLanguageRules.sheetClosedLine(code)
        case .failed: return YourLanguageRules.failedLine(code)
        }
    }
}

/// Whether a window was presented over the app since `baseline` was taken (Apple's download
/// sheet appears as a presented view controller once prepareTranslation asks for it).
@MainActor
enum DownloadSheetWatch {
    /// How many view controllers are stacked over the app's root right now, and the top one's class.
    static func stack() -> (depth: Int, top: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var vc = window?.rootViewController
        var depth = 0
        while let next = vc?.presentedViewController, !next.isBeingDismissed {
            depth += 1
            vc = next
        }
        return (depth, vc.map { String(describing: type(of: $0)) } ?? "none")
    }
}

/// The guide shared by the watcher and the task waiting for Apple (both on the main actor).
@MainActor
final class DownloadGuideState {
    var guide: DownloadGuide
    var done = false
    init(_ guide: DownloadGuide) { self.guide = guide }
}
