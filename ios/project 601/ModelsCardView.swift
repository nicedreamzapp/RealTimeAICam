import SwiftUI

/// Settings > Models (1.4.0), built for VoiceOver first.
///
/// In Settings it is ONE row: "Models. Using Sharp, the best fit for this
/// phone." Someone who never wants to touch it hears one line and swipes on.
/// Double-tap opens ``ModelsChooserView``: a short list of big rows, one swipe
/// stop each, every row saying everything in one sentence, and every choice
/// confirmed out loud. The same rows work for explore-by-touch (full width, at
/// least 64 points tall) and for sighted taps.
struct ModelsCardView: View {
    @ObservedObject private var downloader = VisionModelDownloader.shared
    @ObservedObject private var setup = ModelSetup.shared
    @AppStorage(ModelPicker.chosenKey) private var choice = "auto"
    @AppStorage(ModelPicker.priorityKey) private var priority = ModelPriority.accuracy.rawValue
    @AppStorage(ModelPicker.balancedSecondsKey) private var balancedSeconds = 0.0
    @State private var showChooser = false

    var body: some View {
        let summary = ModelsText.summary(checking: setup.checkingSpeed, downloading: downloader.current,
                                         progress: downloader.progress, redraw: [choice, priority, "\(balancedSeconds)"])
        Button { showChooser = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "cpu")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Models").font(.headline)
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial.opacity(0.3)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Models. " + summary)
        .accessibilityHint("Double-tap to change which model What's this? uses. You don't need to.")
        .accessibilityAddTraits(.isButton)
        .sheet(isPresented: $showChooser) { ModelsChooserView() }
    }
}

/// The words, in one place, so the screen and VoiceOver always say the same thing.
enum ModelsText {
    /// `redraw` only makes SwiftUI re-ask when a setting changes.
    @MainActor
    static func summary(checking: Bool, downloading: ModelLevel?, progress: Double, redraw: [String] = []) -> String {
        _ = redraw
        if checking { return "Measuring this phone's speed. This takes a few seconds." }
        if let level = downloading {
            return "Getting \(level.name), \(Int(progress * 100)) percent. What's this? works meanwhile."
        }
        guard ModelPicker.balancedSeconds != nil else {
            return "Using the built-in model. The best one for this phone is picked in a moment."
        }
        let using = ModelPicker.level(for: .scene)
        if ModelPicker.manualLevel != nil { return "Using \(using.name), the one you picked." }
        let page = ModelPicker.ideal(for: .page), scene = ModelPicker.ideal(for: .scene)
        if !VisionModelStore.isInstalled(page) || !VisionModelStore.isInstalled(scene) {
            return "Using \(using.name) for now. \(page.name), the best fit, downloads on Wi-Fi."
        }
        if page == scene { return "Using \(page.name), the best fit for this phone." }
        return "Using \(page.name) for mail, money and medicine, \(scene.name) for everything else."
    }

    /// Everything about one model in one sentence, after its name.
    @MainActor
    static func row(_ level: ModelLevel) -> String {
        var parts = [level.blurb]
        let downloader = VisionModelDownloader.shared
        let state = downloader.state(level)
        if !level.fitsThisPhone {
            parts.append("Too big for this phone's memory.")
        } else if case .downloading = state {
            let pct = downloader.current == level ? Int(downloader.progress * 100) : 0
            parts.append("Downloading, \(pct) percent.")
        } else if state == .queued {
            parts.append("Waiting to download.")
        } else if state == .verifying {
            parts.append("Checking the download.")
        } else if VisionModelStore.isInstalled(level) {
            parts.append(level.isBundled ? "Built in." : "On this phone.")
        } else {
            parts.append("Not downloaded. \(level.sizeDescription), downloads when you pick it.")
        }
        if case .failed = state { parts.append("The last download stopped. Pick it to try again.") }
        if level.fitsThisPhone, let s = ModelPicker.estimate(level, kind: .scene) {
            parts.append("Answers in \(ModelPicker.spoken(s)).")
        }
        parts.append("Accuracy \(level.score) out of 100.")
        return parts.joined(separator: " ")
    }
}

