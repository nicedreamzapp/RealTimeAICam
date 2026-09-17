import AVFoundation
import AppKit
import Vision

// Usage:
//   bench ocr IMAGE...        -> prints OCR text (same settings as the app's English reader)
//   bench fix                 -> reads stdin, prints the speakable version
//   bench say OUT.caf TEXT    -> renders TEXT with Samantha into OUT.caf (no playback)

func ocr(_ path: String, languages: [String] = ["en-US", "en"]) -> String {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    req.minimumTextHeight = 0.015
    req.recognitionLanguages = languages
    try? VNImageRequestHandler(cgImage: cg).perform([req])
    return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

func render(_ text: String, to path: String) {
    let synth = AVSpeechSynthesizer()
    let u = AVSpeechUtterance(string: text)
    u.voice = AVSpeechSynthesisVoice.speechVoices().first { $0.name == "Samantha" && $0.language == "en-US" }
        ?? AVSpeechSynthesisVoice(language: "en-US")
    u.rate = 0.5
    var file: AVAudioFile?
    let done = DispatchSemaphore(value: 0)
    synth.write(u) { buf in
        guard let pcm = buf as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 { done.signal(); return }
        if file == nil {
            file = try? AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: pcm.format.settings,
                                    commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
        }
        try? file?.write(from: pcm)
    }
    while done.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "ocr":
    for p in args.dropFirst(2) { print(ocr(p)) }
case "ocr-es":
    for p in args.dropFirst(2) { print(ocr(p, languages: ["es-ES", "es"])) }
case "translate":
    // The app's own Spanish engine; its data file sits next to this binary.
    let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let engine = FixedSpanishEngine.shared
    let deadline = Date().addingTimeInterval(30)
    while !engine.isReady(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    // Same unit split as LiveOCRViewModel.translationUnits (copied: that file needs UIKit).
    var units: [String] = []
    for line in input.components(separatedBy: .newlines) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { continue }
        if let prev = units.last, let f = t.first, f.isLowercase, let e = prev.last, !".!?:;".contains(e) {
            units[units.count - 1] = prev + " " + t
        } else { units.append(t) }
    }
    let out = units.map(engine.translate).filter { !$0.isEmpty }.joined(separator: "\n")
    FileHandle.standardError.write(("RESULT\t" + out.replacingOccurrences(of: "\n", with: " | ") + "\n").data(using: .utf8)!)
case "fix":
    let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    print(SpeakableText.make(input))
case "say":
    render(args.dropFirst(3).joined(separator: " "), to: args[2])
default:
    print("usage: bench ocr|fix|say")
}
