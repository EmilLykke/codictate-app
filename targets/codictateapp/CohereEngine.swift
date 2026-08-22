import Foundation

/// Danish hviske backend. Wraps the ObjC++ CohereBridge, which runs crispasr's
/// cohere backend -- the only runtime that can read the hviske GGUF weights --
/// loading them from the App Group container via ModelManager.
final class CohereEngine: TranscriptionEngine {

    /// hviske is Danish only, so the language is pinned rather than passed through.
    /// A wrong code produces a fluent wrong-language transcript and never an error,
    /// so this is the one place the value is allowed to be decided.
    static let pinnedLanguageId = "da"

    private let bridge = CohereBridge()
    private var loadedModelPath: String?

    /// `languageId` is ignored, and by the time it arrives it is already `da`: the
    /// resolver turns the automatic id into Danish and the Language Lock refuses every
    /// other Transcription Language before a Dictation turn starts.
    func transcribe(wavPath: String, languageId: String) async throws -> String {
        let modelPath = try await ensureModel()
        return try await runBridge(wavPath: wavPath, modelPath: modelPath)
    }

    func warmUp() async throws {
        _ = try await ensureModel()
    }

    // MARK: - Private

    private func ensureModel() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            ModelManager.shared.ensureModel(
                variant: .hviske,
                onProgress: { _ in },
                onComplete: { result in
                    switch result {
                    case .success(let path):
                        continuation.resume(returning: path)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            )
        }
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

                if !self.bridge.isLoaded || self.loadedModelPath != modelPath {
                    guard self.bridge.loadModel(atPath: modelPath) else {
                        continuation.resume(throwing: NSError(
                            domain: "CohereEngine", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Could not load the Danish speech model."]
                        ))
                        return
                    }
                    self.loadedModelPath = modelPath
                }

                self.bridge.transcribeWavFile(
                    wavPath,
                    language: Self.pinnedLanguageId
                ) { transcript, errorMsg in
                    if let text = transcript, !text.isEmpty {
                        continuation.resume(returning: text)
                    } else {
                        let msg = errorMsg ?? "No speech detected."
                        continuation.resume(throwing: NSError(
                            domain: "CohereEngine", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: msg]
                        ))
                    }
                }
            }
        }
    }
}
