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
    /// "2.05 GB" for one or more levels.
    static func totalSize(_ levels: [ModelLevel]) -> String {
        ByteCountFormatter.string(fromByteCount: levels.reduce(0) { $0 + $1.bytes }, countStyle: .file)
    }

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
        if let missing = [page, scene].first(where: { !VisionModelStore.isInstalled($0) }) {
            if ModelPicker.removed.contains(missing) {
                return L("Using %@. %@ fits this phone best, tap it below to download it.", using.name, missing.name)
            }
            return L("Using %@ for now. %@, the best fit, downloads on Wi-Fi.", using.name, missing.name)
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
            parts.append(L("Not downloaded, %@. Tap to download it.", level.sizeDescription))
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
    /// A level waiting for "Download?" / "Delete?" to be answered.
    @State private var askDownload: ModelLevel?
    @State private var askDelete: ModelLevel?
    /// Automatic (or a new priority) wants these, waiting for "Download?".
    @State private var askAutomatic: [ModelLevel] = []

    var body: some View {
        let redraw = [choice, priority, "\(balancedSeconds)"]
        NavigationStack {
            List {
                Section {
                    Text(L("You don't need to change anything. Automatic picks the best model this phone can run, and What's this? keeps working while it downloads."))
                }

                onThisPhone

                Section(L("What matters more to you?")) {
                    ForEach(ModelPriority.allCases) { p in
                        bigRow(title: p.name, detail: p.explanation, selected: priority == p.rawValue) {
                            priority = p.rawValue
                            confirm(L("%@ selected.", p.name))
                            askAboutAutomatic()
                        }
                    }
                }

                Section(L("Which model")) {
                    bigRow(title: L("Automatic (recommended)"),
                           detail: ModelsText.summary(checking: setup.checkingSpeed, downloading: nil,
                                                      progress: 0, redraw: redraw),
                           selected: choice == "auto") {
                        choice = "auto"
                        confirm(L("Automatic selected.") + " " + ModelsText.summary(checking: false, downloading: nil, progress: 0))
                        askAboutAutomatic()
                    }
                    ForEach(ModelLevel.allCases) { level in
                        modelRow(level)
                        stopRow(level)
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
        .alert(L("Download %@?", askDownload?.name ?? ""), isPresented: isAsking($askDownload), presenting: askDownload) { level in
            Button(L("Download")) { startConfirmed(level) }
            Button(L("Cancel"), role: .cancel) {}
        } message: { level in
            Text(L("%@. Uses Wi-Fi or your data plan. You can stop it any time.", level.sizeDescription))
        }
        .alert(L("Delete %@?", askDelete?.name ?? ""), isPresented: isAsking($askDelete), presenting: askDelete) { level in
            Button(L("Delete"), role: .destructive) { delete(level) }
            Button(L("Cancel"), role: .cancel) {}
        } message: { level in
            Text(L("Frees %@. It won't download again unless you choose it.", level.sizeDescription))
        }
        .alert(L("Download %@?", askAutomatic.map(\.name).joined(separator: " + ")),
               isPresented: Binding(get: { !askAutomatic.isEmpty }, set: { if !$0 { askAutomatic = [] } })) {
            Button(L("Download")) {
                askAutomatic.forEach { setup.download($0) }
                askAutomatic = []
            }
            Button(L("Not now"), role: .cancel) {
                // "No" sticks: automatic mode won't fetch these behind their back later.
                askAutomatic.forEach { ModelPicker.markRemoved($0) }
                askAutomatic = []
            }
        } message: {
            Text(L("Automatic picked this for your phone. %@. Uses Wi-Fi or your data plan.",
                   ModelsText.totalSize(askAutomatic)))
        }
    }

    private func isAsking(_ item: Binding<ModelLevel?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    /// Every model file the phone holds right now, with its size and a Delete button.
    @ViewBuilder private var onThisPhone: some View {
        let installed = ModelLevel.allCases.filter { VisionModelStore.isInstalled($0) }
        let downloaded = installed.filter { !$0.isBundled }
        Section {
            ForEach(installed) { level in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(level.name).font(.headline)
                        Text(level.isBundled ? L("%@. Built into the app, can't be deleted.", level.sizeDescription)
                             : level.sizeDescription)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if !level.isBundled {
                        Button(L("Delete"), role: .destructive) { askDelete = level }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .accessibilityLabel(L("Delete %@ to free %@", level.name, level.sizeDescription))
                    }
                }
                .frame(minHeight: 64)
                .accessibilityElement(children: level.isBundled ? .combine : .contain)
            }
        } header: {
            Text(L("On this phone"))
        } footer: {
            Text(downloaded.isEmpty ? L("Only the built-in model is on this phone.")
                 : L("Downloaded models use %@.", ModelsText.totalSize(downloaded)))
        }
    }

    /// A visible Stop button under a level that is downloading or waiting its turn.
    @ViewBuilder private func stopRow(_ level: ModelLevel) -> some View {
        let state = downloader.state(level)
        if !level.isBundled, state == .queued || state == .downloading || state == .verifying {
            Button(role: .destructive) { stop(level) } label: {
                Label(L("Stop downloading %@", level.name), systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .tint(.red)
        }
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
                Button(L("Delete"), role: .destructive) { askDelete = level }
            }
        }
        .accessibilityActions {
            if !level.isBundled, VisionModelStore.isInstalled(level) {
                Button(L("Delete %@ to free %@", level.name, level.sizeDescription)) { askDelete = level }
            }
            if !level.isBundled, downloading || state == .queued {
                Button(L("Stop downloading %@", level.name)) { stop(level) }
            }
        }
    }

    private func pick(_ level: ModelLevel) {
        guard level.fitsThisPhone else {
            confirm(L("%@ is too big for this phone's memory.", level.name))
            return
        }
        if VisionModelStore.isInstalled(level) {
            choice = level.rawValue
            confirm(L("%@ selected. What's this? uses it from now on.", level.name))
        } else if notStarted(level) {
            askDownload = level       // nothing downloads until they say yes
        } else {
            choice = level.rawValue   // already on its way
            confirm(L("%@ selected.", level.name))
        }
    }

    private func startConfirmed(_ level: ModelLevel) {
        choice = level.rawValue
        setup.download(level)
        // The downloader says the rest ("Getting Sharp, 2 GB…"), once.
        confirm(L("%@ selected.", level.name))
    }

    private func stop(_ level: ModelLevel) {
        setup.stop(level)
        if choice == level.rawValue { choice = "auto" }
        confirm(L("Stopped. %@ won't download unless you choose it.", level.name))
    }

    private func delete(_ level: ModelLevel) {
        setup.delete(level)
        if choice == level.rawValue { choice = "auto" }
        confirm(L("%@ deleted. %@ freed.", level.name, level.sizeDescription))
    }

    /// Not on the phone and not on its way (never started, stopped, or failed).
    private func notStarted(_ level: ModelLevel) -> Bool {
        switch downloader.state(level) {
        case .idle, .failed: return true
        default: return false
        }
    }

    /// Automatic (or a new priority) may want a model that isn't here: ask first.
    private func askAboutAutomatic() {
        let missing = setup.missingWanted.filter { notStarted($0) }
        if !missing.isEmpty { askAutomatic = missing }
    }

    /// Every choice is said out loud, so nobody has to go looking for what changed.
    private func confirm(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: SpeechManager.voiceOverLine(text, lang: AppLang.code))
    }
}
