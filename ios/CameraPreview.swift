import AVFoundation
import SwiftUI

// MARK: - Camera Preview for OCR

struct CameraPreview: UIViewRepresentable {
    let onFrame: (CVPixelBuffer) -> Void
    var onCameraReady: ((AVCaptureDevice) -> Void)?
    var isUltraWide: Bool = false
    var cameraPosition: AVCaptureDevice.Position = .back

    func makeUIView(context _: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.onFrame = onFrame
        view.onCameraReady = onCameraReady
        view.isUltraWide = isUltraWide
        view.cameraPosition = cameraPosition
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context _: Context) {
        // Check if camera settings changed
        if uiView.isUltraWide != isUltraWide || uiView.cameraPosition != cameraPosition {
            uiView.isUltraWide = isUltraWide
            uiView.cameraPosition = cameraPosition
            uiView.reconfigureCamera()
        }
    }

    static func dismantleUIView(_ uiView: CameraPreviewView, coordinator _: ()) {
        uiView.stopSession()
    }
}

// MARK: - Camera Preview UIView

class CameraPreviewView: UIView {
    // Add a callback for when the view is ready

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "ocr.camera.session")
    private let videoQueue = DispatchQueue(label: "ocr.camera.video", qos: .userInitiated)

    var onFrame: ((CVPixelBuffer) -> Void)?
    var onCameraReady: ((AVCaptureDevice) -> Void)?

    private var currentDevice: AVCaptureDevice?
    private var focusIndicatorLayer: CALayer?
    private var isPaused = false
    var isUltraWide: Bool = false
    var cameraPosition: AVCaptureDevice.Position = .back

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupCamera()
        setupFocusIndicator()
        setupTapGesture()
        // Notify that view is ready
        DispatchQueue.main.async { [weak self] in
            if let self {
            }
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCamera()
        setupFocusIndicator()
        setupTapGesture()
        // Notify that view is ready
        DispatchQueue.main.async { [weak self] in
            if let self {
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    private var previewLayer: AVCaptureVideoPreviewLayer? {
        layer as? AVCaptureVideoPreviewLayer
    }

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    // MARK: - Focus Features

    private func setupFocusIndicator() {
        let focusLayer = CALayer()
        focusLayer.frame = CGRect(x: 0, y: 0, width: 80, height: 80)
        focusLayer.borderColor = UIColor.systemYellow.cgColor
        focusLayer.borderWidth = 2.0
        focusLayer.cornerRadius = 4.0
        focusLayer.opacity = 0
        layer.addSublayer(focusLayer)
        focusIndicatorLayer = focusLayer
    }

    private func setupTapGesture() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus(_:)))
        addGestureRecognizer(tapGesture)
    }

    @objc private func handleTapToFocus(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        focusAtPoint(location)
    }

    private func focusAtPoint(_ point: CGPoint) {
        guard let device = currentDevice,
              let previewLayer else { return }

        // Convert UI point to camera point
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)

        // Configure focus
        do {
            try device.lockForConfiguration()

            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }

            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }

            device.unlockForConfiguration()

            // Show focus animation
            showFocusAnimation(at: point)

            // Return to continuous autofocus after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.resetToContinuousAutoFocus()
            }

        } catch {
            // Removed print statement
        }
    }

    private func showFocusAnimation(at point: CGPoint) {
        guard let focusLayer = focusIndicatorLayer else { return }

        // Position the focus indicator
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusLayer.position = point
        focusLayer.opacity = 0
        focusLayer.transform = CATransform3DMakeScale(1.5, 1.5, 1.0)
        CATransaction.commit()

        // Animate the focus indicator
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)

        // Scale down animation
        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = 1.5
        scaleAnimation.toValue = 1.0
        scaleAnimation.duration = 0.3

        // Fade in then out animation
        let opacityAnimation = CAKeyframeAnimation(keyPath: "opacity")
        opacityAnimation.values = [0, 1, 1, 0]
        opacityAnimation.keyTimes = [0, 0.2, 0.8, 1]
        opacityAnimation.duration = 1.5

        focusLayer.add(scaleAnimation, forKey: "scale")
        focusLayer.add(opacityAnimation, forKey: "opacity")

        CATransaction.commit()

        // Haptic feedback
        let impactFeedback = UIImpactFeedbackGenerator(style: .light)
        impactFeedback.impactOccurred()
    }

    private func resetToContinuousAutoFocus() {
        guard let device = currentDevice else { return }

        do {
            try device.lockForConfiguration()

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }

            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }

            device.unlockForConfiguration()
        } catch {
            // Removed print statement
        }
    }

    // MARK: - Camera Setup

    private func setupCamera() {
        sessionQueue.async { [weak self] in
            self?.configureSession()
        }
    }

    private func configureSession() {
        session.beginConfiguration()

        // Configure session preset for OCR (lower resolution is fine)
        session.sessionPreset = .hd1280x720

        // Select camera based on position and wide angle setting
        let camera: AVCaptureDevice? = if cameraPosition == .front {
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        } else {
            // Back camera - check for ultra wide
            if isUltraWide {
                AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                    ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            } else {
                AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            }
        }

        guard let camera else {
            // Removed print statement
            session.commitConfiguration()
            return
        }

        currentDevice = camera

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) {
                session.addInput(input)

                // Configure camera for optimal focus
                try camera.lockForConfiguration()

                // Set continuous autofocus as default
                if camera.isFocusModeSupported(.continuousAutoFocus) {
                    camera.focusMode = .continuousAutoFocus
                }

                // Set continuous auto exposure
                if camera.isExposureModeSupported(.continuousAutoExposure) {
                    camera.exposureMode = .continuousAutoExposure
                }

                // Enable auto focus range restriction for close-up text when available
                if camera.isAutoFocusRangeRestrictionSupported {
                    camera.autoFocusRangeRestriction = .none // Will detect automatically
                }

                camera.unlockForConfiguration()

                // Notify that camera is ready
                DispatchQueue.main.async { [weak self] in
                    self?.onCameraReady?(camera)
                }
            }
        } catch {
            // Removed print statement
            session.commitConfiguration()
            return
        }

        // Configure video output
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true

        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        // Set video orientation
        if let connection = videoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) {
                // Use videoRotationAngle and isVideoRotationAngleSupported(_:) on iOS 17+
                if connection.isVideoRotationAngleSupported(0) {
                    connection.videoRotationAngle = 0 // 0 degrees = portrait
                }
            } else {
                // Fallback on earlier versions
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }
        }

        session.commitConfiguration()

        // Configure preview layer
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let previewLayer = layer as? AVCaptureVideoPreviewLayer {
                previewLayer.session = session
                previewLayer.videoGravity = .resizeAspectFill
            }
        }

        // Start session
        session.startRunning()
    }

    func stopSession() {
        print("📷 CameraPreviewView: Stopping camera session")
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            print("📷 CameraPreviewView: Camera session stopped")
        }
    }

    // MARK: - Torch Control

    func setTorchLevel(_ level: Float) {
        guard let device = currentDevice,
              device.hasTorch else { return }

        do {
            try device.lockForConfiguration()

            if level > 0 {
                try device.setTorchModeOn(level: level)
            } else {
                device.torchMode = .off
            }

            device.unlockForConfiguration()
        } catch {
            // Removed print statement
        }
    }


    func reconfigureCamera() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            session.stopRunning()

            // Remove all inputs
            session.inputs.forEach { self.session.removeInput($0) }

            // Reconfigure with new settings
            configureSession()

            session.startRunning()
        }
    }
}

// MARK: - Video Output Delegate

extension CameraPreviewView: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
        guard !isPaused else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }
}
