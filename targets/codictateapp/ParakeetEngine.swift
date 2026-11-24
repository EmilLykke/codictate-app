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
/// Uses FluidAudio's `downloadAndLoad(to: modelDirectory)`, which downloads once and then
/// loads from that folder. The folder is in the App Group, not FluidAudio's default
/// Application Support cache, because the keyboard extension loads the same files and
/// cannot read the app's own container.
final class ParakeetModelManager {

    static let shared = ParakeetModelManager()

    private static let readyKey = "parakeetModelReady"
    /// True while a Parakeet Preparation the app shows is running. The Host writes, JS reads.
    private static let preparingKey = "parakeetPreparing"

    private(set) var loadedModels: AsrModels?
    private var downloadTask: Task<Void, Error>?
    private let downloadLock = NSLock()

    private static let appGroupID = "group.app.codictate"
    /// The leaf every other reader of the models hard-codes: the Expo module's
    /// `AppGroupModelManager.parakeetModelDirectory` and the keyboard extension.
    private static let expectedFolderName = "parakeet-tdt-0.6b-v3"

    /// Where FluidAudio kept the models before they moved to the App Group:
    /// `Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`. Read only by
    /// `migrateLegacyModelsIfNeeded()`.
    private static var legacyModelDirectory: URL {
        AsrModels.defaultCacheDirectory(for: .v3)
    }

