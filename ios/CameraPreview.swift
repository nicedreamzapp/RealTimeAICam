import AVFoundation
import CoreMedia
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
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "ocr.camera.session")
    private let videoQueue = DispatchQueue(label: "ocr.camera.video", qos: .userInitiated)

    var onFrame: ((CVPixelBuffer) -> Void)?
    var onCameraReady: ((AVCaptureDevice) -> Void)?

    /// Mail mode reads a whole sheet of paper at once, where the body text is a
    /// few percent of the frame. At 720p that's a handful of pixels per letter and
    /// the recognizer guesses. This switches the session to full photo resolution
    /// so a single still has real detail to work with.
    var useHighResolutionCapture = false
    private var photoCompletion: ((CGImage?) -> Void)?

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

        // Do NOT let the capture session touch the app audio session. Left on
        // (the default), resuming the camera after a scan flips the route to the
        // receiver and the spoken description comes out the quiet earpiece.
        session.automaticallyConfiguresApplicationAudioSession = false

        // 720p is plenty when you're pointing at a sign or a paragraph. It is NOT
        // enough for a full page — see useHighResolutionCapture.
        session.sessionPreset = useHighResolutionCapture ? .photo : .hd1280x720

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

        if useHighResolutionCapture, session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            // Asking a capture for full quality is only legal if the output was
            // told to allow it first. Without this line the capture request is
            // rejected with an exception rather than an error.
            // Allow the full range so a dark scene can use Night mode; per shot
            // we drop to .speed in good light for an instant shutter (capturePhoto).
            photoOutput.maxPhotoQualityPrioritization = .quality
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

        // Resolution has to be asked for AFTER the commit. Switching the preset to
        // .photo only changes the camera's active format when the configuration
        // lands, so a size read before that describes the 720p format we are
        // leaving — and a size the format doesn't support is refused at capture
        // time by throwing, which takes the whole app down.
        if useHighResolutionCapture, #available(iOS 16.0, *),
           let largest = currentDevice?.activeFormat.supportedMaxPhotoDimensions.last,
           largest.width > 0, largest.height > 0 {
            session.beginConfiguration()
            photoOutput.maxPhotoDimensions = largest
            session.commitConfiguration()
        }

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

    /// Brings the camera back after a pause (see `stopSession`). Used around a
    /// model run: the camera daemon alone holds ~1.5 GB while streaming, which on
    /// a 6 GB phone is the difference between answering and being jetsammed.
    func resumeSession() {
        sessionQueue.async { [weak self] in
            guard let self, !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stopSession() {
        print("📷 CameraPreviewView: Stopping camera session")
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            print("📷 CameraPreviewView: Camera session stopped")
        }
    }

    // MARK: - Still Capture

    /// Grabs one full-resolution frame. Reading a page is a deliberate act — aim,
    /// then capture — not something to sample thirty times a second off a video
    /// stream and hope a good frame shows up.
    func capturePhoto(completion: @escaping (CGImage?) -> Void) {
        guard useHighResolutionCapture, session.isRunning else {
            completion(nil)
            return
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }

            // Every one of these is a hard requirement of capturePhoto: miss one
            // and it throws instead of reporting failure. Checked here, on the
            // session queue, so the answer can't go stale between test and use.
            guard let connection = photoOutput.connection(with: .video), connection.isActive else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            // Point the still the way the phone is actually being held. The video
            // stream elsewhere is pinned to one angle, which is fine for a live
            // preview and wrong for a page — text that arrives sideways reads as
            // gibberish no matter how good the recognizer is.
            if #available(iOS 17.0, *), let device = currentDevice {
                let coordinator = AVCaptureDevice.RotationCoordinator(
                    device: device, previewLayer: nil
                )
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                if connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }

            let settings = AVCapturePhotoSettings()
            if #available(iOS 16.0, *) {
                // Mirror the output's own setting rather than asking for a size of
                // our own: whatever it currently holds is valid by definition.
                settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
            }
            // Never ask for more than the output was configured to allow — that
            // mismatch is itself a throwing offence.
            // Smart capture: instant single-frame in good light, but let the system
            // use its multi-frame Night mode when it is genuinely dark. The camera's
            // own ISO and exposure are the tell -- both climb in the dark. Without
            // this a night shot comes back near-black and the model can only say so.
            let iso = currentDevice?.iso ?? 0
            let exposure = currentDevice.map { CMTimeGetSeconds($0.exposureDuration) } ?? 0
            let dim = iso > 1000 || exposure > 0.08
            settings.photoQualityPrioritization = dim ? .quality : .speed
            // The flash decision belongs to the torch button the user already set.
            if photoOutput.supportedFlashModes.contains(.off) {
                settings.flashMode = .off
            }

            photoCompletion = completion
            photoOutput.capturePhoto(with: settings, delegate: self)
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

// MARK: - Photo Output Delegate

extension CameraPreviewView: AVCapturePhotoCaptureDelegate {
    func photoOutput(_: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let image: CGImage? = error == nil ? Self.uprightImage(from: photo) : nil
        DispatchQueue.main.async { [weak self] in
            let done = self?.photoCompletion
            self?.photoCompletion = nil
            done?(image)
        }
    }

    /// The recogniser reads pixels, not metadata, so a photo that merely *claims*
    /// to be rotated is still a sideways page to it. Bake the rotation in.
    private static func uprightImage(from photo: AVCapturePhoto) -> CGImage? {
        guard let data = photo.fileDataRepresentation(),
              let captured = UIImage(data: data) else {
            return photo.cgImageRepresentation()
        }
        if captured.imageOrientation == .up { return captured.cgImage }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1  // the image is already at full pixel size; don't multiply it
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: captured.size, format: format)
        let redrawn = renderer.image { _ in
            captured.draw(in: CGRect(origin: .zero, size: captured.size))
        }
        return redrawn.cgImage ?? captured.cgImage
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
