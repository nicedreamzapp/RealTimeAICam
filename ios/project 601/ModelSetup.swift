import Combine
import Foundation

/// First launch and every launch after it (1.4.0): run the speed check once, so
/// automatic mode knows which level fits this phone.
///
/// Nothing downloads on its own, on any connection (Matt 11/09): the Home screen
/// and Settings > Models offer the level automatic picked, with its size, and it
/// downloads only after a "Download?" yes.
@MainActor
final class ModelSetup: ObservableObject {
    static let shared = ModelSetup()

    @Published private(set) var checkingSpeed = false

    private var started = false

    private init() {}

    /// Called once from the app's first `.task`.
    func launch() {
        guard !started else { return }
        started = true
        VisionModelStore.removeLegacyDownload()
        // Once, for phones updating from before the approved list (11/09): a hand pick whose
        // download was interrupted part-way counts as a yes. Nothing else is assumed approved.
        let migratedKey = "modelApprovedMigrated"
        if !UserDefaults.standard.bool(forKey: migratedKey) {
            UserDefaults.standard.set(true, forKey: migratedKey)
            if let manual = ModelPicker.manualLevel, !ModelPicker.removed.contains(manual),
               !VisionModelStore.isInstalled(manual),
               FileManager.default.fileExists(atPath: VisionModelStore.stagingURL(manual).path) {
                ModelPicker.approve(manual)
            }
        }
        // Only models the person said yes to resume; anything else half-downloaded is thrown away.
        VisionModelDownloader.shared.resumeInterrupted()
        // Then a hand pick that is neither here nor on its way goes back to automatic.
        ModelPicker.dropStalePick()
        guard #available(iOS 17.0, *), VisionModelStore.isInstalled else { return }
        if ModelPicker.balancedSeconds == nil {
            Task {
                // Let the camera and first screen settle before the GPU gets busy.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await runSpeedCheck()
            }
        }
    }

    /// Times one bundled photo on Balanced (Settings > Models can run it again).
    @available(iOS 17.0, *)
    func runSpeedCheck() async {
        guard !checkingSpeed else { return }
        checkingSpeed = true
        defer { checkingSpeed = false }
        if let seconds = await OnDeviceVisionNarrator.shared.speedCheck() {
            ModelPicker.setBalancedSeconds(seconds)
        }
    }

    /// Levels automatic mode wants that are not on the phone yet, minus any the
    /// person deleted, stopped or turned down.
    var missingWanted: [ModelLevel] {
        guard ModelPicker.manualLevel == nil else { return [] }
        let removed = ModelPicker.removed
        return ModelLevel.allCases.filter {
            ModelPicker.wanted.contains($0) && !VisionModelStore.isInstalled($0) && !removed.contains($0)
        }
    }

    /// Starts the downloads automatic mode wants, after the person said yes to them.
    func fetchWanted() {
        for level in missingWanted { download(level) }
    }

    /// The person stopped a download: throw the partial files away and keep
    /// automatic mode from starting it again.
    func stop(_ level: ModelLevel) {
        ModelPicker.markRemoved(level)
        ModelPicker.unapprove(level)
        if ModelPicker.manualLevel == level { ModelPicker.manualLevel = nil }
        VisionModelDownloader.shared.cancel(level)
    }

    /// The person deleted a downloaded level: same promise as ``stop(_:)``.
    func delete(_ level: ModelLevel) {
        ModelPicker.markRemoved(level)
        ModelPicker.unapprove(level)
        if ModelPicker.manualLevel == level { ModelPicker.manualLevel = nil }
        VisionModelDownloader.shared.delete(level)
    }

    /// A confirmed tap on a level: it may download again, starting now.
    func download(_ level: ModelLevel) {
        ModelPicker.clearRemoved(level)
        ModelPicker.approve(level)
        VisionModelDownloader.shared.start(level)
    }
}
