import Foundation

/// Cross-module NSNotification names for Speech Model downloads. String-based so the
/// Expo module (a separate Swift module) can post and observe the same events.
enum ModelDownloadNotification {
    /// userInfo: ["variant": String, "inFlight": Bool]
    static let stateChanged = Notification.Name("codictate.model.downloadStateChanged")
    /// The Expo module asks the Host to download a Speech Model.
    /// userInfo: ["variant": String]. The module cannot download it itself: iOS wakes a
    /// terminated app to finish a background URLSession without initialising React
    /// Native, so a session owned by the module would never be recreated on the one
    /// launch that exists to finish the transfer. Same shape as
    /// `ParakeetModelNotification.ensureModel`, which the module cannot own either.
    static let ensureModel = Notification.Name("codictate.model.ensureModel")
    /// userInfo: ["variant": String, "progress": Double]
    static let progress = Notification.Name("codictate.model.progress")
    /// userInfo: ["variant": String, "path": String]
    static let ready = Notification.Name("codictate.model.ready")
    /// userInfo: ["variant": String, "error": String]
    static let failed = Notification.Name("codictate.model.failed")
    /// The background URLSession has replayed every event it queued while the app was not
    /// running. userInfo: ["identifier": String]. `BackgroundDownloadEvents` answers the
    /// completion handler iOS handed the AppDelegate for that identifier.
    static let backgroundEventsFinished =
        Notification.Name("codictate.model.backgroundEventsFinished")
}

final class ModelManager {

    /// A Speech Model: its id, its weights, its download and its declared capabilities.
    /// Keep in sync with `AppGroupModelManager.Variant` and the canonical table in
    /// `docs/adr/0001-crispasr-as-the-ios-asr-harness.md`.
    enum Variant: String {
        case parakeet = "parakeet"
        case base = "base"
        case baseEn = "base_en"
        case hviske = "hviske"

        /// The Transcription Language id meaning "let the Speech Model decide".
        static let automaticLanguageId = "auto"

        /// The runtime that executes this Speech Model's weights.
        /// Replaces the old `isWhisper` flag, which stopped being a sufficient
        /// discriminator the moment a third engine arrived.
        enum Engine: String {
            /// FluidAudio's AsrManager, Core ML on the Neural Engine.
            case parakeet
            /// crispasr's whisper backend.
            case whisper
            /// crispasr's cohere backend, the only runtime that reads hviske GGUF weights.
            case cohere
        }

        var engine: Engine {
            switch self {
            case .parakeet: return .parakeet
            case .base, .baseEn: return .whisper
            case .hviske: return .cohere
            }
        }

        var label: String {
            switch self {
            case .parakeet: return "Parakeet TDT v3"
            case .base: return "Base (Q5_1)"
            case .baseEn: return "Base.en (Q5_1)"
            case .hviske: return "Hviske V5 Tiny Q5"
            }
        }

        /// Language Lock: the Transcription Languages this Speech Model accepts.
        /// `nil` means the full picker. Feeding a Speech Model a language it does not
        /// support yields a fluent wrong-language transcript and never an error, which
        /// is why the lock is declared data rather than a runtime guess.
        var supportedLanguages: [String]? {
            switch self {
            case .parakeet: return nil
            case .base: return nil
            case .baseEn: return ["en"]
            case .hviske: return ["da"]
            }
        }

        /// Parakeet takes no language input at all, so it locks to automatic rather
        /// than to a list of codes.
        var locksLanguageToAutomatic: Bool {
            switch self {
            case .parakeet: return true
            case .base, .baseEn, .hviske: return false
            }
        }

        /// The single Transcription Language a locked Speech Model runs, or nil when it
        /// accepts the full list. The UI shows this instead of an enabled picker.
        var pinnedLanguageId: String? {
            if locksLanguageToAutomatic { return Variant.automaticLanguageId }
            guard let supported = supportedLanguages, supported.count == 1 else { return nil }
            return supported[0]
        }

        /// Human-readable form of the Language Lock, for the Dictation Readiness message.
        var languageLockLabel: String {
            switch self {
            case .parakeet: return "automatic language detection"
            case .base: return "every language"
            case .baseEn: return "English"
            case .hviske: return "Danish"
            }
        }

