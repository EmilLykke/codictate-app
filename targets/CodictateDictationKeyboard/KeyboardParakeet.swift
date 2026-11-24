import CoreML
import Darwin
import FluidAudio
import Foundation

// Adapted from Hex (anomalyco/hex, MIT, `KeyboardParakeet.swift` and
// `KeyboardParakeetSettings.swift`'s `KeyboardParakeetBudget`). See NOTICE.

/// Parakeet TDT v3 in the keyboard's own process, for the In-keyboard path.
///
/// Loads the Host's models from the App Group on the Neural Engine. The Neural Engine's copy
/// of the model lives outside the footprint iOS limits a keyboard to, which is what makes
/// a 600 MB model fit a keyboard: Hex measured its keyboard at a 177 MB limit with Parakeet
/// loaded. The first load in a build compiles the model for the Neural Engine (about 15 s);
/// later loads take about 0.3 s. Loaded once and kept for the process lifetime, until a
/// memory warning. A load that fails, or lands off the Neural Engine, sets the path aside
/// for this process, and the keyboard goes back to handing dictation to the Host.
@MainActor
final class KeyboardParakeet {
    static let shared = KeyboardParakeet()

    /// `<App Group>/FluidAudio/Models/parakeet-tdt-0.6b-v3/`, where the Host keeps Parakeet.
    /// The leaf must stay FluidAudio's folder name, because `AsrModels.load(from:)` reads
    /// `directory.deletingLastPathComponent()/<folderName>`.
    nonisolated static var modelDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: KbdSuite.suiteName)?
            .appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3", isDirectory: true)
    }

    /// The Host marked Parakeet ready and every model file is in the App Group.
    nonisolated static func modelIsReady(suite: UserDefaults) -> Bool {
        guard suite.bool(forKey: KbdSuite.parakeetModelReadyKey), let modelDirectory else { return false }
        return AsrModels.modelsExist(at: modelDirectory, version: .v3)
    }

    /// Hex's gate: a Neural Engine, and 6 GB iPhones or more (they report about 5.5 GB).
    nonisolated static var deviceFits: Bool {
        hasNeuralEngine && ProcessInfo.processInfo.physicalMemory >= 5 << 30
    }

    /// A load this long compiled the model; a load Core ML compiled before takes 0.3 s.
    static let compilingLoad: TimeInterval = 5
    /// After a memory warning, no new load in this process for this long.
    static let reloadAfterWarning: TimeInterval = 300
    /// The Neural Engine's memory for the process rose this much: the model is on it.
    static let neuralEngineEvidence = 100 * KeyboardParakeetBudget.megabyte

    private var manager: AsrManager?
    private var loadTask: Task<AsrManager?, Never>?
    private(set) var isSetAside = false
    private var memoryWarnedAt: Date?
    private var isTranscribing = false
    private var releasesAfterTranscription = false

    /// True from an In-keyboard turn's tap to its end: a memory warning meanwhile releases
    /// the model only once the turn is over, so the recording is never left without it.
    var isHeldForTurn = false {
        didSet { releaseIfDeferred() }
    }

    var isLoaded: Bool { manager != nil }
    var isLoading: Bool { loadTask != nil }

    private init() {
        // The keyboard must never download or delete models: FluidAudio's loader re-downloads
        // (and first deletes) a cache it fails to load, and the App Group copy is the Host's.
        ModelHub.offlineMode = true
    }

    /// Why a load cannot start now, or nil when it can (or the model is loaded or loading).
    func loadBlockedReason() -> String? {
        if isLoaded || isLoading { return nil }
        if isSetAside { return "set aside after a failure in this process" }
        if let warned = memoryWarnedAt, Date().timeIntervalSince(warned) < Self.reloadAfterWarning {
            return "memory warning \(Int(Date().timeIntervalSince(warned))) s ago"
        }
        let memory = Self.memory()
        guard KeyboardParakeetBudget.allowsLoad(footprint: memory.footprint, available: memory.available) else {
            return "short of memory to load \(memory)"
        }
        return nil
    }

    /// Starts loading the model off the main thread unless it is loaded, loading or blocked.
    /// Returns whether it is now loaded or loading. Main thread only.
    @discardableResult
    func warmUp() -> Bool {
        if isLoaded || isLoading { return true }
        if let reason = loadBlockedReason() {
            NSLog("[Keyboard] Parakeet not loaded: \(reason)")
            return false
        }
        guard let directory = Self.modelDirectory else { return false }
        let started = Date()
        let neuralBefore = Self.memory().neural
        NSLog("[Keyboard] Parakeet loading \(Self.memory())")
        loadTask = Task { @MainActor [weak self] in
            do {
                let manager = try await Self.load(from: directory)
                let after = Self.memory()
                var onEngine = after.neural - neuralBefore >= Self.neuralEngineEvidence
                if !onEngine, after.neural == 0 {
                    // Before iOS 27 the Neural Engine's memory isn't counted for the process: ask Core ML.
                    onEngine = await Self.plansNeuralEngine(directory)
                }
                let seconds = Date().timeIntervalSince(started)
                guard let self else { return nil }
                self.loadTask = nil
                guard onEngine else {
                    await manager.cleanup()
                    self.setAside("not on the Neural Engine \(Self.memory())")
                    return nil
                }
                self.manager = manager
                let kind = seconds >= Self.compilingLoad ? "cold" : "warm"
                NSLog("[Keyboard] Parakeet loaded in \(String(format: "%.1f", seconds)) s (\(kind)) \(after)")
                return manager
            } catch {
                guard let self else { return nil }
                self.loadTask = nil
                self.setAside("load failed: \(error.localizedDescription) \(Self.memory())")
                return nil
            }
        }
        return true
    }

    /// The loaded manager, waiting for a load in flight; nil when there is neither.
    func loadedManager() async -> AsrManager? {
        if let manager { return manager }
        guard let loadTask else { return nil }
        return await loadTask.value
    }

    /// Transcribes the WAV at `url` the way the Host's `ParakeetEngine` does.
    func transcribe(_ url: URL, audioSeconds: Double) async throws -> String {
        guard let manager = await loadedManager() else {
            throw NSError(
                domain: "KeyboardParakeet", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Parakeet could not load in the keyboard."]
            )
        }
        let before = Self.memory()
        if !KeyboardParakeetBudget.allowsTranscription(
            footprint: before.footprint, available: before.available, audioSeconds: audioSeconds
        ) {
            // Checked for the longest turn at the tap; memory moved since. Try anyway: not
            // trying loses the dictation for certain.
            NSLog("[Keyboard] Parakeet transcribing short of memory \(before)")
        }
        isTranscribing = true
        defer {
            isTranscribing = false
            releaseIfDeferred()
        }
        let started = Date()
        let layers = await manager.decoderLayerCount
        var state = TdtDecoderState.make(decoderLayers: layers)
        let result = try await manager.transcribe(url, decoderState: &state)
        NSLog(String(
            format: "[Keyboard] Parakeet transcribed %.1f s of audio in %.2f s, footprint before %.1f MB, after %@",
            audioSeconds, Date().timeIntervalSince(started), Self.mb(before.footprint), Self.memory().description
        ))
        return result.text
    }

    /// iOS warned the keyboard about memory: the model goes, now or once the turn using it
    /// ends, and no new load starts in this process for `reloadAfterWarning`.
    func handleMemoryWarning() {
        memoryWarnedAt = Date()
        guard manager != nil else { return }
        if isTranscribing || isHeldForTurn {
            releasesAfterTranscription = true
        } else {
            release(reason: "memory warning")
        }
    }

    private func releaseIfDeferred() {
        guard releasesAfterTranscription, !isTranscribing, !isHeldForTurn else { return }
        releasesAfterTranscription = false
        release(reason: "memory warning")
    }

    /// The In-keyboard path is off for the rest of this process.
    func setAside(_ reason: String) {
        isSetAside = true
        NSLog("[Keyboard] In-keyboard path set aside: \(reason)")
        release(reason: "set aside")
    }

    private func release(reason: String) {
        guard let current = manager else { return }
        manager = nil
        Task { await current.cleanup() }
        NSLog("[Keyboard] Parakeet released (\(reason)) \(Self.memory())")
    }

    // MARK: - Loading

    /// FluidAudio's default configuration: the preprocessor on the CPU, the rest on the CPU
    /// and Neural Engine, never the GPU, which a keyboard may not use. One chunk at a time.
    nonisolated private static func load(from directory: URL) async throws -> AsrManager {
        let models = try await Task.detached(priority: .utility) {
            try await AsrModels.load(from: directory, version: .v3)
        }.value
        let manager = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1))
        try await manager.loadModels(models)
        return manager
    }

    nonisolated private static var hasNeuralEngine: Bool {
        MLModel.availableComputeDevices.contains { device in
            if case .neuralEngine = device { return true }
            return false
        }
    }

    /// Whether Core ML puts most of the encoder's work on the Neural Engine. `MLComputePlan`
    /// is iOS 17.4; before it, the configuration's CPU+ANE units are trusted.
    nonisolated private static func plansNeuralEngine(_ directory: URL) async -> Bool {
        guard #available(iOS 17.4, *) else { return true }
        let configuration = AsrModels.defaultConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let encoder = directory.appendingPathComponent(ParakeetEncoderPrecision.int8.encoderFileName)
        guard let plan = try? await MLComputePlan.load(contentsOf: encoder, configuration: configuration),
              case .program(let program) = plan.modelStructure
        else { return false }
        var neural = 0.0
        var total = 0.0
        func walk(_ block: MLModelStructure.Program.Block) {
            for operation in block.operations {
                let weight = plan.estimatedCost(of: operation)?.weight ?? 0
                total += weight
                if case .neuralEngine = plan.deviceUsage(for: operation)?.preferred { neural += weight }
                operation.blocks.forEach(walk)
            }
        }
        program.functions.values.forEach { walk($0.block) }
        return total > 0 && neural / total >= 0.5
    }

    // MARK: - Memory

    struct Memory: CustomStringConvertible {
        let footprint: Int
        let available: Int
        /// The Neural Engine's memory for this process, outside the footprint iOS limits.
        let neural: Int

        var description: String {
            String(
                format: "[limit %.0f MB, footprint %.1f MB, available %.1f MB, neural %.0f MB]",
                KeyboardParakeet.mb(footprint + available), KeyboardParakeet.mb(footprint),
                KeyboardParakeet.mb(available), KeyboardParakeet.mb(neural)
            )
        }
    }

    nonisolated static func memory() -> Memory {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return Memory(footprint: 0, available: os_proc_available_memory(), neural: 0)
        }
        return Memory(
            footprint: Int(info.phys_footprint),
            available: os_proc_available_memory(),
            neural: Int(info.ledger_tag_neural_nofootprint + info.ledger_tag_neural_nofootprint_compressed)
        )
    }

    nonisolated static func mb(_ bytes: Int) -> Double {
        Double(bytes) / Double(KeyboardParakeetBudget.megabyte)
    }
}

