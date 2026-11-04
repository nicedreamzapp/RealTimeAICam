// Live Cam's eyes: the same model What's this? uses, on the same files. No second download, ever:
// the level is whatever this phone already has (Settings > Models, or automatic), found through
// VisionModelStore; if that level isn't on the phone, the bundled Balanced. Fully on the phone.
//
// Ported from Moonstone's LiveVisionModel + VisionLlama.c (2026-11-04). Moonstone opens its own
// llama.framework with dlopen; RT Cam links llama.cpp directly (the same b11954 that
// LlamaVisionEngine uses), so the three calls Live Cam needs on top of What's this? live here in Swift:
// streaming text (each sentence is spoken while the rest is written), a photo with no picture at all
// (a plain question), and prefill (system + photo read while the person is still talking).
import CoreGraphics
import Foundation
import llama

enum LiveCamModel {
    /// The level Live Cam runs: the scene pick from what is actually installed (manual choice honoured,
    /// Balanced when the pick isn't here). Never triggers a download.
    static var level: ModelLevel {
        #if DEBUG
        if let forced = UserDefaults.standard.string(forKey: "liveCamLevel"), let l = ModelLevel(rawValue: forced),
           VisionModelStore.isInstalled(l) { return l }
        #endif
        return ModelPicker.level(for: .scene)
    }
}

/// The loaded model. One answer at a time (one llama context).
final class LiveVisionEngine: @unchecked Sendable {
    struct Answer {
        var text: String; var firstTokenMs: Double; var encodeMs: Double; var totalMs: Double; var tokens: Int
        /// How sure it was (Moonstone 11/2): mean probability of each chosen word, and the least sure word.
        var confidence: Double = 1; var lowest: Double = 1
    }
    enum Failure: Error { case notInstalled, modelLoad, context, projector }

    let level: ModelLevel
    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let mtmd: OpaquePointer
    private let vocab: OpaquePointer
    private let lock = NSLock()
    private var prefilled = false
    private var confMean = 1.0, confMin = 1.0

    /// Prefill only works with LFM3's hand-written template (Quick uses its own GGUF template).
    var canPrefill: Bool { level.usesLFM3Prompt }

    /// Blocking: call off the main thread.
    init(level: ModelLevel) throws {
        self.level = level
        guard let folder = VisionModelStore.folder(level) else { throw Failure.notInstalled }
        #if targetEnvironment(simulator)
        setenv("GGML_METAL_DEVICES", "0", 1)
        setenv("GGML_METAL_SHARED_BUFFERS_DISABLE", "1", 1)
        setenv("MTMD_BACKEND_DEVICE", "CPU", 1)
        #endif
        llama_backend_init()
        var mp = llama_model_default_params()
        #if targetEnvironment(simulator)
        mp.n_gpu_layers = 0
        #else
        mp.n_gpu_layers = 99
        #endif
        guard let m = llama_model_load_from_file(folder.appendingPathComponent(level.modelFile).path, mp) else { throw Failure.modelLoad }
        var cp = llama_context_default_params()
        cp.n_ctx = 3072      // photo (~300 tokens at 768 px) + question + answer
        cp.n_batch = 512
        cp.n_ubatch = 256
        guard let c = llama_init_from_model(m, cp) else { llama_model_free(m); throw Failure.context }
        var vp = mtmd_context_params_default()
        #if targetEnvironment(simulator)
        vp.use_gpu = false
        #endif
        vp.print_timings = false
        vp.warmup = false
        guard let v = mtmd_init_from_file(folder.appendingPathComponent(level.mmprojFile).path, m, vp) else {
            llama_free(c); llama_model_free(m); throw Failure.projector
        }
        model = m; ctx = c; mtmd = v
        vocab = llama_model_get_vocab(m)
    }

    deinit {
        mtmd_free(mtmd)
        llama_free(ctx)
        llama_model_free(model)
    }

    // MARK: Prompts (the same strings LlamaVisionEngine builds)

    private static var marker: String { String(cString: mtmd_default_marker()) }

    /// LFM3 as llama-server renders it with thinking off. `image` false: a plain text turn.
    private static func lfm3Prompt(system: String, question: String, image: Bool) -> String {
        "<|startoftext|><|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n"
            + (image ? marker : "") + "\(question)<|im_end|>\n<|im_start|>assistant\n<think></think>"
    }

