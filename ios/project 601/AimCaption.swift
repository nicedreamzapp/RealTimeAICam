import Foundation
import ImageIO
import Photos
import UIKit

/// The words that go with a Help Me Aim photo.
///
/// Asked for on AppleVis by the user "Matt" (2026-09-15): save the picture and
/// its description together, so the photo still says what it is when it is
/// found in Photos later or sent to someone. The on-phone vision model
/// describes the kept shot, and the description is written INTO the JPEG as its
/// caption (IPTC Caption, which Photos shows as the caption, plus the TIFF
/// ImageDescription). It travels with the file; nothing is uploaded.
enum AimCaption {
    /// The vision model's description of the kept shot, or nil when the model
    /// is not on the phone or had nothing to say. A page with words on it gets
    /// the mail reader, anything else the scene describer — same split as
    /// What's this?.
    static func describe(_ image: UIImage, isPage: Bool) async -> String? {
        guard OnDeviceVisionNarrator.isBundled else { return nil }
        if isPage, let cg = image.cgImage, await OnDeviceVisionNarrator.hasReadableText(in: cg) {
            return await OnDeviceVisionNarrator.shared.narratePage(image, gate: "help-me-aim")
        }
        return await OnDeviceVisionNarrator.shared.narrateScene(image, gate: "help-me-aim")
    }

    /// The same JPEG with `caption` written into its metadata. The pixels are
    /// copied as they are, not re-encoded. Nil if the file can't be rewritten,
    /// in which case the caller saves the plain photo.
    static func embed(_ caption: String, in jpeg: Data) -> Data? {
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let type = CGImageSourceGetType(src) else { return nil }
        let meta = CGImageMetadataCreateMutable()
        let tags: [(CFString, CFString)] = [
            (kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract),
            (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription),
        ]
        for (dict, key) in tags {
            guard CGImageMetadataSetValueMatchingImageProperty(meta, dict, key, text as CFString) else { return nil }
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: meta,
            kCGImageDestinationMergeMetadata: true,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &error) else { return nil }
        return out as Data
    }

    /// The caption written into `jpeg`, if any. Used by the tests.
    static func read(from jpeg: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] else { return nil }
        return iptc[kCGImagePropertyIPTCCaptionAbstract] as? String
    }

    /// Adds `jpeg` to Photos (add-only permission). Shared by Help Me Aim and
    /// What's this?'s Save Photo button.
    static func saveToPhotos(_ jpeg: Data, done: @escaping @MainActor (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { done(false) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: jpeg, options: nil)
            }, completionHandler: { ok, _ in
                DispatchQueue.main.async { done(ok) }
            })
        }
    }
}
