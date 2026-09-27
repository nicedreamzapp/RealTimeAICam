@testable import RealTime_Ai_Cam
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UIKit

// Fixes from Matt's house walkaround (2026-09-16, evidence in
// ~/rtcam-dev/walk). Boxes: normalized, top-left origin, y down.

private func rect(midX: CGFloat, midY: CGFloat, w: CGFloat, h: CGFloat) -> CGRect {
    CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
}

// MARK: - 1. Saved photos are upright pixels

struct AimUprightPhotoTests {
    /// A sensor-style JPEG: landscape pixels with EXIF orientation 6 (turn
    /// clockwise to view), red in the pixel top-left corner.
    private func sensorJPEG(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        // CGContext's origin is bottom-left: this is the TOP-left of the pixels.
        ctx.fill(CGRect(x: 0, y: height - height / 4, width: width / 4, height: height / 4))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func info(_ data: Data) -> (w: Int, h: Int, orientation: Int) {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        return (p[kCGImagePropertyPixelWidth] as! Int, p[kCGImagePropertyPixelHeight] as! Int,
                p[kCGImagePropertyOrientation] as? Int ?? 1)
    }

    /// Red channel at a point of the raw pixels (top-left origin).
    private func red(_ data: Data, x: CGFloat, y: CGFloat) -> UInt8 {
        let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let ix = Int(x * CGFloat(img.width)), iy = Int(y * CGFloat(img.height))
        return px[iy * img.width * 4 + ix * 4]
    }

    @Test func uncroppedWinnerIsSavedAsUprightPixels() throws {
        let shot = sensorJPEG(width: 400, height: 300)
        #expect(info(shot).orientation == 6)
        let result = AimShotProcessor.keepOne([shot], scored: [AimBurst.Frame(box: nil, sharpness: 100)],
                                              framing: .person, subjectName: "a face")
        let kept = try #require(result.keep)
        let saved = info(kept.photo)
        #expect(saved.orientation == 1)
        #expect(saved.w == 300 && saved.h == 400)
        // Orientation 6 moves the pixel top-left to the viewed top-right.
        #expect(red(kept.photo, x: 0.9, y: 0.05) > 200)
        #expect(red(kept.photo, x: 0.05, y: 0.05) < 160)
        #expect(kept.original == shot)
    }

    @Test func croppedWinnerIsUprightAndPortrait() throws {
        let shot = sensorJPEG(width: 2800, height: 2100)
        let box = rect(midX: 0.4, midY: 0.6, w: 0.12, h: 0.1)
        let result = AimShotProcessor.keepOne([shot], scored: [AimBurst.Frame(box: box, sharpness: 100)],
                                              framing: .whole, subjectName: "a cup")
        let kept = try #require(result.keep)
        #expect(kept.cropped)
        let saved = info(kept.photo)
        #expect(saved.orientation == 1)
        #expect(saved.h > saved.w)
        #expect(abs(CGFloat(saved.w) / CGFloat(saved.h) - 0.75) < 0.01)
    }

    @Test func holdAngleStaysPortraitUnlessClearlySideways() {
        // Flat on a table, whatever the coordinator last guessed.
        #expect(AimHold.captureAngle(levelAngle: 0, gravity: (0.05, -0.1, -0.99)) == 90)
        #expect(AimHold.captureAngle(levelAngle: 180, gravity: (0.3, 0.1, 0.95)) == 90)
        // Upright but the coordinator is stale.
        #expect(AimHold.captureAngle(levelAngle: 0, gravity: (0.1, -0.95, -0.2)) == 90)
        // Clearly on its side: trust the landscape angle.
        #expect(AimHold.captureAngle(levelAngle: 0, gravity: (-0.95, 0.05, -0.2)) == 0)
        #expect(AimHold.captureAngle(levelAngle: 180, gravity: (0.95, 0.05, -0.2)) == 180)
        // Diagonal is not "clearly".
        #expect(AimHold.captureAngle(levelAngle: 0, gravity: (-0.7, -0.6, -0.2)) == 90)
        // Unknown.
        #expect(AimHold.captureAngle(levelAngle: nil, gravity: nil) == 90)
        #expect(AimHold.captureAngle(levelAngle: 0, gravity: nil) == 90)
        // Portrait held on its side can't produce a portrait-only answer.
        #expect(AimHold.captureAngle(levelAngle: 90, gravity: (-0.95, 0.05, -0.2)) == 90)
    }
}

// MARK: - 2. Big selfie faces still get cropped

struct AimBigFaceCropTests {
    private let portrait = CGSize(width: 3024, height: 4032)

    @Test func walkaroundSelfieFaceIsLiftedTowardTheUpperThird() throws {
        // Winner box from walk/20260916-212853 (212921).
        let box = CGRect(x: 0.2924, y: 0.3626, width: 0.3512, height: 0.2634)
        let c = try #require(AimBurst.crop(box: box, imageSize: portrait, framing: .person))
        let face = CGRect(x: box.minX * portrait.width, y: box.minY * portrait.height,
                          width: box.width * portrait.width, height: box.height * portrait.height)
        #expect(c.contains(face))
        #expect(CGRect(origin: .zero, size: portrait).contains(c))
        #expect(abs(c.width / c.height - 0.75) < 0.01)
        let before = hypot(box.midX - 0.5, box.midY - 1.0 / 3.0)
        let after = hypot((face.midX - c.minX) / c.width - 0.5, (face.midY - c.minY) / c.height - 1.0 / 3.0)
        #expect(after < before - 0.03)
    }

