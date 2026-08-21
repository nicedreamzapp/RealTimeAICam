import Foundation
import Vision

/// Reads one captured still of a page as carefully as the device allows.
///
/// The live-video path elsewhere in the app is tuned for speed: 720p frames, fast
/// recognition, no language correction. That is the right trade for pointing at a
/// sign. It is the wrong trade for a sheet of paper, where the words you need are
/// a few percent of the frame — the recognizer returns fragments and guesses, and
/// no amount of clever parsing downstream can recover what was never read.
///
/// So mail scanning captures once, at full resolution, and reads it properly.
enum PageScanner {

    struct Page {
        /// Every line, in reading order where the recognizer could establish one.
        var lines: [String]
        /// True when the text came back with document structure attached (tables,
        /// rows), which is what a bill actually is.
        var isStructured: Bool

        var text: String { lines.joined(separator: "\n") }
    }

    static func read(_ image: CGImage, completion: @escaping (Page) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            if #available(iOS 26.0, *), let structured = readStructured(image) {
                completion(structured)
                return
            }
            completion(readFlat(image))
        }
    }

    // MARK: - iOS 26: structure included

    /// A bill is a table: a label in one cell and the figure in the cell beside it.
    /// Flat text throws that away and leaves us guessing that whatever number sits
    /// near "Amount Due" belongs to it — which breaks the moment a scan reorders
    /// the page. When the OS can hand back the structure, keep it.
    @available(iOS 26.0, *)
    private static func readStructured(_ image: CGImage) -> Page? {
        let request = RecognizeDocumentsRequest()

        let semaphore = DispatchSemaphore(value: 0)
        var result: Page?

        Task {
            defer { semaphore.signal() }
            guard let observation = try? await request.perform(on: image).first else { return }
            var lines: [String] = []

            // Tables first: emit each row as "label value", which is exactly the
            // shape the summarizer wants and never needs proximity guessing.
            for table in observation.document.tables {
                for row in table.rows {
                    let cells = row.compactMap { cell -> String? in
                        let text = cell.content.text.transcript
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        return text.isEmpty ? nil : text
                    }
                    if !cells.isEmpty { lines.append(cells.joined(separator: " ")) }
                }
            }

            for paragraph in observation.document.paragraphs {
                let text = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(text) }
            }

            if !lines.isEmpty { result = Page(lines: lines, isStructured: true) }
        }

        semaphore.wait()
        return result
    }

    // MARK: - iOS 16-25: flat text, read carefully

    private static func readFlat(_ image: CGImage) -> Page {
        let request = VNRecognizeTextRequest()
        // The opposite of the live path on purpose: accuracy over speed, because
        // this runs once on a still rather than thirty times a second.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "es-ES"]
        // A page of body text is small in the frame; without this the recognizer
        // discards exactly the lines that matter.
        request.minimumTextHeight = 0.005

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])

        let observations = request.results ?? []
        // Top to bottom, then left to right — Vision returns results in confidence
        // order, which scrambles a page.
        let ordered = observations.sorted { lhs, rhs in
            let dy = lhs.boundingBox.midY - rhs.boundingBox.midY
            if abs(dy) > 0.012 { return lhs.boundingBox.midY > rhs.boundingBox.midY }
            return lhs.boundingBox.midX < rhs.boundingBox.midX
        }

        let lines = ordered.compactMap {
            $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }

        return Page(lines: lines, isStructured: false)
    }
}
