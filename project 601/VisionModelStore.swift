import Combine
import CryptoKit
import Foundation

/// Where the vision model lives, and how it gets there.
///
/// Lookup order, first hit wins:
///   1. a `VisionModel` folder bundled inside the app (the way v4 ships today);
///   2. `<Application Support>/VisionModel`, but only when every file in its
///      `manifest.json` is present at the byte size the manifest says.
///
/// Nothing here ever reaches the network except ``VisionModelDownloader``, and
/// that only when the user taps the download button. Once the folder is on the
/// phone the app is as offline as it has always been.
enum VisionModelStore {
    /// Folder that holds the manifest and the weights. Change this one line to
    /// move the model to a different host or version.
    static let baseURL = URL(string: "https://ineedhemp.com/models/visionmodel/v4-q4all/")!

    static let manifestName = "manifest.json"
    static let folderName = "VisionModel"

    /// Rough size shown to the user before they commit to the download.
    /// 1.2 GB was the 2B model. The bundle now carries the 0.8B at 4-bit,
    /// which is 622 MB on disk (596 MB of weights). Telling a blind user on
    /// cellular that a download is twice its real size is its own bug.
    static let approximateSizeDescription = "622 MB"

    struct Manifest: Codable, Equatable {
        struct File: Codable, Equatable {
            let name: String
            let size: Int64
            let sha256: String?
        }
        let version: String
        let files: [File]
        var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    // MARK: - Lookup

    /// The folder to load weights from, or `nil` when the model is nowhere.
    static var installedURL: URL? {
        if let bundled = Bundle.main.url(forResource: folderName, withExtension: nil) {
            return bundled
        }
        let downloaded = downloadedURL
        if isComplete(at: downloaded) { return downloaded }
        return nil
    }

    static var isInstalled: Bool { installedURL != nil }

    /// `<Application Support>/VisionModel`
    static var downloadedURL: URL {
        applicationSupport.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Where files land while they are being fetched; renamed to
    /// ``downloadedURL`` in one move once everything checks out.
    static var stagingURL: URL {
        applicationSupport.appendingPathComponent(folderName + ".partial", isDirectory: true)
    }

    private static var applicationSupport: URL {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        return dir
    }

    /// True when the folder carries a manifest and every listed file is there
    /// at exactly the listed size. Hashes are checked once, at install time.
    static func isComplete(at folder: URL) -> Bool {
        guard let manifest = readManifest(at: folder) else { return false }
        return manifest.files.allSatisfy { fileIsComplete($0, in: folder) }
    }

    static func readManifest(at folder: URL) -> Manifest? {
        let url = folder.appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    static func fileIsComplete(_ file: Manifest.File, in folder: URL) -> Bool {
        fileSize(at: folder.appendingPathComponent(file.name)) == file.size
    }

    static func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// Streams the file through SHA-256; lowercase hex.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 4 * 1024 * 1024)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Downloader

/// Fetches the model folder once, file by file, on a background `URLSession`
/// so the transfer keeps going when the app is put away. Files that are
/// already complete in the staging folder are skipped, so a second tap after
/// an interruption picks up where it left off.
@MainActor
final class VisionModelDownloader: NSObject, ObservableObject {
    static let shared = VisionModelDownloader()

    enum State: Equatable {
        case idle
        case downloading
        case verifying
        case ready
        case failed(String)
    }

    /// 0…1 across every byte in the manifest.
    @Published private(set) var progress: Double = 0
    @Published private(set) var state: State = VisionModelStore.isInstalled ? .ready : .idle

    static let sessionIdentifier = "com.nicedreamz.visionmodel"

    private var manifest: VisionModelStore.Manifest?
    /// Bytes known to be on disk (or received so far) per file name.
    private var received: [String: Int64] = [:]
    /// File names still owed by the session.
    private var pending: Set<String> = []
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: relay, delegateQueue: nil)
    }()
    private lazy var relay = Relay(owner: self)

    private override init() { super.init() }

    /// Kicks off (or resumes) the download. Safe to call again after a failure.
    func start() {
        guard state == .idle || { if case .failed = state { return true } else { return false } }() else { return }
        if VisionModelStore.isInstalled {
            state = .ready
            progress = 1
            return
        }
        state = .downloading
        progress = 0
        Task { await fetchManifestAndQueue() }
    }

    // MARK: Manifest

    private func fetchManifestAndQueue() async {
        let manifestURL = VisionModelStore.baseURL.appendingPathComponent(VisionModelStore.manifestName)
        do {
            let (data, response) = try await URLSession.shared.data(from: manifestURL)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw DownloadError.http(http.statusCode, VisionModelStore.manifestName)
            }
            let manifest = try JSONDecoder().decode(VisionModelStore.Manifest.self, from: data)
            guard !manifest.files.isEmpty else { throw DownloadError.emptyManifest }
            let staging = VisionModelStore.stagingURL
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try data.write(to: staging.appendingPathComponent(VisionModelStore.manifestName), options: .atomic)
            self.manifest = manifest
            queueMissingFiles(manifest, in: staging)
        } catch {
            fail(Self.describe(error))
        }
    }

