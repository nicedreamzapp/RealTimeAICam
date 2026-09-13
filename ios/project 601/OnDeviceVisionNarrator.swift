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
    You are the eyes of a blind person. Look at the photo and say what matters in one to three short spoken sentences. If it is a page of mail, a bill, a label or a receipt: lead with what the page is and who sent it, then the number that matters, then the deadline, then what happens if it is ignored. Money owed to the person is money coming to them, never a bill. Use only what is printed. An issue date is not a deadline. A number is only money if a dollar sign or the word dollars is printed with it. Not every page is a bill; an advertisement owes nothing. If it is a place or a thing: say where they are, then what is nearby and where it is relative to them, then people and anything moving, then hazards. Plain words, no lists, no markdown. Never guess at names or senders that are not printed. Never refuse, never say you cannot see it, and never ask for another photo. If the shot is dark, blurry or cut off, say in a few words that it is hard to see and then describe whatever you can make out anyway: the shapes, the colours, where things are, and any words you can read.
    """

    /// The stripped-back instruction for the last-resort pass: describe, full
    /// stop. No page rules, no money rules, nothing that can be read as grounds
    /// to bounce the shot back at the person holding the camera.
    private static let describeOnlyInstructions = """
    You are the eyes of a blind person. Describe what is in the photo in one to three short spoken sentences: the objects, their colours, where they are, any people, and any words you can read. Plain words, no lists, no markdown. If the photo is unclear, say so in a few words and then describe what you can make out anyway. Never say you cannot see it and never ask for another photo.
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
    func narratePage(_ image: UIImage, gate: String = "ok", hint: String? = nil,
                     cutOff: String? = nil) async -> String? {
        // Same lesson as the scene path: no dark/blurry/cut-off priming, it only
        // triggers false refusals. Kept as params for logging.
        _ = hint; _ = cutOff
        return await narrate(image, longSide: 1024, asking: "What is this page?", kind: "page", gate: gate)
    }

    /// A room, a street, a thing in front of the camera. 768 px is plenty for a
    /// scene and keeps the answer quick.
    func narrateScene(_ image: UIImage, gate: String = "ok", hint: String? = nil) async -> String? {
        // NO "the photo looks dark" priming. On-device testing showed that telling
        // the model the shot is dark or blurry is exactly what makes it refuse a
        // perfectly readable dim photo -- the plain question describes dim scenes
        // fine on its own. `hint` is kept for logging only.
        _ = hint
        let ask = "What is in front of me? Describe the scene: the objects, any people, and where they are."
        return await narrate(image, longSide: 768, asking: ask, kind: "scene", gate: gate)
    }

    /// A spoken follow-up question about a photo already on screen — same model,
    /// same offline promise. Used by the hold-to-ask button after a scan.
    func ask(_ question: String, about image: UIImage) async -> String? {
        guard !unavailable else { return nil }
        guard let photo = Self.downscaled(image, longSide: 1024) else { return nil }
        do {
            let model = try await loaded()
            func run(_ q: String, _ temp: Float) async throws -> String? {
                let session = ChatSession(
                    model, instructions: Self.instructions,
                    generateParameters: GenerateParameters(maxTokens: 160, temperature: temp,
                                                           repetitionPenalty: 1.1),
                    processing: UserInput.Processing(resize: nil),
                    additionalContext: ["enable_thinking": false]
                )
                return Self.tidy(try await session.respond(to: q, image: .ciImage(photo)))
            }
            let started = Date()
            var said = try await run(question, 0.2)
            if Self.looksLikeRefusal(said) {
                said = try await run(
                    "Answer this question as best you can from the photo, even if it is unclear. "
                    + "Do not refuse. Question: \(question)", 0.3)
            }
            OnDeviceNarrator.log(read: "[ask: \(question)]", said: said,
                                 extra: ["kind": "ask",
                                         "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100])
            return said
        } catch {
            OnDeviceNarrator.log(read: "[ask]", said: nil, extra: ["error": String(describing: error)])
            return nil
        }
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
            let started = Date()
            let answer = try await session.respond(to: question, image: .ciImage(photo))
            var said = Self.tidy(answer)
            // Wall-clock seconds from photo to sentence, on this phone. The M5
            // numbers never meant anything for the device; this does.
            var extra: [String: Any] = ["gate": gate,
                                        "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100,
                                        "model": VisionModelStore.installedURL?.lastPathComponent ?? "?"]
            // Never leave the user with a flat "I can't" — mail or scene. If the
            // model balked, ask once more and require an answer that leads with an
            // honest caveat instead of a refusal.
            if Self.looksLikeRefusal(said) {
                let forced: String
                if kind == "page" {
                    forced = "Read whatever you can from this page even though it is unclear. "
                        + "Do not say you cannot. Start with \"The shot was hard to read, but I can make out\" "
                        + "and then read the words, amounts and dates you can see."
                } else {
                    forced = "Describe what is in this photo even though it is unclear. "
                        + "Do not say you cannot. Start with \"It's hard to see clearly, but\" and then "
                        + "describe the shapes, colours, objects and people you can make out and where they are."
                }
                let retrySession = ChatSession(
                    model, instructions: Self.instructions,
                    generateParameters: GenerateParameters(maxTokens: 120, temperature: 0.2,
                                                           repetitionPenalty: 1.1),
                    processing: UserInput.Processing(resize: nil),
                    additionalContext: ["enable_thinking": false]
                )
                if let retry = Self.tidy(try await retrySession.respond(
                        to: forced, image: .ciImage(Self.brightened(photo, ev: 1.6)))) {
                    said = retry
                    extra["forced_describe"] = true
                }
            }
            // The retry was never re-checked, so a second refusal went straight
            // out of the speaker. Now it doesn't: drop the page framing entirely
            // and ask for a plain description of whatever is in the picture.
            if Self.looksLikeRefusal(said) {
                let plain = "Describe this photo: the objects, their colours, where they are, any people, "
                    + "and any words you can read. Describe only. Never say you cannot see it."
                let lastSession = ChatSession(
                    model, instructions: Self.describeOnlyInstructions,
                    generateParameters: GenerateParameters(maxTokens: 120, temperature: 0.4,
                                                           repetitionPenalty: 1.1),
                    processing: UserInput.Processing(resize: nil),
                    additionalContext: ["enable_thinking": false]
                )
                if let last = Self.tidy(try await lastSession.respond(
                        to: plain, image: .ciImage(Self.brightened(photo, ev: 2.2)))) {
                    said = last
                    extra["plain_describe"] = true
                }
            }
            // Three refusals in a row means prose is the problem: asked for a
            // sentence, this model keeps choosing the apology. So stop asking for
            // a sentence. A bare comma list of nouns is very hard to refuse, and
            // "I can see a bed, a lamp, a dark shape" is a real answer.
            if Self.looksLikeRefusal(said) {
                let listing = "List the things you can see in this picture, separated by commas. "
                    + "Nouns only. No sentences, no explanations, no apologies."
                let listSession = ChatSession(
                    model, instructions: Self.describeOnlyInstructions,
                    generateParameters: GenerateParameters(maxTokens: 90, temperature: 0.6,
                                                           repetitionPenalty: 1.1),
                    processing: UserInput.Processing(resize: nil),
                    additionalContext: ["enable_thinking": false]
                )
                let raw = try await listSession.respond(
                    to: listing, image: .ciImage(Self.brightened(photo, ev: 2.6)))
                if let things = Self.thingsOnly(raw) {
                    // Matt's words for what this should sound like: "I'm having a
                    // hard time seeing it, but this is what I think it is."
                    // Honest about the shot, and still an answer.
                    said = "It's hard to see clearly, but I think I can make out \(things)."
                    extra["listed_things"] = true
                }
            }
            // Last line of defence. If an excuse still survived every pass, cut
            // the excuse sentences out and speak whatever description is left,
            // rather than reading "move the camera back and try again" to someone
            // who cannot see where the camera is pointing.
            if Self.looksLikeRefusal(said), let sentence = said,
               let kept = Self.strippingExcuses(sentence) {
                said = kept
                extra["excuses_stripped"] = true
            }
            // Money double-read: on a page, let Apple's recognizer check every
            // dollar amount the model spoke — after the retry, so it checks the
            // words actually about to be spoken. Digits are where a small VLM slips.
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
            // A missing or broken model bundle degrades the feature, never the scan --
            // but it is written down, so a silent fallback to OCR can be seen.
            OnDeviceNarrator.log(read: "[photo: \(kind)]", said: nil,
                                 extra: ["error": String(describing: error), "gate": gate])
            unavailable = true
            return nil
        }
    }

    /// Full-res accurate OCR for the cross-check, off the main thread. Empty
    /// string if Vision throws, which makes the cross-check a no-op.
    /// Is there enough printed text here to be worth the strict page reader?
    /// The gate's document detector fires on any big rectangle — a bed, a table,
    /// a wall — and routing a cat into "What is this page?" is what produced
    /// "too blurry to read" on a perfectly visible cat (2026-09-12). Apple's
    /// recognizer is the honest test: no words, no page.
    static func hasReadableText(in image: CGImage) async -> Bool {
        let text = await recognizedText(in: image)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A stray letter off a label or a logo is not a page of mail.
        return text.count >= 24
    }

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

    /// Does this answer read as a refusal rather than a description? Used only
    /// on the scene path, to trigger one forced best-guess retry. A nil answer
    /// counts as a refusal so an empty result also gets the second try.
    private static func looksLikeRefusal(_ s: String?) -> Bool {
        guard let s = s?.lowercased() else { return true }
        // These must be REFUSAL phrases, not description words. "make out" on its
        // own flagged "I can make out a cat on a bed" as a refusal — and the
        // forced retry prompt literally asks for "I can make out", so every good
        // answer was rejected and the chain fell through to the floor line
        // (2026-09-12, a perfectly visible cat). Match the whole phrase.
        let markers = ["can't make out", "cannot make out", "can not make out",
                       "couldn't make out", "could not make out",
                       "can't see", "cannot see", "can't read", "cannot read",
                       "can't tell", "cannot tell", "can't determine", "cannot determine",
                       "unable to", "too dark to", "too blurry to", "too dark and blurry",
                       "retake", "hold the camera still", "hold the phone still",
                       "turn on a light", "turn on the flash", "add some light",
                       "move closer", "take the picture again", "take it again",
                       "try again", "not clear enough", "no details are visible"]
        return markers.contains { s.contains($0) }
    }

    /// Throw away the sentences that are excuses and keep the ones that actually
    /// describe something. Returns nil when nothing describable is left, so the
    /// caller keeps what it had rather than speaking an empty string.
    /// When the model says it is too dark, the useful answer is a brighter
    /// picture, not a sterner question. Used on the retry passes only, so a
    /// normal shot is never touched.
    private static func brightened(_ image: CIImage, ev: Float) -> CIImage {
        guard let filter = CIFilter(name: "CIExposureAdjust") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(ev, forKey: kCIInputEVKey)
        return filter.outputImage ?? image
    }

    /// An instruction is not a thing. "Hold the camera steady" came back from the
    /// listing pass and was read out as something visible in the room.
    private static func isInstruction(_ fragment: String) -> Bool {
        let verbs = ["hold", "move", "turn", "take", "try", "use", "ensure", "make sure",
                     "point", "adjust", "increase", "retry", "please", "consider",
                     "bring", "step", "add", "switch", "clean", "wipe", "check"]
        let f = fragment.lowercased().trimmingCharacters(in: .whitespaces)
        return verbs.contains { f.hasPrefix($0 + " ") || f == $0 }
    }

    /// Keep the comma-separated things and throw away any apology the model
    /// wrapped them in. Returns nil when there is genuinely nothing listed.
    private static func thingsOnly(_ raw: String) -> String? {
        guard var text = tidyKeepingShort(raw) else { return nil }
        // Models like to open with "I can see" or "In this picture, I can see".
        for opener in ["in this picture, i can see", "in this photo, i can see",
                       "i can see", "i see", "the things i can see are",
                       "here is a list", "here are the things"] {
            if text.lowercased().hasPrefix(opener) {
                text = String(text.dropFirst(opener.count))
                break
            }
        }
        let things = text
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .:-*\t")) }
            .filter { !$0.isEmpty && $0.count <= 40 && !looksLikeRefusal($0) && !isInstruction($0) }
        guard !things.isEmpty else { return nil }
        // Three is enough to picture a room; more turns into a recital.
        let kept = Array(things.prefix(4))
        if kept.count == 1 { return kept[0] }
        return kept.dropLast().joined(separator: ", ") + " and " + kept[kept.count - 1]
    }

    /// ``tidy`` throws away anything under 12 characters, which is right for a
    /// spoken sentence and wrong for a list of two words.
    private static func tidyKeepingShort(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \n\"'"))
        if let stray = text.range(of: "</think>") {
            text = String(text[stray.upperBound...])
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \n\"'"))
        return text.isEmpty ? nil : text
    }

    private static func strippingExcuses(_ sentence: String) -> String? {
        // ";" matters: the model likes "I can't make out the details; it's too
        // dark" as ONE sentence, and splitting on "." alone kept the whole thing.
        let parts = sentence
            .split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let described = parts.filter { !looksLikeRefusal($0) }
        if !described.isEmpty {
            let rebuilt = described.joined(separator: ". ") + "."
            if rebuilt.count >= 12 { return rebuilt }
        }
        // Nothing but excuses. Never read the person an instruction they cannot
        // act on — "move closer, turn on a light, take it again" is useless to
        // someone who cannot see where the camera is pointing.
        return "It's hard to see clearly, and I couldn't make out enough to say."
    }

    enum VisionNarratorError: Error { case noModelInBundle }
}
