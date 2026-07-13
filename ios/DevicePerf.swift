import Foundation
import Metal

enum PerfTier { case low, mid, high }

struct DevicePerf {
    static let shared = DevicePerf()
    let tier: PerfTier

    private init() {
        if #available(iOS 16.0, *) {
            tier = .high // NE + newer SoCs
            return
        }
        // iOS 15.x: use Metal GPU family as a proxy for age
        let supportsApple3Plus = MTLCreateSystemDefaultDevice()?.supportsFamily(.apple3) ?? false
        tier = supportsApple3Plus ? .mid : .low // iPhone 6s → .low
    }
}

extension DevicePerf {
    var thermalOptimizedTier: PerfTier {
        switch tier {
        case .high:
            .mid
        case .mid:
            .low
        case .low:
            .low
        }
    }

    var thermalOptimizedFrameRate: Int {
        switch thermalOptimizedTier {
        case .high:
            60
        case .mid:
            30
        case .low:
            15
        }
    }
}