    private func queueMissingFiles(_ manifest: VisionModelStore.Manifest, in staging: URL) {
        received = [:]
        pending = []
        for file in manifest.files {
            if VisionModelStore.fileIsComplete(file, in: staging) {
                received[file.name] = file.size
            } else {
                // A stale partial or wrong-size file is thrown away; the
                // session re-downloads it whole.
                try? FileManager.default.removeItem(at: staging.appendingPathComponent(file.name))
                received[file.name] = 0
                pending.insert(file.name)
            }
        }
        publishProgress()
        if pending.isEmpty {
            Task { await verifyAndInstall() }
            return
        }
        // Don't double-queue anything the session is already carrying from a
        // previous run of the app.
        session.getAllTasks { [weak self] tasks in
            let inFlight = Set(tasks.compactMap { $0.taskDescription })
            Task { @MainActor [weak self] in
                guard let self else { return }
                for name in self.pending where !inFlight.contains(name) {
                    let task = self.session.downloadTask(with: VisionModelStore.baseURL.appendingPathComponent(name))
                    task.taskDescription = name
                    task.resume()
                }
            }
        }
    }

    // MARK: Progress

    private func publishProgress() {
        guard let manifest, manifest.totalBytes > 0 else { progress = 0; return }
        let done = received.values.reduce(0, +)
        progress = min(1, Double(done) / Double(manifest.totalBytes))
    }

    fileprivate func fileProgressed(name: String, bytes: Int64) {
        guard state == .downloading else { return }
        received[name] = bytes
        publishProgress()
    }

    /// Called once the relay has moved the finished file into staging.
    fileprivate func fileFinished(name: String, error: Error?) {
        guard state == .downloading else { return }
        if let error {
            fail(Self.describe(error, file: name))
            return
        }
        guard let file = manifest?.files.first(where: { $0.name == name }) else { return }
        received[name] = file.size
        pending.remove(name)
        publishProgress()
        if pending.isEmpty {
            Task { await verifyAndInstall() }
        }
    }

    // MARK: Verify + install

    private func verifyAndInstall() async {
        guard let manifest else { return }
        state = .verifying
        let staging = VisionModelStore.stagingURL
        let final = VisionModelStore.downloadedURL
        let outcome: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            do {
                for file in manifest.files {
                    let url = staging.appendingPathComponent(file.name)
                    guard VisionModelStore.fileSize(at: url) == file.size else {
                        throw DownloadError.sizeMismatch(file.name)
                    }
                    if let expected = file.sha256, !expected.isEmpty {
                        let actual = try VisionModelStore.sha256Hex(of: url)
                        guard actual.lowercased() == expected.lowercased() else {
                            throw DownloadError.hashMismatch(file.name)
                        }
                    }
                }
                let fm = FileManager.default
                if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
                try fm.moveItem(at: staging, to: final)
                var keepOut = final
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? keepOut.setResourceValues(values)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        switch outcome {
        case .success:
            progress = 1
            state = .ready
        case .failure(let error):
            // A bad file must not be trusted next time round.
            if case DownloadError.hashMismatch(let name) = error {
                try? FileManager.default.removeItem(at: staging.appendingPathComponent(name))
            }
            fail(Self.describe(error))
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
    }

    enum DownloadError: LocalizedError {
        case http(Int, String)
        case emptyManifest
        case sizeMismatch(String)
        case hashMismatch(String)
        case noFile(String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let name): return "The server answered \(code) for \(name)."
            case .emptyManifest: return "The model list on the server is empty."
            case .sizeMismatch(let name): return "\(name) came down the wrong size."
            case .hashMismatch(let name): return "\(name) failed its integrity check."
            case .noFile(let name): return "\(name) did not arrive."
            }
        }
    }

    private static func describe(_ error: Error, file: String? = nil) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let file, !(error is DownloadError) { return "\(file): \(text)" }
        return text
    }

    // MARK: Session delegate

    /// `URLSession` wants an `NSObject` delegate on its own queue; this hops
    /// every callback onto the main actor where the downloader lives.
    private final class Relay: NSObject, URLSessionDownloadDelegate {
        unowned let owner: VisionModelDownloader
        init(owner: VisionModelDownloader) { self.owner = owner }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64)
        {
            guard let name = downloadTask.taskDescription else { return }
            Task { @MainActor in self.owner.fileProgressed(name: name, bytes: totalBytesWritten) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL)
        {
            // `location` is gone the moment this returns: move it now, on this thread.
            guard let name = downloadTask.taskDescription else { return }
            var moveError: Error?
            if let http = downloadTask.response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                moveError = DownloadError.http(http.statusCode, name)
            } else {
                let dest = VisionModelStore.stagingURL.appendingPathComponent(name)
                do {
                    let fm = FileManager.default
                    try fm.createDirectory(at: VisionModelStore.stagingURL, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.moveItem(at: location, to: dest)
                } catch {
                    moveError = error
                }
            }
            let failure = moveError
            Task { @MainActor in self.owner.fileFinished(name: name, error: failure) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error, let name = task.taskDescription else { return }
            Task { @MainActor in self.owner.fileFinished(name: name, error: error) }
        }
    }
}
