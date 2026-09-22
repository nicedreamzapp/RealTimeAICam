@testable import RealTime_Ai_Cam
import Foundation
import ImageIO
import Testing
import UIKit

/// AppleVis user "Matt" (2026-09-15): the photo and its description are saved
/// together. The description lives inside the JPEG, and the pixels are untouched.
struct HelpMeAimCaptionTests {
    private func jpeg() -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48), format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    private func pixels(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let bytes = cg.dataProvider?.data else { return nil }
        return bytes as Data
    }

    @Test func captionIsWrittenIntoThePhoto() throws {
        let plain = jpeg()
        #expect(AimCaption.read(from: plain) == nil)
        let said = "A white mug on a wooden table, handle to the right."
        let captioned = try #require(AimCaption.embed(said, in: plain))
        #expect(AimCaption.read(from: captioned) == said)
        let src = try #require(CGImageSourceCreateWithData(captioned as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        let tiff = try #require(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        #expect(tiff[kCGImagePropertyTIFFImageDescription] as? String == said)
    }

    @Test func pixelsAreNotReencoded() throws {
        let plain = jpeg()
        let captioned = try #require(AimCaption.embed("A red square.", in: plain))
        #expect(pixels(captioned) == pixels(plain))
    }

    @Test func emptyDescriptionSavesThePlainPhoto() {
        #expect(AimCaption.embed("   ", in: jpeg()) == nil)
    }
}
