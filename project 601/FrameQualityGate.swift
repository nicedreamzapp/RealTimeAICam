import CoreGraphics
import CoreImage
import Foundation
import UIKit
import Vision

/// Looks at the photo BEFORE the model does, and says out loud what is wrong
/// with the shot when there is no point running inference on it.
///
/// Every check is cheap: the image is redrawn once as a 256 px grayscale
/// thumbnail and all the pixel maths runs on that. The optional document-edge
/// check is the only Vision call and it runs on the same thumbnail.
///
/// All thresholds below are first guesses meant to be tuned on a phone with a
/// real stack of mail. Nothing here can throw, and odd inputs (zero-size
/// images, failed contexts) fall through to `.ok` so the gate can only ever
/// skip a scan, never block one by mistake.
struct FrameQualityGate {
    enum Verdict: Equatable {
        case ok
        /// Plain spoken guidance about the *shot*, never about the person.
        case retake(String)
    }

    /// Numbers behind a verdict, written to scans.jsonl so the thresholds can
    /// be tuned against what actually happened in the field.
    struct Report {
        var verdict: Verdict
        var sharpness: Double = 0      // variance of Laplacian, 0-255 gray, 256 px thumb
        var brightness: Double = 0     // mean gray, 0-255
        var clipped: Double = 0        // fraction of pixels at >= clipLevel
        var documentFound: Bool? = nil // nil when the edge check was skipped
        var cutOffEdge: String? = nil  // "top"/"bottom"/"left"/"right"

        /// Short string for the "gate" log key, e.g. "ok s=312 b=168 c=0.01".
        var logValue: String {
            let tag: String
            switch verdict {
            case .ok: tag = "ok"
            case .retake(let why): tag = "retake:\(why)"
            }
            var parts = [tag, String(format: "s=%.0f", sharpness), String(format: "b=%.0f", brightness),
                         String(format: "c=%.3f", clipped)]
            if let documentFound { parts.append("doc=\(documentFound)") }
            if let cutOffEdge { parts.append("edge=\(cutOffEdge)") }
            return parts.joined(separator: " ")
        }
    }

    // MARK: Thresholds (tune on device)

    /// Long side of the analysis thumbnail. 256 keeps the whole gate well
    /// under 20 ms and is still enough for the Laplacian to see text edges.
    static let thumbLongSide = 256

    /// Variance of the 3x3 Laplacian on the thumbnail. On a 256 px thumb a
    /// sharp printed page usually lands in the hundreds and motion-blurred
    /// shots in the tens; 60 is a conservative first cut so real pages are not
    /// rejected. Raise if blurry shots get through, lower if crisp pages are bounced.
    static let minSharpness: Double = 60

    /// Mean gray below this is a shot taken in the dark. 50/255 is roughly
    /// "can't tell text from paper" on an iPhone exposure.
    static let minBrightness: Double = 50

    /// Mean gray above this is a washed-out frame (lamp in the lens, white wall).
    static let maxBrightness: Double = 235

    /// Gray level counted as blown out. 254 rather than 255 because JPEG
    /// rounding leaves real clipping a hair under full scale.
    static let clipLevel: UInt8 = 254

    /// Fraction of blown-out pixels that means glare. A clean white page
    /// photographs at ~200-240 gray, not 254+, so >12% at full scale is light
    /// bouncing off the paper rather than the paper itself.
    static let maxClipped: Double = 0.12

    /// A document corner within this fraction of the frame border counts as
    /// cut off. 2% of 1024 px is ~20 px, about one line of small print.
    static let edgeMargin: CGFloat = 0.02

    /// Document segmentation confidence below this is treated as "no page
    /// found", which is *not* a retake: scenes and odd paper are fine.
    static let minDocumentConfidence: Float = 0.5

    // MARK: Entry points

