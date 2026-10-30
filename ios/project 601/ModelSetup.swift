import Combine
import Foundation
import Network

/// First launch and every launch after it (1.4.0): run the speed check once,
/// then fetch the level(s) automatic mode wants for this phone.
///
/// Downloads start on their own only on Wi-Fi (an unmetered, unconstrained
/// connection). On cellular or Low Data Mode the Home screen and Settings >
/// Models offer a button instead, with the size, so nobody loses 2 GB of a
/// data plan to a setting they never saw.
@MainActor
final class ModelSetup: ObservableObject {
    static let shared = ModelSetup()

    @Published private(set) var checkingSpeed = false
    @Published private(set) var onWiFi = false

    private let monitor = NWPathMonitor()
    private var started = false

    private init() {
        monitor.pathUpdateHandler = { path in
            let unmetered = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor in
                let was = ModelSetup.shared.onWiFi
                ModelSetup.shared.onWiFi = unmetered
                if unmetered, !was { ModelSetup.shared.fetchWanted(automatic: true) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "rtcam.modelsetup.path"))
    }

    /// Called once from the app's first `.task`.
    func launch() {
        guard !started else { return }
        started = true
        VisionModelStore.removeLegacyDownload()
        VisionModelDownloader.shared.resumeInterrupted()
        guard #available(iOS 17.0, *), VisionModelStore.isInstalled else { return }
        if ModelPicker.balancedSeconds == nil {
            Task {
                // Let the camera and first screen settle before the GPU gets busy.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await runSpeedCheck()
            }
        } else {
            fetchWanted(automatic: true)
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
            fetchWanted(automatic: true)
        }
    }

    /// Levels automatic mode wants that are not on the phone yet.
    var missingWanted: [ModelLevel] {
        guard ModelPicker.manualLevel == nil else { return [] }
        return ModelLevel.allCases.filter { ModelPicker.wanted.contains($0) && !VisionModelStore.isInstalled($0) }
    }

    /// Starts the downloads automatic mode wants. `automatic` ones wait for Wi-Fi;
    /// a tap on a button passes false and starts them on any connection.
    func fetchWanted(automatic: Bool) {
        if automatic, !onWiFi { return }
        for level in missingWanted { VisionModelDownloader.shared.start(level) }
    }
}
