// ButtonPressDebouncer.swift
// Universal, modern, thread-safe button tap debouncer for pro apps
// Works in SwiftUI, UIKit, and async/await contexts (2025 style)

import Combine // Only Combine is required for ObservableObject conformance
import Foundation

final class ButtonPressDebouncer: ObservableObject {
    @Published private var dummy = false

    private var lastTapDates: [String: Date] = [:]
    private let minimumInterval: TimeInterval

    /// Create a new debouncer. Default = 500ms between taps.
    init(minimumInterval: TimeInterval = 0.5) {
        self.minimumInterval = minimumInterval
    }

    /// Per-button debounce: each id gets its own cooldown, so rapid-tapping
    /// one control never swallows a tap on a different control.
    @MainActor
    func canPress(_ id: String) -> Bool {
        let now = Date()
        if now.timeIntervalSince(lastTapDates[id] ?? .distantPast) > minimumInterval {
            lastTapDates[id] = now
            return true
        }
        return false
    }
}

// Usage in a SwiftUI view:
// @StateObject private var debouncer = ButtonPressDebouncer()
// Button { if debouncer.canPress("my-button") { ... } } label: { Text("...") }
