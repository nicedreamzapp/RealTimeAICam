import Foundation
import UIKit

/// On-phone photo test, started only by the launch argument `-rtcamPhotoTest`
/// (devicectl or Xcode; nobody can trigger it from the app). Every .jpg in
/// Documents/photo-test goes through the same path a What's this? press takes,
/// minus the camera: FrameQualityGate, the readable-text check, narratePage or
/// narrateScene with all their retries. One JSON line per photo is written to
/// Documents/photo-test/results.jsonl: route, answer, first-token time, total
/// time, every model pass, and the app's peak memory footprint so far.
/// The photos are private: nothing here sends them anywhere.
@available(iOS 17.0, *)
enum PhotoSetTest {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-rtcamPhotoTest") }

    static func run() async {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("photo-test", isDirectory: true)
        let out = dir.appendingPathComponent("results.jsonl")
        try? fm.removeItem(at: out)
        let photos = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        write(["event": "start", "photos": photos.count, "peakMB": peakMB()], to: out)
        for url in photos {
            guard let ui = UIImage(contentsOfFile: url.path), let cg = upright(ui) else { continue }
            let started = Date()
            let gate = FrameQualityGate.check(cg, checkDocumentEdges: true)
            var isPage = false
            if gate.documentFound == true { isPage = await OnDeviceVisionNarrator.hasReadableText(in: cg) }
            await OnDeviceVisionNarrator.shared.resetPassStats()
            let image = UIImage(cgImage: cg)
            let said = isPage
                ? await OnDeviceVisionNarrator.shared.narratePage(image, gate: gate.logValue)
                : await OnDeviceVisionNarrator.shared.narrateScene(image, gate: gate.logValue)
            let passes = await OnDeviceVisionNarrator.shared.passStats
            let first = passes.first
            write([
                "image": url.lastPathComponent, "kind": isPage ? "page" : "scene", "text": said ?? "",
                "ttftMs": Int(first?.ttftMs ?? -1), "firstPassMs": Int(first?.totalMs ?? -1),
                "encodeMs": Int(first?.encodeMs ?? -1), "promptTokens": first?.promptTokens ?? -1,
                "genTokens": first?.genTokens ?? -1, "passes": passes.count,
                "totalMs": Int(Date().timeIntervalSince(started) * 1000), "peakMB": peakMB(),
            ], to: out)
        }
        write(["event": "done", "peakMB": peakMB()], to: out)
    }

    /// Pixels upright (the camera roll JPEGs carry EXIF orientation).
    private static func upright(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up { return image.cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }

    private static func write(_ row: [String: Any], to url: URL) {
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Peak physical footprint of this process (what jetsam counts), in MB.
    private static func peakMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int(info.ledger_phys_footprint_peak / 1_000_000)
    }
}
