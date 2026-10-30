import Foundation

/// The four sizes of What's this?, smartest first (1.4.0).
///
/// Blind scores are from the living benchmark (27 public photos, three judges):
/// github.com/nicedreamzapp/RealTimeAICam/tree/main/benchmarks. Balanced ships
/// inside the app so the very first photo works with no internet; the other
/// three are downloaded once from our own server and are then as offline as
/// the bundled one.
enum ModelLevel: String, CaseIterable, Codable, Identifiable {
    case sharp, clear, balanced, quick

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sharp: "Sharp"
        case .clear: "Clear"
        case .balanced: "Balanced"
        case .quick: "Quick"
        }
    }

    /// Blind score out of 100 on the public benchmark.
    var score: Int {
        switch self {
        case .sharp: 78
        case .clear: 75
        case .balanced: 57
        case .quick: 47
        }
    }

    var blurb: String {
        switch self {
        case .sharp: "The most accurate answers. Best on newer phones."
        case .clear: "Almost as accurate as Sharp, half the download."
        case .balanced: "Built into the app, always ready, even with no internet."
        case .quick: "The fastest answers, for older phones. Less detail."
        }
    }

    /// Text model and vision projector, as named in the level's folder.
    var modelFile: String {
        switch self {
        case .sharp: "lfm3-omni-2b-Q8_0.gguf"
        case .clear: "lfm3-omni-2b-Q3_K_M.gguf"
        case .balanced: "lfm3-omni-2b-IQ2_XS.gguf"
        case .quick: "vision-narrator-0.8b-Q4_K_M.gguf"
        }
    }

    var mmprojFile: String {
        switch self {
        case .sharp, .clear: "lfm3-omni-2b-mmproj-vision-Q8_0.gguf"
        case .balanced: "lfm3-omni-2b-mmproj-vision-Q4_K_M.gguf"
        case .quick: "vision-narrator-0.8b-mmproj-F16.gguf"
        }
    }

    /// LFM3 gets its chat template written out by hand (BOS + empty think
    /// block, as benchmarked); Quick uses the template inside its own GGUF, the
    /// way the Android app always ran it.
    var usesLFM3Prompt: Bool { self != .quick }

    /// Bytes on disk, from each folder's manifest.json.
    var bytes: Int64 {
        switch self {
        case .sharp: 2_049_283_586
        case .clear: 1_117_944_898
        case .balanced: 735_090_426
        case .quick: 736_644_128
        }
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var isBundled: Bool { self == .balanced }

    /// Folder on our server: https://ineedhemp.com/models/rtcam/<level>/
    var remoteURL: URL {
        URL(string: "https://ineedhemp.com/models/rtcam/\(rawValue)/")!
    }

    /// Time for one answer compared with Balanced, on an iPhone GPU. Sharp,
    /// Clear and Balanced are the iPhone 12 Pro Max medians (18.5 / 15.7 /
    /// 13.8 s, 2026-10-30). Quick is the iPhone 18 ratio of the old 0.8B to
    /// Balanced (0.57 / 1.56 s) rounded up, since its GGUF build has not been
    /// timed on an iPhone yet.
    var costVsBalanced: Double {
        switch self {
        case .sharp: 1.34
        case .clear: 1.14
        case .balanced: 1.0
        case .quick: 0.45
        }
    }

    /// Physical memory the phone needs before this level is offered. iOS
    /// reports a little under the marketing number (a 6 GB iPhone says ~5.6).
    /// Sharp ran on the 6 GB iPhone 12 Pro Max with no memory warnings.
    var minimumMemory: UInt64 {
        switch self {
        case .sharp: 5_400_000_000
        case .clear: 3_500_000_000
        case .balanced, .quick: 0
        }
    }

    var fitsThisPhone: Bool { ProcessInfo.processInfo.physicalMemory >= minimumMemory }
}

/// What kind of photo is being answered. Pages are mail, bills, labels,
/// receipts and medicine (the page reader); everything else is a scene.
enum PhotoKind { case page, scene }

/// "Accuracy first" (the default) or "Speed first", from Settings > Models.
enum ModelPriority: String, CaseIterable, Identifiable {
    case accuracy, speed
    var id: String { rawValue }

    var name: String { self == .accuracy ? "Most accurate" : "Fastest" }

    /// One plain line under the choice.
    var explanation: String {
        self == .accuracy
            ? "Best answers. Mail, money and medicine may take up to a minute, everything else up to 20 seconds."
            : "Quicker answers, about 10 seconds where this phone can, a little less accurate."
    }

