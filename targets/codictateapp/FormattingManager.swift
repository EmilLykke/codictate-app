import Foundation
import NaturalLanguage
import UIKit

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
}

enum FormattingModelNotification {
    static let ensure = Notification.Name("codictate.formatting.ensureModel")
    static let progress = Notification.Name("codictate.formatting.progress")
    static let ready = Notification.Name("codictate.formatting.ready")
    static let failed = Notification.Name("codictate.formatting.failed")
}

final class FormattingManager {
    static let shared = FormattingManager()

    private let bridge = S1MiniBridge()
    private var observerInstalled = false
    private let groupID = KeyboardDictationBridge.suiteName

    private init() {}

    var modelPath: String? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(FormattingConfiguration.filename).path
    }

    var modelIsReady: Bool {
        guard let path = modelPath,
              UserDefaults(suiteName: groupID)?.bool(forKey: FormattingConfiguration.verifiedKey) == true,
              let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int64
        else { return false }
        return size == FormattingConfiguration.byteCount
    }

    func installObserver() {
        guard !observerInstalled else { return }
        observerInstalled = true
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.bridge.unloadModel() }
        NotificationCenter.default.addObserver(
            forName: Notification.Name("codictate.formatting.settingsChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let suite = UserDefaults(suiteName: self?.groupID ?? ""),
                  (suite.string(forKey: FormattingConfiguration.modelKey) ?? "off") == "off"
            else { return }
            self?.bridge.unloadModel()
        }
        NotificationCenter.default.addObserver(
            forName: FormattingModelNotification.ensure, object: nil, queue: .main
        ) { _ in
            ModelManager.shared.ensureFormattingModel(
                onProgress: { progress in
                    NotificationCenter.default.post(name: FormattingModelNotification.progress, object: nil, userInfo: ["progress": progress])
                },
                onComplete: { result in
                    switch result {
                    case .success(let path):
                        NotificationCenter.default.post(name: FormattingModelNotification.ready, object: nil, userInfo: ["path": path])
                    case .failure(let error):
                        NotificationCenter.default.post(name: FormattingModelNotification.failed, object: nil, userInfo: ["error": error.localizedDescription])
                    }
                }
            )
        }
    }

    func formatIfEligible(_ transcript: String, languageId: String, suite: UserDefaults) async -> String {
        let selected = FormattingModel(rawValue: suite.string(forKey: FormattingConfiguration.modelKey) ?? "") ?? .off
        guard selected == .s1Mini, modelIsReady, isConfidentEnglish(transcript, languageId: languageId),
              !transcript.contains("<|"), !transcript.contains("|>"),
              let modelPath else { return transcript }

        let style = FormattingStyle(rawValue: suite.string(forKey: FormattingConfiguration.styleKey) ?? "") ?? .semiFormal
        let context = FormattingContext(rawValue: suite.string(forKey: FormattingConfiguration.contextKey) ?? "") ?? .general

        do {
            var cleaned: [String] = []
            for chunk in chunks(for: transcript) {
                cleaned.append(try await formatOne(chunk, modelPath: modelPath, style: style, context: context))
            }
            return cleaned.filter { !$0.isEmpty }.joined(separator: "\n\n")
        } catch {
            NSLog("[FormattingManager] Preserving raw transcript after failure: \(error.localizedDescription)")
            return transcript
        }
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
                        domain: "FormattingManager", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "S1-mini failed."]
                    ))
                }
            }
        }
    }

    private func chunks(for text: String) -> [String] {
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

    private func isConfidentEnglish(_ text: String, languageId: String) -> Bool {
        if languageId == "en" { return true }
        guard languageId == ModelManager.Variant.automaticLanguageId else { return false }

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