    /// `<App Group>/FluidAudio/Models/parakeet-tdt-0.6b-v3`: FluidAudio's own relative
    /// layout, rooted in the App Group so the keyboard extension loads the same files.
    /// The leaf must be FluidAudio's folder name, because `download(to:)` and `load(from:)`
    /// write and read `directory.deletingLastPathComponent()/<folderName>`, whatever leaf
    /// they are given. Mirrored as a literal by `AppGroupModelManager.parakeetModelDirectory`
    /// in the Expo module, which cannot import FluidAudio, and by the keyboard extension;
    /// keep them the same. Without an App Group container (a missing entitlement) it falls
    /// back to FluidAudio's default, which only this process can read.
    let modelDirectory: URL = {
        let folderName = ParakeetModelManager.legacyModelDirectory.lastPathComponent
        if folderName != ParakeetModelManager.expectedFolderName {
            NSLog("[ParakeetModelManager] FluidAudio's v3 folder is \(folderName), not \(ParakeetModelManager.expectedFolderName); the Expo module and keyboard look in the wrong place")
            assertionFailure("FluidAudio renamed the Parakeet v3 folder")
        }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: ParakeetModelManager.appGroupID
        ) else {
            NSLog("[ParakeetModelManager] No App Group container; using FluidAudio's default cache")
            return ParakeetModelManager.legacyModelDirectory
        }
        return container
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }()

    private var modelsExistOnDisk: Bool {
        AsrModels.modelsExist(at: modelDirectory, version: .v3)
    }

    /// Persistent readiness flag: true after first successful download+load.
    /// The models stay in `modelDirectory` across launches, so the flag
    /// indicates that `downloadAndLoad` will resolve from disk on next call.
    /// `migrateLegacyModelsIfNeeded()` clears it when the files are not there.
    var isReady: Bool {
        if loadedModels != nil { return true }
        let suite = UserDefaults(suiteName: Self.appGroupID)
        return suite?.bool(forKey: Self.readyKey) == true
    }

    /// Moves models FluidAudio downloaded into Application Support before this build into
    /// `modelDirectory`, so an update neither re-downloads ~500 MB nor leaves it behind.
    /// Both folders are on the same APFS volume, so the move is a rename and the copy
    /// fallback a clone. An incomplete legacy folder moves too, since FluidAudio downloads
    /// only the files missing from it. The legacy folder is deleted only once
    /// `modelDirectory` holds the models.
    /// Then reconciles `parakeetModelReady` with the disk, so the flag never claims models
    /// that are not at `modelDirectory`; the next load downloads them there.
    /// Synchronous: call from `KeyboardHostRecorder.bootstrap()` before anything reads
    /// readiness or loads Parakeet.
    func migrateLegacyModelsIfNeeded() {
        let suite = UserDefaults(suiteName: Self.appGroupID)
        let legacy = Self.legacyModelDirectory
        let destination = modelDirectory
        let fileManager = FileManager.default

        if legacy.standardizedFileURL != destination.standardizedFileURL,
           fileManager.fileExists(atPath: legacy.path) {
            if modelsExistOnDisk {
                Self.removeLegacy(legacy, reason: "App Group already has the models")
            } else if Self.moveLegacy(legacy, to: destination) {
                // The Neural Engine copy is cached per model path, so the first load
                // from the new path recompiles; let the after-update Preparation run it.
                suite?.removeObject(forKey: KeyboardDictationBridge.parakeetPreparedBuildKey)
            }
        }

        if suite?.bool(forKey: Self.readyKey) == true, !modelsExistOnDisk {
            NSLog("[ParakeetModelManager] parakeetModelReady was set but no models are at \(destination.path); clearing it")
            suite?.removeObject(forKey: Self.readyKey)
        }
        suite?.synchronize()
    }

    /// Moves, else copies then deletes the source. A partial copy is removed, so the
    /// legacy folder stays the only copy. True once `destination` holds everything
    /// `legacy` held.
    private static func moveLegacy(_ legacy: URL, to destination: URL) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Only an incomplete folder (an interrupted download) gets here, and it would
            // make the move fail.
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
        } catch {
            NSLog("[ParakeetModelManager] Migration could not prepare \(destination.path): \(error.localizedDescription); keeping \(legacy.path)")
            return false
        }

        do {
            try fileManager.moveItem(at: legacy, to: destination)
            NSLog("[ParakeetModelManager] Moved Parakeet models to \(destination.path)")
            return true
        } catch {
            NSLog("[ParakeetModelManager] Move failed: \(error.localizedDescription); copying instead")
        }

        do {
            try fileManager.copyItem(at: legacy, to: destination)
        } catch {
            NSLog("[ParakeetModelManager] Copy failed: \(error.localizedDescription); keeping \(legacy.path)")
            try? fileManager.removeItem(at: destination)
            return false
        }
        NSLog("[ParakeetModelManager] Copied Parakeet models to \(destination.path)")
        // A failed delete is retried on the next launch, which finds both folders.
        removeLegacy(legacy, reason: "copied to the App Group")
        return true
    }

    private static func removeLegacy(_ legacy: URL, reason: String) {
        do {
            try FileManager.default.removeItem(at: legacy)
            NSLog("[ParakeetModelManager] Deleted \(legacy.path) (\(reason))")
        } catch {
            NSLog("[ParakeetModelManager] Could not delete \(legacy.path) (\(reason)): \(error.localizedDescription)")
        }
    }

    /// Clears in-memory cache after Settings delete so re-download runs fully, and lets go
    /// of the loaded models before the Expo module removes `modelDirectory`.
    /// `ParakeetEngine` releases its `AsrManager` on the same notification.
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
    /// A redundant `true` is skipped; `false` always publishes, so a stale `true`
    /// is always cleared.
    func setPreparing(_ preparing: Bool) {
        guard !preparing || !isPreparing else { return }
        isPreparing = preparing
        NSLog("[ParakeetModelManager] preparing=\(preparing)")
        let suite = UserDefaults(suiteName: Self.appGroupID)
        suite?.set(preparing, forKey: Self.preparingKey)
        suite?.synchronize()
        NotificationCenter.default.post(
            name: ParakeetModelNotification.preparing,
            object: nil,
            userInfo: ["preparing": preparing]
        )
    }

    /// Downloads (if needed) and loads the Parakeet TDT v3 CoreML models.
    /// `downloadAndLoad(to: modelDirectory)` skips the download when the files are
    /// already there.
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

        // No configuration: FluidAudio's default keeps every part on the CPU and Neural
        // Engine, never the GPU, which iOS forbids in the background.
        let models = try await AsrModels.downloadAndLoad(to: modelDirectory, version: .v3)
        loadedModels = models

        let suite = UserDefaults(suiteName: Self.appGroupID)
        suite?.set(true, forKey: Self.readyKey)
        suite?.synchronize()

        NotificationCenter.default.post(
            name: ParakeetModelNotification.progress,
            object: nil,
            userInfo: ["progress": 1.0]
        )
    }

    private func syncReadyFlag() {
        let suite = UserDefaults(suiteName: Self.appGroupID)
        suite?.set(true, forKey: Self.readyKey)
        suite?.synchronize()
    }

    /// Installs a NotificationCenter observer for the Expo module's download request.
    /// Called once from `KeyboardHostRecorder.bootstrap()`.
    func installObserver() {
        // A Preparation cut short by the process ending must not leave the app showing it.
        let suite = UserDefaults(suiteName: Self.appGroupID)
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
        // Posted when the user deletes Parakeet: nothing may keep the model files loaded.
        NotificationCenter.default.addObserver(
            forName: ParakeetModelNotification.reset,
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
    /// same memory warning or delete. A transcription already running keeps its own reference and
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
