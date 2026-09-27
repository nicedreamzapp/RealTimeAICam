@testable import RealTime_Ai_Cam
import CoreGraphics
import Foundation
import Testing
import UIKit

// Kareen (Blind Android Users, 2026-09-25): Help Me Aim's photos had the
// subject in them but "usually not in the centre", and a photo frame "was
// taken at an angle". Boxes: normalized, top-left origin, y down.

private func rect(midX: CGFloat, midY: CGFloat, w: CGFloat, h: CGFloat) -> CGRect {
    CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
}

struct KareenCenteringTests {
    private let portrait = CGSize(width: 3024, height: 4032)

    @Test func smallSubjectsKeepTheWideZone() {
        #expect(AimSteering.centerTolerance(size: 0.3, loose: false) == AimSteering.wholeTolerance)
        #expect(AimSteering.centerTolerance(size: 0.3, loose: true) == AimSteering.wholeLooseTolerance)
    }

    @Test func bigSubjectsGetATighterZoneButNeverTiny() {
        let t6 = AimSteering.centerTolerance(size: 0.6, loose: false)
        #expect(abs(t6 - (1 - 0.6 / 0.9) / 2) < 1e-6)
        #expect(AimSteering.centerTolerance(size: 0.9, loose: false) == AimSteering.bigSubjectMinTolerance)
        #expect(AimSteering.centerTolerance(size: 0.6, loose: true) > t6)
    }

    @Test func bigPictureOffToTheSideIsSteered() {
        let off = rect(midX: 0.3, midY: 0.5, w: 0.6, h: 0.5)
        #expect(AimSteering.instruction(for: off, framing: .page) == .moveLeft)
        #expect(AimSteering.instruction(for: off, framing: .whole) == .moveLeft)
        let near = rect(midX: 0.4, midY: 0.5, w: 0.6, h: 0.5)
        #expect(AimSteering.instruction(for: near, framing: .page) == .framed)
    }

    /// Whatever the tight zone calls framed, the crop finishes centring.
    @Test func everyFramedObjectEndsUpCentered() {
        for size in stride(from: 0.12 as CGFloat, through: 0.86, by: 0.02) {
            let tol = AimSteering.centerTolerance(size: size, loose: false)
            for sign in [-1.0 as CGFloat, 1.0] {
                let box = rect(midX: 0.5 + sign * (tol - 0.001), midY: 0.5, w: size, h: size * 0.75)
                guard AimSteering.instruction(for: box, framing: .whole) == .framed else { continue }
                if let c = AimBurst.crop(box: box, imageSize: portrait, framing: .whole) {
                    let x = (box.midX * portrait.width - c.minX) / c.width
                    #expect(abs(x - 0.5) < 0.02, "size \(size) sign \(sign): x \(x)")
                } else {
                    #expect(abs(box.midX - 0.5) <= AimBurst.wellFramedDistance + 1e-6, "size \(size) not cropped")
                }
            }
        }
    }

    @Test func tiltedQuadIsUsable() {
        let q = AimQuad(topLeft: CGPoint(x: 0.25, y: 0.2), topRight: CGPoint(x: 0.8, y: 0.25),
                        bottomRight: CGPoint(x: 0.75, y: 0.8), bottomLeft: CGPoint(x: 0.2, y: 0.75))
        #expect(AimStraighten.usable(q, imageSize: portrait))
    }

