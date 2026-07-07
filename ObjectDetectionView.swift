import AVFoundation
import CoreVideo
import SwiftUI

struct ObjectDetectionView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Binding var mode: AppMode
    @StateObject private var lidar = LiDARManager.shared
    @State private var showConfidenceSlider = false
    let orientation: UIDeviceOrientation
    let isPortrait: Bool
    let rotationAngle: Angle
    let onBack: () -> Void

    @ObservedObject var buttonDebouncer: ButtonPressDebouncer

    private var fpsColor: Color {
        switch viewModel.framesPerSecond {
        case 0 ..< 15: .red
        case 15 ..< 25: .orange
        case 25 ..< 30: .yellow
        default: .green
        }
    }

    private var objectCountColor: Color {
        switch viewModel.detectedObjectCount {
        case 0: .gray
        case 1 ... 3: .blue
        case 4 ... 6: .orange
        case 7 ... 10: .red
        default: .purple
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                CameraView(viewModel: viewModel)
                    .ignoresSafeArea()
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                viewModel.handlePinchGesture(value)
                            }
                            .onEnded { _ in
                                viewModel.setPinchGestureStartZoom()
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                if value > 0.98, value < 1.02 {
                                    viewModel.setPinchGestureStartZoom()
                                }
                            }
                    )

                DetectionOverlayView(
                    detectedObjects: viewModel.detections,
                    isPortrait: isPortrait,
                    orientation: orientation
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // Performance Overlay - Fixed positioning for both camera modes
                if isPortrait {
                    VStack {
                        HStack(alignment: .top) {
                            Button(action: {
                                guard buttonDebouncer.canPress("ObjectDetectionView-1") else { return }
                                // Encapsulated back action logic
                                viewModel.handleBackAction(onBack: onBack)
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                    Text("Back")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundColor(.white)
                                }
                                .padding(.vertical, 10)
                                .padding(.horizontal, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 20)
                                        .fill(.ultraThinMaterial)
                                        .opacity(0.85)
                                )
                            }
                            .padding(.leading, max(geometry.safeAreaInsets.leading + 16, 28))

                            Spacer()

                            // Right side - FPS indicator aligned at top with Back button
                            HStack(spacing: 10) {
                                HStack(spacing: 6) {
                                    Image(systemName: "speedometer")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(fpsColor)
                                    Text(String(format: "%.2f", viewModel.framesPerSecond))
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundColor(.white)
                                    Text("FPS")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.white.opacity(0.8))
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(.ultraThinMaterial)
                                        .opacity(0.55)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(fpsColor, lineWidth: 1.25)
                                        )
                                )
                                .fixedSize()
                                .layoutPriority(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.top, geometry.safeAreaInsets.top + 50)
                        .padding(.trailing, max(geometry.safeAreaInsets.trailing + 28, 36))

                        // Object count indicator below FPS
                        if viewModel.detectedObjectCount > 0 {
                            HStack {
                                Spacer()
                                HStack(spacing: 6) {
                                    Image(systemName: "eye")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(objectCountColor)
                                    Text("\(viewModel.detectedObjectCount)")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundColor(.white)
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(.ultraThinMaterial)
                                        .opacity(0.85)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(objectCountColor, lineWidth: 1.5)
                                        )
                                )
                                .padding(.trailing, max(geometry.safeAreaInsets.trailing + 28, 36))
                            }
                        }

                        Spacer()
                    }
                } else {
                    // Landscape performance display - consistent positioning
                    PerformanceOverlayView(
                        fps: viewModel.framesPerSecond,
                        objectCount: viewModel.detectedObjectCount,
                        isPortrait: isPortrait
                    )
                    .rotationEffect(rotationAngle)
                    .position(
                        x: geometry.size.width - max(30, geometry.size.width * 0.05),
                        y: max(120, geometry.size.height * 0.07)
                    )

                    // Landscape back button - consistent positioning and styled
                    Button(action: {
                        guard buttonDebouncer.canPress("ObjectDetectionView-2") else { return }
                        // Encapsulated back action logic
                        viewModel.handleBackAction(onBack: onBack)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                            Text("Back")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .padding(.vertical, 7)
                        .padding(.horizontal, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(.ultraThinMaterial)
                                .opacity(0.65)
                        )
                    }
                    .rotationEffect(rotationAngle)
                    .fixedSize()
                    .position(
                        x: max(40, geometry.size.width * 0.08),
                        y: min(60, geometry.size.height * 0.12)
                    )
                }

                if viewModel.currentZoomLevel > 1.05 || viewModel.currentZoomLevel < 0.95 {
                    VStack {
                        Text(String(format: "%.1fx", viewModel.currentZoomLevel))
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(.black.opacity(0.7))
                            )
                            .padding(.top, geometry.safeAreaInsets.top + 60)
                        Spacer()
                    }
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: viewModel.currentZoomLevel)
                }

                // LiDAR notification overlay
                Group {
                    if let message = viewModel.lidarNotificationMessage {
                        VStack {
                            Spacer()
                            HStack {
                                Image(systemName: "ruler")
                                    .font(.system(size: 16, weight: .medium))
                                Text(message)
                                    .font(.system(size: 15, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 20)
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 20)
                                            .fill(
                                                LinearGradient(
                                                    gradient: Gradient(colors: [
                                                        Color.white.opacity(0.25),
                                                        Color.white.opacity(0.05),
                                                    ]),
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 20)
                                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                                    )
                                    .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
                            )
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                            .animation(.spring(response: 0.3), value: viewModel.lidarNotificationMessage)
                            Spacer()
                        }
                        .rotationEffect(isPortrait ? .zero : rotationAngle)
                        .padding(.bottom, isPortrait ? 10 : 0)
                        .padding(.leading, isPortrait ? 0 : 12)
                    }
                }

                if isPortrait {
                    portraitOverlays(geometry: geometry)
                } else {
                    landscapeOverlays(geometry: geometry)
                }
            }
        }
        .onAppear {
            LiDARManager.shared.recheckSupport()
            viewModel.reinitialize()
            viewModel.startSession()
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    // Camera access granted
                }
            }
        }
        .onChange(of: lidar.isAvailable) { newValue in
            if viewModel.useLiDAR, !newValue {
                viewModel.setLiDAR(enabled: false)
                viewModel.showLiDARNotification("LiDAR not available in \(viewModel.isUltraWide ? "ultra-wide" : "this") mode")
            }
        }
        .onChange(of: viewModel.isUltraWide) { _ in
            if viewModel.useLiDAR, lidar.isEnabled, !lidar.isAvailable {
                viewModel.setLiDAR(enabled: false)
                viewModel.showLiDARNotification("LiDAR only works with 1x camera")
            }
        }
        .onChange(of: viewModel.currentZoomLevel) { newValue in
            if viewModel.useLiDAR, lidar.isEnabled, lidar.isAvailable {
                if newValue < 0.95 || newValue > 1.05 {
                    viewModel.setLiDAR(enabled: false)
                    viewModel.showLiDARNotification("LiDAR works best at 1x zoom")
                }
            }
        }
    }

    @ViewBuilder
    private func portraitOverlays(geometry: GeometryProxy) -> some View {
        Spacer()
        Color.clear
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    // Segmented control - adaptive width
                    GeometryReader { geo in
                        let safeHorizontal = max(geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing, 0)
                        let availableWidth = geo.size.width - safeHorizontal - 32
                        let segmentWidth = min(availableWidth, 560)

                        HStack {
                            Spacer()
                            Picker("Mode", selection: $viewModel.filterMode) {
                                Text("All").tag("all")
                                Text("Indoor").tag("indoor")
                                Text("Outdoor").tag("outdoor")
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .frame(width: segmentWidth, height: 36)
                            Spacer()
                        }
                    }
                    .frame(height: 36)

                    // Adaptive button layout with robust spacing
                    let screenWidth = geometry.size.width
                    let safeHorizontal = max(geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing, 0)

                    // Only adjust for truly small screens (iPhone 12/13 mini and smaller)
                    let isVerySmallScreen = screenWidth <= 375
                    let buttonSize: CGFloat = isVerySmallScreen ? 40 : 44
                    let horizontalPadding: CGFloat = isVerySmallScreen ? 24 : 20
                    let totalHorizontalPadding = safeHorizontal + (horizontalPadding * 2)
                    let availableButtonSpace = screenWidth - totalHorizontalPadding

                    // Calculate optimal spacing
                    let buttonCount: CGFloat = 6
                    let totalButtonWidth = buttonCount * buttonSize
                    let remainingSpace = availableButtonSpace - totalButtonWidth
                    let idealSpacing = remainingSpace / (buttonCount - 1)
                    let finalSpacing = idealSpacing >= 12 ? min(20, idealSpacing) : max(6, idealSpacing)

                    HStack(spacing: finalSpacing) {
                        controlButton(
                            systemName: "camera.rotate",
                            foregroundColor: .primary,
                            size: 22,
                            frameSize: buttonSize,
                            action: {
                                guard buttonDebouncer.canPress("ObjectDetectionView-3") else { return }
                                viewModel.handleFlipCamera()
                            }
                        )
                        .accessibilityLabel("Switch Camera")
                        .accessibilityHint("Switches between front and rear camera")
                        .accessibilityValue(viewModel.cameraPosition == .back ? "Using rear camera" : "Using front camera")

                        controlButton(
                            systemName: "rectangle.3.offgrid",
                            foregroundColor: viewModel.isUltraWide ? .cyan : .primary,
                            size: 22,
                            frameSize: buttonSize,
                            action: {
                                guard buttonDebouncer.canPress("ObjectDetectionView-4") else { return }
                                viewModel.handleToggleCameraZoom()
                            }
                        )
                        .opacity(viewModel.cameraPosition == .back ? 1.0 : 0.0)
                        .disabled(viewModel.cameraPosition == .front)
                        .accessibilityLabel(viewModel.isUltraWide ? "Switch to normal camera" : "Switch to wide angle camera")
                        .accessibilityHint("Changes camera field of view for wider or normal view")

                        TorchButton(
                            initialTorchLevel: viewModel.currentTorchLevel,
                            onLevelChanged: { level in viewModel.currentTorchLevel = level }
                        )
                        .frame(width: buttonSize, height: buttonSize)
                        .opacity(viewModel.cameraPosition == .back ? 1.0 : 0.0)
                        .disabled(viewModel.cameraPosition == .front)

                        controlButton(
                            systemName: "ruler",
                            foregroundColor: viewModel.useLiDAR && LiDARManager.shared.isEnabled ? .green : .blue,
                            size: 22,
                            frameSize: buttonSize,
                            action: {
                                guard buttonDebouncer.canPress("ObjectDetectionView-5") else { return }
                                let newState = !viewModel.useLiDAR
                                viewModel.setLiDAR(enabled: newState)
                                if newState {
                                    viewModel.showLiDARNotification("LiDAR distance enabled")
                                } else {
                                    viewModel.showLiDARNotification("LiDAR distance disabled")
                                }
                            }
                        )
                        .opacity(viewModel.isLiDARSupported && viewModel.cameraPosition == .back && LiDARManager.shared.isAvailable ? 1.0 : 0.0)
                        .disabled(!(viewModel.isLiDARSupported && viewModel.cameraPosition == .back && LiDARManager.shared.isAvailable))

                        Button(action: {
                            guard buttonDebouncer.canPress("ObjectDetectionView-6") else { return }
                            viewModel.handleToggleSpeech()
                        }) {
                            Text("🗣️")
                                .font(.system(size: isVerySmallScreen ? 18 : 20, weight: .medium))
                                .frame(width: buttonSize, height: buttonSize)
                                .background(
                                    Circle()
                                        .fill(.ultraThinMaterial.opacity(0.15))
                                        .background(Circle().fill(Color.black.opacity(0.25)))
                                )
                                .overlay(
                                    Circle()
                                        .stroke(
                                            viewModel.isSpeechEnabled ? Color.green.opacity(0.5) : Color.white.opacity(0.25),
                                            lineWidth: viewModel.isSpeechEnabled ? 2 : 1
                                        )
                                )
                                .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
                                .foregroundColor(viewModel.isSpeechEnabled ? .black : .primary)
                        }
                        .accessibilityLabel(viewModel.isSpeechEnabled ? "Turn off speech announcements" : "Turn on speech announcements")
                        .accessibilityHint("Controls automatic object detection announcements")
                        .accessibilityValue(viewModel.isSpeechEnabled ? "Speech enabled" : "Speech disabled")

                        Button(action: {
                            guard buttonDebouncer.canPress("ObjectDetectionView-7") else { return }
                            withAnimation(.spring(response: 0.3)) {
                                showConfidenceSlider.toggle()
                            }
                        }) {
                            VStack(spacing: 2) {
                                Image(systemName: "eye")
                                    .font(.system(size: isVerySmallScreen ? 18 : 20, weight: .medium))
                                Text("\(Int(viewModel.confidenceThreshold * 100))%")
                                    .font(.system(size: isVerySmallScreen ? 12 : 14, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(.primary)
                            .frame(width: buttonSize, height: buttonSize)
                            .background(.ultraThinMaterial.opacity(0.20))
                            .background(Circle().fill(Color.black.opacity(0.25)))
                            .clipShape(Circle())
                        }
                        .overlay(
                            confidenceSliderOverlay(isPortrait: true)
                        )
                    }
                    .padding(.horizontal, horizontalPadding + max(geometry.safeAreaInsets.leading, geometry.safeAreaInsets.trailing))
                    .padding(.bottom, 32)
                }
                .background(.black.opacity(0.001))
            }
    }

    @ViewBuilder
    private func landscapeOverlays(geometry: GeometryProxy) -> some View {
        HStack(spacing: 12) {
            Spacer()

            controlButton(
                systemName: "camera.rotate",
                foregroundColor: .primary,
                size: 24,
                frameSize: 48,
                action: {
                    guard buttonDebouncer.canPress("ObjectDetectionView-8") else { return }
                    viewModel.handleFlipCamera()
                }
            )
            .accessibilityLabel("Switch Camera")
            .accessibilityHint("Switches between front and rear camera")
            .accessibilityValue(viewModel.cameraPosition == .back ? "Using rear camera" : "Using front camera")

            // Ultra-wide button - hidden but maintains space in front camera
            controlButton(
                systemName: "rectangle.3.offgrid",
                foregroundColor: viewModel.isUltraWide ? .cyan : .primary,
                size: 24,
                frameSize: 48,
                action: {
                    guard buttonDebouncer.canPress("ObjectDetectionView-9") else { return }
                    viewModel.handleToggleCameraZoom()
                }
            )
            .opacity(viewModel.cameraPosition == .back ? 1.0 : 0.0)
            .disabled(viewModel.cameraPosition == .front)
            .accessibilityLabel(viewModel.isUltraWide ? "Switch to normal camera" : "Switch to wide angle camera")
            .accessibilityHint("Changes camera field of view for wider or normal view")

            // TorchButton properly connected to viewModel
            TorchButton(
                initialTorchLevel: viewModel.currentTorchLevel,
                onLevelChanged: { level in
                    viewModel.currentTorchLevel = level
                }
            )
            .frame(width: 48, height: 48)
            .opacity(viewModel.cameraPosition == .back ? 1.0 : 0.0)
            .disabled(viewModel.cameraPosition == .front)

            // LiDAR button - hidden but maintains space when not available
            controlButton(
                systemName: "ruler",
                foregroundColor: viewModel.useLiDAR && LiDARManager.shared.isEnabled ? .green : .blue,
                size: 24,
                frameSize: 48,
                action: {
                    guard buttonDebouncer.canPress("ObjectDetectionView-10") else { return }
                    let newState = !viewModel.useLiDAR
                    viewModel.setLiDAR(enabled: newState)
                    if newState {
                        viewModel.showLiDARNotification("LiDAR distance enabled")
                    } else {
                        viewModel.showLiDARNotification("LiDAR distance disabled")
                    }
                }
            )
            .opacity(viewModel.isLiDARSupported && viewModel.cameraPosition == .back && LiDARManager.shared.isAvailable ? 1.0 : 0.0)
            .disabled(!(viewModel.isLiDARSupported && viewModel.cameraPosition == .back && LiDARManager.shared.isAvailable))
            .accessibilityLabel(
                viewModel.useLiDAR ? "Turn off LiDAR distance measurement" : "Turn on LiDAR distance measurement"
            )
            .accessibilityHint("Measures distance to detected objects")

            Button(action: {
                guard buttonDebouncer.canPress("ObjectDetectionView-11") else { return }
                viewModel.handleToggleSpeech()
            }) {
                Text("🗣️")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 48, height: 48)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                            .opacity(0.15)
                            .background(Circle().fill(Color.black.opacity(0.25)))
                    )
                    .overlay(
                        Circle()
                            .stroke(
                                viewModel.isSpeechEnabled
                                    ? Color.green.opacity(0.5)
                                    : Color.white.opacity(0.25),
                                lineWidth: viewModel.isSpeechEnabled ? 2 : 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.18), radius: 4, y: 2)
                    .foregroundColor(viewModel.isSpeechEnabled ? .black : .primary)
            }
            .accessibilityLabel(viewModel.isSpeechEnabled ? "Turn off speech announcements" : "Turn on speech announcements")
            .accessibilityHint("Controls automatic object detection announcements")
            .accessibilityValue(viewModel.isSpeechEnabled ? "Speech enabled" : "Speech disabled")

            Button(action: {
                guard buttonDebouncer.canPress("ObjectDetectionView-12") else { return }
                withAnimation(.spring(response: 0.3)) {
                    showConfidenceSlider.toggle()
                }
            }) {
                VStack(spacing: 2) {
                    Image(systemName: "eye")
                        .font(.system(size: 22, weight: .medium))
                    Text("\(Int(viewModel.confidenceThreshold * 100))%")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundColor(.primary)
                .frame(width: 48, height: 48)
                .background(.ultraThinMaterial.opacity(0.20))
                .background(Circle().fill(Color.black.opacity(0.25)))
                .clipShape(Circle())
            }
            .overlay(
                confidenceSliderOverlay(isPortrait: false)
            )

            Picker("Mode", selection: $viewModel.filterMode) {
                Text("All").tag("all")
                Text("Indoor").tag("indoor")
                Text("Outdoor").tag("outdoor")
            }
            .pickerStyle(SegmentedPickerStyle())
            .frame(width: 200)

            Spacer()
        }
        .padding(.horizontal, 32)
        .rotationEffect(rotationAngle)
        .fixedSize()
        .position(
            x: max(40, geometry.size.width * 0.05),
            y: geometry.size.height - max(235, geometry.size.height * 0.45)
        )
    }

    private func controlButton(
        systemName: String,
        foregroundColor: Color = .primary,
        size: CGFloat = 26,
        frameSize: CGFloat = 60,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size))
                .foregroundStyle(foregroundColor)
                .symbolRenderingMode(.palette)
                .frame(width: frameSize, height: frameSize)
                .background(
                    Circle()
                        .fill(.ultraThinMaterial.opacity(0.15))
                        .background(Circle().fill(Color.black.opacity(0.25)))
                )
                .contentShape(Circle())
        }
    }

    @ViewBuilder
    private func confidenceSliderOverlay(isPortrait: Bool) -> some View {
        if showConfidenceSlider {
            Group {
                if isPortrait {
                    VStack(spacing: 8) {
                        Slider(value: $viewModel.confidenceThreshold, in: 0.0001 ... 1.0, onEditingChanged: { editing in
                            if !editing {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    showConfidenceSlider = false
                                }
                            }
                        })
                        .accentColor(.blue)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 160, height: 32)
                        Text("\(Int(viewModel.confidenceThreshold * 100))%")
                            .font(.caption.bold())
                            .foregroundColor(.primary)
                    }
                } else {
                    VStack(spacing: 8) {
                        Slider(value: $viewModel.confidenceThreshold, in: 0.0001 ... 1.0, onEditingChanged: { editing in
                            if !editing {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    showConfidenceSlider = false
                                }
                            }
                        })
                        .accentColor(.blue)
                        .frame(width: 160, height: 32)
                        Text("\(Int(viewModel.confidenceThreshold * 100))%")
                            .font(.caption.bold())
                            .foregroundColor(.primary)
                    }
                }
            }
            .padding(10)
            .shadow(radius: 8)
            .offset(y: isPortrait ? -90 : -60)
            .transition(.scale.combined(with: .opacity))
        }
    }
}

private extension CameraViewModel {
    func handleBackAction(onBack: () -> Void) {
        stopSession()
        clearDetections()
        stopSpeech()
        SpeechManager.shared.stopSpeech()
        SpeechManager.shared.resetSpeechState()
        onBack()
    }
}
