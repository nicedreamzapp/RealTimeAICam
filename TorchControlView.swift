import AVFoundation
import SwiftUI

// Simple torch preset button
struct TorchPresetButton: View {
    let percentage: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(percentage)%")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 60, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.yellow.opacity(0.4) : Color.white.opacity(0.2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.yellow : Color.white.opacity(0.3), lineWidth: 1)
                )
        }
    }
}

// Torch button with vertical popup
struct TorchButton: View {
    @State private var showPresets = false
    @State private var torchLevel: Float = 0.0
    let onLevelChanged: ((Float) -> Void)?

    init(initialTorchLevel: Float = 0.0, onLevelChanged: ((Float) -> Void)? = nil) {
        _torchLevel = State(initialValue: initialTorchLevel)
        self.onLevelChanged = onLevelChanged
    }

    var body: some View {
        Button(action: {
            if torchLevel > 0 {
                // If torch is on, turn it off
                torchLevel = 0.0
                onLevelChanged?(0.0)
                showPresets = false
            } else {
                // Toggle so a second tap dismisses the menu instead of
                // stranding the user with no way to close it.
                showPresets.toggle()
            }
        }) {
            Image(systemName: torchLevel > 0 ? "flashlight.on.fill" : "flashlight.off.fill")
                .accessibilityLabel(torchLevel > 0 ? "Turn off flashlight" : "Turn on flashlight")
                .accessibilityHint("Controls camera flashlight brightness. Double tap to adjust brightness levels")
                .accessibilityValue(torchLevel > 0 ? "Flashlight is on at \(Int(torchLevel * 100)) percent" : "Flashlight is off")
                .symbolRenderingMode(.palette)
                .foregroundStyle(torchLevel > 0 ? .yellow : .primary)
                .font(.system(size: 20))
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial.opacity(0.15))
                        .overlay(
                            Circle()
                                .stroke(torchLevel > 0 ? Color.yellow.opacity(0.5) : Color.white.opacity(0.2), lineWidth: 1)
                        )
                )
        }
        .overlay(
            // Vertical preset buttons positioned with overlay
            Group {
                if showPresets {
                    VStack(spacing: 8) {
                        ForEach([100, 75, 50, 25], id: \.self) { percentage in
                            TorchPresetButton(
                                percentage: percentage,
                                isSelected: Int(torchLevel * 100) == percentage,
                                action: {
                                    let level = Float(percentage) / 100.0
                                    torchLevel = level
                                    onLevelChanged?(level)
                                    showPresets = false
                                }
                            )
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.ultraThinMaterial.opacity(0.8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                    )
                    .offset(y: -130) // Position just above the torch button
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                    .animation(.easeOut(duration: 0.1), value: showPresets)
                }
            },
            alignment: .top
        )
    }
}
