@testable import RealTime_Ai_Cam
import CoreGraphics
import Foundation
import Testing
import UIKit

/// Matt's rule (2026-09-16): a burst keeps exactly ONE photo, the best
/// framed and sharpest; the other frames are never saved anywhere. And the
/// dev-only shot log can never be switched on from the project file.
struct HelpMeAimOnePhotoTests {
    private func jpeg(width: Int, height: Int, shade: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor(white: shade, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    private func rect(midX: CGFloat, midY: CGFloat, w: CGFloat, h: CGFloat) -> CGRect {
        CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }

    /// Every Data value reachable from `value`.
    private func allData(in value: Any) -> [Data] {
        if let d = value as? Data { return [d] }
        return Mirror(reflecting: value).children.flatMap { allData(in: $0.value) }
    }

    @Test func burstKeepsExactlyOnePhotoAndNoLosers() throws {
        let frames = (0 ..< 5).map { jpeg(width: 300, height: 400, shade: CGFloat($0) / 5) }
        let scored = [
            AimBurst.Frame(box: rect(midX: 0.8, midY: 0.5, w: 0.3, h: 0.3), sharpness: 200),
            AimBurst.Frame(box: nil, sharpness: 500),
            AimBurst.Frame(box: rect(midX: 0.5, midY: 0.5, w: 0.5, h: 0.5), sharpness: 250),
            AimBurst.Frame(box: rect(midX: 0.5, midY: 0.5, w: 0.5, h: 0.5), sharpness: 100),
            AimBurst.Frame(box: CGRect(x: 0, y: 0.2, width: 0.5, height: 0.5), sharpness: 300),
        ]
        let result = AimShotProcessor.keepOne(frames, scored: scored, framing: .whole, subjectName: "a dog")
        let kept = try #require(result.keep)
        #expect(kept.info.winner == 2)
        #expect(kept.photo == frames[2])
        #expect(kept.cropped == false)
        // Nothing from the four other frames is anywhere in what is kept.
        let carried = allData(in: result)
        for (i, frame) in frames.enumerated() where i != 2 {
            #expect(!carried.contains(frame), "frame \(i) leaked into the result")
        }
        // One distinct photo.
        #expect(Set(carried).count == 1)
        // Scores for every frame, pixels for none of the losers.
        #expect(kept.info.frames.count == 5)
    }

    @Test func croppedWinnerIsStillOnePhoto() throws {
        let frames = (0 ..< 3).map { jpeg(width: 2400, height: 3200, shade: CGFloat($0) / 3) }
        let small = rect(midX: 0.3, midY: 0.6, w: 0.15, h: 0.12)
        let scored = [
            AimBurst.Frame(box: nil, sharpness: 10),
            AimBurst.Frame(box: small, sharpness: 50),
            AimBurst.Frame(box: nil, sharpness: 90),
        ]
        let result = AimShotProcessor.keepOne(frames, scored: scored, framing: .whole, subjectName: "a key")
        let kept = try #require(result.keep)
        #expect(kept.info.winner == 1)
        #expect(kept.cropped)
        #expect(kept.original == frames[1])
        #expect(kept.photo != frames[1])
        let image = try #require(UIImage(data: kept.photo))
        #expect(max(image.size.width, image.size.height) >= 2000)
        let carried = allData(in: result)
        #expect(!carried.contains(frames[0]))
        #expect(!carried.contains(frames[2]))
    }

    @Test func emptyBurstKeepsNothing() {
        #expect(AimShotProcessor.keepOne([], scored: [], framing: .whole, subjectName: "x").keep == nil)
    }

    @Test func shotLogFlagIsNeverInTheProjectFile() throws {
        // The dev-only shot log is switched on only from the xcodebuild
        // command line; an archive built from the project must not have it.
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RealTime Ai Cam.xcodeproj/project.pbxproj")
        let text = try String(contentsOf: project, encoding: .utf8)
        #expect(!text.contains("HELP_ME_AIM_SHOT_LOG"))
        #if HELP_ME_AIM_SHOT_LOG
        Issue.record("HELP_ME_AIM_SHOT_LOG is set for the unit test build")
        #endif
    }
}
