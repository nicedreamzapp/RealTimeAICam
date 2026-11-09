import Combine
import SwiftUI
import UIKit

/// A picture shared to the app from another app's share sheet.
///
/// The Share Extension writes it into the App Group container as
/// `<seconds since 1970>_<uuid>.jpg` and opens `rtcam://shared-image?id=<that name>`.
/// This picks the file up, deletes it, and holds the picture in `current`, the
/// one root-level state ContentView shows the Shared picture screen from.
/// Cold launch works too, and so does a share whose link iOS never delivered:
/// every time the app comes to the front it looks in the folder (`checkFolder`).
@MainActor
final class SharedImageInbox: ObservableObject {
    static let shared = SharedImageInbox()

    /// Same group as both targets' entitlements (group.<app bundle id>).
    nonisolated static let appGroup = "group.B9RA6QH559.project-601"
    nonisolated static let folderName = "SharedImages"
    /// A hand-over older than this is from a share long given up on: deleted, never shown.
    nonisolated static let maxAge: TimeInterval = 10 * 60

    struct Shared: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    /// The picture on screen, nil when the Shared picture screen is closed.
    @Published private(set) var current: Shared?
    /// A share link came in but the picture couldn't be read.
    @Published var failed = false

    /// A shared picture is on screen or about to be: the guide and Home's cues stay out of its way.
    var isBusy: Bool { current != nil }

    func close() { current = nil }

    /// True when the URL was ours (handled, whatever the outcome).
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "rtcam", url.host?.lowercased() == "shared-image" else { return false }
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "id" }?.value
        // Only our own file name format: nothing in the link can reach outside the folder.
        guard let id, Self.created(id) != nil else {
            NSLog("SharedImage: bad link \(url.absoluteString)")
            failed = true
            return true
        }
        if let image = Self.take(id: id) {
            current = Shared(image: image)
        } else if current == nil {
            // Already opened by checkFolder() when the app came up is fine; anything else isn't.
            NSLog("SharedImage: could not load \(id)")
            failed = true
        }
        return true
    }

    /// Opens the newest waiting picture, if any, and deletes stale ones. Called each
    /// time the app becomes active, so a share works even when the link never arrives.
    func checkFolder() {
        guard let folder = Self.folder else { return }
        let now = Date().timeIntervalSince1970
        var newest: (id: String, time: Int)?
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            let id = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "jpg", let time = Self.created(id),
                  now - TimeInterval(time) < Self.maxAge
            else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            if newest == nil || time > newest!.time { newest = (id, time) }
        }
        guard current == nil, let newest, let image = Self.take(id: newest.id) else { return }
        NSLog("SharedImage: opened a waiting picture from the folder")
        current = Shared(image: image)
    }

    /// The creation time in a "<seconds>_<uuid>" name, nil for any other name.
    nonisolated static func created(_ id: String) -> Int? {
        let parts = id.split(separator: "_", maxSplits: 1).map(String.init)
        guard parts.count == 2, let seconds = Int(parts[0]), seconds > 0,
              UUID(uuidString: parts[1]) != nil else { return nil }
        return seconds
    }

    private nonisolated static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// Reads the shared picture, then empties the folder: it was only ever a hand-over.
    private static func take(id: String) -> UIImage? {
        guard let folder else { return nil }
        let file = folder.appendingPathComponent(id).appendingPathExtension("jpg")
        guard let data = try? Data(contentsOf: file) else { return nil }
        let fm = FileManager.default
        for leftover in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: leftover)
        }
        return UIImage(data: data)
    }
}
