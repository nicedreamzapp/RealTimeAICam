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
        // A picture shared from another app opens over everything; this sheet would hide it.
        .onReceive(SharedImageInbox.shared.$current) { shared in
            if shared != nil { showChooser = false }
        }
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

    /// What the model is like, after its status: what it is for, how fast, how accurate.
    @MainActor
    static func details(_ level: ModelLevel) -> String {
        var parts = [level.blurb]
        if case .failed = VisionModelDownloader.shared.state(level) {
            parts.append(L("The last download stopped. Pick it to try again."))
        }
        if level.fitsThisPhone, let s = ModelPicker.estimate(level, kind: .scene) {
            parts.append(L("Answers in %@.", ModelPicker.spoken(s)))
        }
        parts.append(L("Accuracy %ld out of 100.", level.score))
        return parts.joined(separator: " ")
    }

    /// Where a model stands on this phone, in the words on its tag.
    enum Status: Equatable {
        case builtIn, onPhone, downloading(Int), queued, verifying, notDownloaded, tooBig

        @MainActor
        static func of(_ level: ModelLevel) -> Status {
            let downloader = VisionModelDownloader.shared
            switch downloader.state(level) {
            case .downloading: return .downloading(downloader.current == level ? Int(downloader.progress * 100) : 0)
            case .queued: return .queued
            case .verifying: return .verifying
            default: break
            }
            if level.isBundled { return .builtIn }
            if VisionModelStore.isInstalled(level) { return .onPhone }
            return level.fitsThisPhone ? .notDownloaded : .tooBig
        }

        var isHere: Bool { self == .builtIn || self == .onPhone }
        var isBusy: Bool {
            switch self {
            case .downloading, .queued, .verifying: true
            default: false
            }
        }

        /// The tag on screen.
        func tag(_ level: ModelLevel) -> String {
            switch self {
            case .builtIn: L("Built in")
            case .onPhone: L("On this phone")
            case let .downloading(p): L("Downloading · %ld%%", p)
            case .queued: L("Waiting to download")
            case .verifying: L("Checking the download")
            case .notDownloaded: L("Not downloaded · %@", level.sizeDescription)
            case .tooBig: L("Too big for this phone")
            }
        }

        /// The same, as VoiceOver says it after the name.
        func spoken(_ level: ModelLevel) -> String {
            switch self {
            case .builtIn: L("built in, on this phone")
            case .onPhone: L("on this phone")
            case let .downloading(p): L("downloading, %ld percent", p)
            case .queued: L("waiting to download")
            case .verifying: L("checking the download")
            case .notDownloaded: L("not downloaded")
            case .tooBig: L("too big for this phone's memory")
            }
        }
    }

    /// "On this phone: Balanced (built in), Sharp", or the built-in one alone.
    @MainActor
    static func onPhoneSummary() -> String {
        let here = ModelPicker.installed
        if here.allSatisfy(\.isBundled) {
            return L("Only the built-in %@ model is on this phone.", (here.first ?? .balanced).name)
        }
        let names = here.map { $0.isBundled ? L("%@ (built in)", $0.name) : $0.name }
        return L("On this phone: %@", names.joined(separator: ", "))
    }
}

