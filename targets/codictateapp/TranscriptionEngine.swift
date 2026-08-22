import Foundation

/// Abstraction over ASR backends (Parakeet, Whisper, cohere).
/// Conforming types must be safe to call from any thread; the router
/// serializes access so only one transcription runs at a time.
///
/// `languageId` is a Transcription Language **picker id**, not a harness language
/// code: see `TranscriptionLanguages`. It is already resolved against the selected
/// Speech Model by `ModelManager.Variant.resolvedLanguageId`, so a Speech Model with
/// a pinned language never receives a bare `auto`. Each engine converts from there at
/// its own boundary -- Parakeet takes no language input, Whisper maps the id to a
/// whisper code, and cohere pins Danish.
protocol TranscriptionEngine: AnyObject {
    func transcribe(wavPath: String, languageId: String) async throws -> String
    func warmUp() async throws
}

extension TranscriptionEngine {
    func warmUp() async throws {}
}
