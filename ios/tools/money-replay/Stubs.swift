import Foundation
// Just enough of the app around LiveVisionEngine.swift to load a level from this Mac: the same GGUF files the
// phone has (Balanced from ios/VisionModel in the main checkout, the others from ~/rtcam-models).
enum PhotoKind { case page, scene }
enum ModelLevel: String { case sharp, clear, balanced, quick
  var modelFile: String { switch self { case .sharp: "lfm3-omni-2b-Q8_0.gguf"; case .clear: "lfm3-omni-2b-Q3_K_M.gguf"; case .balanced: "lfm3-omni-2b-IQ2_XS.gguf"; case .quick: "vision-narrator-0.8b-Q4_K_M.gguf" } }
  var mmprojFile: String { switch self { case .sharp, .clear: "lfm3-omni-2b-mmproj-vision-Q8_0.gguf"; case .balanced: "lfm3-omni-2b-mmproj-vision-Q4_K_M.gguf"; case .quick: "vision-narrator-0.8b-mmproj-F16.gguf" } }
  var usesLFM3Prompt: Bool { self != .quick }
}
enum VisionModelStore {
  static func folder(_ l: ModelLevel) -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return URL(fileURLWithPath: l == .balanced ? home + "/rtcam-repo/ios/VisionModel" : home + "/rtcam-models/\(l.rawValue)")
  }
  static func isInstalled(_ l: ModelLevel) -> Bool { true }
}
enum ModelPicker { static func level(for: PhotoKind) -> ModelLevel { .balanced } }
