import CryptoKit
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
        case ekko = "ekko"

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
            /// parakeet.cpp, the only runtime that reads ekko GGUF weights.
            case ekko
        }

        var engine: Engine {
            switch self {
            case .parakeet: return .parakeet
            case .base, .baseEn: return .whisper
            case .hviske: return .cohere
            case .ekko: return .ekko
            }
        }

        var label: String {
            switch self {
            case .parakeet: return "Parakeet TDT v3"
            case .base: return "Base (Q5_1)"
            case .baseEn: return "Base.en (Q5_1)"
            case .hviske: return "Hviske V5 Tiny Q5"
            case .ekko: return "Ekko V1 Tiny Q5"
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
            case .hviske, .ekko: return ["da"]
            }
        }

        /// Parakeet takes no language input at all, so it locks to automatic rather
        /// than to a list of codes.
        var locksLanguageToAutomatic: Bool {
            switch self {
            case .parakeet: return true
            case .base, .baseEn, .hviske, .ekko: return false
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
            case .hviske, .ekko: return "Danish"
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
            case .ekko: return "ekko-v1-tiny-q5_0.gguf"
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
            case .ekko:
                // The Mirror commit, never `main`: desktop's `EKKO_V1_TINY_MIRROR_REVISION`.
                return URL(string:
                    "https://huggingface.co/emillykkegrann/ekko-v1-tiny-GGUF/resolve/d60b91ae714fdccf4ecd7a9f22a06b349c87ffc1/ekko-v1-tiny-q5_0.gguf"
                )!
            }
        }

        /// The exact file a download must be, for a Speech Model pinned by size and sha256.
        /// A downloaded file that does not match is never installed. nil for the Speech
        /// Models fetched from an unpinned `main`, which only get the `minBytes` floor.
        var pinnedFile: PinnedFile? {
            switch self {
            case .parakeet, .base, .baseEn, .hviske: return nil
            case .ekko:
                return PinnedFile(
                    bytes: 134_710_976,
                    sha256: "f5380485d80d552ae46313185126d7ade54b2e7360cb0d15b91f1ab26ced7791"
                )
            }
        }

        /// Sanity floor for "these are real weights, not a truncated file or an error page".
        var minBytes: Int64 {
            switch self {
            case .parakeet: return 0
            case .base, .baseEn: return 50 * 1024 * 1024
            case .hviske: return 150 * 1024 * 1024
            case .ekko: return pinnedFile?.bytes ?? 0
            }
        }

        /// Every Speech Model whose weights are a single file in the App Group container.
        /// ekko's weights are, though it also needs the Punctuation Model to count as ready.
        static let fileBacked: [Variant] = [.base, .baseEn, .hviske, .ekko]

        static let all: [Variant] = [.parakeet, .base, .baseEn, .hviske, .ekko]

        static func variant(forRemote url: URL) -> Variant? {
            fileBacked.first { $0.url == url }
        }
    }

    /// A downloaded file's pinned size and sha256.
    struct PinnedFile: Equatable {
        let bytes: Int64
        let sha256: String
    }

    /// ekko-pnc, the Punctuation Model every ekko Raw Transcript goes through. Its Mirror,
    /// pinned commit and the runtime files Punctuation Restoration reads, as desktop pins them
    /// in `src/shared/punctuation-model-files.ts` (the Mirror's licence files are carried in
    /// `third-party/ekko-pnc` instead). Installed in its own App Group folder, beside the
    /// Speech Models, and downloaded as part of ekko.
    enum PunctuationModel {
        struct File: Equatable {
            /// Path inside the Mirror, and inside `directoryName`.
            let path: String
            let pinned: PinnedFile
        }

        static let mirrorRepoId = "emillykkegrann/ekko-pnc-ONNX"
        /// The Mirror commit, never `main`. Moving it is a new model.
        static let mirrorRevision = "44b0483333423a31d36907f1d71dee7e71045a42"
        /// The App Group folder the runtime files install into.
        static let directoryName = "ekko-pnc"

        /// What `EkkoPncModel` opens. The Punctuation Model is installed only with all three.
        static let runtimeFiles: [File] = [
            File(path: "pnc.int8.onnx", pinned: PinnedFile(
                bytes: 22_424_741,
                sha256: "46bb979d409731872f10b6cb71298594595f16368d2aec2fcaf94d87b4266527")),
            File(path: "tokenizer.json", pinned: PinnedFile(
                bytes: 2_301_084,
                sha256: "a1e0d43ee307ad7a1ccc23e6e5398d877a68ca7f576067ac507625a0d50e9502")),
            File(path: "config.json", pinned: PinnedFile(
                bytes: 1_062,
                sha256: "dc655c46f69eeb15dd43786ad58fb5862cc794b36cc9d2c426ab5bc4b01f23ca")),
        ]

        static func url(for file: File) -> URL {
            URL(string: "https://huggingface.co/\(mirrorRepoId)/resolve/\(mirrorRevision)/\(file.path)")!
        }

        static func file(forRemote url: URL) -> File? {
            runtimeFiles.first { Self.url(for: $0) == url }
        }
    }

    static let shared = ModelManager()

    private let groupID = "group.app.codictate"

    private var requestObserverInstalled = false
    /// The URLs each Speech Model is downloading. ekko downloads several at once and is in
    /// flight until the last one ends. Main queue only, like `onInFlightChange`.
    private var inFlightDownloads: [Variant: Set<URL>] = [:]

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
        case .base, .baseEn, .hviske, .ekko:
            return containerURL?.appendingPathComponent(variant.filename).path
        }
    }

    /// ekko is ready only with its GGUF and every ekko-pnc runtime file on disk: its Raw
    /// Transcript is lowercase and unpunctuated, and Punctuation Restoration always runs on it.
    func modelIsReady(for variant: Variant) -> Bool {
        switch variant {
        case .parakeet:
            return ParakeetModelManager.shared.isReady
        case .base, .baseEn, .hviske:
            return weightsArePresent(variant)
        case .ekko:
            return weightsArePresent(variant) && punctuationModelIsInstalled
        }
    }

    /// The folder holding ekko-pnc's runtime files, which `PunctuationRestorer` opens.
    var punctuationModelDirectory: URL? {
        containerURL?.appendingPathComponent(PunctuationModel.directoryName, isDirectory: true)
    }

    var punctuationModelIsInstalled: Bool {
        PunctuationModel.runtimeFiles.allSatisfy { file in
            guard let url = punctuationModelDirectory?.appendingPathComponent(file.path) else {
                return false
            }
            return Self.fileSize(url) == file.pinned.bytes
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

    func ensureFormattingModel(
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        guard let destination = containerURL?.appendingPathComponent(FormattingConfiguration.filename) else {
            onComplete(.failure(NSError(domain: "ModelManager", code: 20, userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable."])))
            return
        }
        if FormattingManager.shared.modelIsReady {
            onComplete(.success(destination.path))
            return
        }
        UserDefaults(suiteName: groupID)?.set(false, forKey: FormattingConfiguration.verifiedKey)
        onProgress(0)
        downloader.download(
            from: FormattingConfiguration.url,
            onProgress: onProgress,
            onComplete: { result in
                onComplete(result.map(\.path))
            }
        )
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

        if variant == .ekko {
            ensureEkko(onProgress: onProgress, onComplete: onComplete)
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

    /// `ensureModel(variant:onProgress:onComplete:)` for a caller that only needs the path.
    func ensureModel(variant: Variant) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            ensureModel(
                variant: variant,
                onProgress: { _ in },
                onComplete: { continuation.resume(with: $0) }
            )
        }
    }

    // MARK: - Private

    private func weightsArePresent(_ variant: Variant) -> Bool {
        guard let path = modelFilePath(for: variant) else { return false }
        return Self.fileSize(URL(fileURLWithPath: path)) >= variant.minBytes
    }

    /// ekko is one download with one progress value: whichever of its GGUF and the ekko-pnc
    /// runtime files are missing, started together on the one background session so they all
    /// keep going if the app is suspended. Progress is weighted by the pinned sizes. A file
    /// already installed is never fetched again, so a retry after a failure only downloads
    /// what is still missing. Every callback arrives on the main queue.
    private func ensureEkko(
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        guard let ggufPath = modelFilePath(for: .ekko),
              let pncDirectory = punctuationModelDirectory else {
            onComplete(.failure(NSError(
                domain: "ModelManager", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable."]
            )))
            return
        }

        var parts: [(url: URL, bytes: Int64)] = []
        if !weightsArePresent(.ekko) {
            parts.append((Variant.ekko.url, Variant.ekko.minBytes))
        }
        for file in PunctuationModel.runtimeFiles
        where Self.fileSize(pncDirectory.appendingPathComponent(file.path)) != file.pinned.bytes {
            parts.append((PunctuationModel.url(for: file), file.pinned.bytes))
        }

        let totalBytes = Double(parts.reduce(0) { $0 + $1.bytes })
        var fractions: [URL: Double] = [:]
        var remaining = parts.count
        var firstError: Error?

        onProgress(0)
        for part in parts {
            downloader.download(
                from: part.url,
                onProgress: { fraction in
                    fractions[part.url] = fraction
                    let done = parts.reduce(0.0) { $0 + (fractions[$1.url] ?? 0) * Double($1.bytes) }
                    onProgress(done / totalBytes)
                },
                onComplete: { [weak self] result in
                    switch result {
                    case .success: fractions[part.url] = 1
                    case .failure(let error): firstError = firstError ?? error
                    }
                    remaining -= 1
                    guard remaining == 0 else { return }
                    if let firstError {
                        onComplete(.failure(firstError))
                    } else if self?.modelIsReady(for: .ekko) == true {
                        onComplete(.success(ggufPath))
                    } else {
                        onComplete(.failure(NSError(
                            domain: "ModelManager", code: 23,
                            userInfo: [NSLocalizedDescriptionKey: "Ekko V1 Tiny Q5 download is incomplete."]
                        )))
                    }
                }
            )
        }
    }

    /// The Speech Model a remote URL is downloaded for: its own weights, or ekko-pnc's
    /// runtime files, which only ekko downloads.
    private func downloadOwner(forRemote url: URL) -> Variant? {
        if let variant = Variant.variant(forRemote: url) { return variant }
        return PunctuationModel.file(forRemote: url) == nil ? nil : .ekko
    }

    /// The pinned size and sha256 a downloaded file must match, or nil when it has none.
    private func pinnedFile(forRemote url: URL) -> PinnedFile? {
        if let file = PunctuationModel.file(forRemote: url) { return file.pinned }
        return Variant.variant(forRemote: url)?.pinnedFile
    }

    /// Main queue. Posts `stateChanged` only when the Speech Model as a whole starts or
    /// stops downloading, so ekko's first finished file does not end its "downloading".
    private func downloadInFlightChanged(_ url: URL, _ inFlight: Bool) {
        guard let variant = downloadOwner(forRemote: url) else { return }
        var urls = inFlightDownloads[variant] ?? []
        let wasInFlight = !urls.isEmpty
        if inFlight { urls.insert(url) } else { urls.remove(url) }
        inFlightDownloads[variant] = urls
        guard wasInFlight != !urls.isEmpty else { return }
        NotificationCenter.default.post(
            name: ModelDownloadNotification.stateChanged,
            object: nil,
            userInfo: ["variant": variant.rawValue, "inFlight": !urls.isEmpty]
        )
    }

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
            guard let self else { return nil }
            if url == FormattingConfiguration.url {
                return self.containerURL?.appendingPathComponent(FormattingConfiguration.filename)
            }
            if let file = PunctuationModel.file(forRemote: url) {
                return self.punctuationModelDirectory?.appendingPathComponent(file.path)
            }
            guard let variant = Variant.variant(forRemote: url) else { return nil }
            return self.containerURL?.appendingPathComponent(variant.filename)
        },
        validateFile: { [weak self] url, file in
            if let pinned = self?.pinnedFile(forRemote: url) {
                guard Self.fileSize(file) == pinned.bytes else {
                    return NSError(domain: "ModelManager", code: 24, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) download has the wrong size."])
                }
                guard Self.sha256(file) == pinned.sha256 else {
                    return NSError(domain: "ModelManager", code: 25, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) download failed integrity verification."])
                }
                return nil
            }
            guard url == FormattingConfiguration.url else { return nil }
            guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int64,
                  size == FormattingConfiguration.byteCount else {
                return NSError(domain: "ModelManager", code: 21, userInfo: [NSLocalizedDescriptionKey: "S1-mini download has the wrong size."])
            }
            guard Self.sha256(file) == FormattingConfiguration.sha256 else {
                return NSError(domain: "ModelManager", code: 22, userInfo: [NSLocalizedDescriptionKey: "S1-mini download failed integrity verification."])
            }
            return nil
        },
        onFileStored: { url, _ in
            guard url == FormattingConfiguration.url else { return }
            UserDefaults(suiteName: self.groupID)?.set(true, forKey: FormattingConfiguration.verifiedKey)
        },
        onInFlightChange: { url, inFlight in
            if url == FormattingConfiguration.url {
                let suite = UserDefaults(suiteName: self.groupID)
                suite?.set(inFlight, forKey: FormattingConfiguration.downloadingKey)
                suite?.synchronize()
                return
            }
            self.downloadInFlightChanged(url, inFlight)
        },
        onCompleteResult: { url, result in
            guard url == FormattingConfiguration.url else { return }
            switch result {
            case .success(let path):
                NotificationCenter.default.post(
                    name: FormattingModelNotification.ready,
                    object: nil,
                    userInfo: ["path": path.path]
                )
            case .failure(let error):
                NotificationCenter.default.post(
                    name: FormattingModelNotification.failed,
                    object: nil,
                    userInfo: ["error": error.localizedDescription]
                )
            }
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
    private let validateFile: (URL, URL) -> Error?
    private let onFileStored: (URL, URL) -> Void
    /// Called on the main queue whenever a URL starts or stops downloading.
    private let onInFlightChange: (URL, Bool) -> Void
    private let onCompleteResult: (URL, Result<URL, Error>) -> Void

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
        validateFile: @escaping (URL, URL) -> Error? = { _, _ in nil },
        onFileStored: @escaping (URL, URL) -> Void = { _, _ in },
        onInFlightChange: @escaping (URL, Bool) -> Void,
        onCompleteResult: @escaping (URL, Result<URL, Error>) -> Void = { _, _ in }
    ) {
        self.identifier = identifier
        self.destinationForURL = destinationForURL
        self.validateFile = validateFile
        self.onFileStored = onFileStored
        self.onInFlightChange = onInFlightChange
        self.onCompleteResult = onCompleteResult
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
            if let validationError = validateFile(url, location) {
                finish(url, .failure(validationError))
                return
            }
            let directory = destination.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            onFileStored(url, destination)
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

        DispatchQueue.main.async {
            self.onCompleteResult(url, result)
            for waiter in pending { waiter.onComplete(result) }
        }
    }
}

private extension ModelManager {
    static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    static func sha256(_ url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            hash.update(data: Data(buffer[0..<count]))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