/// The chooser: big rows, one sentence each, nothing nested.
struct ModelsChooserView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var downloader = VisionModelDownloader.shared
    @ObservedObject private var setup = ModelSetup.shared
    @AppStorage(ModelPicker.chosenKey) private var choice = "auto"
    @AppStorage(ModelPicker.priorityKey) private var priority = ModelPriority.accuracy.rawValue
    @AppStorage(ModelPicker.balancedSecondsKey) private var balancedSeconds = 0.0

    var body: some View {
        let redraw = [choice, priority, "\(balancedSeconds)"]
        NavigationStack {
            List {
                Section {
                    Text("You don't need to change anything. Automatic picks the best model this phone can run, and What's this? keeps working while it downloads.")
                }

                Section("What matters more to you?") {
                    ForEach(ModelPriority.allCases) { p in
                        bigRow(title: p.name, detail: p.explanation, selected: priority == p.rawValue) {
                            priority = p.rawValue
                            setup.fetchWanted(automatic: true)
                            confirm("\(p.name) selected.")
                        }
                    }
                }

                Section("Which model") {
                    bigRow(title: "Automatic (recommended)",
                           detail: ModelsText.summary(checking: setup.checkingSpeed, downloading: nil,
                                                      progress: 0, redraw: redraw),
                           selected: choice == "auto") {
                        choice = "auto"
                        setup.fetchWanted(automatic: true)
                        confirm("Automatic selected. " + ModelsText.summary(checking: false, downloading: nil, progress: 0))
                    }
                    ForEach(ModelLevel.allCases) { level in
                        modelRow(level)
                    }
                }

                Section {
                    Button(setup.checkingSpeed ? "Measuring speed…" : "Measure this phone's speed again") {
                        if #available(iOS 17.0, *) { Task { await setup.runSpeedCheck() } }
                    }
                    .frame(minHeight: 44)
                    .disabled(setup.checkingSpeed)
                    .accessibilityHint("Times one test photo, about 10 seconds")
                }
            }
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Full-width, at least 64 points tall, one VoiceOver stop, says "Selected".
    private func bigRow(title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? .teal : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + ". " + detail)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func modelRow(_ level: ModelLevel) -> some View {
        let selected = choice == level.rawValue
        let state = downloader.state(level)
        let downloading: Bool = { if case .downloading = state { return true }; return false }()
        let sentence = ModelsText.row(level)
        return Button { pick(level) } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? .teal : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(level.name).font(.headline)
                    Text(sentence).font(.subheadline).foregroundStyle(.secondary)
                    if downloading, downloader.current == level {
                        ProgressView(value: downloader.progress).tint(.teal)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(level.fitsThisPhone ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level.name + ". " + sentence)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(level.fitsThisPhone && !selected ? "Double-tap to use \(level.name)." : "")
        // Delete is the swipe-left action and a VoiceOver action (swipe up or
        // down to hear it), so it is never an extra stop on every row.
        .swipeActions {
            if !level.isBundled, VisionModelStore.isInstalled(level) {
                Button("Delete", role: .destructive) { delete(level) }
            }
        }
        .accessibilityActions {
            if !level.isBundled, VisionModelStore.isInstalled(level) {
                Button("Delete \(level.name) to free \(level.sizeDescription)") { delete(level) }
            }
            if !level.isBundled, downloading || state == .queued {
                Button("Stop downloading \(level.name)") { downloader.cancel(level) }
            }
        }
    }

    private func pick(_ level: ModelLevel) {
        guard level.fitsThisPhone else {
            confirm("\(level.name) is too big for this phone's memory.")
            return
        }
        choice = level.rawValue
        if VisionModelStore.isInstalled(level) {
            confirm("\(level.name) selected. What's this? uses it from now on.")
        } else {
            downloader.start(level)
            // The downloader says the rest ("Getting Sharp, 2 GB…"), once.
            confirm("\(level.name) selected.")
        }
    }

    private func delete(_ level: ModelLevel) {
        downloader.delete(level)
        if choice == level.rawValue { choice = "auto" }
        confirm("\(level.name) deleted. \(level.sizeDescription) freed.")
    }

    /// Every choice is said out loud, so nobody has to go looking for what changed.
    private func confirm(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}
