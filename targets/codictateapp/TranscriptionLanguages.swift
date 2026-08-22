import Foundation

/// The Transcription Languages the user can pick, ported from
/// `src/constants/transcription-languages.ts`. Keep the two in sync.
///
/// The App Group key `transcriptionLanguageId` holds the **picker id**, which is not
/// always the code an ASR Harness wants: `zh-cn` and `zh-tw` are both whisper `zh`,
/// `yue-cn` and `yue-hk` are both `yue`. The Host does the conversion, because
/// keyboard and Action Button dictation run with no React Native process alive to do
/// it in JavaScript.
enum TranscriptionLanguages {

    /// The picker id meaning "let the Speech Model decide".
    static let automaticId = ModelManager.Variant.automaticLanguageId

    /// What `whisper_full_params.language` wants when it should detect the language.
    static let whisperAutoCode = "auto"

    /// Picker id -> whisper.cpp language code, in the picker's own label order.
    private static let idToWhisperCode: [String: String] = [
        "af":     "af",
        "sq":     "sq",
        "ar":     "ar",
        "hy":     "hy",
        "az":     "az",
        "eu":     "eu",
        "be":     "be",
        "bn":     "bn",
        "yue-cn": "yue",  // Cantonese (CN)
        "yue-hk": "yue",  // Cantonese (HK)
        "ca":     "ca",
        "cs":     "cs",
        "da":     "da",
        "nl":     "nl",
        "en":     "en",
        "et":     "et",
        "fi":     "fi",
        "fr":     "fr",
        "gl":     "gl",
        "de":     "de",
        "el":     "el",
        "he":     "he",
        "hi":     "hi",
        "hu":     "hu",
        "id":     "id",
        "it":     "it",
        "ja":     "ja",
        "kk":     "kk",
        "ko":     "ko",
        "lv":     "lv",
        "lt":     "lt",
        "mk":     "mk",
        "zh-cn":  "zh",  // Mandarin (CN)
        "zh-tw":  "zh",  // Mandarin (TW)
        "mr":     "mr",
        "ne":     "ne",
        "nn":     "nn",
        "fa":     "fa",
        "pl":     "pl",
        "pt":     "pt",
        "pa":     "pa",
        "ro":     "ro",
        "ru":     "ru",
        "sr":     "sr",
        "sk":     "sk",
        "sl":     "sl",
        "es":     "es",
        "sw":     "sw",
        "sv":     "sv",
        "ta":     "ta",
        "th":     "th",
        "tr":     "tr",
        "uk":     "uk",
        "ur":     "ur",
        "vi":     "vi",
        "cy":     "cy",
    ]

    static func isValid(id: String) -> Bool {
        id == automaticId || idToWhisperCode[id] != nil
    }

    /// whisper's language code for a picker id. The automatic id, an empty string and
    /// any id this table does not know all resolve to `auto`: whisper detects rather
    /// than transcribing in a wrong language, and an unknown id is a bug in the picker
    /// rather than a language.
    static func whisperCode(forId id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty || trimmed == automaticId { return whisperAutoCode }
        return idToWhisperCode[trimmed] ?? whisperAutoCode
    }
}
