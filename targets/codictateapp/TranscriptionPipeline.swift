import Foundation

/// One Dictation turn's recording to text, in the Host's order: Language Lock resolution,
/// Dictation Readiness, the Speech Model's engine, Punctuation Restoration (ekko only,
/// always), then S1-mini formatting when eligible. Shared by the Host's
/// `TranscriptionRouter` and the Dictation AU (`CodictateFormattingAU`), which runs it for
/// the keyboard's In-keyboard path, so a keyboard dictation is transcribed exactly as a Host
/// one. It knows nothing about where the text goes; each caller delivers the `Outcome` its
/// own way and supplies the three steps that differ between the processes.
struct TranscriptionPipeline {
    /// Whether the turn may run, decided before any engine is touched.
    enum Admission {
        /// Run with this Transcription Language, already resolved against the Speech Model.
        case run(languageId: String)
        /// Dictation Readiness refused the turn; nothing runs.
        case blocked(DictationReadinessState)
    }

    enum Outcome {
        /// The text to deliver. Empty only when S1-mini cleaned a transcript down to
        /// nothing, which is a successful turn with no output.
        case text(String)
        /// The Speech Model ran and returned no words.
        case noSpeech
        /// The engine failed (`TranscriptionEngineError.noSpeech` included, as on the Host).
        case failed(Error)
    }

    /// The verdict for (Speech Model, resolved Transcription Language).
    let readiness: (SpeechModelCatalog.Variant, String) -> DictationReadinessState
    /// The engine that runs the Speech Model, set up for it (Whisper's `activeVariant`).
    let engine: (SpeechModelCatalog.Variant) -> TranscriptionEngine
    /// ekko-pnc, or nil without an App Group container, where ekko cannot be ready either.
    let punctuation: PunctuationRestorer?
    /// S1-mini when eligible; gives the text back unchanged otherwise, and on any fault.
    let format: (String, String) async -> String

    /// Synchronous, on the caller's thread, so `readiness` may read state that thread owns.
    func admit(variant: SpeechModelCatalog.Variant, storedLanguageId: String) -> Admission {
        // "auto" means the user expressed no preference, so a Speech Model with a pinned
        // language runs that language. Resolved once, here, and handed to both the
        // readiness check and the engine, so the verdict and the run cannot disagree.
        let languageId = variant.resolvedLanguageId(storedLanguageId)

        // Dictation Readiness is consulted before the turn starts, never after. A blocked
        // state starts nothing and never silently switches to a different Speech Model.
        // The recording paths gate on this too; this is the pre-spawn race check for a
        // state that changed while the user was speaking.
        let verdict = readiness(variant, languageId)
        return verdict.blocked ? .blocked(verdict) : .run(languageId: languageId)
    }

    /// A turn `admit` let run.
    func transcribe(
        wavPath: String,
        variant: SpeechModelCatalog.Variant,
        languageId: String
    ) async -> Outcome {
        let rawText: String
        do {
            rawText = try await engine(variant).transcribe(wavPath: wavPath, languageId: languageId)
        } catch {
            return .failed(error)
        }
        guard !rawText.isEmpty else { return .noSpeech }

        // ekko's Raw Transcript is lowercase and unpunctuated, so Punctuation Restoration
        // always runs on it. It never fails: on any fault it hands the words back unchanged.
        let restorer = variant.engine == .ekko ? punctuation : nil
        let punctuated = await restorer?.restore(rawText) ?? rawText
        return .text(await format(punctuated, languageId))
    }
}
