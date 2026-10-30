import Foundation

/// Mirrors `ModelManager` from the main app target.
/// Duplicated intentionally -- the Expo module pod cannot import main-app symbols.
/// Keep variant filenames, minBytes, engines, labels, Language Locks and the ekko-pnc
/// runtime files in sync with `ModelManager.swift`. Download URLs are deliberately absent here: the Host owns every
/// download, so this copy never needs one and the two cannot drift on it.
final class AppGroupModelManager {

    enum Variant: String {
        case parakeet = "parakeet"
        case base = "base"
        case baseEn = "base_en"
        case hviske = "hviske"
        case ekko = "ekko"

        /// The Transcription Language id meaning "let the Speech Model decide".
        static let automaticLanguageId = "auto"

        /// The runtime that executes this Speech Model's weights.
        enum Engine: String {
            case parakeet
            case whisper
            case cohere
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
        /// `nil` means the full picker.
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
        /// accepts the full list.
        var pinnedLanguageId: String? {
            if locksLanguageToAutomatic { return Variant.automaticLanguageId }
            guard let supported = supportedLanguages, supported.count == 1 else { return nil }
            return supported[0]
        }

        /// A Speech Model locked to a language list accepts exactly that list, plus the
        /// automatic id: `auto` is the absence of a choice, not a conflicting one, and
        /// `resolvedLanguageId` turns it into the pinned language before any engine
        /// sees it. A Speech Model locked to automatic accepts only automatic.
        func accepts(languageId: String) -> Bool {
            if locksLanguageToAutomatic { return languageId == Variant.automaticLanguageId }
            guard let supported = supportedLanguages else { return true }
            if languageId == Variant.automaticLanguageId, pinnedLanguageId != nil { return true }
            return supported.contains(languageId)
        }

        /// The Transcription Language the engine actually runs with. A Speech Model with
        /// a pinned language reads the automatic id as its own language; everything else
        /// keeps the stored id.
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

        /// Sanity floor for "these are real weights, not a truncated file or an error page".
        var minBytes: Int64 {
            switch self {
            case .parakeet: return 0
            case .base, .baseEn: return 50 * 1024 * 1024
            case .hviske: return 150 * 1024 * 1024
            // The pinned size; the Host verifies its sha256 before installing it.
            case .ekko: return 134_710_976
            }
        }

        static let all: [Variant] = [.parakeet, .base, .baseEn, .hviske, .ekko]
    }

    /// ekko-pnc, the Punctuation Model ekko needs: its App Group folder and the runtime
    /// files with their pinned sizes. Mirror of `ModelManager.PunctuationModel`.
    enum PunctuationModel {
        static let directoryName = "ekko-pnc"
        static let runtimeFiles: [(path: String, bytes: Int64)] = [
            ("pnc.int8.onnx", 22_424_741),
            ("tokenizer.json", 2_301_084),
            ("config.json", 1_062),
        ]
    }

    static let shared = AppGroupModelManager()

    private let groupID = "group.app.codictate"

    // MARK: - Cross-module notification names
    //
    // Mirrors of `ModelDownloadNotification` and `ParakeetModelNotification`. String
    // literals because a separate Swift module cannot import the main app target's types.

    private static let ensureModelNotification = Notification.Name("codictate.model.ensureModel")
    private static let progressNotification = Notification.Name("codictate.model.progress")
    private static let readyNotification = Notification.Name("codictate.model.ready")
    private static let failedNotification = Notification.Name("codictate.model.failed")
    private static let downloadStateChangedNotification =
        Notification.Name("codictate.model.downloadStateChanged")

    private static let parakeetEnsureModelNotification =
        Notification.Name("codictate.parakeet.ensureModel")
    private static let parakeetProgressNotification =
        Notification.Name("codictate.parakeet.progress")
    private static let parakeetReadyNotification = Notification.Name("codictate.parakeet.ready")
    private static let parakeetFailedNotification = Notification.Name("codictate.parakeet.failed")

    private typealias Waiter = (
        onProgress: (Double) -> Void,
        onComplete: (Result<String, Error>) -> Void
    )

    /// Keyed by `Variant.rawValue`. Main queue only, like the observers that drain it.
    private var waiters: [String: [Waiter]] = [:]
    private var requested: Set<String> = []
    private var observersInstalled = false

    private init() {}

    var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    // MARK: - Parakeet readiness (managed by ParakeetModelManager in main app target)

