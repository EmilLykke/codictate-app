import Foundation

/// Whisper ASR backend. Wraps the existing ObjC++ WhisperBridge, loading
/// the GGML model from the App Group container via ModelManager.
final class WhisperEngine: TranscriptionEngine {

    private let bridge = WhisperBridge()
    private var loadedModelPath: String?

    func transcribe(wavPath: String) async throws -> String {
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
                variant: .base,
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
                        domain: "WhisperEngine", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Engine was deallocated."]
                    ))
                    return
                }

                if !self.bridge.isLoaded || self.loadedModelPath != modelPath {
                    guard self.bridge.loadModel(atPath: modelPath) else {
                        continuation.resume(throwing: NSError(
                            domain: "WhisperEngine", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Could not load the speech model."]
                        ))
                        return
                    }
                    self.loadedModelPath = modelPath
                }

                self.bridge.transcribeWavFile(wavPath, language: "auto") { transcript, errorMsg in
                    if let text = transcript, !text.isEmpty {
                        continuation.resume(returning: text)
                    } else {
                        let msg = errorMsg ?? "No speech detected."
                        continuation.resume(throwing: NSError(
                            domain: "WhisperEngine", code: 3,
                            userInfo: [NSLocalizedDescriptionKey: msg]
                        ))
                    }
                }
            }
        }
    }
}
