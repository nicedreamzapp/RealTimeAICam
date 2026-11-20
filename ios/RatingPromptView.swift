import SwiftUI

/// Asks the user to rate the app after they have used translation enough to
/// form an opinion. Shows once per major version (1.0, 1.1, etc.).
struct RatingPromptView: View {
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
                .accessibilityHidden(true)

            VStack(spacing: 20) {
                Text("Enjoying RealTime AI Cam?")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)

                Text("A quick rating helps a lot — and costs nothing.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 16) {
                    Button("Not now") { dismiss() }
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.gray.opacity(0.3))
                        )

                    Button("Rate now") { openStore() }
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.blue.opacity(0.3))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.blue.opacity(0.5), lineWidth: 1)
                                )
                        )
                }

                Button("No thanks") {
                    dismiss()
                    UserDefaults.standard.set(true, forKey: "ratingPromptDismissedForever")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            .scaleEffect(shown ? 1 : 0.9)
            .opacity(shown ? 1 : 0)
            .accessibilityAddTraits(.isModal)
        }
        .onAppear { shown = true }
        .accessibilityElement(children: .contain)
    }

    private func dismiss() {
        withAnimation(.spring(response: 0.3)) { shown = false }
    }

    private func openStore() {
        if let url = URL(string: "https://apps.apple.com/app/id6743267268") {
            UIApplication.shared.open(url)
        }
        dismiss()
    }
}

/// Call this after a translation succeeds to track usage and decide whether to
/// show the rating prompt.
struct RatingTracker {
    /// How many successful translations before we ask.
    private static let threshold = 10

    static func recordTranslation() {
        var count = UserDefaults.standard.integer(forKey: "ratingTranslationCount")
        count += 1
        UserDefaults.standard.set(count, forKey: "ratingTranslationCount")

        if shouldShow(forCount: count) {
            showPrompt()
        }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: "ratingTranslationCount")
    }

    // MARK: - internal

    private static func shouldShow(forCount count: Int) -> Bool {
        // Never show if they tapped "No thanks"
        if UserDefaults.standard.bool(forKey: "ratingPromptDismissedForever") { return false }
        // Only show once per major version
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let lastShownVersion = UserDefaults.standard.string(forKey: "ratingPromptLastShownVersion")
        if lastShownVersion == currentVersion { return false }
        // Show at the threshold
        return count >= threshold
    }

    private static func showPrompt() {
        // Post a notification that the view can observe
        NotificationCenter.default.post(name: .ratingPromptShow, object: nil)
        // Remember we showed it this version
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        UserDefaults.standard.set(currentVersion, forKey: "ratingPromptLastShownVersion")
    }
}

extension Notification.Name {
    static let ratingPromptShow = Notification.Name("ratingPromptShow")
}
