import SwiftUI

/// Settings > Models (1.4.0): which What's this? level answers, and how the
/// automatic pick leans. Every row says its size and how long an answer takes
/// on this phone, from the speed check.
struct ModelsCardView: View {
    @ObservedObject private var downloader = VisionModelDownloader.shared
    @ObservedObject private var setup = ModelSetup.shared

    @AppStorage(ModelPicker.chosenKey) private var choice = "auto"
    @AppStorage(ModelPicker.priorityKey) private var priority = ModelPriority.accuracy.rawValue
    @AppStorage(ModelPicker.balancedSecondsKey) private var balancedSeconds = 0.0

    private var pickedPriority: ModelPriority { ModelPriority(rawValue: priority) ?? .accuracy }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.teal)
                Text("Models")
                    .font(.headline)
            }

            Text("You don't need to change anything here. What's this? uses an AI model that lives on your phone. "
                 + "Bigger models give more accurate answers but take longer. Automatic picks the best one this phone can handle "
                 + "and downloads it once, on Wi-Fi. What's this? keeps working while it downloads.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(summary)
                .font(.subheadline.weight(.semibold))

            Text("What matters more to you?")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Picker("What matters more to you?", selection: $priority) {
                ForEach(ModelPriority.allCases) { Text($0.name).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .onChange(of: priority) { _, _ in setup.fetchWanted(automatic: true) }
            Text(pickedPriority.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Which model")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            levelRow(nil)
            ForEach(ModelLevel.allCases) { levelRow($0) }

            Button(setup.checkingSpeed ? "Checking speed…" : "Measure this phone's speed again") {
                if #available(iOS 17.0, *) { Task { await setup.runSpeedCheck() } }
            }
            .disabled(setup.checkingSpeed)
            .font(.subheadline)
            .accessibilityHint("Times one test photo, about 10 seconds, and updates every estimate")
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    private var summary: String {
        _ = balancedSeconds   // redraw when the speed check lands
        if setup.checkingSpeed { return "Checking this phone's speed with one test photo…" }
        if ModelPicker.balancedSeconds == nil { return "The speed check runs once, a few seconds after the app opens." }
        let page = ModelPicker.ideal(for: .page, priority: pickedPriority)
        let scene = ModelPicker.ideal(for: .scene, priority: pickedPriority)
        let using = ModelPicker.level(for: .scene)
        if ModelPicker.manualLevel != nil { return "This phone is using \(using.name), the one you picked." }
        if page == scene {
            return using == page ? "This phone is using \(page.name), the best fit for it."
                : "This phone is using \(using.name) for now. \(page.name), the best fit, is on its way."
        }
        return "Best fit for this phone: \(page.name) for mail, money and medicine, \(scene.name) for everything else."
    }

    /// nil is the Automatic row.
    @ViewBuilder
    private func levelRow(_ level: ModelLevel?) -> some View {
        let tag = level?.rawValue ?? "auto"
        let selected = choice == tag
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? .teal : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(level?.name ?? "Automatic (recommended)")
                    .font(.subheadline.weight(.semibold))
                if let level {
                    Text("Accuracy \(level.score) out of 100")
                        .font(.caption.weight(.semibold))
                }
                Text(detail(level))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let level, let words = statusWords(level) {
                    Text(words)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.teal)
                }
                if let level { status(level) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { choose(level) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// "In use now", "On this phone", "Not downloaded yet" — said in words, not
    /// left for a colour or an icon to carry.
    private func statusWords(_ level: ModelLevel) -> String? {
        _ = balancedSeconds; _ = choice
        guard level.fitsThisPhone else { return nil }
        guard VisionModelStore.isInstalled(level) else {
            return downloader.state(level) == .idle ? "Not downloaded yet" : nil
        }
        let scene = ModelPicker.level(for: .scene) == level
        let page = ModelPicker.level(for: .page) == level
        switch (scene, page) {
        case (true, true): return "In use now"
        case (false, true): return "In use now for mail, money and medicine"
        case (true, false): return "In use now for everything except mail, money and medicine"
        default: return "On this phone"
        }
    }

    private func detail(_ level: ModelLevel?) -> String {
        _ = balancedSeconds
        guard let level else {
            return "The app chooses for you. Mail, money and medicine always get the most accurate model this phone can run."
        }
        if !level.fitsThisPhone { return "\(level.blurb) This phone doesn't have enough memory for it." }
        let scene = ModelPicker.spoken(ModelPicker.estimate(level, kind: .scene))
        let page = ModelPicker.spoken(ModelPicker.estimate(level, kind: .page))
        let size = level.isBundled ? "No download needed"
            : VisionModelStore.isInstalled(level) ? "Uses \(level.sizeDescription)" : "\(level.sizeDescription) download"
        if ModelPicker.balancedSeconds == nil { return "\(level.blurb) \(size)." }
        return "\(level.blurb) \(size). On this phone: \(scene) for a room or object, \(page) for a letter or label."
    }

    @ViewBuilder
    private func status(_ level: ModelLevel) -> some View {
        switch downloader.state(level) {
        case .ready:
            if level.isBundled {
                EmptyView()
            } else {
                Button("Delete (frees \(level.sizeDescription))", role: .destructive) { downloader.delete(level) }
                    .font(.caption)
            }
        case .queued:
            Text("Waiting to download").font(.caption).foregroundStyle(.secondary)
        case .downloading:
            ProgressView(value: downloader.current == level ? downloader.progress : 0)
                .tint(.teal)
                .accessibilityLabel("Downloading, \(Int(downloader.progress * 100)) percent")
        case .verifying:
            Text("Checking the download…").font(.caption).foregroundStyle(.secondary)
        case .idle, .failed:
            if level.fitsThisPhone {
                VStack(alignment: .leading, spacing: 2) {
                    if case .failed(let why) = downloader.state(level) {
                        Text("Download failed: \(why)").font(.caption).foregroundStyle(.red)
                    }
                    Button("Download \(level.sizeDescription)") { downloader.start(level) }
                        .font(.caption.weight(.semibold))
                }
            }
        }
    }

    /// Choosing a level that is not on the phone starts its download; until it
    /// lands, What's this? keeps answering with Balanced.
    private func choose(_ level: ModelLevel?) {
        guard let level else {
            choice = "auto"
            setup.fetchWanted(automatic: true)
            return
        }
        guard level.fitsThisPhone else { return }
        choice = level.rawValue
        if !VisionModelStore.isInstalled(level) { downloader.start(level) }
    }
}
