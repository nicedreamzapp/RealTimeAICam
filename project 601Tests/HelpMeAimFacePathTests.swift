@testable import RealTime_Ai_Cam
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Testing
import Vision

/// Proves the Face path offline (no phone, no person in front of a live
/// build): real frames go through AimFrameAnalyzer.detect exactly as the
/// camera hands them over: a portrait 32BGRA buffer (video rotation 90) and,
/// for the front camera, mirrored. Fixtures live on the dev Mac only (they
/// show people) and are never committed; the tests skip when they are absent.
struct HelpMeAimFacePathTests {
    /// Room scan frame (back camera, portrait buffer as delivered).
    static let roomFrame = "/Users/dtribe/rtcam-dev/roomscan/20260916-185335/frame-026.jpg"
    /// The analyzer's own saved input during the live front-camera run.
    static let frontFrame = "/Users/dtribe/rtcam-dev/shots/HelpMeAimShots/debug/205849-face-n1.jpg"

    /// The simulator cannot run Vision's face detector ("Could not create
    /// inference context", code 9), so these checks only mean something on a
    /// device or a Mac; elsewhere they are skipped rather than failing.
    static let visionFacesWork: Bool = {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pb)
        guard let pb else { return false }
        do {
            try VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
                .perform([VNDetectFaceRectanglesRequest()])
            return true
        } catch {
            return false
        }
    }()

    static func ready(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path) && visionFacesWork
    }

    static func cgImage(_ path: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 32BGRA buffer like the video output's, optionally mirrored left-right
    /// or turned a quarter (what an unrotated sensor buffer would look like).
    static func buffer(_ image: CGImage, mirrored: Bool = false, sideways: Bool = false) -> CVPixelBuffer? {
        var ci = CIImage(cgImage: image)
        if mirrored {
            ci = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -ci.extent.width, y: 0))
        }
        if sideways {
            ci = ci.oriented(.left)
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        }
        let w = Int(ci.extent.width), h = Int(ci.extent.height)
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let pb else { return nil }
        CIContext().render(ci, to: pb)
        return pb
    }

    static func faces(_ pb: CVPixelBuffer) -> AimObservation {
        AimFrameAnalyzer.detect(
            kind: .face,
            handler: VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:]),
            image: CIImage(cvPixelBuffer: pb), finder: nil, ids: [])
    }

    @Test(.enabled(if: HelpMeAimFacePathTests.ready(roomFrame)))
    func backCameraPortraitBufferFindsTheFace() throws {
        let img = try #require(Self.cgImage(Self.roomFrame))
        let pb = try #require(Self.buffer(img))
        let obs = Self.faces(pb)
        print("FACE-PATH room portrait: count \(obs.count) box \(String(describing: obs.box))")
        #expect(obs.count >= 1)
        // The 601 model put a face at x 0.38-0.72, y 0.43-0.67 in this frame.
        let box = try #require(obs.box)
        #expect(box.intersects(CGRect(x: 0.38, y: 0.43, width: 0.34, height: 0.24)))
    }

    @Test(.enabled(if: HelpMeAimFacePathTests.ready(roomFrame)))
    func frontCameraMirroredBufferFindsTheFace() throws {
        let img = try #require(Self.cgImage(Self.roomFrame))
        let pb = try #require(Self.buffer(img, mirrored: true))
        let obs = Self.faces(pb)
        print("FACE-PATH room mirrored: count \(obs.count) box \(String(describing: obs.box))")
        #expect(obs.count >= 1)
        let box = try #require(obs.box)
        // Mirrored: the face moves to x 0.28-0.62.
        #expect(box.intersects(CGRect(x: 0.28, y: 0.43, width: 0.34, height: 0.24)))
    }

    @Test(.enabled(if: HelpMeAimFacePathTests.ready(roomFrame)))
    func sidewaysBufferIsTheControl() throws {
        // What the camera would deliver WITHOUT the 90 degree rotation. Only
        // recorded, to show whether orientation matters to the detector.
        let img = try #require(Self.cgImage(Self.roomFrame))
        let pb = try #require(Self.buffer(img, sideways: true))
        let obs = Self.faces(pb)
        print("FACE-PATH room sideways (control): count \(obs.count) size \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))")
    }

    @Test(.enabled(if: HelpMeAimFacePathTests.ready(frontFrame)))
    func liveFrontCameraFrameFindsTheFace() throws {
        let img = try #require(Self.cgImage(Self.frontFrame))
        let pb = try #require(Self.buffer(img))
        let obs = Self.faces(pb)
        print("FACE-PATH live front frame: count \(obs.count) box \(String(describing: obs.box))")
        #expect(obs.count >= 1)
    }

    @Test(.enabled(if: HelpMeAimFacePathTests.ready(roomFrame)))
    func coachSteersOnTheRealFaceBox() throws {
        let img = try #require(Self.cgImage(Self.roomFrame))
        let pb = try #require(Self.buffer(img, mirrored: true))
        let box = try #require(Self.faces(pb).box)
        let said = AimSteering.instruction(for: box, framing: .person)
        print("FACE-PATH instruction for real face box \(box): \(said)")
        #expect(said != .notFound)
    }
}