/// The chooser: one list of models, each saying in plain words whether it is on this
/// phone, whether it is the one answering now, and the one thing you can do with it.
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
        let downloaded = ModelPicker.installed.filter { !$0.isBundled }
        NavigationStack {
          ScrollViewReader { proxy in
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(ModelsText.onPhoneSummary()).font(.headline)
                        Text(L("You don't need to change anything. Automatic picks the best model this phone can run, and What's this? keeps working while it downloads."))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }

                Section(L("What matters more to you?")) {
                    ForEach(ModelPriority.allCases) { p in
                        bigRow(title: p.name, detail: p.explanation, selected: priority == p.rawValue) {
                            priority = p.rawValue
                            confirm(L("%@ selected.", p.name))
                            askAboutAutomatic()
                        }
                    }
                }

                Section {
                    automaticRow(redraw: redraw)
                    ForEach(ModelLevel.allCases) { level in
                        modelRow(level)
                    }
                } header: {
                    Text(L("Which model")).id("whichModel")
                } footer: {
                    Text(downloaded.isEmpty ? L("Swipe left on a downloaded model to delete it.")
                         : L("Downloaded models use %@. Swipe left on one to delete it.", ModelsText.totalSize(downloaded)))
                }
            }
            #if DEBUG
            // Screenshots only: `-rtcamModelsList` scrolls straight to the model list.
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-rtcamModelsList") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo("whichModel", anchor: .top) }
                }
            }
            #endif
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

    // MARK: Rows

    /// A small rounded tag: "On this phone", "Using now"...
    private func tag(_ text: String, color: Color, filled: Bool) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(filled ? Color.black : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(filled ? color : color.opacity(0.18)))
            .overlay(Capsule().stroke(color.opacity(filled ? 0 : 0.6), lineWidth: 1))
            .fixedSize()
    }

    private func color(_ status: ModelsText.Status) -> Color {
        switch status {
        case .builtIn, .onPhone: .green
        case .downloading, .queued, .verifying: .blue
        case .notDownloaded: .gray
        case .tooBig: .orange
        }
    }

    /// The one button on the right of a row, as a plain action.
    private enum RowAction { case use, download, stop }

    private func action(for level: ModelLevel, status: ModelsText.Status, inUse: Bool) -> RowAction? {
        if status.isBusy { return .stop }
        if status == .notDownloaded { return notStarted(level) ? .download : nil }
        if status.isHere { return inUse ? nil : .use }
        return nil
    }

    private func title(_ a: RowAction) -> String {
        switch a {
        case .use: L("Use this")
        case .download: L("Download")
        case .stop: L("Stop")
        }
    }

    private func run(_ a: RowAction, _ level: ModelLevel) {
        switch a {
        case .use: use(level)
        case .download: askDownload = level       // nothing downloads until they say yes
        case .stop: stop(level)
        }
    }

    @ViewBuilder private func actionButton(_ a: RowAction?, perform: @escaping () -> Void) -> some View {
        if let a {
            if a == .stop {
                Button(role: .destructive, action: perform) { Text(title(a)) }
                    .buttonStyle(.bordered).tint(.red)
            } else if a == .download {
                Button(action: perform) { Label(title(a), systemImage: "arrow.down.circle") }
                    .buttonStyle(.borderedProminent).tint(.teal)
            } else {
                Button(action: perform) { Text(title(a)) }
                    .buttonStyle(.bordered).tint(.teal)
            }
        }
    }

    private func automaticRow(redraw: [String]) -> some View {
        let selected = choice == "auto"
        let detail = ModelsText.summary(checking: setup.checkingSpeed, downloading: nil, progress: 0, redraw: redraw)
        let pick = {
            choice = "auto"
            confirm(L("Automatic selected.") + " " + ModelsText.summary(checking: false, downloading: nil, progress: 0))
            askAboutAutomatic()
        }
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(L("Automatic (recommended)")).font(.headline)
                    if selected { tag(L("Using now"), color: .teal, filled: true) }
                }
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            actionButton(selected ? nil : .use, perform: pick)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([L("Automatic, recommended"), selected ? L("using now") : L("Use this")].joined(separator: ", "))
        .accessibilityHint(detail)
        .accessibilityAddTraits(selected ? [.isSelected] : [.isButton])
        .accessibilityAction { if !selected { pick() } }
    }

    private func modelRow(_ level: ModelLevel) -> some View {
        let status = ModelsText.Status.of(level)
        let inUse = status.isHere && ModelPicker.inUse.contains(level)
        let act = action(for: level, status: status, inUse: inUse)
        let deletable = !level.isBundled && status == .onPhone
        var spoken = [level.name, status.spoken(level)]
        if inUse { spoken.append(L("using now")) }
        spoken.append(level.sizeDescription)
        if let act { spoken.append(title(act)) }
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(level.name).font(.headline)
                    if inUse { tag(L("Using now"), color: .teal, filled: true) }
                }
                tag(status.tag(level), color: color(status), filled: false)
                Text(ModelsText.details(level)).font(.subheadline).foregroundStyle(.secondary)
                Text(level.technicalLine).font(.caption).foregroundStyle(.secondary)
                if case .downloading = status, downloader.current == level {
                    ProgressView(value: downloader.progress).tint(.teal)
                }
            }
            Spacer(minLength: 0)
            actionButton(act) { run(act!, level) }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .opacity(status == .tooBig ? 0.55 : 1)
        // One VoiceOver stop: "Sharp, on this phone, using now, 2 GB". Double-tap does the
        // row's one action; Delete and Stop are in the actions rotor too.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken.joined(separator: ", "))
        .accessibilityHint(ModelsText.details(level) + " " + level.technicalLine)
        .accessibilityAddTraits(act == nil ? [] : [.isButton])
        .accessibilityAction { if let act { run(act, level) } }
        // Delete is the swipe-left action and a VoiceOver action, never an extra stop.
        .swipeActions {
            if deletable {
                Button(L("Delete"), role: .destructive) { askDelete = level }
            }
        }
        .accessibilityActions {
            if deletable {
                Button(L("Delete %@ to free %@", level.name, level.sizeDescription)) { askDelete = level }
            }
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

    // MARK: Actions

    private func use(_ level: ModelLevel) {
        guard level.fitsThisPhone else {
            confirm(L("%@ is too big for this phone's memory.", level.name))
            return
        }
        choice = level.rawValue
        confirm(L("%@ selected. What's this? uses it from now on.", level.name))
    }

    private func startConfirmed(_ level: ModelLevel) {
        choice = level.rawValue
        setup.download(level)
        // The downloader says the rest ("Getting Sharp, 2 GB…"), once.
        confirm(L("%@ selected.", level.name))
    }

    private func stop(_ level: ModelLevel) {
        setup.stop(level)
        confirm(L("Stopped. %@ won't download unless you choose it.", level.name))
    }

    /// Deleting the model in use moves to the best one left (ModelSetup.delete goes back to
    /// automatic) and says which.
    private func delete(_ level: ModelLevel) {
        let wasInUse = ModelPicker.inUse.contains(level)
        setup.delete(level)
        choice = ModelPicker.manualLevel?.rawValue ?? "auto"
        if wasInUse {
            confirm(L("%@ deleted. %@ freed. Now using %@.", level.name, level.sizeDescription,
                      ModelPicker.level(for: .scene).name))
        } else {
            confirm(L("%@ deleted. %@ freed.", level.name, level.sizeDescription))
        }
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
