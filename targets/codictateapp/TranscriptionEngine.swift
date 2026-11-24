import Foundation

/// Abstraction over ASR backends (Parakeet, Whisper, cohere, ekko).
/// Conforming types must be safe to call from any thread; the router
/// serializes access so only one transcription runs at a time.
///
/// `languageId` is a Transcription Language **picker id**, not a harness language
/// code: see `TranscriptionLanguages`. It is already resolved against the selected
/// Speech Model by `SpeechModelCatalog.Variant.resolvedLanguageId`, so a Speech Model with
/// a pinned language never receives a bare `auto`. Each engine converts from there at
/// its own boundary -- Parakeet takes no language input, Whisper maps the id to a
/// whisper code, and cohere pins Danish.
///
/// Every engine but Parakeet is compiled into the Host and the Dictation AU
/// (`CodictateFormattingAU`) too, which runs it for the keyboard's In-keyboard path. The
/// engines never download: each is handed a `ModelPathProvider`, which in the Host may
/// download and in the AU only finds the file.
protocol TranscriptionEngine: AnyObject {
    func transcribe(wavPath: String, languageId: String) async throws -> String
    func warmUp() async throws
}

extension TranscriptionEngine {
    func warmUp() async throws {}
}

/// Resolves a Speech Model's weights on disk for an engine.
typealias ModelPathProvider = (SpeechModelCatalog.Variant) async throws -> String

/// Thrown by an engine whose run succeeded but heard no words. Its description is the
/// message the Host has always shown for it.
enum TranscriptionEngineError: LocalizedError {
    case noSpeech

    var errorDescription: String? { "No speech detected." }
}
