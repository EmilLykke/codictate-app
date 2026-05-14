import Foundation

/// Abstraction over ASR backends (Parakeet, Whisper, etc.).
/// Conforming types must be safe to call from any thread; the router
/// serializes access so only one transcription runs at a time.
protocol TranscriptionEngine: AnyObject {
    func transcribe(wavPath: String) async throws -> String
    func warmUp() async throws
}

extension TranscriptionEngine {
    func warmUp() async throws {}
}
