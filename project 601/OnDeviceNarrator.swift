import Foundation
import MLXLLM
import MLXLMCommon

/// Says what the page means, not what it says.
///
/// The recognizer hands back every word on a letter or a label. Turning that into
/// the one sentence a person would actually say — "a check for $54.90 you never
/// cashed, and California keeps it if you don't answer by May 25th" — takes
/// understanding, and understanding takes a model.
///
/// This one lives inside the app. No network, no account, nothing leaves the
/// phone: someone's mail is the last thing that should be uploaded anywhere.
@available(iOS 17.0, *)
actor OnDeviceNarrator {
    static let shared = OnDeviceNarrator()

    private var context: ModelContext?
    private var unavailable = false

    /// Written for a listener, who can't skim back over a sentence they missed.
    /// Word for word the instruction the model was fine-tuned against. If this
    /// text drifts from the training set, the model is being asked a slightly
    /// different question than the one it was taught to answer.
    /// Word for word the instruction the model was fine-tuned against. If this
    /// text drifts from the training set, the model is being asked a slightly
    /// different question than the one it was taught to answer.
    private static let instructions = """
    Below are the words printed on a page. Say what it is in one spoken sentence for a blind listener, two at most. Lead with what the page is and who sent it, then the number that matters, then the deadline, then what happens if it is ignored. Money owed TO the person is money coming to them, never a bill. Use only what is printed. An issue date is not a deadline. Amounts are read the normal way: two thousand nine hundred sixty one dollars and three cents is written $2,961.03 even when the page prints it wrong.
    """

    /// Returns nil rather than a guess — the caller falls back to the plain
    /// summary, which is worse but never invented.
    func narrate(_ text: String) async -> String? {
        guard !unavailable, !text.isEmpty else { return nil }
        do {
            let model = try await loaded()
            // A fresh session per page: one letter must never colour the next.
            let session = ChatSession(model, instructions: Self.instructions)
            // Qwen's soft switch for "answer, don't deliberate out loud."
            let answer = try await session.respond(to: text.prefix(6000) + "\n/no_think")
            let said = Self.tidy(answer)
            Self.log(read: text, said: said)
            return said
        } catch {
            // A missing or broken model bundle should degrade the feature, not
            // take the scan down with it.
            unavailable = true
            return nil
        }
    }

    private func loaded() async throws -> ModelContext {
        if let context { return context }
        guard let url = Bundle.main.url(forResource: "NarratorModel", withExtension: nil) else {
            throw NarratorError.noModelInBundle
        }
        let loaded = try await loadModel(configuration: ModelConfiguration(directory: url))
        context = loaded
        return loaded
    }

    /// Strips the scaffolding small models like to wrap an answer in.
    private static func tidy(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = text.range(of: "</think>") {
            text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = text.replacingOccurrences(of: "<think>", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\"'"))
        return text.count >= 12 ? text : nil
    }

    /// Every scan is written down: the words the camera read, and the sentence
    /// this model produced from them. Two reasons — a wrong answer can be looked
    /// at instead of argued about, and each line is a training example for the
    /// model that replaces this one.
    nonisolated static func log(read: String, said: String?, extra: [String: Any] = [:]) {
        var entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "read": read,
            "said": said ?? "",
        ]
        for (k, v) in extra { entry[k] = v }
        guard let line = try? JSONSerialization.data(withJSONObject: entry),
              let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let file = dir.appendingPathComponent("scans.jsonl")
        var blob = line
        blob.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: blob)
        } else {
            try? blob.write(to: file)
        }
    }

    enum NarratorError: Error { case noModelInBundle }
}
