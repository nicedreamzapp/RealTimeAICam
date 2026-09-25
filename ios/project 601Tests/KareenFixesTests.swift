@testable import RealTime_Ai_Cam
import CoreGraphics
import Foundation
import Testing

/// Kareen and Warren (Blind Android Users, 2026-09-22/25): what the live
/// detector says first, the remembered Help Me Aim words, and emoji-free labels.
struct KareenFixesTests {
    private func defaults() -> UserDefaults {
        let name = "KareenFixesTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func recentTargetsNewestFirstDedupedAndCapped() {
        let d = defaults()
        for word in ["cup", "laptop", "Cup", "keys", "dog", "plant", "book", "chair"] {
            AimRecentTargets.remember(word, in: d)
        }
        let list = AimRecentTargets.all(d)
        #expect(list == ["chair", "book", "plant", "dog", "keys", "cup"])
        #expect(list.count == AimRecentTargets.limit)
    }

    @Test func recentTargetsNormaliseAndClear() {
        let d = defaults()
        AimRecentTargets.remember("  I'm looking for my Coffee Mug! ", in: d)
        #expect(AimRecentTargets.all(d) == ["coffee mug"])
        #expect(AimRecentTargets.title("coffee mug") == "Coffee mug")
        AimRecentTargets.remember("   ", in: d)
        #expect(AimRecentTargets.all(d).count == 1)
        AimRecentTargets.clear(d)
        #expect(AimRecentTargets.all(d).isEmpty)
    }

    private func det(_ name: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) -> YOLODetection {
        YOLODetection(classIndex: 0, className: name, score: 0.5,
                      rect: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size))
    }

    @Test func mostCentralObjectComesFirst() {
        let order = SpeechManager.centralFirst([
            det("Trampoline", 0.1, 0.1, 0.2),
            det("Squash", 0.5, 0.52, 0.1),
            det("Chair", 0.8, 0.5, 0.3),
        ]).map(\.className)
        #expect(order == ["Squash", "Chair", "Trampoline"])
    }

    @Test func tieGoesToTheBiggerBox() {
        let order = SpeechManager.centralFirst([
            det("Cup", 0.5, 0.5, 0.1),
            det("Table", 0.5, 0.5, 0.6),
        ]).map(\.className)
        #expect(order == ["Table", "Cup"])
    }

    @Test func voiceOverWaitScalesWithLength() {
        #expect(abs(SpeechManager.estimatedAnnouncementSeconds("cup") - 0.61) < 0.001)
        #expect(SpeechManager.estimatedAnnouncementSeconds("cup, laptop, chair") > 1.5)
    }

    @Test func labelsLoseTheirEmoji() {
        #expect(SpokenLabel.withoutEmoji("🔄 Switch Camera — Front / Rear") == "Switch Camera — Front / Rear")
        #expect(SpokenLabel.withoutEmoji("🐕 **Object Detection**") == "Object Detection")
        #expect(SpokenLabel.withoutEmoji("• 🗣️ Speak detected/translated text") == "Speak detected/translated text")
        #expect(SpokenLabel.withoutEmoji("🇲🇽→🇺🇸 **Spanish to English Translate**") == "Spanish to English Translate")
        #expect(SpokenLabel.withoutEmoji("🌐 Lens Toggle — Wide ↔ Ultra-wide") == "Lens Toggle — Wide or Ultra-wide")
        #expect(SpokenLabel.withoutEmoji("🔦 Torch — 25% / 50% / 75% / 100%") == "Torch — 25% / 50% / 75% / 100%")
    }
}