    /// Quick: the chat template inside its own GGUF, the image marker on its own line.
    private func ownTemplatePrompt(system: String, question: String, image: Bool) -> String {
        let user = (image ? Self.marker + "\n" : "") + question
        let tmpl = llama_model_chat_template(model, nil)
        return system.withCString { sys in
            user.withCString { usr in
                var msgs = [llama_chat_message(role: "system", content: sys), llama_chat_message(role: "user", content: usr)]
                var buf = [CChar](repeating: 0, count: system.utf8.count + user.utf8.count + 2048)
                var n = llama_chat_apply_template(tmpl, &msgs, 2, true, &buf, Int32(buf.count))
                if n > Int32(buf.count) {
                    buf = [CChar](repeating: 0, count: Int(n) + 1)
                    n = llama_chat_apply_template(tmpl, &msgs, 2, true, &buf, Int32(buf.count))
                }
                guard n >= 0 else { return system + "\n\n" + user }
                return String(decoding: buf[0 ..< Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
    }

    private func prompt(system: String, question: String, image: Bool) -> String {
        level.usesLFM3Prompt ? Self.lfm3Prompt(system: system, question: question, image: image)
            : ownTemplatePrompt(system: system, question: question, image: image)
    }

    // MARK: Answering

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

    /// Probability of the most likely next token (softmax of the last logits).
    private func topProb() -> Double {
        guard let lg = llama_get_logits_ith(ctx, -1) else { return 1 }
        let n = Int(llama_vocab_n_tokens(vocab))
        guard n > 0 else { return 1 }
        var mx = lg[0]
        for i in 1 ..< n where lg[i] > mx { mx = lg[i] }
        var sum = 0.0
        for i in 0 ..< n { sum += exp(Double(lg[i] - mx)) }
        return sum > 0 ? 1 / sum : 1
    }

    /// Greedy generation from what is in the context now. `onText` gets everything written so far; false stops.
    private func generate(maxTokens: Int, onText: ((String) -> Bool)?, t0: Double) -> (String, Double, Int) {
        let smpl = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(smpl) }
        llama_sampler_chain_add(smpl, llama_sampler_init_greedy())
        var bytes = [UInt8]()
        var piece = [CChar](repeating: 0, count: 256)
        var ttft = 0.0, n = 0, psum = 0.0, pmin = 1.0
        for i in 0 ..< maxTokens {
            let p = topProb()
            var tok = llama_sampler_sample(smpl, ctx, -1)
            if i == 0 { ttft = Self.now() - t0 }
            if llama_vocab_is_eog(vocab, tok) { break }
            n += 1; psum += p; pmin = min(pmin, p)
            let len = llama_token_to_piece(vocab, tok, &piece, Int32(piece.count), 0, true)
            if len > 0 { bytes += piece[0 ..< Int(len)].map { UInt8(bitPattern: $0) } }
            if let onText, !onText(String(decoding: bytes, as: UTF8.self)) { break }
            guard llama_decode(ctx, llama_batch_get_one(&tok, 1)) == 0 else { break }
        }
        confMean = n > 0 ? psum / Double(n) : 1
        confMin = n > 0 ? pmin : 1
        var out = String(decoding: bytes, as: UTF8.self)
        if let r = out.range(of: "</think>", options: .backwards) { out = String(out[r.upperBound...]) }
        return (out, ttft, n)
    }

    /// One frame (or none), one answer. Blocking.
    func respond(system: String, question: String, image: CGImage?, longSide: Int = 768, maxTokens: Int = 90,
                 onText: ((String) -> Bool)? = nil) -> Answer? {
        lock.lock(); defer { lock.unlock() }
        prefilled = false
        let t0 = Self.now()
        var rgb: (Data, Int, Int)?
        if let image { guard let r = Self.rgb(image, longSide: longSide) else { return nil }; rgb = r }
        llama_memory_clear(llama_get_memory(ctx), true)   // a fresh turn; the conversation travels as text
        let bitmap: OpaquePointer? = rgb.flatMap { r in
            r.0.withUnsafeBytes { mtmd_bitmap_init(UInt32(r.1), UInt32(r.2), $0.bindMemory(to: UInt8.self).baseAddress) }
        }
        defer { if let bitmap { mtmd_bitmap_free(bitmap) } }
        let chunks = mtmd_input_chunks_init()
        defer { mtmd_input_chunks_free(chunks) }
        let text = prompt(system: system, question: question, image: bitmap != nil)
        let rc: Int32 = text.withCString { p in
            var input = mtmd_input_text(text: p, text_len: strlen(p), add_special: true, parse_special: true)
            var bitmaps: [OpaquePointer?] = [bitmap]
            return bitmaps.withUnsafeMutableBufferPointer { mtmd_tokenize(mtmd, chunks, &input, $0.baseAddress, bitmap == nil ? 0 : 1) }
        }
        guard rc == 0 else { return nil }
        var nPast: llama_pos = 0
        guard mtmd_helper_eval_chunks(mtmd, ctx, chunks, 0, 0, 512, true, &nPast) == 0 else { return nil }
        let enc = Self.now() - t0
        let (out, ttft, n) = generate(maxTokens: maxTokens, onText: onText, t0: t0)
        return Answer(text: out, firstTokenMs: ttft, encodeMs: enc, totalMs: Self.now() - t0, tokens: n,
                      confidence: confMean, lowest: confMin)
    }

    /// While they're still talking: system + photo into the context, so the answer only has the question
    /// left (Fable 10/31: ~300 ms of the ~430 ms photo read moves into the time they're talking). Blocking.
    func prefill(system: String, image: CGImage, longSide: Int) -> (ok: Bool, ms: Double) {
        lock.lock(); defer { lock.unlock() }
        prefilled = false
        guard canPrefill, let (rgb, w, h) = Self.rgb(image, longSide: longSide) else { return (false, 0) }
        let t0 = Self.now()
        llama_memory_clear(llama_get_memory(ctx), true)
        let bitmap = rgb.withUnsafeBytes { mtmd_bitmap_init(UInt32(w), UInt32(h), $0.bindMemory(to: UInt8.self).baseAddress) }
        defer { mtmd_bitmap_free(bitmap) }
        let chunks = mtmd_input_chunks_init()
        defer { mtmd_input_chunks_free(chunks) }
        // Everything respond() sends up to and including the photo; the question follows in answer().
        let text = "<|startoftext|><|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n" + Self.marker
        let rc: Int32 = text.withCString { p in
            var input = mtmd_input_text(text: p, text_len: strlen(p), add_special: true, parse_special: true)
            var bitmaps: [OpaquePointer?] = [bitmap]
            return bitmaps.withUnsafeMutableBufferPointer { mtmd_tokenize(mtmd, chunks, &input, $0.baseAddress, 1) }
        }
        guard rc == 0 else { return (false, Self.now() - t0) }
        var nPast: llama_pos = 0
        guard mtmd_helper_eval_chunks(mtmd, ctx, chunks, 0, 0, 512, false, &nPast) == 0 else { return (false, Self.now() - t0) }
        prefilled = true
        return (true, Self.now() - t0)
    }

    /// The question on top of the last prefill. nil if nothing is prefilled (another turn used the context).
    func answer(question: String, maxTokens: Int = 90, onText: ((String) -> Bool)? = nil) -> Answer? {
        lock.lock(); defer { lock.unlock() }
        guard prefilled else { return nil }
        prefilled = false
        let t0 = Self.now()
        let text = "\(question)<|im_end|>\n<|im_start|>assistant\n<think></think>"
        var toks = [llama_token](repeating: 0, count: text.utf8.count + 16)
        let n = llama_tokenize(vocab, text, Int32(text.utf8.count), &toks, Int32(toks.count), false, true)
        guard n > 0 else { return nil }
        let ok = toks.withUnsafeMutableBufferPointer { llama_decode(ctx, llama_batch_get_one($0.baseAddress, n)) == 0 }
        guard ok else { return nil }
        let enc = Self.now() - t0
        let (out, ttft, count) = generate(maxTokens: maxTokens, onText: onText, t0: t0)
        return Answer(text: out, firstTokenMs: ttft, encodeMs: enc, totalMs: Self.now() - t0, tokens: count,
                      confidence: confMean, lowest: confMin)
    }

    /// Long side `longSide`, packed RGB, which mtmd takes directly.
    static func rgb(_ image: CGImage, longSide: Int) -> (Data, Int, Int)? {
        let scale = min(1, Double(longSide) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = rgba.withUnsafeMutableBytes { buf in
            guard let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            c.interpolationQuality = .high
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var out = Data(count: w * h * 3)
        out.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
            for i in 0 ..< (w * h) { o[i * 3] = rgba[i * 4]; o[i * 3 + 1] = rgba[i * 4 + 1]; o[i * 3 + 2] = rgba[i * 4 + 2] }
        }
        return (out, w, h)
    }
}
