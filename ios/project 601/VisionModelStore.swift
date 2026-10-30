import Combine
import CryptoKit
import Foundation

/// Where each What's this? level lives, and how it gets there (1.4.0).
///
/// Balanced is a `VisionModel` folder inside the app. Sharp, Clear and Quick
/// are downloaded once into `<Application Support>/VisionModels/<level>` and
/// count as installed only when every file in their `manifest.json` is there
/// at the byte size the manifest says.
///
/// Nothing here reaches the network except ``VisionModelDownloader``, which
/// only fetches model files from our own server (ineedhemp.com) and sends
/// nothing about the person or their photos. Once a level is on the phone it
/// is as offline as the bundled one.
enum VisionModelStore {
    static let manifestName = "manifest.json"
    static let bundledFolderName = "VisionModel"

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

    /// The folder to load `level` from, or nil when it is not on the phone.
    static func folder(_ level: ModelLevel) -> URL? {
        if level.isBundled {
            return Bundle.main.url(forResource: bundledFolderName, withExtension: nil)
        }
        let url = downloadedURL(level)
        return isComplete(at: url) ? url : nil
    }

    static func isInstalled(_ level: ModelLevel) -> Bool { folder(level) != nil }

    /// True when any level can answer. Balanced is bundled, so this is the
    /// old feature flag: false only in a build that ships without weights.
    static var isInstalled: Bool { ModelLevel.allCases.contains { isInstalled($0) } }

    /// The bundled folder (license text, credits).
    static var installedURL: URL? { folder(.balanced) }

    static func downloadedURL(_ level: ModelLevel) -> URL {
        applicationSupport.appendingPathComponent("VisionModels", isDirectory: true)
            .appendingPathComponent(level.rawValue, isDirectory: true)
    }

    /// Where files land while they are being fetched; renamed to
    /// ``downloadedURL(_:)`` in one move once everything checks out.
    static func stagingURL(_ level: ModelLevel) -> URL {
        applicationSupport.appendingPathComponent("VisionModels", isDirectory: true)
            .appendingPathComponent(level.rawValue + ".partial", isDirectory: true)
    }

    /// Frees the space a downloaded level takes. The bundled one stays.
    static func delete(_ level: ModelLevel) {
        guard !level.isBundled else { return }
        try? FileManager.default.removeItem(at: downloadedURL(level))
        try? FileManager.default.removeItem(at: stagingURL(level))
    }

    /// Before 1.3.6 the one model could be downloaded to
    /// `<Application Support>/VisionModel` (the old MLX 0.8B). Nothing reads it
    /// any more, so it is 600+ MB of nothing.
    static func removeLegacyDownload() {
        let old = applicationSupport.appendingPathComponent("VisionModel", isDirectory: true)
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.removeItem(at: applicationSupport.appendingPathComponent("VisionModel.partial"))
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

/// Fetches downloadable levels, one at a time, file by file, on a background
/// `URLSession` so a transfer keeps going when the app is put away. Files
/// already complete in a level's staging folder are skipped, so an
/// interrupted download picks up where it left off.
@MainActor
final class VisionModelDownloader: NSObject, ObservableObject {
    static let shared = VisionModelDownloader()

    enum State: Equatable {
        case idle
        case queued
        case downloading
        case verifying
        case ready
        case failed(String)
    }

    /// Per level. A level missing from the dictionary is ready if it is on the
    /// phone and idle otherwise (see ``state(_:)``).
    @Published private(set) var states: [ModelLevel: State] = [:]
    /// 0…1 across every byte of the level now downloading.
    @Published private(set) var progress: Double = 0
    @Published private(set) var current: ModelLevel?

    static let sessionIdentifier = "com.nicedreamz.visionmodels"

    private var queue: [ModelLevel] = []
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

    func state(_ level: ModelLevel) -> State {
        if let s = states[level] { return s }
        return VisionModelStore.isInstalled(level) ? .ready : .idle
    }

    /// Adds a level to the queue (or retries a failed one). Safe to call twice.
    func start(_ level: ModelLevel) {
        guard !level.isBundled else { return }
        switch state(level) {
        case .ready, .queued, .downloading, .verifying: return
        case .idle, .failed: break
        }
        if VisionModelStore.isInstalled(level) { states[level] = .ready; return }
        states[level] = .queued
        queue.append(level)
        next()
    }

    /// Stops a queued or running level and throws its partial files away.
    func cancel(_ level: ModelLevel) {
        queue.removeAll { $0 == level }
        if current == level {
            session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
            current = nil
            manifest = nil
            pending = []
        }
        try? FileManager.default.removeItem(at: VisionModelStore.stagingURL(level))
        states[level] = .idle
        next()
    }

    /// Picks up any level whose download was cut off by the app being closed.
    func resumeInterrupted() {
        for level in ModelLevel.allCases where !level.isBundled && !VisionModelStore.isInstalled(level) {
            if FileManager.default.fileExists(atPath: VisionModelStore.stagingURL(level).path) { start(level) }
        }
    }

    func delete(_ level: ModelLevel) {
        cancel(level)
        VisionModelStore.delete(level)
        states[level] = .idle
    }

    private func next() {
        guard current == nil, !queue.isEmpty else { return }
        let level = queue.removeFirst()
        current = level
        states[level] = .downloading
        progress = 0
        Task { await fetchManifestAndQueue(level) }
    }

    // MARK: Manifest

    private func fetchManifestAndQueue(_ level: ModelLevel) async {
        let manifestURL = level.remoteURL.appendingPathComponent(VisionModelStore.manifestName)
        do {
            let (data, response) = try await URLSession.shared.data(from: manifestURL)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw DownloadError.http(http.statusCode, VisionModelStore.manifestName)
            }
            let manifest = try JSONDecoder().decode(VisionModelStore.Manifest.self, from: data)
            guard !manifest.files.isEmpty else { throw DownloadError.emptyManifest }
            guard current == level else { return }
            let staging = VisionModelStore.stagingURL(level)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try data.write(to: staging.appendingPathComponent(VisionModelStore.manifestName), options: .atomic)
            self.manifest = manifest
            queueMissingFiles(manifest, level: level, in: staging)
        } catch {
            fail(level, Self.describe(error))
        }
    }

    private func queueMissingFiles(_ manifest: VisionModelStore.Manifest, level: ModelLevel, in staging: URL) {
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
            Task { await verifyAndInstall(level) }
            return
        }
        // Don't double-queue anything the session is already carrying from a
        // previous run of the app.
        session.getAllTasks { [weak self] tasks in
            let inFlight = Set(tasks.compactMap { $0.taskDescription })
            Task { @MainActor [weak self] in
                guard let self, self.current == level else { return }
                for name in self.pending where !inFlight.contains(Self.tag(level, name)) {
                    let task = self.session.downloadTask(with: level.remoteURL.appendingPathComponent(name))
                    task.taskDescription = Self.tag(level, name)
                    task.resume()
                }
            }
        }
    }