        /// Language Lock check. A Speech Model locked to a language list accepts exactly
        /// that list, plus the automatic id: `auto` is the absence of a choice, not a
        /// conflicting one, and `resolvedLanguageId` turns it into the pinned language
        /// before any engine sees it. Only an explicitly picked other language conflicts.
        /// A Speech Model locked to automatic accepts only automatic.
        func accepts(languageId: String) -> Bool {
            if locksLanguageToAutomatic { return languageId == Variant.automaticLanguageId }
            guard let supported = supportedLanguages else { return true }
            if languageId == Variant.automaticLanguageId, pinnedLanguageId != nil { return true }
            return supported.contains(languageId)
        }

        /// The Transcription Language the engine actually runs with. A Speech Model with
        /// a pinned language reads the automatic id as its own language; everything else
        /// keeps the stored id. This is the single place the stored picker id becomes an
        /// engine input, so a bare `auto` can never reach weights that cannot detect a
        /// language. Idempotent: resolving an already-resolved id returns it unchanged.
        func resolvedLanguageId(_ storedId: String) -> String {
            guard let pinned = pinnedLanguageId, storedId == Variant.automaticLanguageId else {
                return storedId
            }
            return pinned
        }

        var filename: String {
            switch self {
            case .parakeet: return ""
            case .base: return "ggml-base-q5_1.bin"
            case .baseEn: return "ggml-base.en-q5_1.bin"
            case .hviske: return "hviske-v5-tiny-q5_0.gguf"
            }
        }

        var url: URL {
            switch self {
            case .parakeet:
                return URL(string:
                    "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml"
                )!
            case .base:
                return URL(string:
                    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin"
                )!
            case .baseEn:
                return URL(string:
                    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en-q5_1.bin"
                )!
            case .hviske:
                return URL(string:
                    "https://huggingface.co/emillykkegrann/hviske-v5-tiny-GGUF/resolve/main/hviske-v5-tiny-q5_0.gguf"
                )!
            }
        }

        /// Sanity floor for "these are real weights, not a truncated file or an error page".
        var minBytes: Int64 {
            switch self {
            case .parakeet: return 0
            case .base, .baseEn: return 50 * 1024 * 1024
            case .hviske: return 150 * 1024 * 1024
            }
        }

        /// Every Speech Model whose weights are a single file in the App Group container.
        static let fileBacked: [Variant] = [.base, .baseEn, .hviske]

        static let all: [Variant] = [.parakeet, .base, .baseEn, .hviske]

        static func variant(forRemote url: URL) -> Variant? {
            fileBacked.first { $0.url == url }
        }
    }

    static let shared = ModelManager()

    private let groupID = "group.app.codictate"

    private var requestObserverInstalled = false

    private init() {}

    // MARK: - Public API

    /// Default model used when only the legacy `modelFilePath` property is read.
    /// Host / intent paths use `transcriptionVariant(...)` and the App Group preference.
    var modelFilePath: String? {
        modelFilePath(for: .base)
    }

    var modelIsReady: Bool {
        modelIsReady(for: .base)
    }

    func modelFilePath(for variant: Variant) -> String? {
        switch variant {
        case .parakeet:
            return ParakeetModelManager.shared.modelDirectory.path
        case .base, .baseEn, .hviske:
            return containerURL?.appendingPathComponent(variant.filename).path
        }
    }

    func modelIsReady(for variant: Variant) -> Bool {
        switch variant {
        case .parakeet:
            return ParakeetModelManager.shared.isReady
        case .base, .baseEn, .hviske:
            guard let path = containerURL?.appendingPathComponent(variant.filename).path else {
                return false
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? Int64) ?? 0
            return size >= variant.minBytes
        }
    }

    /// Attaches the background URLSession. Downloads that finished while the app was
    /// suspended or terminated are filed and reported from here, so call it once at boot.
    func activateBackgroundDownloads() {
        _ = downloader
    }

    /// Listens for the Expo module's download requests. Called once from
    /// `KeyboardHostRecorder.bootstrap()`, which runs on every launch -- including the
    /// background relaunch iOS performs purely to finish a download, where the module's
    /// `OnCreate` never runs because React Native is not initialised.
    ///
    /// The requester's promise is answered over `progress` / `ready` / `failed`, the same
    /// way `ParakeetModelManager` answers `codictate.parakeet.ensureModel`.
    func installObserver() {
        guard !requestObserverInstalled else { return }
        requestObserverInstalled = true

        NotificationCenter.default.addObserver(
            forName: ModelDownloadNotification.ensureModel,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?["variant"] as? String,
                  let variant = Variant(rawValue: raw) else { return }
            // Parakeet is not a URLSession download. FluidAudio fetches it, and
            // `ParakeetModelManager` answers its own notification pair for it.
            guard variant != .parakeet else { return }
            self.performRequestedDownload(variant)
        }
    }

