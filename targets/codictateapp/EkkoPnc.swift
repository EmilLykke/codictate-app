import Foundation

/// Why Punctuation Restoration failed. Never reaches the Host: `PunctuationRestorer` logs it
/// and hands back the text unchanged.
struct PunctuationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// One model run's output tensor: row-major scores of shape `[1, tokens, labels]`.
struct PunctuationLogits {
    let data: [Float]
    let dims: [Int]
}

/// A loaded Punctuation Model: what the Python reference holds as its tokenizer, ONNX
/// session and `id2label`. The real one is `EkkoPncModel`; a fake one tests the rest.
protocol PunctuationModel: AnyObject {
    /// `config.json`'s `id2label`, keyed by label id (`O`, `,`, `.|U`, ...).
    var labels: [Int: String] { get }
    /// Tokenize whitespace words as one pretokenized sequence, exactly as the Python
    /// `tokenizers` library does with `is_pretokenized=True`.
    func encode(_ words: [String]) throws -> PretokenizedEncoding
    /// One session run on a single sequence of at most 128 ids: `input_ids` of shape
    /// `[1, n]` (int64) and an all-ones `attention_mask`. Gives the first output.
    func run(_ inputIds: [Int64]) throws -> PunctuationLogits
}

/// The port of ekko-pnc's Python reference: `Punctuator.__call__` from `ekko/pnc.py` in the
/// `ekko-stt[pnc]==0.1.2` wheel, by way of desktop `src/bun/utils/punctuation/ekko-pnc.ts`.
/// Its output must be byte-identical to that reference on the same weights, so every step
/// follows the Python line for line, including its edge behaviour; the names in brackets
/// are the Python functions each piece mirrors. Changing it means bumping the pin and
/// regenerating desktop's parity fixture, not improving it here.
///
/// Text is handled as code points (`Unicode.Scalar`), as Python does.
///
/// Internal to the Punctuation Restorer: callers go through `PunctuationRestorer`.
enum EkkoPnc {

    /// `Punctuator(max_length=128)`: the most tokens one model run sees.
    static let maxLength = 128
    /// `Punctuator(overlap_words=12)`: words of context shared by neighbouring windows.
    static let overlapWords = 12

    /// One model run: the words it sees, and the slice of them whose predictions are kept.
    struct Window: Equatable {
        let contextStart: Int
        let windowEnd: Int
        let emitStart: Int
        let emitEnd: Int
    }

    /// Where the windows fall [`_punctuate_words_locked`]. The Python decides each window
    /// from token counts alone, never from a prediction, so the whole sequence can be laid
    /// out before the first model run; that is what lets the restorer size its timeout by
    /// window count.
    static func planWindows(_ model: PunctuationModel, _ words: [String]) throws -> [Window] {
        let encoding = try model.encode(words)
        var tokenCounts = [Int](repeating: 0, count: words.count)
        var specialTokens = 0
        for wordId in encoding.wordIds {
            if let wordId {
                tokenCounts[try checkedWordIndex(wordId, words.count)] += 1
            } else {
                specialTokens += 1
            }
        }
        var prefix = [0]
        for count in tokenCounts { prefix.append(prefix[prefix.count - 1] + count) }

        func maxWindowEnd(_ start: Int) -> Int {
            let tokenBudget = prefix[start] + maxLength - specialTokens
            return min(
                words.count,
                start + maxLength,
                max(start + 1, bisectRight(prefix, tokenBudget) - 1)
            )
        }

        var windows: [Window] = []
        var nextWord = 0
        while nextWord < words.count {
            var contextStart = max(0, nextWord - overlapWords)
            var windowEnd = maxWindowEnd(contextStart)
            if windowEnd <= nextWord {
                contextStart = nextWord
                windowEnd = maxWindowEnd(contextStart)
            }
            let finalWindow = windowEnd == words.count
            let emitEnd = finalWindow ? windowEnd : max(nextWord + 1, windowEnd - overlapWords)
            windows.append(Window(
                contextStart: contextStart, windowEnd: windowEnd,
                emitStart: nextWord, emitEnd: emitEnd
            ))
            nextWord = emitEnd
        }
        return windows
    }

    /// Punctuate whitespace words along a window plan [`punctuate_words`]: one model run per
    /// window, in order, then the sentence-case pass. Throws on anything the Python would
    /// raise on, and on a change in the number of words.
    static func punctuateWords(
        _ model: PunctuationModel, _ words: [String], _ windows: [Window]
    ) throws -> [String] {
        if words.isEmpty { return [] }
        var output: [String] = []
        for window in windows {
            let rendered = try predictWindow(
                model, Array(words[window.contextStart..<window.windowEnd])
            )
            output += rendered[
                (window.emitStart - window.contextStart)..<(window.emitEnd - window.contextStart)
            ]
        }
        guard output.count == words.count else {
            throw PunctuationError("PnC changed word cardinality: \(words.count) -> \(output.count)")
        }
        return stabilizeSentenceCase(output)
    }

