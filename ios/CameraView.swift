import AVFoundation
import SwiftUI

struct CameraView: UIViewRepresentable {
    @ObservedObject var viewModel: CameraViewModel

    func makeUIView(context _: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black

        // Configure preview layer
        viewModel.previewLayer.videoGravity = .resizeAspectFill
        viewModel.previewLayer.frame = view.bounds
        view.layer.addSublayer(viewModel.previewLayer)

        // Start camera session
        DispatchQueue.global(qos: .userInitiated).async {
            viewModel.startSession()
        }

        return view
    }

    func updateUIView(_ uiView: UIView, context _: Context) {
        // Update preview layer frame when view size changes
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            viewModel.previewLayer.frame = uiView.bounds
            CATransaction.commit()
        }
    }

    static func dismantleUIView(_: UIView, coordinator _: ()) {
        // View is being removed
    }
}
