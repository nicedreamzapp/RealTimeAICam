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

            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Picker("Pick for me", selection: $priority) {
                ForEach(ModelPriority.allCases) { Text($0.name).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Accuracy first lets mail, money and medicine take up to a minute and scenes up to 20 seconds. Speed first keeps scenes near 10 seconds.")
            .onChange(of: priority) { _, _ in setup.fetchWanted(automatic: true) }

            levelRow(nil)
            ForEach(ModelLevel.allCases) { levelRow($0) }

            Button(setup.checkingSpeed ? "Checking speed…" : "Check this phone's speed again") {
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
        if page == scene { return "Automatic uses \(page.name) on this phone." }
        return "Automatic uses \(page.name) for mail, money and medicine, and \(scene.name) for everything else."
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
                Text(level.map { "\($0.name)  ·  \($0.score)/100" } ?? "Automatic (recommended)")
                    .font(.subheadline.weight(.semibold))
                Text(detail(level))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let level { status(level) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { choose(level) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func detail(_ level: ModelLevel?) -> String {
        _ = balancedSeconds
        guard let level else {
            return "Picks the smartest level this phone runs in time, and gives mail, money and medicine the most accurate one."
        }
        if !level.fitsThisPhone { return "\(level.blurb) Needs more memory than this phone has." }
        let scene = ModelPicker.spoken(ModelPicker.estimate(level, kind: .scene))
        let page = ModelPicker.spoken(ModelPicker.estimate(level, kind: .page))
        let size = level.isBundled ? "No download" : level.sizeDescription
        if ModelPicker.balancedSeconds == nil { return "\(level.blurb) \(size)." }
        return "\(level.blurb) \(size). A scene takes \(scene), a page \(page)."
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
