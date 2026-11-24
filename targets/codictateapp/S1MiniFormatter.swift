import Foundation
import NaturalLanguage

// S1-mini formatting shared by the Host (`FormattingManager`) and the Dictation AU
// (`CodictateFormattingAU`), which compiles this file and `S1MiniBridge` too, so a keyboard
// dictation is cleaned exactly as a Host dictation is. Nothing here may use the Host's own
// types (`ModelManager`, `KeyboardDictationBridge`, UIKit); `SpeechModelCatalog` is shared.

enum FormattingModel: String {
    case off
    case s1Mini = "s1-mini"
}

enum FormattingStyle: String, CaseIterable {
    case casual
    case semiCasual = "semi-casual"
    case semiFormal = "semi-formal"
    case formal
}

enum FormattingContext: String, CaseIterable {
    case general
    case email
}

enum FormattingConfiguration {
    static let modelKey = "formattingModel"
    static let styleKey = "formattingStyle"
    static let contextKey = "formattingContext"
    static let verifiedKey = "s1MiniModelVerified"
    static let downloadingKey = "s1MiniModelDownloading"
    static let filename = "s1-mini-q4_k_m.gguf"
    static let byteCount: Int64 = 484_219_808
    static let sha256 = "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634"
    static let url = URL(string: "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/34add00a48a2e5d24e5a4ee5405a99620a3a240c/s1-mini-q4_k_m.gguf")!
    static let appGroupID = "group.app.codictate"
    static let automaticLanguageId = SpeechModelCatalog.Variant.automaticLanguageId

    static var modelPath: String? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(filename).path
    }

    /// The Host verified the download and the file is whole.
    static func modelIsReady(suite: UserDefaults?) -> Bool {
        guard let path = modelPath,
              suite?.bool(forKey: verifiedKey) == true,
              let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int64
        else { return false }
        return size == byteCount
    }
}

/// Runs S1-mini on one transcript: the English gate, chunking and the bridge. Never decides
/// whether S1-mini is selected; callers do.
struct S1MiniFormatter {
    let bridge: S1MiniBridge

    /// Why S1-mini must not touch `transcript`, or nil when it may.
    static func ineligibilityReason(_ transcript: String, languageId: String) -> String? {
        if transcript.contains("<|") || transcript.contains("|>") { return "transcript holds protocol tokens" }
        guard isConfidentEnglish(transcript, languageId: languageId) else { return "not confidently English" }
        return nil
    }

    /// The cleaned transcript; an empty string is a successful cleanup with no output.
    /// Throws when any chunk fails, so the caller keeps the transcript.
    func format(
        _ transcript: String,
        modelPath: String,
        style: FormattingStyle,
        context: FormattingContext
    ) async throws -> String {
        var cleaned: [String] = []
        for chunk in Self.chunks(for: transcript) {
            cleaned.append(try await formatOne(chunk, modelPath: modelPath, style: style, context: context))
        }
        return cleaned.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func formatOne(
        _ transcript: String,
        modelPath: String,
        style: FormattingStyle,
        context: FormattingContext
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            bridge.formatTranscript(
                transcript,
                modelPath: modelPath,
                styling: style.rawValue,
                context: context.rawValue
            ) { output, errorMessage in
                if let output {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "S1MiniFormatter", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "S1-mini failed."]
                    ))
                }
            }
        }
    }

    static func chunks(for text: String) -> [String] {
        let limit = 2_800
        guard text.count > limit else { return [text] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var pieces: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if sentence.count <= limit {
                pieces.append(sentence)
            } else {
                var current = ""
                for word in sentence.split(whereSeparator: { $0.isWhitespace }) {
                    if current.count + word.count + 1 > limit, !current.isEmpty {
                        pieces.append(current)
                        current = ""
                    }
                    current += current.isEmpty ? String(word) : " \(word)"
                }
                if !current.isEmpty { pieces.append(current) }
            }
            return true
        }
        var chunks: [String] = []
        for piece in pieces {
            if let last = chunks.last, last.count + piece.count + 1 <= limit {
                chunks[chunks.count - 1] = "\(last) \(piece)"
            } else if !piece.isEmpty {
                chunks.append(piece)
            }
        }
        return chunks.isEmpty ? [text] : chunks
    }

    static func isConfidentEnglish(_ text: String, languageId: String) -> Bool {
        if languageId == "en" { return true }
        guard languageId == FormattingConfiguration.automaticLanguageId else { return false }

        let words = text.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.unicodeScalars.contains(where: CharacterSet.letters.contains) }
        let letterCount = text.unicodeScalars.filter(CharacterSet.letters.contains).count
        guard words.count >= 4, letterCount >= 20 else { return false }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        let english = hypotheses[.english] ?? 0
        let runnerUp = hypotheses
            .filter { $0.key != .english }
            .map(\.value)
            .max() ?? 0
        guard recognizer.dominantLanguage == .english,
              english >= 0.75,
              english - runnerUp >= 0.20 else { return false }

        // A dominant whole-document score can hide a substantial Danish sentence in
        // otherwise English text. Keep mixed dictation raw rather than partially clean it.
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var containsConfidentDanish = false
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range])
            let sentenceWords = sentence.split(whereSeparator: { $0.isWhitespace })
                .filter { $0.unicodeScalars.contains(where: CharacterSet.letters.contains) }
            let sentenceLetters = sentence.unicodeScalars.filter(CharacterSet.letters.contains).count
            guard sentenceWords.count >= 3, sentenceLetters >= 12 else { return true }

            let sentenceRecognizer = NLLanguageRecognizer()
            sentenceRecognizer.processString(sentence)
            let sentenceHypotheses = sentenceRecognizer.languageHypotheses(withMaximum: 2)
            let danish = sentenceHypotheses[.danish] ?? 0
            let sentenceEnglish = sentenceHypotheses[.english] ?? 0
            if sentenceRecognizer.dominantLanguage == .danish,
               danish >= 0.55,
               danish - sentenceEnglish >= 0.20 {
                containsConfidentDanish = true
                return false
            }
            return true
        }
        guard !containsConfidentDanish else { return false }

        // Also inspect overlapping word windows: code-switching often happens inside
        // one unpunctuated sentence, where the document-level result still looks English.
        let wordStrings = words.map(String.init)
        guard wordStrings.count >= 4 else { return true }
        for start in 0...(wordStrings.count - 4) {
            let end = min(wordStrings.count, start + 6)
            let window = wordStrings[start..<end].joined(separator: " ")
            let windowRecognizer = NLLanguageRecognizer()
            windowRecognizer.processString(window)
            let windowHypotheses = windowRecognizer.languageHypotheses(withMaximum: 2)
            let danish = windowHypotheses[.danish] ?? 0
            let windowEnglish = windowHypotheses[.english] ?? 0
            if windowRecognizer.dominantLanguage == .danish,
               danish >= 0.65,
               danish - windowEnglish >= 0.30 {
                return false
            }
        }
        return true
    }
}
