import Foundation

/// Danish hviske backend. Wraps the ObjC++ CohereBridge, which runs crispasr's
/// cohere backend -- the only runtime that can read the hviske GGUF weights --
/// loading them from the path the `ModelPathProvider` resolves in the App Group container.
/// `@unchecked Sendable`: every use of the bridge and the loaded-model state runs on the main
/// queue; `allowsGPU` is set only between runs (the Dictation AU's serial chain).
final class CohereEngine: TranscriptionEngine, @unchecked Sendable {

    /// hviske is Danish only, so the language is pinned rather than passed through.
    /// A wrong code produces a fluent wrong-language transcript and never an error,
    /// so this is the one place the value is allowed to be decided.
    static let pinnedLanguageId = "da"

    /// Metal for the next load (the Host's setting). The Dictation AU turns it off after a
    /// Metal fault; a model loaded the other way is loaded again.
    var allowsGPU = true
    private let modelPath: ModelPathProvider
    private let bridge = CohereBridge()
    private var loadedModelPath: String?
    private var loadedWithGPU = true

    init(modelPath: @escaping ModelPathProvider) {
        self.modelPath = modelPath
    }

    /// `languageId` is ignored, and by the time it arrives it is already `da`: the
    /// resolver turns the automatic id into Danish and the Language Lock refuses every
    /// other Transcription Language before a Dictation turn starts.
    func transcribe(wavPath: String, languageId: String) async throws -> String {
        let modelPath = try await modelPath(.hviske)
        return try await runBridge(wavPath: wavPath, modelPath: modelPath)
    }

    /// Resolves the model and loads it, so the next `transcribe` finds it loaded.
    func warmUp() async throws {
        let modelPath = try await modelPath(.hviske)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async { [self] in
                continuation.resume(with: Result { try ensureLoaded(modelPath) })
            }
        }
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
                domain: "CohereEngine", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not load the Danish speech model."]
            )
        }
        loadedModelPath = modelPath
        loadedWithGPU = allowsGPU
    }

    private func runBridge(wavPath: String, modelPath: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: NSError(
                        domain: "CohereEngine", code: 1,
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

                self.bridge.transcribeWavFile(
                    wavPath,
                    language: Self.pinnedLanguageId
                ) { transcript, errorMsg in
                    if let text = transcript, !text.isEmpty {
                        continuation.resume(returning: text)
                    } else if let errorMsg {
                        continuation.resume(throwing: NSError(
                            domain: "CohereEngine", code: 3,
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