    @Test func bigFaceAlreadyInPlaceIsLeftAlone() {
        // Big and already near the upper third: trimming would not help.
        #expect(AimBurst.crop(box: rect(midX: 0.5, midY: 0.36, w: 0.36, h: 0.27),
                              imageSize: portrait, framing: .person) == nil)
    }

    @Test func bigObjectsAreMovedToTheMiddleWithLessPadding() throws {
        // Was left alone before Kareen's report (2026-09-25).
        let box = rect(midX: 0.4, midY: 0.5, w: 0.6, h: 0.4)
        let c = try #require(AimBurst.crop(box: box, imageSize: portrait, framing: .whole))
        #expect(abs((box.midX * portrait.width - c.minX) / c.width - 0.5) < 0.01)
    }

    @Test func objectsFillingTheFrameAreNotCropped() {
        #expect(AimBurst.crop(box: rect(midX: 0.47, midY: 0.5, w: 0.9, h: 0.5),
                              imageSize: portrait, framing: .whole) == nil)
    }
}

// MARK: - 4. Bigger than the frame

struct AimTooBigTests {
    private func say(_ b: CGRect, _ f: AimSteering.Framing, loose: Bool = false) -> AimInstruction {
        AimSteering.instruction(for: b, framing: f, loose: loose)
    }

    @Test func twoEdgesMeansBackUp() {
        // Top-left corner cut: used to say "move left", then bounce.
        let corner = CGRect(x: 0.0, y: 0.0, width: 0.7, height: 0.6)
        #expect(say(corner, .whole) == .backUp)
        #expect(say(corner, .page) == .backUpCutOff)
        #expect(say(CGRect(x: 0.3, y: 0.3, width: 0.7, height: 0.7), .page) == .backUpCutOff)
        // One edge only: still move toward it.
        #expect(say(CGRect(x: 0.0, y: 0.2, width: 0.5, height: 0.5), .whole) == .moveLeft)
    }

    @Test func coveringMostOfTheFrameMeansBackUp() {
        #expect(say(rect(midX: 0.5, midY: 0.5, w: 0.95, h: 0.92), .whole) == .backUp)
        #expect(say(rect(midX: 0.5, midY: 0.5, w: 0.95, h: 0.92), .page) == .backUp)
    }

    @Test func pagePhraseSaysItIsCutOff() {
        #expect(AimPhrases.phrase(for: .backUpCutOff, subject: .page) == "back up, the page is cut off")
        #expect(AimPhrases.phrase(for: .backUp, subject: .page) == "back up")
    }

    @Test func pageNeedsAllFourCornersClearlyInside() {
        // 1% from the left edge: fine for an object, cut off for a page.
        let nearEdge = CGRect(x: 0.01, y: 0.25, width: 0.55, height: 0.5)
        #expect(!AimSteering.isCutOff(nearEdge))
        #expect(AimSteering.isCutOff(nearEdge, margin: AimSteering.pageEdgeMargin))
        #expect(say(nearEdge, .page) == .moveLeft)
        #expect(say(rect(midX: 0.5, midY: 0.5, w: 0.6, h: 0.7), .page) == .framed)
        #expect(AimSubject.page.framing == .page)
    }
}

struct AimFlipTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)
    private let left = rect(midX: 0.1, midY: 0.5, w: 0.1, h: 0.1)
    private let right = rect(midX: 0.9, midY: 0.5, w: 0.1, h: 0.1)
    private let up = rect(midX: 0.5, midY: 0.1, w: 0.1, h: 0.1)
    private let down = rect(midX: 0.5, midY: 0.9, w: 0.1, h: 0.1)

    /// Feeds `box` every 0.1 s over [from, to) and returns (time, line).
    private func run(_ c: inout AimCoach, _ box: CGRect, from: Double, to: Double) -> [(Double, String)] {
        var said: [(Double, String)] = []
        var t = from
        while t < to - 1e-9 {
            for case let .say(text, _) in c.observe(box: box, now: t0.addingTimeInterval(t), voiceBusy: false) {
                said.append((t, text))
            }
            t += 0.1
        }
        return said
    }

    @Test func reversingDirectionWaitsLonger() throws {
        var c = AimCoach(subject: .object(AimVocabulary.Match(spokenName: "cup", classNames: ["cup"], classIDs: [1])))
        c.reset(now: t0)
        let first = run(&c, left, from: 0, to: 1.0)
        #expect(first.map(\.1) == ["move the phone left"])
        // Smoothing needs a few frames to swing over, then 1.2 s must hold.
        let second = run(&c, right, from: 1.0, to: 4.0)
        let flip = try #require(second.first)
        #expect(flip.1 == "move the phone right")
        #expect(flip.0 >= 2.2 - 1e-6)
    }

    @Test func pageBouncingTurnsIntoBackUp() {
        var c = AimCoach(subject: .page)
        c.reset(now: t0)
        var lines: [String] = []
        lines += run(&c, left, from: 0, to: 1.5).map(\.1)
        lines += run(&c, up, from: 1.5, to: 3.0).map(\.1)
        lines += run(&c, right, from: 3.0, to: 4.5).map(\.1)
        lines += run(&c, down, from: 4.5, to: 6.0).map(\.1)
        #expect(lines == ["move the phone left", "move the phone up", "move the phone right", "back up"])
    }

    @Test func objectsDoNotGetTheBounceRule() {
        var c = AimCoach(subject: .object(AimVocabulary.Match(spokenName: "cup", classNames: ["cup"], classIDs: [1])))
        c.reset(now: t0)
        var lines: [String] = []
        lines += run(&c, left, from: 0, to: 1.5).map(\.1)
        lines += run(&c, up, from: 1.5, to: 3.0).map(\.1)
        lines += run(&c, right, from: 3.0, to: 4.5).map(\.1)
        lines += run(&c, down, from: 4.5, to: 6.0).map(\.1)
        #expect(lines.last == "move the phone down")
    }
}

