import AVFoundation
import Foundation

/// The Speech Models the Dictation AU runs for the keyboard's In-keyboard path: every one but
/// Parakeet, which the keyboard runs itself on the Neural Engine. These are the Host's own
/// engines (`WhisperEngine`, `CohereEngine`, `EkkoEngine` and `PunctuationRestorer`, the same
/// files), so a keyboard turn is decoded exactly as a Host turn. They read the Host's files in
/// the App Group and never download.
///
/// One engine holds a model at a time: asking for another frees the first. Every load,
/// transcription and unload runs in arrival order on one serial chain (`enqueue`), so a model
/// is never freed under a running transcription.
///
/// GPU: Whisper, hviske and ekko ask for Metal, as in the Host. This process works for a
/// keyboard, out of process, and iOS may refuse it GPU work. A load or run that fails while
/// Metal is allowed turns Metal off for every engine in this process, frees the model and
/// tries once more on the CPU.
final class DictationAUSpeech: @unchecked Sendable {
    static let shared = DictationAUSpeech()

    typealias Variant = SpeechModelCatalog.Variant

    let punctuation: PunctuationRestorer?
    private let whisper = WhisperEngine(modelPath: DictationAUSpeech.installedModelPath)
    private let cohere = CohereEngine(modelPath: DictationAUSpeech.installedModelPath)
    private let ekko = EkkoEngine(modelPath: DictationAUSpeech.installedModelPath)

    private let chainLock = NSLock()
    /// The last job on the chain. Guarded by `chainLock`.
    private var tail: Task<Void, Never>?

    // Only touched on the chain.
    private var loadedVariant: Variant?
    private var loadedBefore: Set<Variant.Engine> = []
    private var gpuAllowed = true

    private init() {
        punctuation = SpeechModelCatalog.punctuationModelDirectory.map {
            PunctuationRestorer(modelDirectory: $0.path)
        }
    }

    /// Runs `job` after every job enqueued before it.
    func enqueue(_ job: @escaping @Sendable () async -> Void) {
        chainLock.lock()
        let previous = tail
        tail = Task(priority: .userInitiated) {
            await previous?.value
            await job()
        }
        chainLock.unlock()
    }

    /// The pipeline's readiness step in this process. The microphone has already done its
    /// part (the keyboard recorded), and a download writes its file only once complete, so
    /// the Host's rule runs with the files on disk deciding `weightsMissing`.
    static func readiness(_ variant: Variant, _ languageId: String) -> DictationReadinessState {
        DictationReadinessState.resolve(
            variant: variant,
            languageId: languageId,
            micPermissionDenied: false,
            downloadInProgress: false,
            modelIsReady: { SpeechModelCatalog.filesAreInstalled(for: variant) }
        )
    }

    /// The pipeline's engine step: the Host's engine for `variant`, wrapped to log, keep one
    /// model loaded and fall back to the CPU. On the chain only.
    func engine(for variant: Variant) -> TranscriptionEngine {
        GuardedEngine(speech: self, variant: variant)
    }

    /// Loads `variant` (and ekko's Punctuation Model) ahead of its transcription. On the chain.
    func prewarm(_ variant: Variant) async {
        guard SpeechModelCatalog.filesAreInstalled(for: variant) else {
            AppGroupLog.write("[DictationAU] Prewarm \(variant.rawValue) skipped: files not installed")
            return
        }
        do {
            try await load(variant)
        } catch {
            AppGroupLog.write("[DictationAU] Prewarm \(variant.rawValue) failed: \(error.localizedDescription)")
        }
        if variant.engine == .ekko, let punctuation {
            let started = Date()
            await punctuation.warmUp()
            AppGroupLog.write(String(format: "[DictationAU] ekko-pnc ready in %.2f s", Date().timeIntervalSince(started)))
        }
    }

    /// Frees the loaded Speech Model once the jobs before it are done.
    func unloadAll(reason: String) {
        enqueue { [self] in
            guard let variant = loadedVariant else { return }
            free(variant.engine)
            loadedVariant = nil
            AppGroupLog.write("[DictationAU] \(variant.rawValue) unloaded (\(reason)) \(DictationAUMemory.current())")
        }
    }

    // MARK: - On the chain

    private func base(_ engine: Variant.Engine) -> TranscriptionEngine? {
        switch engine {
        case .parakeet: return nil
        case .whisper: return whisper
        case .cohere: return cohere
        case .ekko: return ekko
        }
    }