    /// `checkDocumentEdges` should be true for the page path only; a room or a
    /// street has no edges to cut off.
    static func check(_ image: CGImage, checkDocumentEdges: Bool) -> Report {
        guard let thumb = grayThumbnail(of: image) else { return Report(verdict: .ok) }
        var report = Report(verdict: .ok)
        report.brightness = thumb.mean
        report.clipped = thumb.clippedFraction
        report.sharpness = thumb.laplacianVariance

        // Order matters: a dark frame is also "blurry" by the numbers, so say
        // the thing that actually fixes the shot first.
        if report.brightness < minBrightness {
            report.verdict = .retake("It's too dark. Add some light or turn on the flash.")
            return report
        }
        if report.clipped > maxClipped || report.brightness > maxBrightness {
            report.verdict = .retake("There's glare on the page. Tilt the phone slightly.")
            return report
        }
        if report.sharpness < minSharpness {
            report.verdict = .retake("The page is blurry. Hold the phone still and try again.")
            return report
        }
        if checkDocumentEdges {
            let doc = documentEdges(in: image)
            report.documentFound = doc.found
            report.cutOffEdge = doc.cutOff
            if let edge = doc.cutOff {
                report.verdict = .retake("The \(edge) edge is cut off. Move back a little.")
                return report
            }
        }
        return report
    }

    static func check(_ image: CIImage, checkDocumentEdges: Bool) -> Report {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard image.extent.width > 0, image.extent.height > 0, image.extent.width.isFinite,
              let cg = context.createCGImage(image, from: image.extent)
        else { return Report(verdict: .ok) }
        return check(cg, checkDocumentEdges: checkDocumentEdges)
    }

    // MARK: Pixel maths

    struct GrayThumb {
        let width: Int
        let height: Int
        let pixels: [UInt8]

        var mean: Double {
            guard !pixels.isEmpty else { return 0 }
            var sum = 0
            for p in pixels { sum += Int(p) }
            return Double(sum) / Double(pixels.count)
        }

        var clippedFraction: Double {
            guard !pixels.isEmpty else { return 0 }
            var n = 0
            for p in pixels where p >= FrameQualityGate.clipLevel { n += 1 }
            return Double(n) / Double(pixels.count)
        }

        /// Variance of the 4-neighbour Laplacian over the interior pixels.
        var laplacianVariance: Double {
            guard width >= 3, height >= 3 else { return 0 }
            var sum = 0.0
            var sumSq = 0.0
            var count = 0.0
            pixels.withUnsafeBufferPointer { p in
                for y in 1 ..< (height - 1) {
                    let row = y * width
                    for x in 1 ..< (width - 1) {
                        let i = row + x
                        let lap = 4 * Int(p[i]) - Int(p[i - 1]) - Int(p[i + 1])
                            - Int(p[i - width]) - Int(p[i + width])
                        let v = Double(lap)
                        sum += v
                        sumSq += v * v
                        count += 1
                    }
                }
            }
            guard count > 0 else { return 0 }
            let m = sum / count
            return max(0, sumSq / count - m * m)
        }
    }

    static func grayThumbnail(of image: CGImage) -> GrayThumb? {
        let w0 = image.width, h0 = image.height
        guard w0 > 0, h0 > 0 else { return nil }
        let scale = min(1, Double(thumbLongSide) / Double(max(w0, h0)))
        let w = max(3, Int(Double(w0) * scale)), h = max(3, Int(Double(h0) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress,
                  let ctx = CGContext(
                      data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                      space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  )
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? GrayThumb(width: w, height: h, pixels: pixels) : nil
    }

    // MARK: Document edges

    /// Runs Vision's document segmentation and reports whether a page was
    /// found and, if so, which edge (if any) touches the frame border.
    static func documentEdges(in image: CGImage) -> (found: Bool, cutOff: String?) {
        guard #available(iOS 15.0, *) else { return (false, nil) }
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return (false, nil) }
        guard let obs = request.results?.first, obs.confidence >= minDocumentConfidence else {
            return (false, nil)
        }
        // Vision's normalized coordinates have the origin at the bottom-left.
        let corners = [obs.topLeft, obs.topRight, obs.bottomLeft, obs.bottomRight]
        var edge: String?
        for c in corners {
            if c.y > 1 - edgeMargin { edge = "top"; break }
            if c.y < edgeMargin { edge = "bottom"; break }
            if c.x < edgeMargin { edge = "left"; break }
            if c.x > 1 - edgeMargin { edge = "right"; break }
        }
        return (true, edge)
    }
}