    private static let parakeetReadyKey = "parakeetModelReady"

    /// Where FluidAudio keeps Parakeet TDT v3: its `AsrModels.defaultCacheDirectory(for: .v3)`.
    /// Mirror of `ParakeetModelManager.modelDirectory` in the main app target, which asks
    /// FluidAudio for it; a literal here because this module cannot import FluidAudio.
    /// Keep the two the same.
    var parakeetModelDirectory: URL? {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return appSupport?.appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3", isDirectory: true)
    }

    /// Checks the persistent flag set by ParakeetModelManager after a successful download.
    /// FluidAudio manages its own CoreML cache, so we rely on this flag
    /// rather than checking for specific files on disk.
    func parakeetModelIsReady() -> Bool {
        guard let suite = UserDefaults(suiteName: groupID) else { return false }
        return suite.bool(forKey: Self.parakeetReadyKey)
    }

    func resetParakeetDownloadState() {
        onMain {
            self.requested.remove(Variant.parakeet.rawValue)
            self.waiters.removeValue(forKey: Variant.parakeet.rawValue)
            self.postDownloadState(variant: .parakeet, inFlight: false)
        }
    }

    func modelFilePath(for variant: Variant) -> String? {
        switch variant {
        case .parakeet:
            return parakeetModelDirectory?.path
        case .base, .baseEn, .hviske, .ekko:
            return containerURL?.appendingPathComponent(variant.filename).path
        }
    }

    /// ekko is ready only with its GGUF and every ekko-pnc runtime file on disk.
    func modelIsReady(for variant: Variant) -> Bool {
        switch variant {
        case .parakeet:
            return parakeetModelIsReady()
        case .base, .baseEn, .hviske:
            return weightsArePresent(variant)
        case .ekko:
            return weightsArePresent(variant) && punctuationModelIsInstalled
        }
    }

    /// The folder holding ekko-pnc's runtime files. Mirror of
    /// `ModelManager.punctuationModelDirectory`.
    var punctuationModelDirectory: URL? {
        containerURL?.appendingPathComponent(PunctuationModel.directoryName, isDirectory: true)
    }

    var punctuationModelIsInstalled: Bool {
        PunctuationModel.runtimeFiles.allSatisfy { file in
            guard let url = punctuationModelDirectory?.appendingPathComponent(file.path) else {
                return false
            }
            return Self.fileSize(atPath: url.path) == file.bytes
        }
    }

    /// Bytes on disk for a file-backed Speech Model, counting ekko-pnc's runtime files for
    /// ekko, which downloads them.
    func installedBytes(for variant: Variant) -> Int64 {
        guard let path = modelFilePath(for: variant) else { return 0 }
        var bytes = Self.fileSize(atPath: path)
        if variant == .ekko, let directory = punctuationModelDirectory {
            for file in PunctuationModel.runtimeFiles {
                bytes += Self.fileSize(atPath: directory.appendingPathComponent(file.path).path)
            }
        }
        return bytes
    }

    /// Removes a file-backed Speech Model's files. Deleting ekko removes ekko-pnc too: on
    /// iOS only ekko uses the Punctuation Model, so it is part of what ekko installs and
    /// downloading ekko again brings it back. Revisit if another Speech Model starts using it.
    func deleteFiles(for variant: Variant) {
        if let path = modelFilePath(for: variant) {
            try? FileManager.default.removeItem(atPath: path)
        }
        if variant == .ekko, let directory = punctuationModelDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func weightsArePresent(_ variant: Variant) -> Bool {
        guard let path = modelFilePath(for: variant) else { return false }
        return Self.fileSize(atPath: path) >= variant.minBytes
    }

    private static func fileSize(atPath path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int64) ?? 0
    }

    /// Asks the Host to make a Speech Model's weights present, and reports back on the
    /// callbacks the Expo module turns into `onModelProgress` and a resolved promise.
    ///
    /// This module is a requester, never a downloader. It cannot own the background
    /// URLSession: iOS relaunches a terminated app to finish a background download without
    /// initialising React Native, so a session attached from `OnCreate` would never be
    /// recreated on the one launch that exists to file the bytes. The Host attaches it from
    /// `KeyboardHostRecorder.bootstrap()`, which runs on that launch. Parakeet already
    /// worked this way for a different reason -- FluidAudio cannot be imported here -- and
    /// both requests answer over the same shape.
    func ensureModel(
        variant: Variant,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        // Expo calls this off the main queue; the waiter bookkeeping below and the
        // observers that drain it are main-queue only.
        onMain {
            self.startEnsure(variant: variant, onProgress: onProgress, onComplete: onComplete)
        }
    }

