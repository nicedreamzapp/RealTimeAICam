import SwiftUI

struct SettingsOverlayView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Binding var isPresented: Bool
    let mode: AppMode
    let onAppear: (() -> Void)? = nil
    let onDisappear: (() -> Void)? = nil
    let onDismiss: (() -> Void)? = nil

    @StateObject private var buttonDebouncer = ButtonPressDebouncer()

    @State private var copyHistory: [String] = UserDefaults.standard.stringArray(forKey: "ocrCopyHistory") ?? []

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    if buttonDebouncer.canPress("SettingsOverlayView-1") {
                        onDismiss?()
                        withAnimation(.spring(response: 0.3)) {
                            isPresented = false
                        }
                    }
                }

            VStack(spacing: 0) {
                HStack {
                    Text("Settings")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Spacer()

                    Button(action: {
                        if buttonDebouncer.canPress("SettingsOverlayView-2") {
                            onDismiss?()
                            withAnimation(.spring(response: 0.3)) {
                                isPresented = false
                            }
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()

                Divider()
                    .opacity(0.5)

                ScrollView {
                    VStack(spacing: 20) {
                        if mode == .objectDetection {
                            VStack(alignment: .leading, spacing: 16) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: "eye.circle")
                                            .font(.system(size: 20))
                                            .foregroundStyle(.blue)

                                        Text("Detection Sensitivity")
                                            .font(.headline)

                                        Spacer()

                                        Text("\(Int(viewModel.confidenceThreshold * 100))%")
                                            .font(.system(.body, design: .rounded))
                                            .foregroundStyle(.secondary)
                                    }

                                    Slider(value: $viewModel.confidenceThreshold, in: 0.0001 ... 1.0)
                                        .accentColor(.blue)

                                    HStack {
                                        Text("More Objects")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text("Fewer Objects")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(.ultraThinMaterial.opacity(0.3))
                                )
                            }
                        }

                        if mode == .ocrEnglish || mode == .ocrSpanish {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "doc.on.clipboard")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.orange)

                                    Text("Copy History")
                                        .font(.headline)

                                    Spacer()

                                    if !copyHistory.isEmpty {
                                        Button("Clear") {
                                            if buttonDebouncer.canPress("SettingsOverlayView-3") {
                                                copyHistory.removeAll()
                                                UserDefaults.standard.removeObject(forKey: "ocrCopyHistory")
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                    }
                                }

                                if copyHistory.isEmpty {
                                    Text("No copied text yet")
                                        .font(.body)
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 20)
                                } else {
                                    VStack(spacing: 8) {
                                        ForEach(Array(copyHistory.enumerated()), id: \.offset) { _, text in
                                            HStack {
                                                Text(text)
                                                    .font(.system(.body, design: .monospaced))
                                                    .lineLimit(2)
                                                    .frame(maxWidth: .infinity, alignment: .leading)

                                                Button(action: {
                                                    if buttonDebouncer.canPress("SettingsOverlayView-4") {
                                                        UIPasteboard.general.string = text

                                                        let generator = UINotificationFeedbackGenerator()
                                                        generator.notificationOccurred(.success)
                                                    }
                                                }) {
                                                    Image(systemName: "doc.on.doc")
                                                        .font(.body)
                                                        .foregroundStyle(.blue)
                                                }
                                            }
                                            .padding(12)
                                            .background(
                                                RoundedRectangle(cornerRadius: 8)
                                                    .fill(.ultraThinMaterial.opacity(0.2))
                                            )
                                        }
                                    }
                                }
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.ultraThinMaterial.opacity(0.3))
                            )
                        }

                        if viewModel.currentZoomLevel > 1.05 || viewModel.currentZoomLevel < 0.95 {
                            HStack {
                                Image(systemName: "camera.viewfinder")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.purple)

                                Text("Camera Zoom")
                                    .font(.headline)

                                Spacer()

                                Text(String(format: "%.1fx", viewModel.currentZoomLevel))
                                    .font(.system(.title3, design: .rounded))
                                    .fontWeight(.medium)
                                    .foregroundStyle(.purple)
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(.ultraThinMaterial.opacity(0.3))
                            )
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.blue)

                                Text("Tips")
                                    .font(.headline)
                            }

                            if mode == .objectDetection {
                                Text("• 🤏 Pinch to zoom the camera")
                                Text("• 🗣️ Speak detected objects")
                                Text("• 🔦 Adjust flashlight")
                                Text("• 🌎 Toggle wide/ultra-wide lens")
                                Text("• ⚙️ Open settings")
                            } else {
                                Text("• 🤏 Pinch to zoom the camera")
                                Text("• 📋 Copy detected/translated text")
                                HStack {
                                    Image(systemName: "arrow.clockwise")
                                    Text("Reset/Stop — Clears text, translation, and stops speaking")
                                }
                                Text("• 🗣️ Speak detected/translated text")
                                Text("• 🔦 Adjust flashlight")
                                Text("• 🌎 Toggle wide/ultra-wide lens")
                                Text("• ⚙️ Open settings/history")
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.ultraThinMaterial.opacity(0.3))
                        )

                        PrivacyCardView()
                    }
                    .padding()
                }
            }
            .frame(maxWidth: 380, maxHeight: 600)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial.opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .shadow(radius: 20)
            .scaleEffect(isPresented ? 1 : 0.9)
            .opacity(isPresented ? 1 : 0)
        }
        .gesture(
            DragGesture().onEnded { value in
                if value.translation.height > 80, abs(value.translation.width) < 50 {
                    if buttonDebouncer.canPress("SettingsOverlayView-5") {
                        onDismiss?()
                        withAnimation(.spring(response: 0.3)) {
                            isPresented = false
                        }
                    }
                }
            }
        )
        .onAppear { onAppear?() }
        .onDisappear { onDisappear?() }
    }

    static func addToCopyHistory(_ text: String) {
        var history = UserDefaults.standard.stringArray(forKey: "ocrCopyHistory") ?? []

        history.removeAll { $0 == text }
        history.insert(text, at: 0)
        history = Array(history.prefix(5))

        UserDefaults.standard.set(history, forKey: "ocrCopyHistory")
    }
}

private struct PrivacyCardView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.green)
                Text("Private by Design")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Works 100% offline — even in Airplane Mode", systemImage: "airplane")
                Label("No tracking, no analytics, no accounts", systemImage: "eye.slash")
                Label("Camera frames are processed on-device only", systemImage: "camera.viewfinder")
                Label("Copy history stays on this device (you can clear it anytime)", systemImage: "doc.on.clipboard")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
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
}
