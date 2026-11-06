import Combine
import SwiftUI
import UIKit

/// Settings: "Your language" with English and the 17 Read languages, plus the one
/// download row. The language downloads ONLY on a tap of that row (Matt's rule:
/// nothing downloads until the person clearly wants it). Same as Android's card.
struct YourLanguageCard: View {
    @ObservedObject private var yourLanguage = YourLanguage.shared
    @ObservedObject private var appLang = AppLangObserver.shared

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
                Text(L("Your language"))
                    .font(.headline)
                Spacer()
                if YourLanguage.translatorAvailable {
                    Menu {
                        ForEach(YourLanguageRules.languages, id: \.code) { lang in
                            Button {
                                pick(lang.code)
                            } label: {
                                // Each name in the app's language ("Francés" in Spanish).
                                if lang.code == code {
                                    Label(YourLanguageRules.name(lang.code), systemImage: "checkmark")
                                } else {
                                    Text(YourLanguageRules.name(lang.code))
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
                    .accessibilityLabel(L("Your language"))
                    .accessibilityValue(YourLanguageRules.name(code))
                    .accessibilityHint(L("Double tap to choose the language results are spoken in"))
                } else {
                    Text(YourLanguageRules.name(YourLanguageRules.english)).font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                }
            }

            Text(YourLanguage.translatorAvailable
                 ? L("Read, Object Detection, Help Me Aim and What's this? speak in this language.")
                 : L("Other languages need iOS 18 or later. On this phone everything is spoken in English."))
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
                    Text(YourLanguageRules.noVoiceShown(code))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("Open phone settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.caption.bold())
                    .accessibilityIdentifier("yourLanguageVoiceSettings")
                }
            }

            #if DEBUG
            // Simulator tests only (the fake translator, never in a release build): how the object
            // names stand. Its own line under the button, so it never sits on top of it.
            if YourLanguageTranslator.isFake {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let status = ObjectLabelCache.shared.status
                    Text(status).font(.system(size: 9)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityIdentifier("yourLanguageObjectNames")
                        .accessibilityLabel(status)
                }
            }
            #endif
        }
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
            say(L("Your language is English."))
        } else if yourLanguage.isReady(new) {
            say(L("Your language is %@.", YourLanguageRules.nameInSentence(new)))
        } else {
            say(L("Your language is %@. Tap %@.", YourLanguageRules.nameInSentence(new), YourLanguageRules.downloadRow(new)))
        }
    }
}
