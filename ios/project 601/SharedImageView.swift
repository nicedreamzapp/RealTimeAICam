import CoreImage
import SwiftUI
import UIKit

/// A picture shared from another app (Photos, Messages, WhatsApp, Safari...).
///
/// Opens describing it out loud with the model the phone picked, the same way
/// What's this? describes a library photo, then takes follow-up questions about
/// the same picture: hold to ask, or type. Every answer stays in a short list
/// on screen. Nothing leaves the phone.
@MainActor
struct SharedImageView: View {
    let image: UIImage
    let onClose: () -> Void

    struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
    }

    /// The speaker the camera screens use: SpeakableText, the chosen voice, the
    /// loudspeaker, and VoiceOver announcements when Speak answers aloud is off.
    @StateObject private var speaker = LiveOCRViewModel()
    @StateObject private var listener = SpeechRecognizer()
    @ObservedObject private var appLang = AppLangObserver.shared

    @State private var description = ""
    @State private var descriptionLang = AppLang.code
    @State private var isDescribing = true
    @State private var exchanges: [Exchange] = []
    @State private var isListening = false
    @State private var isAsking = false
    @State private var typedQuestion = ""
    @FocusState private var typingQuestion: Bool
    /// Bumps on close, so an answer that lands after leaving is never said.
    @State private var generation = 0
    @State private var started = false
    /// The app's voice is reading something on this screen.
    @State private var isSpeaking = false
    @State private var speakingWatch: Task<Void, Never>?
    /// Follow-up questions need the picture model; without it the words are read instead.
    @State private var canAsk = SharedImageView.pictureModelOnPhone
    @State private var noModelNoteSaid = false

    private static var pictureModelOnPhone: Bool {
        #if DEBUG
        // `RTCAM_NO_VISION_MODEL=1`: a phone without the picture model, for the Simulator.
        if ProcessInfo.processInfo.environment["RTCAM_NO_VISION_MODEL"] == "1" { return false }
        #endif
        return OnDeviceVisionNarrator.isBundled
    }


    private var voice: String { SpeechManager.shared.selectedVoiceIdentifier }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 340)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .accessibilityHidden(true)

                        descriptionCard

                        ForEach(exchanges) { exchange in
                            exchangeRow(exchange).id(exchange.id)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .onChange(of: exchanges.count) { _, _ in
                    guard let last = exchanges.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            if canAsk {
                askBar
            } else {
                noModelNote
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        // VoiceOver's escape (two-finger Z): the same as Back.
        .accessibilityAction(.escape) { close() }
        .onAppear {
            guard !started else { return }
            started = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                UIAccessibility.post(notification: .screenChanged,
                                     argument: SpeechManager.voiceOverLine(L("Shared picture"), lang: AppLang.code))
            }
            // The screen stays on the whole time this screen is up: a VoiceOver reading of
            // the answer can't be timed from here, and this screen is short-lived anyway.
            ScreenAwake.hold("sharedImage")
            describe()
        }
        .onChange(of: isSpeaking) { _, speaking in
            // No picture model: once the description has been read, say why there is no ask button.
            guard !speaking, !canAsk, !isDescribing, !noModelNoteSaid else { return }
            noModelNoteSaid = true
            let note = "Asking about pictures needs the picture model. Get it in Settings, under Models."
            guard LiveOCRViewModel.speaksAloud else {
                // VoiceOver is reading the description: queue the note behind it, never over it.
                let gen = generation
                Task {
                    let out = await UICue.line(note)
                    guard gen == generation else { return }
                    UIAccessibility.post(notification: .announcement,
                                         argument: SpeechManager.voiceOverLine(out.text, lang: out.lang, queue: true))
                }
                return
            }
            sayApp(note)
        }
        .onDisappear {
            generation += 1
            speaker.stopSpeaking()
            if isListening { Task { _ = await listener.stopAndTranscribe() } }
            speakingWatch?.cancel()
            ScreenAwake.release("sharedImage")
        }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Button(action: close) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                    Text(L("Back")).font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(.ultraThinMaterial).opacity(0.85))
            }
            .accessibilityLabel(L("Back"))
            .accessibilityHint(L("Closes this picture and goes back to the home screen"))

            Spacer()

            Text(L("Shared picture"))
                .font(.headline)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Button(action: sayAgain) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.ultraThinMaterial).opacity(0.85))
            }
            .disabled(isDescribing || description.isEmpty)
            .accessibilityLabel(L("Say it again"))
            .accessibilityHint(L("Reads the description of this picture out loud again"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var descriptionCard: some View {
        HStack(alignment: .top, spacing: 10) {
            if isDescribing { ProgressView().tint(.white) }
            Text(isDescribing ? L("Working it out…") : description)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.1)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isDescribing ? L("Working it out…") : description)
        .accessibilityHint(L("Description of the shared picture"))
    }

    private func exchangeRow(_ exchange: Exchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(exchange.question)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.55)))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(exchange.answer ?? L("Thinking…"))
                .font(.system(size: 17))
                .foregroundStyle(.white)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("You asked: %@. Answer: %@", exchange.question, exchange.answer ?? L("Thinking…")))
    }

    /// Without the picture model a follow-up can only fail, so say where to get it instead.
    private var noModelNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle").font(.system(size: 20, weight: .semibold))
            Text(L("Asking about pictures needs the picture model. Get it in Settings, under Models."))
                .font(.system(size: 17, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.1)))
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }

    private var askBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isListening ? "waveform" : (isAsking ? "hourglass" : "mic.fill"))
                    .font(.system(size: 22, weight: .semibold))
                Text(isListening ? L("Listening… let go to ask")
                     : (isAsking ? L("Thinking…") : L("Hold to ask about this")))
                    .font(.system(size: 18, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                Capsule()
                    .fill((isListening ? Color.red : Color.blue).opacity(0.8))
                    .overlay(Capsule().stroke(Color.white.opacity(0.5), lineWidth: 1.5))
            )
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in startAsk() }
                    .onEnded { _ in finishAsk() }
            )
            .opacity(isDescribing ? 0.5 : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(L("Ask about this photo"))
            .accessibilityHint(L("Hold, speak your question, then let go to hear the answer"))

            HStack(spacing: 8) {
                TextField(L("Or type a question"), text: $typedQuestion)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .focused($typingQuestion)
                    .onSubmit { askTyped() }
                    .accessibilityLabel(L("Or type a question about this photo"))
                Button(L("Ask")) { askTyped() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDescribing || isAsking
                              || typedQuestion.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel(L("Ask"))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .background(Color.black)
    }

    // MARK: - Describe

    /// Same routing as What's this? on a library photo: paper with words on it
    /// gets the page reader, anything else the scene describer; without the
    /// picture model it reads the words and says what they mean.
    private func describe() {
        isDescribing = true
        // The model picked by hand isn't on the phone: say once which one answers instead.
        if Self.pictureModelOnPhone, let notice = ModelPicker.fallbackNotice() { speak(notice, lang: AppLang.code) }
        let gen = generation
        let photo = image
        Task {
            let said = await Self.describeText(photo)
            await MainActor.run {
                guard gen == generation else { return }
                if let said {
                    RatePrompt.noteResult()
                    sayContent(said) { text, lang in
                        description = text
                        descriptionLang = lang
                        isDescribing = false
                    }
                } else {
                    sayApp("That picture couldn't be opened.") { text, lang in
                        description = text
                        descriptionLang = lang
                        isDescribing = false
                    }
                }
            }
        }
    }

    /// The description in English, or nil when the picture can't be read at all.
    private static func describeText(_ photo: UIImage) async -> String? {
        #if DEBUG
        if let fake = ProcessInfo.processInfo.environment["RTCAM_FAKE_DESCRIBE"], !fake.isEmpty {
            try? await Task.sleep(nanoseconds: 600_000_000)
            return fake
        }
        #endif
        guard let cg = photo.cgImage ?? photo.ciImage.flatMap({
            CIContext(options: [.useSoftwareRenderer: false]).createCGImage($0, from: $0.extent)
        }) else { return nil }
        let upright = UIImage(cgImage: cg)

        if pictureModelOnPhone {
            let gate = await Task.detached(priority: .userInitiated) {
                FrameQualityGate.check(cg, checkDocumentEdges: true)
            }.value
            var looksLikePage = false
            if gate.documentFound == true {
                looksLikePage = await OnDeviceVisionNarrator.hasReadableText(in: cg)
            }
            let said = looksLikePage
                ? await OnDeviceVisionNarrator.shared.narratePage(upright, gate: gate.logValue,
                                                                  hint: gate.qualityHint, cutOff: gate.cutOffEdge)
                : await OnDeviceVisionNarrator.shared.narrateScene(upright, gate: gate.logValue,
                                                                   hint: gate.qualityHint)
            if let said { return said }
        }

        // No picture model on this phone (or it couldn't help): the words, if any.
        let page: PageScanner.Page = await withCheckedContinuation { done in
            PageScanner.read(cg) { done.resume(returning: $0) }
        }
        let words = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            return "I couldn't find any words in that picture."
        }
        return await OnDeviceNarrator.shared.narrate(words) ?? MailSummarizer.summarize(words).spoken
    }

    // MARK: - Ask

    private func startAsk() {
        guard !isDescribing, !isListening, !isAsking else { return }
        speaker.stopSpeaking()
        isListening = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { await listener.start() }
    }

    private func finishAsk() {
        guard isListening else { return }
        isListening = false
        Task {
            let heard = await listener.stopAndTranscribe()
            let q = heard.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else {
                await MainActor.run { sayApp("I didn't catch that. Hold the button and ask again.") }
                return
            }
            await answer(q)
        }
    }

    private func askTyped() {
        let q = typedQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isDescribing, !isAsking, !isListening else { return }
        typingQuestion = false
        typedQuestion = ""
        speaker.stopSpeaking()
        Task { await answer(q) }
    }

    private func answer(_ q: String) async {
        let gen = generation
        let entry = Exchange(question: q)
        await MainActor.run {
            isAsking = true
            exchanges.append(entry)
        }
        // Asked in Your language: the model gets it in English.
        let english = await YourLanguage.toEnglish(q)
        var said: String?
        #if DEBUG
        if let fake = ProcessInfo.processInfo.environment["RTCAM_FAKE_FOLLOWUP"], !fake.isEmpty {
            said = fake
        } else {
            said = await OnDeviceVisionNarrator.shared.ask(english, about: image)
        }
        #else
        said = await OnDeviceVisionNarrator.shared.ask(english, about: image)
        #endif
        await MainActor.run {
            guard gen == generation else { return }
            isAsking = false
            let show: (String, String) -> Void = { text, _ in
                if let i = exchanges.firstIndex(where: { $0.id == entry.id }) { exchanges[i].answer = text }
            }
            if let said {
                RatePrompt.noteResult()
                sayContent(said, then: show)
            } else {
                sayApp("Sorry, I couldn't work that out. Try asking again.", then: show)
            }
        }
    }

    // MARK: - Speech

    /// The model's English, shown and said in Your language (English: as is).
    private func sayContent(_ english: String, then show: @escaping (String, String) -> Void) {
        let gen = generation
        guard YourLanguage.activeCode != YourLanguageRules.english else {
            show(english, YourLanguageRules.english)
            speak(english, lang: YourLanguageRules.english)
            return
        }
        Task {
            let out = await YourLanguage.intoActive(english)
            await MainActor.run {
                guard gen == generation else { return }
                show(out.text, out.lang)
                speak(out.text, lang: out.lang)
            }
        }
    }

    /// One of the app's own lines (English key), in the app's language or Your language.
    private func sayApp(_ english: String, then show: ((String, String) -> Void)? = nil) {
        let gen = generation
        Task {
            let out = await UICue.line(english)
            await MainActor.run {
                guard gen == generation else { return }
                show?(out.text, out.lang)
                speak(out.text, lang: out.lang)
            }
        }
    }

    private func speak(_ text: String, lang: String) {
        isSpeaking = true
        speaker.speak(text: text, voiceIdentifier: voice, language: lang) {}
        // Watch the voice itself: a cancelled line can hand its completion to the next one.
        speakingWatch?.cancel()
        speakingWatch = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000) // the speaker starts 0.1 s late
            while !Task.isCancelled, speaker.isSpeakingNow {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if !Task.isCancelled { isSpeaking = false }
        }
    }

    private func sayAgain() {
        guard !description.isEmpty else { return }
        speak(description, lang: descriptionLang)
    }

    private func close() {
        generation += 1
        speaker.stopSpeaking()
        onClose()
    }
}
