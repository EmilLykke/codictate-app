import FluidAudio
import Foundation
import UIKit

/// Notification names for cross-module Parakeet model management.
/// The Expo module posts `ensureModel` to trigger a download;
/// the main app posts `progress` and `ready`/`failed` back.
enum ParakeetModelNotification {
    static let ensureModel = Notification.Name("codictate.parakeet.ensureModel")
    static let progress = Notification.Name("codictate.parakeet.progress")
    static let ready = Notification.Name("codictate.parakeet.ready")
    static let failed = Notification.Name("codictate.parakeet.failed")
    static let reset = Notification.Name("codictate.parakeet.reset")
    /// Parakeet Preparation has run long enough to show. userInfo: `["preparing": Bool]`.
    static let preparing = Notification.Name("codictate.parakeet.preparing")
}

/// Manages the Parakeet TDT v3 CoreML model lifecycle.
/// Uses FluidAudio's `downloadAndLoad` for first-time download and `load(from:)`
/// for subsequent launches. Models are stored in the app's Documents directory
/// (not the App Group), because only the main app process runs Parakeet inference.
final class ParakeetModelManager {

    static let shared = ParakeetModelManager()

    private static let modelDirName = "parakeet-tdt-v3"

    private static let readyKey = "parakeetModelReady"
    /// True while a Parakeet Preparation the app shows is running. The Host writes, JS reads.
    private static let preparingKey = "parakeetPreparing"

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

    /// Clears in-memory cache after Settings delete so re-download runs fully.
    func resetAfterDelete() {
        downloadLock.lock()
        downloadTask?.cancel()
        downloadTask = nil
        loadedModels = nil
        downloadLock.unlock()
    }

    /// Drops the loaded models on a memory warning; the next Dictation loads them again.
    /// A download still in flight is left alone, since cancelling it would throw the
    /// bytes away.
    func releaseLoadedModels() {
        downloadLock.lock()
        if loadedModels != nil {
            loadedModels = nil
            downloadTask = nil
        }
        downloadLock.unlock()
    }

    private(set) var isPreparing = false

    /// Publishes whether the app should show "Preparing Parakeet". Main thread only.
    func setPreparing(_ preparing: Bool) {
        guard preparing != isPreparing else { return }
        isPreparing = preparing
        let suite = UserDefaults(suiteName: "group.app.codictate")
        suite?.set(preparing, forKey: Self.preparingKey)
        suite?.synchronize()
        NotificationCenter.default.post(
            name: ParakeetModelNotification.preparing,
            object: nil,
            userInfo: ["preparing": preparing]
        )
    }

    /// Downloads (if needed) and loads the Parakeet TDT v3 CoreML models.
    /// FluidAudio manages the on-disk cache internally; `downloadAndLoad`
    /// is a no-op when the cache is warm.
    func downloadAndPrepare() async throws {
        if loadedModels != nil {
            syncReadyFlag()
            return
        }

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

    private func syncReadyFlag() {
        let suite = UserDefaults(suiteName: "group.app.codictate")
        suite?.set(true, forKey: Self.readyKey)
        suite?.synchronize()
    }

    /// Installs a NotificationCenter observer for the Expo module's download request.
    /// Called once from `KeyboardHostRecorder.bootstrap()`.
    func installObserver() {
        // A Preparation cut short by the process ending must not leave the app showing it.
        let suite = UserDefaults(suiteName: "group.app.codictate")
        suite?.removeObject(forKey: Self.preparingKey)

        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.releaseLoadedModels()
        }

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

        NotificationCenter.default.addObserver(
            forName: ParakeetModelNotification.reset,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetAfterDelete()
        }
    }
}

/// Parakeet TDT v3 ASR backend via FluidAudio.
/// Transcribes WAV files in batch mode using the Neural Engine.
///
/// The loaded `AsrManager` is kept for the life of the process, warm session or not, and
/// dropped only on a memory warning. One load runs at a time: a `transcribe()` that
/// arrives while a `warmUp()` is loading joins that load instead of starting another.
final class ParakeetEngine: TranscriptionEngine {

    private var asrManager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?
    private let loadLock = NSLock()

    init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.unload()
        }
    }

    /// `languageId` is ignored: Parakeet TDT v3 takes no language input, which is
    /// why its Language Lock pins it to automatic instead of to a code list.
    func transcribe(wavPath: String, languageId: String) async throws -> String {
        let asr = try await loadIfNeeded()

        let layers = await asr.decoderLayerCount
        var state = TdtDecoderState.make(decoderLayers: layers)

        let url = URL(fileURLWithPath: wavPath)
        let result = try await asr.transcribe(url, decoderState: &state)
        return result.text
    }

    func warmUp() async throws {
        _ = try await loadIfNeeded()
    }

    /// Releases the loaded `AsrManager`; `ParakeetModelManager` drops its models on the
    /// same memory warning. A transcription already running keeps its own reference and
    /// finishes; a load in flight finishes for its callers but is not kept.
    func unload() {
        loadLock.lock()
        asrManager = nil
        loadTask = nil
        loadLock.unlock()
        NSLog("[ParakeetEngine] Released AsrManager")
    }

    // MARK: - Private

    private enum LoadState {
        case loaded(AsrManager)
        case loading(Task<AsrManager, Error>)
    }

    private func loadIfNeeded() async throws -> AsrManager {
        let task: Task<AsrManager, Error>
        switch beginLoad() {
        case .loaded(let manager):
            return manager
        case .loading(let loading):
            task = loading
        }

        do {
            let manager = try await task.value
            finishLoad(task, keeping: manager)
            return manager
        } catch {
            finishLoad(task, keeping: nil)
            throw error
        }
    }

    /// Returns the loaded manager, or the load to join, starting one if none is running.
    /// Synchronous so the lock is never held across a suspension point.
    private func beginLoad() -> LoadState {
        loadLock.lock()
        defer { loadLock.unlock() }
        if let asrManager { return .loaded(asrManager) }
        if let loadTask { return .loading(loadTask) }
        let task = Task { try await Self.loadManager() }
        loadTask = task
        return .loading(task)
    }

    /// Keeps the result unless `unload()` dropped this load while it ran.
    private func finishLoad(_ task: Task<AsrManager, Error>, keeping manager: AsrManager?) {
        loadLock.lock()
        defer { loadLock.unlock() }
        guard loadTask == task else { return }
        asrManager = manager
        loadTask = nil
    }

    private static func loadManager() async throws -> AsrManager {
        if let models = ParakeetModelManager.shared.loadedModels {
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
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
        return manager
    }
}
