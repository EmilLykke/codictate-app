import FluidAudio
import Foundation

/// Notification names for cross-module Parakeet model management.
/// The Expo module posts `ensureModel` to trigger a download;
/// the main app posts `progress` and `ready`/`failed` back.
enum ParakeetModelNotification {
    static let ensureModel = Notification.Name("codictate.parakeet.ensureModel")
    static let progress = Notification.Name("codictate.parakeet.progress")
    static let ready = Notification.Name("codictate.parakeet.ready")
    static let failed = Notification.Name("codictate.parakeet.failed")
}

/// Manages the Parakeet TDT v3 CoreML model lifecycle.
/// Uses FluidAudio's `downloadAndLoad` for first-time download and `load(from:)`
/// for subsequent launches. Models are stored in the app's Documents directory
/// (not the App Group), because only the main app process runs Parakeet inference.
final class ParakeetModelManager {

    static let shared = ParakeetModelManager()

    private static let modelDirName = "parakeet-tdt-v3"

    private static let readyKey = "parakeetModelReady"

    private(set) var loadedModels: AsrModels?
    private var downloadTask: Task<Void, Error>?
    private let downloadLock = NSLock()

    var modelDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(Self.modelDirName, isDirectory: true)
    }

    /// Persistent readiness flag: true after first successful download+load.
    /// FluidAudio caches the CoreML models across launches, so the flag
    /// indicates that `downloadAndLoad` will resolve from cache on next call.
    var isReady: Bool {
        if loadedModels != nil { return true }
        let suite = UserDefaults(suiteName: "group.app.codictate")
        return suite?.bool(forKey: Self.readyKey) == true
    }

    /// Downloads (if needed) and loads the Parakeet TDT v3 CoreML models.
    /// FluidAudio manages the on-disk cache internally; `downloadAndLoad`
    /// is a no-op when the cache is warm.
    func downloadAndPrepare() async throws {
        if loadedModels != nil { return }

        downloadLock.lock()
        if downloadTask == nil {
            downloadTask = Task { [weak self] in
                guard let self else { return }
                try await self.performDownload()
            }
        }
        let task = downloadTask!
        downloadLock.unlock()

        do {
            try await task.value
        } catch {
            downloadLock.lock()
            downloadTask = nil
            downloadLock.unlock()
            throw error
        }
    }

    private func performDownload() async throws {
        NotificationCenter.default.post(
            name: ParakeetModelNotification.progress,
            object: nil,
            userInfo: ["progress": 0.0]
        )

        let models = try await AsrModels.downloadAndLoad(version: .v3)
        loadedModels = models

        let suite = UserDefaults(suiteName: "group.app.codictate")
        suite?.set(true, forKey: Self.readyKey)
        suite?.synchronize()

        NotificationCenter.default.post(
            name: ParakeetModelNotification.progress,
            object: nil,
            userInfo: ["progress": 1.0]
        )
    }

    /// Installs a NotificationCenter observer for the Expo module's download request.
    /// Called once from `KeyboardHostRecorder.bootstrap()`.
    func installObserver() {
        NotificationCenter.default.addObserver(
            forName: ParakeetModelNotification.ensureModel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task {
                do {
                    try await self.downloadAndPrepare()
                    NotificationCenter.default.post(
                        name: ParakeetModelNotification.ready,
                        object: nil
                    )
                } catch {
                    NotificationCenter.default.post(
                        name: ParakeetModelNotification.failed,
                        object: nil,
                        userInfo: ["error": error.localizedDescription]
                    )
                }
            }
        }
    }
}

/// Parakeet TDT v3 ASR backend via FluidAudio.
/// Transcribes WAV files in batch mode using the Neural Engine.
final class ParakeetEngine: TranscriptionEngine {

    private var asrManager: AsrManager?
    private var decoderState: TdtDecoderState?

    func transcribe(wavPath: String) async throws -> String {
        try await loadIfNeeded()
        guard let asr = asrManager else {
            throw NSError(
                domain: "ParakeetEngine", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ASR manager not initialized."]
            )
        }

        let layers = await asr.decoderLayerCount
        var state = TdtDecoderState.make(decoderLayers: layers)

        let url = URL(fileURLWithPath: wavPath)
        let result = try await asr.transcribe(url, decoderState: &state)
        return result.text
    }

    func warmUp() async throws {
        try await loadIfNeeded()
    }

    // MARK: - Private

    private func loadIfNeeded() async throws {
        guard asrManager == nil else { return }

        if let models = ParakeetModelManager.shared.loadedModels {
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.asrManager = manager
            return
        }

        try await ParakeetModelManager.shared.downloadAndPrepare()

        guard let models = ParakeetModelManager.shared.loadedModels else {
            throw NSError(
                domain: "ParakeetEngine", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Models not available after download."]
            )
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
    }
}
