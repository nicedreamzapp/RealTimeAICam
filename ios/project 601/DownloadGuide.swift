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

        /// Said again and again: with VoiceOver it waits its turn but is dropped if stale.
        var isReminder: Bool { self == .sheetWaiting || self == .stillDownloading }
    }

    /// Reminder gaps while the window stays up: three at 15 s, then one a minute.
    static func waitingGap(after reminders: Int) -> TimeInterval { reminders < 3 ? 15 : 60 }
    /// With no window (already allowed, or a background download): the old 15 s line.
    static let stillGap: TimeInterval = 15
    /// The window counts as gone only after this long away (a presentation flicker is not a close).
    static let goneAfter: TimeInterval = 1.5
    /// A gap between ticks longer than this means the phone slept (locked): start the wait over.
    static let sleptAfter: TimeInterval = 5
    /// Apple still working this long after its window went means the person had tapped it.
    static let tappedAfter: TimeInterval = 3

    /// Seconds that keep counting while the phone sleeps (a lock mid-download).
    static func clock() -> TimeInterval { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

    private(set) var sheetSeen = false
    /// The window is up now (after the flicker filter).
    private(set) var sheetUp = false
    private var awaySince: TimeInterval?
    private var closedAt: TimeInterval?
    private var reminders = 0
    private var lastLineAt: TimeInterval
    private var lastTickAt: TimeInterval
    private var wokeAt: TimeInterval?
    /// After waking from a lock: quiet this long, so VoiceOver can read the unlocked screen.
    static let quietAfterWake: TimeInterval = 3

    /// `start`: when the "Downloading" line was said.
    init(start: TimeInterval) { lastLineAt = start; lastTickAt = start }

    /// Called about once a second while the download runs.
    mutating func tick(sheetShowing: Bool, now: TimeInterval) -> Line? {
        // Back from a lock: quiet for a few seconds (even if Apple's window came up meanwhile),
        // then the wait starts over.
        if now - lastTickAt > Self.sleptAfter { wokeAt = now }
        lastTickAt = now
        if let wokeAt {
            guard now - wokeAt >= Self.quietAfterWake else { return nil }
            self.wokeAt = nil
            lastLineAt = now
        }
        if sheetShowing {
            awaySince = nil
            if !sheetUp {
                // Opened, or opened again after it had gone: where the button is.
                sheetUp = true
                sheetSeen = true
                closedAt = nil
                reminders = 0
                lastLineAt = now
                return .sheetOpened
            }
            guard now - lastLineAt >= Self.waitingGap(after: reminders) else { return nil }
            reminders += 1
            lastLineAt = now
            return .sheetWaiting
        }
        if sheetUp {
            let since = awaySince ?? now
            awaySince = since
            guard now - since >= Self.goneAfter else { return nil }
            // Gone for real: a fresh 15 s before any progress line.
            sheetUp = false
            awaySince = nil
            closedAt = since
            lastLineAt = now
            return nil
        }
        guard now - lastLineAt >= Self.stillGap else { return nil }
        lastLineAt = now
        return .stillDownloading
    }

    /// The last line once Apple's prepare returns. A window closed and Apple done right away:
    /// it closed without the download. Apple still working a while after it closed: the person
    /// tapped and the download itself failed.
    func finished(ok: Bool, now: TimeInterval) -> Line {
        if ok { return .ready }
        guard sheetSeen else { return .failed }
        if let closedAt, now - closedAt >= Self.tappedAfter { return .failed }
        return .sheetClosed
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
    /// The view controllers presented over the app's root right now, and the top one's class.
    /// Apple's window is one that was not there when the download was tapped (comparing which
    /// ones, not how many: closing Settings meanwhile must not hide Apple's window).
    static func stack() -> (presented: Set<ObjectIdentifier>, top: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
        var vc = window?.rootViewController
        var presented = Set<ObjectIdentifier>()
        while let next = vc?.presentedViewController, !next.isBeingDismissed {
            presented.insert(ObjectIdentifier(next))
            vc = next
        }
        return (presented, vc.map { String(describing: type(of: $0)) } ?? "none")
    }
}

/// The guide shared by the watcher and the task waiting for Apple (both on the main actor).
@MainActor
final class DownloadGuideState {
    var guide: DownloadGuide
    var done = false
    init(_ guide: DownloadGuide) { self.guide = guide }
}

/// Download lines under VoiceOver (2026-11-06): one at a time, each queued behind what
/// VoiceOver is reading. A reminder waiting its turn is dropped when a newer line comes or
/// when it went stale (`isStale` is asked again right before it is posted).
@MainActor
final class VoiceOverLineQueue {
    static let shared = VoiceOverLineQueue()

    private struct Item {
        let text: String
        let lang: String
        let isReminder: Bool
        let isStale: () -> Bool
    }

    private var pending: [Item] = []
    private var inFlight: String?
    private var watchdog: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: UIAccessibility.announcementDidFinishNotification, object: nil, queue: .main) { [weak self] note in
            let said = note.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String
            MainActor.assumeIsolated { self?.finished(said) }
        }
    }

    func say(_ text: String, lang: String, isReminder: Bool, isStale: @escaping () -> Bool = { false }) {
        // A newer line makes any reminder still waiting stale.
        pending.removeAll { $0.isReminder }
        pending.append(Item(text: text, lang: lang, isReminder: isReminder, isStale: isStale))
        postNext()
    }

    private func finished(_ said: String?) {
        // Only one line is ever inside VoiceOver at a time, so its report is for that line.
        guard let inFlight, said == nil || said == inFlight else { return }
        self.inFlight = nil
        postNext()
    }

    private func postNext() {
        guard inFlight == nil else { return }
        while let next = pending.first {
            pending.removeFirst()
            if next.isStale() { continue }
            inFlight = next.text
            UIAccessibility.post(notification: .announcement,
                                 argument: SpeechManager.voiceOverLine(next.text, lang: next.lang, queue: true))
            // VoiceOver reports each line when it is read. Only if VoiceOver was turned off
            // meanwhile (no report will come) does the queue move on by itself: never while
            // VoiceOver may still be holding the line, so two never stack inside VoiceOver.
            watchdog?.cancel()
            watchdog = Task { @MainActor [weak self] in
                while !Task.isCancelled, self?.inFlight != nil {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if !UIAccessibility.isVoiceOverRunning {
                        self?.inFlight = nil
                        self?.pending.removeAll()
                        return
                    }
                }
            }
            return
        }
    }
}
