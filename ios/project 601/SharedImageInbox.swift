import Combine
import SwiftUI
import UIKit

/// A picture shared to the app from another app's share sheet.
///
/// The Share Extension writes it into the App Group container and opens
/// `rtcam://shared-image?id=<uuid>`; this picks the file up, deletes it, and
/// hands the picture to ContentView, which opens the Shared Image screen.
/// Works on a cold launch too: the picture waits here until ContentView is up.
@MainActor
final class SharedImageInbox: ObservableObject {
    static let shared = SharedImageInbox()

    /// Same group as both targets' entitlements (group.<app bundle id>).
    nonisolated static let appGroup = "group.B9RA6QH559.project-601"
    nonisolated static let folderName = "SharedImages"

    struct Shared: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    /// The picture waiting to be shown, cleared once ContentView takes it.
    @Published var pending: Shared?
    /// A share link came in but the picture couldn't be read.
    @Published var failed = false

    /// True when the URL was ours (handled, whatever the outcome).
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "rtcam", url.host?.lowercased() == "shared-image" else { return false }
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "id" }?.value
        // Only a plain UUID names a file: nothing in the link can reach outside the folder.
        guard let id, UUID(uuidString: id) != nil, let image = Self.take(id: id) else {
            NSLog("SharedImage: could not load \(url.absoluteString)")
            failed = true
            return true
        }
        pending = Shared(image: image)
        return true
    }

    private nonisolated static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Reads the shared picture, then empties the folder: it was only ever a hand-over.
    private static func take(id: String) -> UIImage? {
        guard let folder else { return nil }
        let file = folder.appendingPathComponent(id).appendingPathExtension("jpg")
        let image = (try? Data(contentsOf: file)).flatMap { UIImage(data: $0) }
        let fm = FileManager.default
        for leftover in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: leftover)
        }
        return image
    }
}