    /// "clear/lfm3-omni-2b-Q3_K_M.gguf": which level a session task belongs to.
    nonisolated static func tag(_ level: ModelLevel, _ name: String) -> String { "\(level.rawValue)/\(name)" }

    nonisolated static func untag(_ tag: String) -> (ModelLevel, String)? {
        guard let slash = tag.firstIndex(of: "/"),
              let level = ModelLevel(rawValue: String(tag[..<slash])) else { return nil }
        return (level, String(tag[tag.index(after: slash)...]))
    }

    // MARK: Progress

    private func publishProgress() {
        guard let manifest, manifest.totalBytes > 0 else { progress = 0; return }
        let done = received.values.reduce(0, +)
        progress = min(1, Double(done) / Double(manifest.totalBytes))
    }

    fileprivate func fileProgressed(level: ModelLevel, name: String, bytes: Int64) {
        guard current == level, states[level] == .downloading else { return }
        received[name] = bytes
        publishProgress()
    }

    /// Called once the relay has moved the finished file into staging.
    fileprivate func fileFinished(level: ModelLevel, name: String, error: Error?) {
        guard current == level, states[level] == .downloading else { return }
        if let error {
            fail(level, Self.describe(error, file: name))
            return
        }
        guard let file = manifest?.files.first(where: { $0.name == name }) else { return }
        received[name] = file.size
        pending.remove(name)
        publishProgress()
        if pending.isEmpty {
            Task { await verifyAndInstall(level) }
        }
    }

    // MARK: Verify + install

    private func verifyAndInstall(_ level: ModelLevel) async {
        guard let manifest else { return }
        states[level] = .verifying
        let staging = VisionModelStore.stagingURL(level)
        let final = VisionModelStore.downloadedURL(level)
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
            states[level] = .ready
            finishCurrent()
        case .failure(let error):
            // A bad file must not be trusted next time round.
            if case DownloadError.hashMismatch(let name) = error {
                try? FileManager.default.removeItem(at: staging.appendingPathComponent(name))
            }
            fail(level, Self.describe(error))
        }
    }

    private func fail(_ level: ModelLevel, _ message: String) {
        states[level] = .failed(message)
        if current == level { finishCurrent() }
    }

    private func finishCurrent() {
        current = nil
        manifest = nil
        pending = []
        next()
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
            guard let tag = downloadTask.taskDescription, let (level, name) = VisionModelDownloader.untag(tag) else { return }
            Task { @MainActor in self.owner.fileProgressed(level: level, name: name, bytes: totalBytesWritten) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL)
        {
            // `location` is gone the moment this returns: move it now, on this thread.
            guard let tag = downloadTask.taskDescription, let (level, name) = VisionModelDownloader.untag(tag) else { return }
            var moveError: Error?
            if let http = downloadTask.response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                moveError = DownloadError.http(http.statusCode, name)
            } else {
                let staging = VisionModelStore.stagingURL(level)
                let dest = staging.appendingPathComponent(name)
                do {
                    let fm = FileManager.default
                    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.moveItem(at: location, to: dest)
                } catch {
                    moveError = error
                }
            }
            let failure = moveError
            Task { @MainActor in self.owner.fileFinished(level: level, name: name, error: failure) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error, let tag = task.taskDescription, let (level, name) = VisionModelDownloader.untag(tag) else { return }
            // A cancel from ``cancel(_:)`` is not a failure worth showing.
            if (error as NSError).code == NSURLErrorCancelled { return }
            Task { @MainActor in self.owner.fileFinished(level: level, name: name, error: error) }
        }
    }
}