/// How much memory Parakeet needs in the keyboard. Hex measured its own keyboard on an
/// iPhone 17 Pro (iOS 27.2, 177 MB keyboard limit): the first load rose 42 MB while
/// compiling, a transcription rose 16 MB above the recording, and FluidAudio holds the
/// recording in memory at about 0.42 MB a second (counted at 0.5). Hex's keyboard records at
/// up to 91 MB with the model loaded; Codictate's has no live words, styles or full keyboard
/// surface, so `recordingFootprint` is an estimate from Hex's first-dictation reading
/// (56 MB) plus room, to replace with a measurement from the `[Keyboard]` footprint logs.
enum KeyboardParakeetBudget {
    static let megabyte = 1_048_576
    static let recordingFootprint = 64 * megabyte
    static let margin = 24 * megabyte
    static let transcriptionRise = 16 * megabyte
    static let loadRise = 42 * megabyte
    static let audioCostPerSecond = megabyte / 2
    /// The longest turn: the keyboard's auto-stop, the same 60 s as the Host's.
    static let longestAudio: TimeInterval = 60

    static var requiredLimit: Int { recordingFootprint + transcriptionRise + margin }
    static var loadHeadroom: Int { loadRise + 16 * megabyte }

    static func transcribeHeadroom(audioSeconds: Double) -> Int {
        transcriptionRise + 8 * megabyte + Int(max(0, audioSeconds) * Double(audioCostPerSecond))
    }

    /// `available` 0 is a process iOS sets no limit for (the simulator): it may.
    static func allowsLoad(footprint: Int, available: Int) -> Bool {
        guard available > 0 else { return true }
        return footprint + available >= requiredLimit && available >= loadHeadroom
    }

    static func allowsTranscription(footprint: Int, available: Int, audioSeconds: Double) -> Bool {
        guard available > 0 else { return true }
        return footprint + available >= requiredLimit
            && available >= transcribeHeadroom(audioSeconds: audioSeconds)
    }
}