    /// One model run over one window's words, rendered with their labels [`_predict_window`].
    private static func predictWindow(_ model: PunctuationModel, _ words: [String]) throws -> [String] {
        let encoding = try model.encode(words)
        let ids = Array(encoding.ids.prefix(maxLength))
        let wordIds = Array(encoding.wordIds.prefix(maxLength))
        let predictions = try argmaxRows(try model.run(ids), rows: ids.count)

        var rendered = words
        var seen = Set<Int>()
        for (index, wordId) in wordIds.enumerated() {
            guard let wordId, !seen.contains(wordId) else { continue }
            seen.insert(wordId)
            let prediction = predictions[index]
            guard let label = model.labels[prediction] else {
                throw PunctuationError("PnC predicted label id \(prediction), not in id2label")
            }
            let upper = label.hasSuffixScalars("|U")
            let mark = upper ? label.droppingLastScalars(2) : label
            let word = words[try checkedWordIndex(wordId, words.count)]
            rendered[wordId] = (upper ? capitalizeInitialPreservingCase(word) : word)
                + (mark.unicodeScalars.elementsEqual("O".unicodeScalars) ? "" : mark)
        }
        return rendered
    }

    /// `logits[0].argmax(-1)` for the first `rows` tokens: numpy's argmax, which keeps the
    /// first of equal maxima and treats NaN as the maximum.
    private static func argmaxRows(_ logits: PunctuationLogits, rows: Int) throws -> [Int] {
        let dims = logits.dims
        guard dims.count == 3, dims[0] >= 1, dims[1] >= rows, dims[2] >= 1,
              logits.data.count >= dims[1] * dims[2] else {
            throw PunctuationError("PnC logits have shape \(dims) for \(rows) tokens")
        }
        let labels = dims[2]
        var predictions: [Int] = []
        predictions.reserveCapacity(rows)
        for row in 0..<rows {
            let offset = row * labels
            var best = 0
            var bestValue = logits.data[offset]
            if !bestValue.isNaN {
                for label in 1..<labels {
                    let value = logits.data[offset + label]
                    if value.isNaN {
                        best = label
                        break
                    }
                    if value > bestValue {
                        best = label
                        bestValue = value
                    }
                }
            }
            predictions.append(best)
        }
        return predictions
    }

    /// [`_capitalize_initial_preserving_case`] Title-case the first letter, unless the word
    /// already holds an uppercase or titlecase character anywhere (`NATO`, `iPhone`, `DR`
    /// stay).
    static func capitalizeInitialPreservingCase(_ word: String) -> String {
        let scalars = Array(word.unicodeScalars)
        if scalars.contains(where: PythonText.isUpperOrTitle) { return word }
        guard let index = scalars.firstIndex(where: PythonText.isAlpha) else { return word }
        var result = String.UnicodeScalarView(scalars[..<index])
        result.append(contentsOf: PythonText.title(scalars[index]).unicodeScalars)
        result.append(contentsOf: scalars[(index + 1)...])
        return String(result)
    }

    /// [`_stabilize_sentence_case`] Capitalise the first word and every word after one
    /// ending in `.`, `!` or `?`, except after an abbreviation like `f.eks.`. Like the
    /// Python, the loop reads the words as they stood before it started (it iterates a slice
    /// copy), so a word it capitalises is not re-read when deciding about the next one.
    private static func stabilizeSentenceCase(_ words: [String]) -> [String] {
        if words.isEmpty { return words }
        var rendered = words
        rendered[0] = capitalizeInitialPreservingCase(rendered[0])
        let before = Array(rendered.dropLast())
        for (index, word) in before.enumerated() {
            guard let last = word.unicodeScalars.last, last == "." || last == "!" || last == "?",
                  !isAbbreviation(word) else { continue }
            rendered[index + 1] = capitalizeInitialPreservingCase(rendered[index + 1])
        }
        return rendered
    }

    /// A `.` with a letter on both sides somewhere inside the word (`f.eks.`, `i.e.`).
    private static func isAbbreviation(_ word: String) -> Bool {
        let scalars = Array(word.unicodeScalars)
        guard scalars.count >= 3 else { return false }
        for index in 1..<(scalars.count - 1)
        where scalars[index] == "." && PythonText.isAlpha(scalars[index - 1])
            && PythonText.isAlpha(scalars[index + 1]) {
            return true
        }
        return false
    }

    /// Python's `bisect_right` on a non-decreasing list.
    private static func bisectRight(_ values: [Int], _ target: Int) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if target < values[middle] {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }

    /// A tokenizer word id used as a list index. Python raises `IndexError` on one past the
    /// end, so check it rather than trap.
    private static func checkedWordIndex(_ wordId: Int, _ wordCount: Int) throws -> Int {
        guard wordId >= 0, wordId < wordCount else {
            throw PunctuationError("PnC tokenizer gave word id \(wordId) for \(wordCount) words")
        }
        return wordId
    }
}

private extension String {
    /// `hasSuffix` on code points, not on canonically equivalent `Character`s.
    func hasSuffixScalars(_ suffix: String) -> Bool {
        let scalars = Array(unicodeScalars)
        let tail = Array(suffix.unicodeScalars)
        return scalars.count >= tail.count && Array(scalars.suffix(tail.count)) == tail
    }

    func droppingLastScalars(_ count: Int) -> String {
        String(String.UnicodeScalarView(unicodeScalars.dropLast(count)))
    }
}