    /// The longest a level may take and still be picked automatically.
    /// Accuracy first is Matt's rule (2026-10-30): pages, money, medicine and
    /// mail get the most accurate level the phone can run in about a minute,
    /// a scene gets the smartest level within about 20 seconds.
    func budget(for kind: PhotoKind) -> Double {
        switch (self, kind) {
        case (.accuracy, .page): 60
        case (.accuracy, .scene): 20
        case (.speed, .page): 20
        case (.speed, .scene): 10
        }
    }
}

/// Picks a level for each photo, from the speed check and what is on the phone.
enum ModelPicker {
    private static let defaults = UserDefaults.standard
    static let chosenKey = "modelLevelChoice"        // "auto" or a ModelLevel raw value
    static let priorityKey = "modelPriority"
    static let balancedSecondsKey = "modelBalancedSeconds"

    /// A page is read at 1024 px, a scene at 768 px: more image to encode.
    static let pageCost = 1.4

    /// nil means automatic.
    static var manualLevel: ModelLevel? {
        get { defaults.string(forKey: chosenKey).flatMap(ModelLevel.init(rawValue:)) }
        set { defaults.set(newValue?.rawValue ?? "auto", forKey: chosenKey) }
    }

    static var priority: ModelPriority {
        get { defaults.string(forKey: priorityKey).flatMap(ModelPriority.init(rawValue:)) ?? .accuracy }
        set { defaults.set(newValue.rawValue, forKey: priorityKey) }
    }

    /// Seconds for one scene answer on Balanced on this phone: the speed check,
    /// then kept current by real answers. nil until the speed check has run.
    static var balancedSeconds: Double? {
        let v = defaults.double(forKey: balancedSecondsKey)
        return v > 0 ? v : nil
    }

    static func setBalancedSeconds(_ seconds: Double) {
        defaults.set(seconds, forKey: balancedSecondsKey)
    }

    /// Folds one real answer into the estimate, so a phone that runs hot or
    /// got an OS update drifts to its true speed. Light weight: one odd photo
    /// (a long answer, a retry) moves it only a little.
    static func noteAnswer(level: ModelLevel, kind: PhotoKind, seconds: Double) {
        guard seconds > 0, let current = balancedSeconds else { return }
        let asBalanced = seconds / level.costVsBalanced / (kind == .page ? pageCost : 1)
        setBalancedSeconds(current * 0.8 + asBalanced * 0.2)
    }

    /// Expected seconds for one answer, or nil before the speed check.
    static func estimate(_ level: ModelLevel, kind: PhotoKind) -> Double? {
        guard let base = balancedSeconds else { return nil }
        return base * level.costVsBalanced * (kind == .page ? pageCost : 1)
    }

    /// Levels this phone has the memory for, smartest first.
    static var candidates: [ModelLevel] { ModelLevel.allCases.filter(\.fitsThisPhone) }

    /// The smartest level that answers within the budget, whether or not it is
    /// on the phone yet. The fastest one when nothing fits.
    static func ideal(for kind: PhotoKind, priority: ModelPriority = priority) -> ModelLevel {
        let budget = priority.budget(for: kind)
        for level in candidates {
            if let s = estimate(level, kind: kind), s <= budget { return level }
        }
        return balancedSeconds == nil ? .balanced : (candidates.last ?? .balanced)
    }

    /// What automatic mode wants downloaded: the page pick and the scene pick.
    static var wanted: Set<ModelLevel> {
        guard balancedSeconds != nil else { return [] }
        return [ideal(for: .page), ideal(for: .scene)]
    }

    /// The level to run right now, from what is actually on the phone.
    static func level(for kind: PhotoKind) -> ModelLevel {
        let installed = ModelLevel.allCases.filter { VisionModelStore.isInstalled($0) }
        if let manual = manualLevel {
            return installed.contains(manual) ? manual : .balanced
        }
        let ideal = ideal(for: kind)
        if installed.contains(ideal) { return ideal }
        // The pick is still downloading: the smartest level already here that
        // fits the budget, else the fastest one here.
        let budget = priority.budget(for: kind)
        let ready = candidates.filter { installed.contains($0) }
        if let fits = ready.first(where: { (estimate($0, kind: kind) ?? .infinity) <= budget }) { return fits }
        return ready.last ?? .balanced
    }

    /// "about 4 seconds", for the screen and VoiceOver.
    static func spoken(_ seconds: Double?) -> String {
        guard let s = seconds else { return "speed not checked yet" }
        if s < 1.5 { return "about 1 second" }
        if s < 60 { return "about \(Int(s.rounded())) seconds" }
        let m = Int((s / 60).rounded())
        return m == 1 ? "about a minute" : "about \(m) minutes"
    }
}