    private func free(_ engine: Variant.Engine) {
        switch engine {
        case .parakeet: break
        case .whisper: whisper.unload()
        case .cohere: cohere.unload()
        case .ekko: ekko.unload()
        }
    }

    private var deviceLabel: String { gpuAllowed ? "GPU (Metal requested)" : "CPU" }

    /// Loads `variant`, freeing another engine's model first, and logs how long it took.
    fileprivate func load(_ variant: Variant) async throws {
        guard let engine = base(variant.engine) else {
            throw DictationAUError("Parakeet runs in the keyboard, not the Dictation AU.")
        }
        if let loaded = loadedVariant, loaded.engine != variant.engine {
            free(loaded.engine)
            AppGroupLog.write("[DictationAU] \(loaded.rawValue) unloaded for \(variant.rawValue)")
        }
        if variant.engine == .whisper { whisper.activeVariant = variant }
        if loadedVariant == variant {
            AppGroupLog.write("[DictationAU] \(variant.rawValue) already loaded (warm) on \(deviceLabel)")
            return
        }
        let kind = loadedBefore.contains(variant.engine) ? "reload" : "cold, first load in this process"
        let started = Date()
        loadedVariant = nil
        try await withGPUFallback(variant, "load") { try await engine.warmUp() }
        loadedVariant = variant
        loadedBefore.insert(variant.engine)
        AppGroupLog.write(String(
            format: "[DictationAU] %@ loaded in %.2f s (%@) on %@ %@",
            variant.rawValue, Date().timeIntervalSince(started), kind, deviceLabel, DictationAUMemory.current()
        ))
    }

    fileprivate func transcribe(_ variant: Variant, wavPath: String, languageId: String) async throws -> String {
        try await load(variant)
        guard let engine = base(variant.engine) else {
            throw DictationAUError("Parakeet runs in the keyboard, not the Dictation AU.")
        }
        let audioSeconds = Self.audioSeconds(wavPath) ?? 0
        let started = Date()
        let text = try await withGPUFallback(variant, "transcription") {
            try await engine.transcribe(wavPath: wavPath, languageId: languageId)
        }
        // A CPU retry reloaded the model.
        loadedVariant = variant
        AppGroupLog.write(String(
            format: "[DictationAU] %@ transcribed %.1f s of audio in %.2f s on %@, %d chars %@",
            variant.rawValue, audioSeconds, Date().timeIntervalSince(started), deviceLabel, text.count,
            DictationAUMemory.current()
        ))
        return text
    }

    /// Runs `operation`; when it fails with Metal allowed, turns Metal off for every engine in
    /// this process and runs it once more. No speech is a result, not a fault.
    private func withGPUFallback<T>(
        _ variant: Variant, _ step: String, _ operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch TranscriptionEngineError.noSpeech {
            throw TranscriptionEngineError.noSpeech
        } catch let error as DictationAUError {
            throw error
        } catch {
            guard gpuAllowed else { throw error }
            AppGroupLog.write(
                "[DictationAU] \(variant.rawValue) \(step) failed on the GPU (\(error.localizedDescription)); retrying on the CPU, and the CPU from now on in this process"
            )
            gpuAllowed = false
            whisper.allowsGPU = false
            cohere.allowsGPU = false
            ekko.allowsGPU = false
            return try await operation()
        }
    }

    /// The recording's length; nil when it cannot be read as audio.
    static func audioSeconds(_ wavPath: String) -> Double? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: wavPath)),
              file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// The engines' `ModelPathProvider` here: the installed file, never a download.
    private static func installedModelPath(_ variant: Variant) async throws -> String {
        guard SpeechModelCatalog.filesAreInstalled(for: variant),
              let path = SpeechModelCatalog.weightsPath(for: variant) else {
            throw DictationAUError(DictationReadinessState.message(for: .weightsMissing, variant: variant))
        }
        return path
    }
}

/// One Speech Model's engine as the pipeline sees it in the Dictation AU: loads through
/// `DictationAUSpeech`, which keeps one model loaded, logs, and falls back to the CPU.
private final class GuardedEngine: TranscriptionEngine {
    private let speech: DictationAUSpeech
    private let variant: SpeechModelCatalog.Variant

    init(speech: DictationAUSpeech, variant: SpeechModelCatalog.Variant) {
        self.speech = speech
        self.variant = variant
    }

    func transcribe(wavPath: String, languageId: String) async throws -> String {
        try await speech.transcribe(variant, wavPath: wavPath, languageId: languageId)
    }

    func warmUp() async throws {
        try await speech.load(variant)
    }
}

struct DictationAUError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