// MARK: - 5. Page picks the right thing

struct AimPageChoiceTests {
    @Test func documentFinderWins() {
        let doc = rect(midX: 0.5, midY: 0.5, w: 0.6, h: 0.7)
        let other = AimPage.Candidate(box: rect(midX: 0.3, midY: 0.3, w: 0.8, h: 0.8), documentLike: true)
        #expect(AimPage.choose(document: doc, rectangles: [other], backup: nil) == doc)
    }

    @Test func colourfulRectangleWithNoSupportIsIgnored() {
        let r = AimPage.Candidate(box: rect(midX: 0.5, midY: 0.5, w: 0.4, h: 0.4), documentLike: false)
        #expect(AimPage.choose(document: nil, rectangles: [r], backup: nil) == nil)
    }

    @Test func paperLookingRectangleCounts() {
        let paper = AimPage.Candidate(box: rect(midX: 0.5, midY: 0.5, w: 0.3, h: 0.4), documentLike: true)
        let junk = AimPage.Candidate(box: rect(midX: 0.5, midY: 0.5, w: 0.8, h: 0.8), documentLike: false)
        #expect(AimPage.choose(document: nil, rectangles: [paper, junk], backup: nil) == paper.box)
    }

    @Test func modelSupportLetsAPaintingCount() {
        let frame = AimPage.Candidate(box: rect(midX: 0.5, midY: 0.45, w: 0.4, h: 0.5), documentLike: false)
        let yoloe = rect(midX: 0.5, midY: 0.45, w: 0.38, h: 0.48)
        #expect(AimPage.choose(document: nil, rectangles: [frame], backup: yoloe) == frame.box)
        // Somewhere else entirely: the model's box, not the stray rectangle.
        let elsewhere = rect(midX: 0.2, midY: 0.8, w: 0.2, h: 0.1)
        #expect(AimPage.choose(document: nil, rectangles: [frame], backup: elsewhere) == elsewhere)
    }

    @Test func pageRunningOffTheEdgeTakesTheModelsBiggerBox() {
        let inner = AimPage.Candidate(box: rect(midX: 0.5, midY: 0.5, w: 0.3, h: 0.3), documentLike: true)
        let whole = CGRect(x: 0, y: 0.1, width: 0.9, height: 0.8)
        #expect(AimPage.choose(document: nil, rectangles: [inner], backup: whole) == whole)
    }

    @Test func paperColours() {
        #expect(AimPage.isDocumentLike(red: 0.85, green: 0.85, blue: 0.8))
        #expect(!AimPage.isDocumentLike(red: 0.3, green: 0.3, blue: 0.32)) // grey cat
        #expect(!AimPage.isDocumentLike(red: 0.9, green: 0.5, blue: 0.2)) // orange painting
    }
}

// MARK: - Burst: blurry frames lose

struct AimBlurryBurstTests {
    @Test func walkaroundBlurryPageShotNoLongerWins() {
        // Scores from walk/20260916-212410 (212447): frame 4 won at sharpness 608.
        let frames = [
            AimBurst.Frame(box: CGRect(x: 0.54, y: 0.18, width: 0.20, height: 0.09), sharpness: 600),
            AimBurst.Frame(box: nil, sharpness: 1357),
            AimBurst.Frame(box: CGRect(x: 0.61, y: 0.19, width: 0.19, height: 0.08), sharpness: 1067),
            AimBurst.Frame(box: CGRect(x: 0.57, y: 0.19, width: 0.21, height: 0.08), sharpness: 879),
            AimBurst.Frame(box: CGRect(x: 0.52, y: 0.19, width: 0.23, height: 0.09), sharpness: 608),
        ]
        let pick = AimBurst.pick(frames, framing: .page)
        #expect(pick == 2 || pick == 3)
    }
}
