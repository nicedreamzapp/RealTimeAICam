import CoreImage
import Foundation
import llama

/// The vision model's engine since 1.3.6: LFM3-Omni-2B by Liquid AI (untrained,
/// LFM Open License v1.0) through llama.cpp's own C API (llama + mtmd, b11954).
/// Same engine, same prompt string, same context sizes and same greedy loop as
/// the Android app's narrator_jni.cpp, which reproduced the Mac benchmark word
/// for word on all 20 of Matt's photos (2026-10-29).
///
/// One answer at a time, enforced here. The narrator actor is re-entrant at its
/// awaits, so a second request (Ask held while "Working it out" is still
/// running) used to reach `respond` while the first was mid-decode, and two
/// threads on one llama context abort in llama_sampler_sample (crash on the
/// iPhone 18, 10/29 10:19 AM). The lock is shared by every instance so a
/// reload can never run beside an answer still finishing; the second request
/// waits for the first and then runs.
final class LlamaVisionEngine: @unchecked Sendable {
    private static let oneAtATime = NSLock()
    static let modelFile = "lfm3-omni-2b-IQ2_XS.gguf"
    static let mmprojFile = "lfm3-omni-2b-mmproj-vision-Q4_K_M.gguf"

    struct Stats {
        var ttftMs = 0.0, totalMs = 0.0, encodeMs = 0.0
        var promptTokens = 0, genTokens = 0
    }

    enum EngineError: Error { case modelLoad, context, projector, image, tokenize(Int32), eval(Int32) }

    private let model: OpaquePointer
    private let ctx: OpaquePointer
    private let mtmd: OpaquePointer
    private let vocab: OpaquePointer
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private(set) var lastStats = Stats()

    /// Loads both files from `folder` (mmap'd). Blocking; call off the main thread.
    init(folder: URL) throws {
        #if targetEnvironment(simulator)
        // The Simulator's Metal shim cannot wrap host memory: CPU only there.
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
        let modelPath = folder.appendingPathComponent(Self.modelFile).path
        let mmprojPath = folder.appendingPathComponent(Self.mmprojFile).path
        guard let m = llama_model_load_from_file(modelPath, mp) else { throw EngineError.modelLoad }
        var cp = llama_context_default_params()
        // A turn is at most ~1,170 tokens (1,045 for a 1024 px page + 120 out).
        cp.n_ctx = 2048
        cp.n_batch = 512
        cp.n_ubatch = 256
        guard let c = llama_init_from_model(m, cp) else { llama_model_free(m); throw EngineError.context }
        var vp = mtmd_context_params_default()
        #if targetEnvironment(simulator)
        vp.use_gpu = false
        #endif
        vp.print_timings = false
        vp.warmup = false
        guard let v = mtmd_init_from_file(mmprojPath, m, vp) else {
            llama_free(c); llama_model_free(m); throw EngineError.projector
        }
        model = m; ctx = c; mtmd = v
        vocab = llama_model_get_vocab(m)
    }

    deinit {
        mtmd_free(mtmd)
        llama_free(ctx)
        llama_model_free(model)
    }

    /// LFM3's chat template as llama-server renders it with enable_thinking=false:
    /// BOS, system turn, the image marker directly in front of the question, and
    /// an empty think block so the model answers straight away.
    private static func prompt(system: String, question: String) -> String {
        let marker = String(cString: mtmd_default_marker())
        return "<|startoftext|><|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n"
            + "\(marker)\(question)<|im_end|>\n<|im_start|>assistant\n<think></think>"
    }

    /// One photo, one answer. `temperature` 0 is greedy (LFM3-Omni's own
    /// generation_config, and what was benchmarked); the retry passes ask for a
    /// little temperature, as they always have. Blocking.
    func respond(system: String, question: String, image: CIImage,
                 maxTokens: Int = 120, temperature: Float = 0) throws -> String {
        Self.oneAtATime.lock()
        defer { Self.oneAtATime.unlock() }
        let t0 = DispatchTime.now().uptimeNanoseconds
        func ms() -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }
        var stats = Stats()
        defer { lastStats = stats }

        guard let (rgb, w, h) = rgbBytes(image) else { throw EngineError.image }
        llama_memory_clear(llama_get_memory(ctx), true)   // a fresh conversation per photo
        let bitmap = rgb.withUnsafeBytes {
            mtmd_bitmap_init(UInt32(w), UInt32(h), $0.bindMemory(to: UInt8.self).baseAddress)
        }
        defer { mtmd_bitmap_free(bitmap) }
        let chunks = mtmd_input_chunks_init()
        defer { mtmd_input_chunks_free(chunks) }
        let text = Self.prompt(system: system, question: question)
        let rc: Int32 = text.withCString { p in
            var input = mtmd_input_text(text: p, text_len: strlen(p), add_special: true, parse_special: true)
            var bitmaps: [OpaquePointer?] = [bitmap]
            return bitmaps.withUnsafeMutableBufferPointer { mtmd_tokenize(mtmd, chunks, &input, $0.baseAddress, 1) }
        }
        guard rc == 0 else { throw EngineError.tokenize(rc) }
        var nPast: llama_pos = 0
        let erc = mtmd_helper_eval_chunks(mtmd, ctx, chunks, 0, 0, 512, true, &nPast)
        guard erc == 0 else { throw EngineError.eval(erc) }
        stats.encodeMs = ms()
        stats.promptTokens = Int(nPast)

        let smpl = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(smpl) }
        if temperature <= 0 {
            llama_sampler_chain_add(smpl, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature))
            llama_sampler_chain_add(smpl, llama_sampler_init_dist(UInt32.random(in: 1 ... .max)))
        }
        var bytes = [UInt8]()
        var piece = [CChar](repeating: 0, count: 256)
        for i in 0 ..< maxTokens {
            var tok = llama_sampler_sample(smpl, ctx, -1)
            if i == 0 { stats.ttftMs = ms() }
            if llama_vocab_is_eog(vocab, tok) { break }
            stats.genTokens += 1
            let len = llama_token_to_piece(vocab, tok, &piece, Int32(piece.count), 0, true)
            if len > 0 { bytes += piece[0 ..< Int(len)].map { UInt8(bitPattern: $0) } }
            guard llama_decode(ctx, llama_batch_get_one(&tok, 1)) == 0 else { break }
        }
        stats.totalMs = ms()
        var out = String(decoding: bytes, as: UTF8.self)
        if let r = out.range(of: "</think>", options: .backwards) { out = String(out[r.upperBound...]) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The already-sized photo as packed RGB, which mtmd takes directly.
    private func rgbBytes(_ image: CIImage) -> (Data, Int, Int)? {
        guard let cg = ciContext.createCGImage(image, from: image.extent) else { return nil }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buf in
            guard let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            c.interpolationQuality = .high
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var rgb = Data(count: w * h * 3)
        rgb.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
            for i in 0 ..< (w * h) {
                o[i * 3] = rgba[i * 4]; o[i * 3 + 1] = rgba[i * 4 + 1]; o[i * 3 + 2] = rgba[i * 4 + 2]
            }
        }
        return (rgb, w, h)
    }
}
