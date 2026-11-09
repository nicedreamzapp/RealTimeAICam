import ImageIO
import UIKit
import UniformTypeIdentifiers

/// "Share to RealTime AI Cam" from Photos, Messages, WhatsApp, Safari...
///
/// The extension never runs a model: share extensions get about 120 MB, the
/// picture model needs far more. It only writes the picture (long side at most
/// 2048 px, JPEG) into the App Group container and opens the app with
/// `rtcam://shared-image?id=<file id>`; the app describes it there.
final class ShareViewController: UIViewController {
    /// Same group as the app's entitlements (group.<app bundle id>).
    static let appGroup = "group.B9RA6QH559.project-601"
    static let folderName = "SharedImages"
    static let maxPixels = 2048

    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark

        spinner.color = .white
        spinner.startAnimating()
        spinner.isAccessibilityElement = false

        label.text = NSLocalizedString("Opening RealTime AI Cam…", comment: "Share extension, while the app opens")
        label.textColor = .white
        label.font = UIFont.preferredFont(forTextStyle: .title2)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [spinner, label])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibility.post(notification: .screenChanged, argument: label.text)
        guard !started else { return }
        started = true
        Task { await handleShare() }
    }

    private func handleShare() async {
        guard let provider = imageProvider() else {
            return fail(NSLocalizedString("That picture couldn't be opened.", comment: "Share extension error"))
        }
        guard let id = await saveImage(from: provider) else {
            return fail(NSLocalizedString("That picture couldn't be opened.", comment: "Share extension error"))
        }
        var parts = URLComponents()
        parts.scheme = "rtcam"
        parts.host = "shared-image"
        parts.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = parts.url else { return finish() }
        openApp(url)
        // A moment for the system to hand over to the app before the sheet closes.
        try? await Task.sleep(nanoseconds: 300_000_000)
        finish()
    }

    /// The first attachment that is a picture.
    private func imageProvider() -> NSItemProvider? {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        for item in items {
            for provider in item.attachments ?? [] where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                return provider
            }
        }
        return nil
    }

    /// Writes the picture into the App Group and returns its id, or nil when it can't be read.
    private func saveImage(from provider: NSItemProvider) async -> String? {
        guard let folder = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)?
            .appendingPathComponent(Self.folderName, isDirectory: true)
        else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let id = UUID().uuidString
        let target = folder.appendingPathComponent(id).appendingPathExtension("jpg")

        // Ask for a file first: ImageIO downsizes straight from disk, so a
        // 48 MP photo never has to be decoded whole inside the extension.
        let jpeg: Data? = await withCheckedContinuation { done in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                if let url, let data = Self.downsizedJPEG(from: url) {
                    done.resume(returning: data)
                } else {
                    done.resume(returning: nil)
                }
            }
        }
        let data: Data?
        if let jpeg {
            data = jpeg
        } else {
            // Some apps only hand over a UIImage or raw bytes.
            data = await withCheckedContinuation { done in
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                    var out: Data?
                    if let url = item as? URL {
                        out = Self.downsizedJPEG(from: url)
                    } else if let bytes = item as? Data {
                        out = Self.downsizedJPEG(from: bytes)
                    } else if let image = item as? UIImage {
                        out = Self.downsizedJPEG(from: image)
                    }
                    done.resume(returning: out)
                }
            }
        }
        guard let data else { return nil }
        do {
            try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return id
        } catch {
            return nil
        }
    }

    private static let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true, // keep the photo upright
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        kCGImageSourceShouldCacheImmediately: true,
    ]

    private static func downsizedJPEG(from url: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return jpeg(from: source)
    }

    private static func downsizedJPEG(from bytes: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return jpeg(from: source)
    }

    private static func jpeg(from source: CGImageSource) -> Data? {
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.88)
    }

    private static func downsizedJPEG(from image: UIImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, CGFloat(maxPixels) / max(size.width * image.scale, size.height * image.scale))
        let target = CGSize(width: (size.width * image.scale * scale).rounded(),
                            height: (size.height * image.scale * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.88)
    }

    /// Share extensions have no `UIApplication.shared`; the app object is still
    /// at the top of the responder chain, and asking it to open the URL is the
    /// standard way an extension hands over to its own app.
    private func openApp(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }

    private func fail(_ message: String) {
        spinner.stopAnimating()
        label.text = message
        UIAccessibility.post(notification: .announcement, argument: message)
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            finish()
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
