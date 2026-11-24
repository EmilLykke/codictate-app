import Foundation

/// Whisper ASR backend. Wraps the ObjC++ WhisperBridge, which runs crispasr's
/// whisper backend, loading the GGML model the `ModelPathProvider` resolves from the
/// App Group container.
/// `@unchecked Sendable`: every use of the bridge and the loaded-model state runs on the main
/// queue; `allowsGPU` is set only between runs (the Dictation AU's serial chain).
final class WhisperEngine: TranscriptionEngine, @unchecked Sendable {

    var activeVariant: SpeechModelCatalog.Variant = .base
    /// Metal for the next load (the Host's setting). The Dictation AU turns it off after a
    /// Metal fault; a model loaded the other way is loaded again.
    var allowsGPU = true
    private let modelPath: ModelPathProvider
    private let bridge = WhisperBridge()
    private var loadedModelPath: String?
    private var loadedWithGPU = true

    init(modelPath: @escaping ModelPathProvider) {
        self.modelPath = modelPath
    }

    func transcribe(wavPath: String, languageId: String) async throws -> String {
        let modelPath = try await modelPath(activeVariant)
        return try await runBridge(
            wavPath: wavPath,
            modelPath: modelPath,
            languageId: languageId
        )
    }

    /// Resolves the model and loads it, so the next `transcribe` finds it loaded.
    func warmUp() async throws {
        let modelPath = try await modelPath(activeVariant)
        try await onMain { [self] in try ensureLoaded(modelPath) }
    }

    /// Frees the model. Call only with no transcription running.
    func unload() {
        DispatchQueue.main.async { [self] in
            bridge.unloadModel()
            loadedModelPath = nil
        }
    }

    // MARK: - Private

    /// Main queue only, like every use of `bridge` and `loadedModelPath`.
    private func ensureLoaded(_ modelPath: String) throws {
        if bridge.isLoaded, loadedModelPath == modelPath, loadedWithGPU == allowsGPU { return }
        bridge.usesGPU = allowsGPU
        guard bridge.loadModel(atPath: modelPath) else {
            loadedModelPath = nil
            throw NSError(
                domain: "WhisperEngine", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not load the speech model."]
            )
        }
        loadedModelPath = modelPath
        loadedWithGPU = allowsGPU
    }

    private func onMain(_ work: @escaping () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private func runBridge(
        wavPath: String,
        modelPath: String,
        languageId: String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: NSError(
                        domain: "WhisperEngine", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Engine was deallocated."]
                    ))
                    return
                }

                do {
                    try self.ensureLoaded(modelPath)
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // The value is a picker id, not a whisper code: `zh-cn` and `zh-tw` are
                // both whisper `zh`. Convert here, at the harness boundary. It arrives
                // already resolved against the Speech Model, so Base.en gets `en` rather
                // than the automatic id even when the user never touched the picker.
                let whisperCode = TranscriptionLanguages.whisperCode(forId: languageId)
                self.bridge.transcribeWavFile(wavPath, language: whisperCode) { transcript, errorMsg in
                    if let text = transcript, !text.isEmpty {
                        continuation.resume(returning: text)
                    } else if let errorMsg {
                        continuation.resume(throwing: NSError(
                            domain: "WhisperEngine", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: errorMsg]
                        ))
                    } else {
                        continuation.resume(throwing: TranscriptionEngineError.noSpeech)
                    }
                }
            }
        }
    }
}
