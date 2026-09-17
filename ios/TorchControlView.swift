import AVFoundation
import SwiftUI

// Torch button: one tap turns the light on at full brightness, one tap turns it off.
// There is deliberately no brightness menu. Feedback from AppleVis (2026-09-12) was that
// making someone pick a percentage before any light appears costs several VoiceOver
// flicks at the exact moment they cannot see, and nobody wants a dim flashlight.
struct TorchButton: View {
    @State private var torchLevel: Float = 0.0
    let initialTorchLevel: Float
    let onLevelChanged: ((Float) -> Void)?

    init(initialTorchLevel: Float = 0.0, onLevelChanged: ((Float) -> Void)? = nil) {
        _torchLevel = State(initialValue: initialTorchLevel)
        self.initialTorchLevel = initialTorchLevel
        self.onLevelChanged = onLevelChanged
    }

    private var isOn: Bool { torchLevel > 0 }

    var body: some View {
        Button(action: {
            let level: Float = isOn ? 0.0 : 1.0
            torchLevel = level
            onLevelChanged?(level)
        }) {
            Image(systemName: isOn ? "flashlight.on.fill" : "flashlight.off.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(isOn ? .yellow : .primary)
                .font(.system(size: 20))
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial.opacity(0.15))
                        .overlay(
                            Circle()
                                .stroke(isOn ? Color.yellow.opacity(0.5) : Color.white.opacity(0.2), lineWidth: 1)
                        )
                )
        }
        .accessibilityLabel("Flashlight")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        // The app turns the light off on its own when you leave; never let the
        // button (or VoiceOver) keep saying "On" after that.
        .onChange(of: initialTorchLevel) { _, level in
            torchLevel = level
        }
    }
}