    @Test func badQuadsAreRefused() {
        // Corner on the edge: the page may be cut off.
        #expect(!AimStraighten.usable(AimQuad(topLeft: CGPoint(x: 0, y: 0.2), topRight: CGPoint(x: 0.8, y: 0.2),
                                              bottomRight: CGPoint(x: 0.8, y: 0.8), bottomLeft: CGPoint(x: 0.1, y: 0.8)),
                                      imageSize: portrait))
        // Tiny.
        #expect(!AimStraighten.usable(AimQuad(topLeft: CGPoint(x: 0.5, y: 0.5), topRight: CGPoint(x: 0.6, y: 0.5),
                                              bottomRight: CGPoint(x: 0.6, y: 0.6), bottomLeft: CGPoint(x: 0.5, y: 0.6)),
                                      imageSize: portrait))
        // Bow tie (corners out of order).
        #expect(!AimStraighten.usable(AimQuad(topLeft: CGPoint(x: 0.2, y: 0.2), topRight: CGPoint(x: 0.8, y: 0.8),
                                              bottomRight: CGPoint(x: 0.8, y: 0.2), bottomLeft: CGPoint(x: 0.2, y: 0.8)),
                                      imageSize: portrait))
        // Far too steep.
        #expect(!AimStraighten.usable(AimQuad(topLeft: CGPoint(x: 0.45, y: 0.2), topRight: CGPoint(x: 0.55, y: 0.2),
                                              bottomRight: CGPoint(x: 0.9, y: 0.8), bottomLeft: CGPoint(x: 0.1, y: 0.8)),
                                      imageSize: portrait))
        #expect(!AimStraighten.usable(nil, imageSize: portrait))
    }

    @Test func outputSizeFollowsTheLongerSides() {
        let q = AimQuad(topLeft: CGPoint(x: 0.2, y: 0.2), topRight: CGPoint(x: 0.8, y: 0.2),
                        bottomRight: CGPoint(x: 0.8, y: 0.6), bottomLeft: CGPoint(x: 0.2, y: 0.6))
        let s = AimStraighten.outputSize(q, imageSize: CGSize(width: 1000, height: 1000))
        #expect(s == CGSize(width: 600, height: 400))
    }

    /// A white page drawn tilted on dark grey comes back as a white rectangle.
    @Test func keptPageIsSquaredUp() throws {
        let W = 2400, H = 3200
        let ctx = try #require(CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(gray: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        // Our corners, top-left origin.
        let q = AimQuad(topLeft: CGPoint(x: 0.25, y: 0.2), topRight: CGPoint(x: 0.8, y: 0.25),
                        bottomRight: CGPoint(x: 0.75, y: 0.8), bottomLeft: CGPoint(x: 0.2, y: 0.75))
        // CGContext has a bottom-left origin.
        ctx.beginPath()
        for (i, p) in q.corners.enumerated() {
            let pt = CGPoint(x: p.x * CGFloat(W), y: (1 - p.y) * CGFloat(H))
            if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
        }
        ctx.closePath()
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fillPath()
        let image = try #require(ctx.makeImage())
        let jpeg = try #require(UIImage(cgImage: image).jpegData(compressionQuality: 0.95))
        let box = CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let result = AimShotProcessor.keepOne([jpeg], scored: [AimBurst.Frame(box: box, sharpness: 100, quad: q)],
                                              framing: .page, subjectName: "a picture or page")
        let kept = try #require(result.keep)
        #expect(kept.cropped)
        #expect(kept.info.straightened?.count == 8)
        let out = try #require(UIImage(data: kept.photo)?.cgImage)
        let want = AimStraighten.outputSize(q, imageSize: CGSize(width: W, height: H))
        #expect(abs(CGFloat(out.width) - want.width) <= 2 && abs(CGFloat(out.height) - want.height) <= 2)
        // Near every corner of the result is page (white), not background.
        let small = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        small.draw(out, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let px = small.data!.assumingMemoryBound(to: UInt8.self)
        for (x, y) in [(5, 5), (94, 5), (5, 94), (94, 94), (50, 50)] {
            #expect(px[y * 400 + x * 4] > 200, "pixel \(x),\(y) is \(px[y * 400 + x * 4])")
        }
    }

    @Test func facesAndObjectsAreNeverSquaredUp() throws {
        let q = AimQuad(topLeft: CGPoint(x: 0.25, y: 0.2), topRight: CGPoint(x: 0.8, y: 0.25),
                        bottomRight: CGPoint(x: 0.75, y: 0.8), bottomLeft: CGPoint(x: 0.2, y: 0.75))
        let img = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { _ in }
        let jpeg = try #require(img.jpegData(compressionQuality: 0.9))
        let r = AimShotProcessor.keepOne([jpeg], scored: [AimBurst.Frame(box: nil, sharpness: 1, quad: q)],
                                         framing: .whole, subjectName: "a cup")
        #expect(r.keep?.info.straightened == nil)
    }
}
