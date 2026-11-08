import SwiftUI
import UIKit

/// Which way the iPhone screen may turn. Everything stays portrait except
/// Help Me Aim's camera and its picture, which turn with the phone
/// (AppleVis user LaBoheme, 2026-11-08: "can you also make the camera follow
/// device orientation for help me aim? Landscape orientation is more
/// appropriate in certain situation"). The iPad keeps every orientation.
final class AppOrientation: NSObject, UIApplicationDelegate {
    @MainActor static var phoneMask: UIInterfaceOrientationMask = .portrait

    func application(_: UIApplication, supportedInterfaceOrientationsFor _: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : MainActor.assumeIsolated { Self.phoneMask }
    }

    /// Allow or stop landscape; going back to portrait turns the screen now.
    @MainActor static func allowLandscape(_ on: Bool) {
        let mask: UIInterfaceOrientationMask = on ? [.portrait, .landscapeLeft, .landscapeRight] : .portrait
        guard mask != phoneMask, UIDevice.current.userInterfaceIdiom != .pad else { return }
        phoneMask = mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            // Ask now: iOS otherwise waits for the next tilt, so a phone
            // already on its side stayed portrait (iPhone 18, 2026-11-08).
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }
}
