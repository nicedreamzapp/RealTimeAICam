// DebouncedButton.swift
// Drop-in replacement for SwiftUI Button that throttles rapid taps globally

import Combine
import SwiftUI

private enum DebouncedButtonState {
    static var lastTapDate: Date = .distantPast
    static let lock = NSLock()
}

/// An app-wide debounced button that prevents rapid repeated taps.
/// Use in place of Button for any action you want to protect from accidental spamming.
struct DebouncedButton<Label: View>: View {
    private let action: () -> Void
    private let label: () -> Label
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.5, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.action = action
        self.label = label
        self.interval = interval
    }

    var body: some View {
        Button(action: {
            DebouncedButtonState.lock.lock()
            let now = Date()
            defer { DebouncedButtonState.lock.unlock() }
            if now.timeIntervalSince(DebouncedButtonState.lastTapDate) > interval {
                DebouncedButtonState.lastTapDate = now
                action()
            }
        }, label: label)
    }
}

// Usage:
// DebouncedButton {
//     // Your action here
// } label: {
//     Text("Tap me")
// }