    /// Default ensure (Base) — kept for backward compatibility with keyboard flow.
    func ensureModel(
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        ensureModel(variant: .base, onProgress: onProgress, onComplete: onComplete)
    }

    /// Pick a specific variant. Skips the network if the file already exists at >= minBytes.
    /// For `parakeet`, readiness is checked via ParakeetModelManager (CoreML directory layout).
    func ensureModel(
        variant: Variant,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        if variant == .parakeet {
            if ParakeetModelManager.shared.isReady {
                onComplete(.success(ParakeetModelManager.shared.modelDirectory.path))
            } else {
                onComplete(.failure(NSError(
                    domain: "ModelManager", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "Parakeet model not downloaded yet. Open Codictate to download."]
                )))
            }
            return
        }

        guard containerURL != nil else {
            onComplete(.failure(NSError(
                domain: "ModelManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable."]
            )))
            return
        }

        if modelIsReady(for: variant), let path = modelFilePath(for: variant) {
            onComplete(.success(path))
            return
        }

        onProgress(0)
        downloader.download(
            from: variant.url,
            onProgress: onProgress,
            onComplete: { result in
                switch result {
                case .success(let destination):
                    onComplete(.success(destination.path))
                case .failure(let error):
                    onComplete(.failure(error))
                }
            }
        )
    }

    // MARK: - Private

    /// Answers one `codictate.model.ensureModel` request. Failures are reported as a
    /// message rather than an `Error`, because a notification cannot carry one across a
    /// module boundary and the requester only ever shows the text.
    private func performRequestedDownload(_ variant: Variant) {
        ensureModel(
            variant: variant,
            onProgress: { fraction in
                NotificationCenter.default.post(
                    name: ModelDownloadNotification.progress,
                    object: nil,
                    userInfo: ["variant": variant.rawValue, "progress": fraction]
                )
            },
            onComplete: { result in
                switch result {
                case .success(let path):
                    NotificationCenter.default.post(
                        name: ModelDownloadNotification.ready,
                        object: nil,
                        userInfo: ["variant": variant.rawValue, "path": path]
                    )
                case .failure(let error):
                    NotificationCenter.default.post(
                        name: ModelDownloadNotification.failed,
                        object: nil,
                        userInfo: [
                            "variant": variant.rawValue,
                            "error": error.localizedDescription,
                        ]
                    )
                }
            }
        )
    }

    /// The one background session in the process: every Speech Model download runs on it,
    /// so a 181 MB hviske download behaves exactly like a 57 MB Whisper one, and the
    /// Speech Model a user tapped in Settings cannot also be downloading somewhere else.
    private lazy var downloader = ModelDownloadCoordinator(
        identifier: BackgroundDownloadEvents.sessionIdentifier,
        destinationForURL: { [weak self] url in
            guard let self, let variant = Variant.variant(forRemote: url) else { return nil }
            return self.containerURL?.appendingPathComponent(variant.filename)
        },
        onInFlightChange: { url, inFlight in
            guard let variant = Variant.variant(forRemote: url) else { return }
            NotificationCenter.default.post(
                name: ModelDownloadNotification.stateChanged,
                object: nil,
                userInfo: ["variant": variant.rawValue, "inFlight": inFlight]
            )
        }
    )

    private var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        )
    }
}

// MARK: - Background download coordinator

/// Every Speech Model download runs on one background URLSession.
/// `URLSessionConfiguration.default` is foreground-only: it dies the moment the app is
/// backgrounded and it cannot resume, which 181 MB of hviske weights will not survive.
/// One code path for every variant, no special case for the big one.
///
/// This is the only downloader in the process. The Expo module owned a copy once and must
/// not again: a session attached from its `OnCreate` is never recreated on a background
/// relaunch, because iOS finishes downloads without initialising React Native.
final class ModelDownloadCoordinator: NSObject, URLSessionDownloadDelegate {

    typealias ProgressHandler = (Double) -> Void
    typealias CompletionHandler = (Result<URL, Error>) -> Void

    private struct Waiter {
        let onProgress: ProgressHandler
        let onComplete: CompletionHandler
    }

