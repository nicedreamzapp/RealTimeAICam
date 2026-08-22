import CoreImage
import Foundation
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers
import UIKit
import Vision

/// Looks at the photo and says what matters.
///
/// ``OnDeviceNarrator`` reads words the recognizer hands it; this one skips the
/// recognizer and is shown the picture itself — a vision-language model
/// (Qwen3.5-2B, MLX 4-bit) found through ``VisionModelStore``: bundled as a
/// `VisionModel` folder, or downloaded once into Application Support.
/// Same promise as before: no network, no account, nothing leaves the phone.
///
/// Shape mirrors ``OnDeviceNarrator`` on purpose: one shared actor, the model
/// loaded on first use, `nil` back (never a guess) when it can't help, and every
/// answer written to scans.jsonl.
@available(iOS 17.0, *)
actor OnDeviceVisionNarrator {
    static let shared = OnDeviceVisionNarrator()

    private var container: ModelContainer?
    private var unavailable = false

    /// Word for word the instruction the model was tuned against. Do not edit
    /// without retuning — a drifted prompt asks a question it was never taught.
    private static let instructions = """
    You are the eyes of a blind person. Look at the photo and say what matters in one to three short spoken sentences. If it is a page of mail, a bill, a label or a receipt: lead with what the page is and who sent it, then the number that matters, then the deadline, then what happens if it is ignored. Money owed to the person is money coming to them, never a bill. Use only what is printed. An issue date is not a deadline. A number is only money if a dollar sign or the word dollars is printed with it. Not every page is a bill; an advertisement owes nothing. If it is a place or a thing: say where they are, then what is nearby and where it is relative to them, then people and anything moving, then hazards. Plain words, no lists, no markdown. Never guess at names or senders that are not printed. If the photo is too dark, blurry or cut off to tell, say so and say how to fix the shot.
    """

    /// The feature flag: the model is either on the phone or it isn't. The name
    /// is historical; it now means "available", whether the folder shipped in
    /// the bundle or was downloaded once (see ``VisionModelStore``). Cheap
    /// enough to ask on every scan, and it keeps the old OCR path the default
    /// whenever the weights are absent.
    nonisolated static var isBundled: Bool { VisionModelStore.isInstalled }

    /// A page of mail, a bill, a label, a receipt. Long side 1024 px so small
    /// print survives.
    /// `gate` is the FrameQualityGate log string for the shot that passed.
    func narratePage(_ image: UIImage, gate: String = "ok") async -> String? {
        await narrate(image, longSide: 1024, asking: "What is this page?", kind: "page", gate: gate)
    }

    /// A room, a street, a thing in front of the camera. 768 px is plenty for a
    /// scene and keeps the answer quick.
    func narrateScene(_ image: UIImage, gate: String = "ok") async -> String? {
        await narrate(image, longSide: 768, asking: "What is in front of me?", kind: "scene", gate: gate)
    }

    private func narrate(_ image: UIImage, longSide: CGFloat, asking question: String, kind: String,
                         gate: String) async -> String?
    {
        guard !unavailable else { return nil }
        #if DEBUG
        assert(MoneyCrossCheck.selfCheck(), "MoneyCrossCheck self-check failed")
        #endif
        guard let photo = Self.downscaled(image, longSide: longSide) else { return nil }
        do {
            let model = try await loaded()
            // A fresh session per photo, on purpose: one letter must never colour
            // the next. (mlx-swift-lm #157, the Qwen3.5 M-RoPE state crash, is
            // fixed in 3.31.4 — position ids now live in per-request LMOutput
            // state — which is why the project pins 3.x.)
            let session = ChatSession(
                model,
                instructions: Self.instructions,
                generateParameters: GenerateParameters(
                    maxTokens: 120,
                    temperature: 0,
                    repetitionPenalty: 1.1
                ),
                // The photo is already the size we want; the default here would
                // shrink it again to fit 512×512.
                processing: UserInput.Processing(resize: nil),
                // Qwen's chat-template switch for "answer, don't deliberate."
                additionalContext: ["enable_thinking": false]
            )
            let answer = try await session.respond(to: question, image: .ciImage(photo))
            var said = Self.tidy(answer)
            var extra: [String: Any] = ["gate": gate]
            // Money double-read: on a page, let Apple's recognizer check every
            // dollar amount the model spoke. Digits are where a small VLM slips.
            if kind == "page", let sentence = said, let cg = image.cgImage {
                let ocr = await Self.recognizedText(in: cg)
                let checked = MoneyCrossCheck.reconcile(sentence: sentence, ocrText: ocr)
                if let agreed = checked.agreed {
                    extra["money_agreed"] = agreed
                    extra["money_vlm"] = MoneyCrossCheck.amounts(in: sentence)
                    extra["money_ocr"] = MoneyCrossCheck.amounts(in: ocr)
                }
                said = checked.sentence
            }
            OnDeviceNarrator.log(read: "[photo: \(kind), long side \(Int(longSide)) px]", said: said,
                                 extra: extra)
            return said
        } catch {
            // A missing or broken model bundle degrades the feature, never the scan.
            unavailable = true
            return nil
        }
    }

    /// Full-res accurate OCR for the cross-check, off the main thread. Empty
    /// string if Vision throws, which makes the cross-check a no-op.
    private static func recognizedText(in image: CGImage) async -> String {
        await Task.detached(priority: .userInitiated) { () -> String in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do { try handler.perform([request]) } catch { return "" }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.joined(separator: "\n")
        }.value
    }

    private func loaded() async throws -> ModelContainer {
        if let container { return container }
        guard let url = VisionModelStore.installedURL else {
            throw VisionNarratorError.noModelInBundle
        }
        // Keep MLX's Metal buffer cache tiny: on a 6 GB phone the default cache
        // plus a 1.7 GB model is enough to get the app jetsammed (signal 9).
        MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)
        // mlx-swift-lm 3.x: the tokenizer implementation is injected rather than
        // bundled; the weights and tokenizer.json both come from the app bundle.
        let loaded = try await VLMModelFactory.shared.loadContainer(
            from: url, using: #huggingFaceTokenizerLoader())
        container = loaded
        return loaded
    }

    /// Redraws the photo so its long side is `longSide` points of pixels (never
    /// upscales), baking in orientation on the way, and hands back a CIImage
    /// the model's processor can take as-is.
    private static func downscaled(_ image: UIImage, longSide: CGFloat) -> CIImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, longSide / max(size.width, size.height))
        let target = CGSize(
            width: (size.width * scale).rounded(.down),
            height: (size.height * scale).rounded(.down)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let drawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let cg = drawn.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }

    /// Strips the scaffolding small models like to wrap an answer in.
    private static func tidy(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let open = text.range(of: "<think>") {
            if let close = text.range(of: "</think>", range: open.upperBound ..< text.endIndex) {
                text.removeSubrange(open.lowerBound ..< close.upperBound)
            } else {
                text.removeSubrange(open.lowerBound ..< text.endIndex)
            }
        }
        if let stray = text.range(of: "</think>") {
            text = String(text[stray.upperBound...])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \n\"'"))
        return text.count >= 12 ? text : nil
    }

    enum VisionNarratorError: Error { case noModelInBundle }
}
