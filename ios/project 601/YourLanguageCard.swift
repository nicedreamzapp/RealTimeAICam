import Combine
import SwiftUI
import UIKit

/// Settings: "Your language" with English and the 17 Read languages, plus the one
/// download row. The language downloads ONLY on a tap of that row (Matt's rule:
/// nothing downloads until the person clearly wants it). Same as Android's card.
struct YourLanguageCard: View {
    @ObservedObject private var yourLanguage = YourLanguage.shared

    private func say(_ line: String) {
        #if DEBUG
        SpeakLog.note("yourLanguage", line)
        #endif
        SpeechManager.shared.speak(line)
    }

    var body: some View {
        let code = yourLanguage.code
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "character.bubble")
                    .font(.system(size: 20))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("Your language")
                    .font(.headline)
                Spacer()
                if YourLanguage.translatorAvailable {
                    Menu {
                        ForEach(YourLanguageRules.languages, id: \.code) { lang in
                            Button {
                                pick(lang.code)
                            } label: {
                                if lang.code == code {
                                    Label(lang.name, systemImage: "checkmark")
                                } else {
                                    Text(lang.name)
                                }
                            }
                            .accessibilityIdentifier("yourLanguage_\(lang.code)")
                        }
                    } label: {
                        Text(YourLanguageRules.name(code))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.purple)
                    }
                    .accessibilityIdentifier("yourLanguagePicker")
                    .accessibilityLabel("Your language")
                    .accessibilityValue(YourLanguageRules.name(code))
                    .accessibilityHint("Double tap to choose the language results are spoken in")
                } else {
                    Text("English").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                }
            }

            Text(YourLanguage.translatorAvailable
                 ? "Read, Object Detection, Help Me Aim and What's this? speak in this language. Buttons stay in English for now."
                 : "Other languages need iOS 18 or later. On this phone everything is spoken in English.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if code != YourLanguageRules.english, !yourLanguage.isReady(code) {
                let busy = yourLanguage.downloading == code
                Button {
                    yourLanguage.download(say: say)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.fill")
                            .accessibilityHidden(true)
                        Text(busy ? YourLanguageRules.downloadingLine(code) : YourLanguageRules.downloadRow(code))
                            .font(.system(size: 15, weight: .semibold))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if busy { ProgressView().tint(.white) }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.blue.opacity(0.85)))
                }
                .disabled(busy)
                .accessibilityIdentifier("yourLanguageDownload")
            } else if code != YourLanguageRules.english, YourLanguageVoice.best(for: code) == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(YourLanguageRules.noVoiceLine(code))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open phone settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.caption.bold())
                    .accessibilityIdentifier("yourLanguageVoiceSettings")
                }
            }
        }
        #if DEBUG
        .overlay(alignment: .bottomTrailing) {
            // Simulator tests only: how the object names stand.
            if YourLanguageTranslator.isFake {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let status = ObjectLabelCache.shared.status
                    Text(status).font(.system(size: 9)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("yourLanguageObjectNames")
                        .accessibilityLabel(status)
                }
            }
        }
        #endif
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.1)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("yourLanguageCard")
    }

    private func pick(_ new: String) {
        guard new != yourLanguage.code else { return }
        yourLanguage.set(new)
        Task { @MainActor in
            await yourLanguage.refresh()
            announce(new)
        }
    }

    private func announce(_ new: String) {
        if new == YourLanguageRules.english {
            say("Your language is English.")
        } else if yourLanguage.isReady(new) {
            say("Your language is \(YourLanguageRules.name(new)).")
        } else {
            say("Your language is \(YourLanguageRules.name(new)). Tap \(YourLanguageRules.downloadRow(new)).")
        }
    }
}