    /// Resolves the final on-disk location for a remote URL. A closure rather than a
    /// captured dictionary because a background task outlives the process: after a
    /// relaunch there is no waiter left, but the bytes still need filing.
    private let destinationForURL: (URL) -> URL?
    /// Called on the main queue whenever a URL starts or stops downloading.
    private let onInFlightChange: (URL, Bool) -> Void

    /// The background session identifier, kept so the AppDelegate's completion handler
    /// for this session can be answered by name.
    private let identifier: String

    private let lock = NSLock()
    private var waiters: [String: [Waiter]] = [:]
    private var resumeData: [String: Data] = [:]
    private var inFlight: Set<String> = []
    private var session: URLSession!

    init(
        identifier: String,
        destinationForURL: @escaping (URL) -> URL?,
        onInFlightChange: @escaping (URL, Bool) -> Void
    ) {
        self.identifier = identifier
        self.destinationForURL = destinationForURL
        self.onInFlightChange = onInFlightChange
        super.init()

        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        // A model download is a foreground-initiated user action, not opportunistic work.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        // URLSession retains its delegate until the session is invalidated, and this
        // coordinator lives for the whole process, so the cycle is intentional.
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        // The session outlives the process. Adopt whatever it is still running so a
        // second tap does not start a duplicate task.
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            for task in tasks {
                guard let url = task.originalRequest?.url else { continue }
                self.markInFlight(url, true)
            }
        }
    }

    func download(
        from url: URL,
        onProgress: @escaping ProgressHandler,
        onComplete: @escaping CompletionHandler
    ) {
        let key = url.absoluteString

        lock.lock()
        let alreadyRunning = inFlight.contains(key)
        waiters[key, default: []].append(Waiter(onProgress: onProgress, onComplete: onComplete))
        let resume = resumeData.removeValue(forKey: key)
        lock.unlock()

        if alreadyRunning { return }
        markInFlight(url, true)

        let task: URLSessionDownloadTask
        if let resume {
            task = session.downloadTask(withResumeData: resume)
        } else {
            task = session.downloadTask(with: url)
        }
        task.resume()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite expected: Int64
    ) {
        guard expected > 0, let url = downloadTask.originalRequest?.url else { return }
        let fraction = Double(totalBytesWritten) / Double(expected)

        lock.lock()
        let pending = waiters[url.absoluteString] ?? []
        lock.unlock()
        guard !pending.isEmpty else { return }

        DispatchQueue.main.async {
            for waiter in pending { waiter.onProgress(fraction) }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let url = downloadTask.originalRequest?.url else { return }

        // A 404 or 403 arrives as a "successful" download whose body is an error page.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            finish(url, .failure(NSError(
                domain: "ModelDownloadCoordinator", code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Model download failed with HTTP \(http.statusCode)."]
            )))
            return
        }

        guard let destination = destinationForURL(url) else {
            finish(url, .failure(NSError(
                domain: "ModelDownloadCoordinator", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Download produced no destination."]
            )))
            return
        }

        // iOS deletes `location` as soon as this method returns, so move it here.
        do {
            let directory = destination.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(url, .success(destination))
        } catch {
            finish(url, .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let url = task.originalRequest?.url else { return }
        // Success is already reported from didFinishDownloadingTo.
        guard let error else { return }

        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            lock.lock()
            resumeData[url.absoluteString] = data
            lock.unlock()
        }
        finish(url, .failure(error))
    }

    /// The hviske mirror answers 302 to the Hugging Face CDN. Following redirects is the
    /// default; this is here so nobody "hardens" the session by refusing them.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request)
    }

    /// End of the replay iOS queued while the app was suspended or terminated. The
    /// AppDelegate is holding iOS's completion handler for this identifier and must call
    /// it on the main queue, or iOS stops relaunching the app for its downloads.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = self.identifier
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: ModelDownloadNotification.backgroundEventsFinished,
                object: nil,
                userInfo: ["identifier": identifier]
            )
        }
    }

    // MARK: - Private

    private func markInFlight(_ url: URL, _ active: Bool) {
        let key = url.absoluteString
        lock.lock()
        let changed = active ? inFlight.insert(key).inserted : (inFlight.remove(key) != nil)
        lock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { self.onInFlightChange(url, active) }
    }

    private func finish(_ url: URL, _ result: Result<URL, Error>) {
        markInFlight(url, false)

        lock.lock()
        let pending = waiters.removeValue(forKey: url.absoluteString) ?? []
        lock.unlock()

        guard !pending.isEmpty else { return }
        DispatchQueue.main.async {
            for waiter in pending { waiter.onComplete(result) }
        }
    }
}
