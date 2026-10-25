@testable import RealTime_Ai_Cam
import Foundation
import Testing
import UIKit
import Vision
import Translation

/// Every language in the Translate "From" list, end to end below the UI: a sign
/// drawn as an image, read by Vision with that language's recognition code (the
/// same request setup LiveOCRViewModel uses), then turned into English by Apple's
/// translator. Prints one PROBE line per language so a run doubles as a report.
struct TranslateLanguagesTests {
    /// print() is lost in xcresult; set TEST_RUNNER_PROBE_OUT=/path to keep the lines.
    static func probe(_ line: String) {
        print(line)
        guard let path = ProcessInfo.processInfo.environment["PROBE_OUT"] else { return }
        let url = URL(fileURLWithPath: path)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write((line + "\n").data(using: .utf8)!); try? h.close() }
        else { try? (line + "\n").write(to: url, atomically: true, encoding: .utf8) }
    }

    static let samples: [String: String] = [
        "es": "Cerrado los domingos. Gracias por su visita.",
        "fr": "Fermé le dimanche. Merci de votre visite.",
        "de": "Bitte nicht rauchen. Der Eingang ist links.",
        "it": "Chiuso per ferie. Torniamo lunedì.",
        "pt": "Proibido estacionar. Saída de emergência.",
        "nl": "Niet roken. De ingang is aan de linkerkant.",
        "pl": "Zakaz palenia. Wejście jest po lewej stronie.",
        "tr": "Sigara içmek yasaktır. Giriş soldadır.",
        "id": "Dilarang merokok. Pintu masuk ada di sebelah kiri.",
        "vi": "Cấm hút thuốc. Lối vào ở bên trái.",
        "ru": "Не курить. Вход находится слева.",
        "uk": "Не палити. Вхід знаходиться ліворуч.",
        "zh-Hans": "禁止吸烟。入口在左边。",
        "ja": "禁煙です。入口は左側です。",
        "ko": "금연입니다. 입구는 왼쪽에 있습니다.",
        "th": "ห้ามสูบบุหรี่ ทางเข้าอยู่ทางซ้าย",
        "ar": "ممنوع التدخين. المدخل على اليسار.",
    ]

    static func sign(_ text: String) -> CGImage {
        let size = CGSize(width: 1400, height: 500)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let style = NSMutableParagraphStyle(); style.alignment = .center
            (text as NSString).draw(in: CGRect(x: 40, y: 120, width: 1320, height: 300), withAttributes: [
                .font: UIFont.systemFont(ofSize: 64, weight: .bold),
                .foregroundColor: UIColor.black, .paragraphStyle: style])
        }
        return img.cgImage!
    }

    static func read(_ image: CGImage, languages: [String]) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = languages
        try VNImageRequestHandler(cgImage: image).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    @Test func listHasEverySupportedLanguage() {
        let names = TranslateLanguage.available.map(\.name)
        Self.probe("PROBE available(\(names.count)): \(names.joined(separator: ", "))")
        #expect(TranslateLanguage.available.first == .spanish)
        #expect(TranslateLanguage.available.count > 1)
    }

    @Test func everyLanguageReadsAndTranslates() async throws {
        var failures: [String] = []
        for lang in TranslateLanguage.available {
            guard let sample = Self.samples[lang.code] else { failures.append("\(lang.code): no sample"); continue }
            let ocr = try Self.read(Self.sign(sample), languages: lang.vision)
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: lang.code), to: Locale.Language(identifier: "en"))
            let statusName = status == .installed ? "installed" : (status == .supported ? "supported" : "unsupported")
            var english = "-"
            if status == .installed {
                let session = TranslationSession(installedSource: Locale.Language(identifier: lang.code),
                                                 target: Locale.Language(identifier: "en"))
                do { english = try await session.translate(ocr).targetText }
                catch { english = "ERROR \(error)" }
            }
            Self.probe("PROBE \(lang.code) | ocr=\(ocr) | pack=\(statusName) | en=\(english)")
            if ocr.isEmpty { failures.append("\(lang.code): OCR read nothing") }
            #if !targetEnvironment(simulator)
            // The Simulator reports every pair unsupported (Apple's translator only
            // runs on hardware), so there this test checks the reading half only.
            if status == .unsupported { failures.append("\(lang.code): pair unsupported") }
            #endif
        }
        #expect(failures.isEmpty, "\(failures)")
    }
}