    // MARK: - Private

    private func startEnsure(
        variant: Variant,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        if variant != .parakeet, containerURL == nil {
            onComplete(.failure(NSError(
                domain: "AppGroupModelManager", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable."]
            )))
            return
        }

        if modelIsReady(for: variant), let path = modelFilePath(for: variant) {
            onComplete(.success(path))
            return
        }

        installObserversIfNeeded()
        waiters[variant.rawValue, default: []].append((onProgress, onComplete))

        // The Host de-duplicates concurrent tasks for the same URL too; this stops a
        // second tap from posting a second request at all.
        guard !requested.contains(variant.rawValue) else { return }
        requested.insert(variant.rawValue)
        onProgress(0)

        if variant == .parakeet {
            // The Host's download coordinator posts in-flight state for the file-backed
            // Speech Models. FluidAudio posts none, so the requester says it instead.
            postDownloadState(variant: .parakeet, inFlight: true)
            NotificationCenter.default.post(
                name: Self.parakeetEnsureModelNotification,
                object: nil
            )
            return
        }

        NotificationCenter.default.post(
            name: Self.ensureModelNotification,
            object: nil,
            userInfo: ["variant": variant.rawValue]
        )
    }

    /// Tells the Host's Dictation Readiness resolver that a download started or stopped.
    /// Mirror of `ModelDownloadNotification.stateChanged`.
    private func postDownloadState(variant: Variant, inFlight: Bool) {
        NotificationCenter.default.post(
            name: Self.downloadStateChangedNotification,
            object: nil,
            userInfo: ["variant": variant.rawValue, "inFlight": inFlight]
        )
    }

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true

        NotificationCenter.default.addObserver(
            forName: Self.progressNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?["variant"] as? String,
                  let variant = Variant(rawValue: raw) else { return }
            self.deliverProgress(variant, (note.userInfo?["progress"] as? Double) ?? 0)
        }

        NotificationCenter.default.addObserver(
            forName: Self.readyNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?["variant"] as? String,
                  let variant = Variant(rawValue: raw) else { return }
            let path = (note.userInfo?["path"] as? String)
                ?? self.modelFilePath(for: variant)
                ?? ""
            self.finish(variant, .success(path))
        }

        NotificationCenter.default.addObserver(
            forName: Self.failedNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?["variant"] as? String,
                  let variant = Variant(rawValue: raw) else { return }
            let message = (note.userInfo?["error"] as? String) ?? "Model download failed."
            self.finish(variant, .failure(NSError(
                domain: "AppGroupModelManager", code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]
            )))
        }

        // Parakeet answers on its own notification names: it is downloaded by FluidAudio
        // inside `ParakeetModelManager`, not by the Host's URLSession, and carries no
        // variant in its userInfo because it can only ever be about Parakeet.
        NotificationCenter.default.addObserver(
            forName: Self.parakeetProgressNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.deliverProgress(.parakeet, (note.userInfo?["progress"] as? Double) ?? 0)
        }

        NotificationCenter.default.addObserver(
            forName: Self.parakeetReadyNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.postDownloadState(variant: .parakeet, inFlight: false)
            self.finish(.parakeet, .success(self.parakeetModelDirectory?.path ?? ""))
        }

        NotificationCenter.default.addObserver(
            forName: Self.parakeetFailedNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let message = (note.userInfo?["error"] as? String) ?? "Parakeet model download failed."
            self.postDownloadState(variant: .parakeet, inFlight: false)
            self.finish(.parakeet, .failure(NSError(
                domain: "AppGroupModelManager", code: 3,
                userInfo: [NSLocalizedDescriptionKey: message]
            )))
        }
    }

    private func deliverProgress(_ variant: Variant, _ fraction: Double) {
        for waiter in waiters[variant.rawValue] ?? [] {
            waiter.onProgress(fraction)
        }
    }

    private func finish(_ variant: Variant, _ result: Result<String, Error>) {
        requested.remove(variant.rawValue)
        let pending = waiters.removeValue(forKey: variant.rawValue) ?? []
        for waiter in pending {
            waiter.onComplete(result)
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
