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
    @ObservedObject private var appLang = AppLangObserver.shared

    var body: some View {
        let summary = ModelsText.summary(checking: setup.checkingSpeed, downloading: downloader.current,
                                         progress: downloader.progress, redraw: [choice, priority, "\(balancedSeconds)"])
        Button { showChooser = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "cpu")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Models")).font(.headline)
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
        .accessibilityLabel(L("Models") + ". " + summary)
        .accessibilityHint(L("Double-tap to change which model What's this? uses. You don't need to."))
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
        if checking { return L("Measuring this phone's speed. This takes a few seconds.") }
        if let level = downloading {
            return L("Getting %@, %ld percent. What's this? works meanwhile.", level.name, Int(progress * 100))
        }
        guard ModelPicker.balancedSeconds != nil else {
            return L("Using the built-in model. The best one for this phone is picked in a moment.")
        }
        let using = ModelPicker.level(for: .scene)
        if ModelPicker.manualLevel != nil { return L("Using %@, the one you picked.", using.name) }
        let page = ModelPicker.ideal(for: .page), scene = ModelPicker.ideal(for: .scene)
        if !VisionModelStore.isInstalled(page) || !VisionModelStore.isInstalled(scene) {
            return L("Using %@ for now. %@, the best fit, downloads on Wi-Fi.", using.name, page.name)
        }
        if page == scene { return L("Using %@, the best fit for this phone.", page.name) }
        return L("Using %@ for mail, money and medicine, %@ for everything else.", page.name, scene.name)
    }

    /// Everything about one model in one sentence, after its name.
    @MainActor
    static func row(_ level: ModelLevel) -> String {
        var parts = [level.blurb]
        let downloader = VisionModelDownloader.shared
        let state = downloader.state(level)
        if !level.fitsThisPhone {
            parts.append(L("Too big for this phone's memory."))
        } else if case .downloading = state {
            let pct = downloader.current == level ? Int(downloader.progress * 100) : 0
            parts.append(L("Downloading, %ld percent.", pct))
        } else if state == .queued {
            parts.append(L("Waiting to download."))
        } else if state == .verifying {
            parts.append(L("Checking the download."))
        } else if level.isBundled {
            // the blurb already says it is built in
        } else if VisionModelStore.isInstalled(level) {
            parts.append(L("On this phone."))
        } else {
            parts.append(L("Not downloaded. %@, downloads when you pick it.", level.sizeDescription))
        }
        if case .failed = state { parts.append(L("The last download stopped. Pick it to try again.")) }
        if level.fitsThisPhone, let s = ModelPicker.estimate(level, kind: .scene) {
            parts.append(L("Answers in %@.", ModelPicker.spoken(s)))
        }
        parts.append(L("Accuracy %ld out of 100.", level.score))
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
    @State private var moneyInstalled = MoneyPack.installedFolder != nil
    @State private var moneyBusy = false

    var body: some View {
        let redraw = [choice, priority, "\(balancedSeconds)"]
        NavigationStack {
            List {
                Section {
                    Text(L("You don't need to change anything. Automatic picks the best model this phone can run, and What's this? keeps working while it downloads."))
                }

                Section(L("What matters more to you?")) {
                    ForEach(ModelPriority.allCases) { p in
                        bigRow(title: p.name, detail: p.explanation, selected: priority == p.rawValue) {
                            priority = p.rawValue
                            setup.fetchWanted(automatic: true)
                            confirm(L("%@ selected.", p.name))
                        }
                    }
                }

                Section(L("Which model")) {
                    bigRow(title: L("Automatic (recommended)"),
                           detail: ModelsText.summary(checking: setup.checkingSpeed, downloading: nil,
                                                      progress: 0, redraw: redraw),
                           selected: choice == "auto") {
                        choice = "auto"
                        setup.fetchWanted(automatic: true)
                        confirm(L("Automatic selected.") + " " + ModelsText.summary(checking: false, downloading: nil, progress: 0))
                    }
                    ForEach(ModelLevel.allCases) { level in
                        modelRow(level)
                    }
                }

                // Live Cam's money reader (8 MB): its own small item, beside the vision models.
                Section(L("Live Cam money reader")) {
                    bigRow(title: L("Money reader"),
                           detail: moneyInstalled ? L("Downloaded, 8 MB. Live Cam uses it to count bills.")
                               : moneyBusy ? L("Downloading, 8 MB.")
                               : L("8 MB. It downloads with your first money question, or tap to get it now."),
                           selected: moneyInstalled) {
                        guard !moneyInstalled, !moneyBusy else { return }
                        moneyBusy = true
                        Task {
                            let ok = (try? await MoneyPack.install()) != nil
                            moneyBusy = false
                            moneyInstalled = MoneyPack.installedFolder != nil
                            confirm(ok ? L("Money reader ready.") : L("The money reader didn't download. Check the internet and try again."))
                        }
                    }
                }

            }
            .navigationTitle(L("Models"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() } }
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
                    Text(level.technicalLine).font(.caption).foregroundStyle(.secondary)
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
        .accessibilityLabel(level.name + ". " + sentence + " " + level.technicalLine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(level.fitsThisPhone && !selected ? L("Double-tap to use %@.", level.name) : "")
        // Delete is the swipe-left action and a VoiceOver action (swipe up or
        // down to hear it), so it is never an extra stop on every row.
        .swipeActions {
            if !level.isBundled, VisionModelStore.isInstalled(level) {
                Button(L("Delete"), role: .destructive) { delete(level) }
            }
        }
        .accessibilityActions {
            if !level.isBundled, VisionModelStore.isInstalled(level) {
                Button(L("Delete %@ to free %@", level.name, level.sizeDescription)) { delete(level) }
            }
            if !level.isBundled, downloading || state == .queued {
                Button(L("Stop downloading %@", level.name)) { downloader.cancel(level) }
            }
        }
    }

    private func pick(_ level: ModelLevel) {
        guard level.fitsThisPhone else {
            confirm(L("%@ is too big for this phone's memory.", level.name))
            return
        }
        choice = level.rawValue
        if VisionModelStore.isInstalled(level) {
            confirm(L("%@ selected. What's this? uses it from now on.", level.name))
        } else {
            downloader.start(level)
            // The downloader says the rest ("Getting Sharp, 2 GB…"), once.
            confirm(L("%@ selected.", level.name))
        }
    }

    private func delete(_ level: ModelLevel) {
        downloader.delete(level)
        if choice == level.rawValue { choice = "auto" }
        confirm(L("%@ deleted. %@ freed.", level.name, level.sizeDescription))
    }

    /// Every choice is said out loud, so nobody has to go looking for what changed.
    private func confirm(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: SpeechManager.voiceOverLine(text, lang: AppLang.code))
    }
}
