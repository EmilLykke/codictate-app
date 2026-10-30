import Foundation

/// What Python's `tokenizer.encode(words, is_pretokenized=True)` gives.
struct PretokenizedEncoding: Equatable {
    /// `encoding.ids`, special tokens included.
    let ids: [Int64]
    /// `encoding.word_ids`: the word each token belongs to, nil for a special token.
    let wordIds: [Int?]
}

/// ekko-pnc's tokenizer: a port of the Rust `tokenizers` library (0.22.2, what the Python
/// reference runs) for exactly the pipeline its `tokenizer.json` declares, encoding
/// pretokenized words the way `tokenizer.encode(words, is_pretokenized=True)` does:
///
/// 1. Each word on its own: the added tokens (`[CLS]`, `[UNK]`, ...) are cut out of the raw
///    word first, leftmost-longest, as tokens of their own.
/// 2. `BertNormalizer` on the rest, with the flags `tokenizer.json` sets.
/// 3. `BertPreTokenizer`: split on whitespace, then isolate every punctuation character.
/// 4. `WordPiece`, greedy longest match with `continuing_subword_prefix`, one `[UNK]` for a
///    piece over `max_input_chars_per_word` code points or with no match.
/// 5. Every token of a word is tagged with the word's index; then `TemplateProcessing`'s
///    single-sequence template adds the special tokens, tagged with none.
///
/// Anything else in `tokenizer.json` (another normalizer, `lowercase` or `strip_accents`,
/// truncation, padding, an added token that is normalized or strips) is refused at load,
/// not approximated: this port is verified byte for byte only on the pinned file.
///
/// Strings are compared as UTF-8 bytes, never with Swift `String` equality, which treats
/// canonically equivalent spellings (`é` and `e` + U+0301) as one and Rust does not.
final class EkkoPncTokenizer {

    private struct AddedToken {
        let content: [UInt8]
        let id: Int64
    }

    private let vocabulary: [[UInt8]: Int64]
    private let unknownId: Int64
    private let continuingPrefix: [UInt8]
    private let maxInputCharsPerWord: Int
    private let cleanText: Bool
    private let handleChineseChars: Bool
    /// Longest first, so the first match at a position is the leftmost-longest one.
    private let addedTokens: [AddedToken]
    /// The single-sequence template, resolved: special token ids, nil where the words go.
    private let template: [Int64?]

    init(tokenizerJSON data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? NSDictionary else {
            throw PunctuationError("PnC tokenizer.json is not a JSON object")
        }
        guard root["truncation"] is NSNull, root["padding"] is NSNull else {
            throw PunctuationError("PnC tokenizer.json sets truncation or padding")
        }

        // Normalizer
        guard let normalizer = root["normalizer"] as? NSDictionary,
              normalizer["type"] as? String == "BertNormalizer" else {
            throw PunctuationError("PnC tokenizer.json has no BertNormalizer")
        }
        let lowercase = try Self.flag(normalizer, "lowercase")
        // `strip_accents: null` means "as lowercase".
        let stripAccents = normalizer["strip_accents"] is NSNull
            ? lowercase : try Self.flag(normalizer, "strip_accents")
        guard !lowercase, !stripAccents else {
            throw PunctuationError("PnC tokenizer.json lowercases or strips accents, which this port does not do")
        }
        cleanText = try Self.flag(normalizer, "clean_text")
        handleChineseChars = try Self.flag(normalizer, "handle_chinese_chars")

        // Pre-tokenizer
        guard (root["pre_tokenizer"] as? NSDictionary)?["type"] as? String == "BertPreTokenizer" else {
            throw PunctuationError("PnC tokenizer.json has no BertPreTokenizer")
        }

        // Model. The vocabulary stays an NSDictionary until its keys are bytes: a Swift
        // `[String: _]` would merge keys that differ only in normalization form.
        guard let model = root["model"] as? NSDictionary,
              model["type"] as? String == "WordPiece",
              let vocab = model["vocab"] as? NSDictionary,
              let unkToken = model["unk_token"] as? String,
              let prefix = model["continuing_subword_prefix"] as? String,
              let maxChars = (model["max_input_chars_per_word"] as? NSNumber)?.intValue else {
            throw PunctuationError("PnC tokenizer.json has no WordPiece model")
        }
        var vocabulary: [[UInt8]: Int64] = [:]
        vocabulary.reserveCapacity(vocab.count)
        for (key, value) in vocab {
            guard let token = key as? NSString, let id = value as? NSNumber else {
                throw PunctuationError("PnC tokenizer.json has a malformed vocabulary entry")
            }
            vocabulary[Array((token as String).utf8)] = id.int64Value
        }
        guard vocabulary.count == vocab.count else {
            throw PunctuationError("PnC tokenizer.json vocabulary has colliding entries")
        }
        guard let unknownId = vocabulary[Array(unkToken.utf8)] else {
            throw PunctuationError("PnC tokenizer.json vocabulary has no \(unkToken)")
        }
        self.vocabulary = vocabulary
        self.unknownId = unknownId
        continuingPrefix = Array(prefix.utf8)
        maxInputCharsPerWord = maxChars

        // Added tokens
        var addedTokens: [AddedToken] = []
        for case let token as NSDictionary in (root["added_tokens"] as? NSArray) ?? [] {
            guard let content = token["content"] as? String, !content.isEmpty,
                  let id = (token["id"] as? NSNumber)?.int64Value else {
                throw PunctuationError("PnC tokenizer.json has a malformed added token")
            }
            for option in ["normalized", "single_word", "lstrip", "rstrip"]
            where (token[option] as? NSNumber)?.boolValue != false {
                throw PunctuationError("PnC tokenizer.json added token \(content) sets \(option), which this port does not do")
            }
            addedTokens.append(AddedToken(content: Array(content.utf8), id: id))
        }
        self.addedTokens = addedTokens.sorted { $0.content.count > $1.content.count }

        // Post-processor
        guard let processor = root["post_processor"] as? NSDictionary,
              processor["type"] as? String == "TemplateProcessing",
              let single = processor["single"] as? [NSDictionary],
              let specialTokens = processor["special_tokens"] as? NSDictionary else {
            throw PunctuationError("PnC tokenizer.json has no single-sequence template")
        }
        var template: [Int64?] = []
        for piece in single {
            if let special = piece["SpecialToken"] as? NSDictionary {
                guard let name = special["id"] as? String,
                      let ids = (specialTokens[name] as? NSDictionary)?["ids"] as? [NSNumber] else {
                    throw PunctuationError("PnC tokenizer.json has no special token \(special["id"] ?? "")")
                }
                template += ids.map { $0.int64Value }
            } else if piece["Sequence"] != nil {
                template.append(nil)
            } else {
                throw PunctuationError("PnC tokenizer.json has an unknown template piece")
            }
        }
        guard template.filter({ $0 == nil }).count == 1 else {
            throw PunctuationError("PnC tokenizer.json has no single-sequence template")
        }
        self.template = template
    }

    /// `tokenizer.encode(words, is_pretokenized=True)`.
    func encode(_ words: [String]) -> PretokenizedEncoding {
        var ids: [Int64] = []
        var wordIds: [Int?] = []
        for slot in template {
            if let id = slot {
                ids.append(id)
                wordIds.append(nil)
                continue
            }
            for (index, word) in words.enumerated() {
                for id in encodeWord(Array(word.unicodeScalars)) {
                    ids.append(id)
                    wordIds.append(index)
                }
            }
        }
        return PretokenizedEncoding(ids: ids, wordIds: wordIds)
    }

    // MARK: - One word

    /// [`AddedVocabulary::extract_and_normalize`] then the pre-tokenizer and the model.
    private func encodeWord(_ word: [Unicode.Scalar]) -> [Int64] {
        var ids: [Int64] = []
        var pending: [Unicode.Scalar] = []
        var index = 0
        while index < word.count {
            if let (token, length) = addedToken(in: word, at: index) {
                ids += encodePlain(pending)
                pending.removeAll()
                ids.append(token.id)
                index += length
            } else {
                pending.append(word[index])
                index += 1
            }
        }
        ids += encodePlain(pending)
        return ids
    }

    /// The longest added token starting at `index`, and its length in code points.
    private func addedToken(in word: [Unicode.Scalar], at index: Int) -> (AddedToken, Int)? {
        for token in addedTokens {
            var bytes: [UInt8] = []
            var end = index
            while bytes.count < token.content.count, end < word.count {
                bytes += Array(String(word[end]).utf8)
                end += 1
            }
            if bytes == token.content { return (token, end - index) }
        }
        return nil
    }

    /// A stretch of a word with no added token in it: normalize, pre-tokenize, WordPiece.
    private func encodePlain(_ text: [Unicode.Scalar]) -> [Int64] {
        if text.isEmpty { return [] }
        return preTokenize(normalize(text)).flatMap(wordPiece)
    }

    /// [`BertNormalizer::normalize`] with `lowercase` and `strip_accents` off.
    private func normalize(_ text: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var normalized: [Unicode.Scalar] = []
        normalized.reserveCapacity(text.count)
        for scalar in text {
            var character = scalar
            if cleanText {
                // [`do_clean_text`]
                let value = scalar.value
                if value == 0 || value == 0xFFFD || Self.isControl(value) { continue }
                if Self.isWhitespace(value) { character = " " }
            }
            if handleChineseChars && Self.isChineseChar(character.value) {
                // [`do_handle_chinese_chars`]
                normalized += [" ", character, " "]
            } else {
                normalized.append(character)
            }
        }
        return normalized
    }

    /// [`BertPreTokenizer`]: split on whitespace (removed), then on punctuation (isolated).
    private func preTokenize(_ text: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        var pieces: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        for scalar in text {
            if Self.isRustWhitespace(scalar.value) {
                if !current.isEmpty { pieces.append(current) }
                current = []
            } else if Self.isBertPunctuation(scalar.value) {
                if !current.isEmpty { pieces.append(current) }
                pieces.append([scalar])
                current = []
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// [`WordPiece::tokenize`] on one pre-token.
    private func wordPiece(_ piece: [Unicode.Scalar]) -> [Int64] {
        if piece.count > maxInputCharsPerWord { return [unknownId] }
        let utf8 = piece.map { Array(String($0).utf8) }
        var ids: [Int64] = []
        var start = 0
        while start < piece.count {
            var end = piece.count
            var match: Int64?
            while start < end {
                var candidate = start > 0 ? continuingPrefix : []
                for index in start..<end { candidate += utf8[index] }
                if let id = vocabulary[candidate] {
                    match = id
                    break
                }
                end -= 1
            }
            guard let id = match else { return [unknownId] }
            ids.append(id)
            start = end
        }
        return ids
    }

    // MARK: - Character classes, exactly as tokenizers 0.22.2 has them

    /// [`bert::is_whitespace`]: `\t`, `\n`, `\r` or Rust `char::is_whitespace`.
    private static func isWhitespace(_ value: UInt32) -> Bool {
        isRustWhitespace(value)
    }

    /// Rust `char::is_whitespace`: the Unicode White_Space property. Unlike Python's
    /// `str.isspace()`, U+001C to U+001F are not in it.
    private static func isRustWhitespace(_ value: UInt32) -> Bool {
        switch value {
        case 0x0009...0x000D, 0x0020, 0x0085, 0x00A0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029,
             0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// [`bert::is_control`]: unicode_categories 0.1.1's `is_other` (Cc, Cf and Co from its
    /// own, older Unicode tables; never Cn), except `\t`, `\n` and `\r`.
    private static func isControl(_ value: UInt32) -> Bool {
        switch value {
        case 0x0009, 0x000A, 0x000D:
            return false
        case 0x0000...0x001F, 0x007F...0x009F:
            return true
        case 0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD:
            return true
        default:
            return contains(otherFormat, value)
        }
    }

    /// [`bert::is_chinese_char`].
    private static func isChineseChar(_ value: UInt32) -> Bool {
        switch value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2B73F,
             0x2B740...0x2B81F, 0x2B920...0x2CEAF, 0xF900...0xFAFF, 0x2F800...0x2FA1F:
            return true
        default:
            return false
        }
    }

    /// [`is_bert_punc`]: ASCII punctuation (symbols included) or unicode_categories 0.1.1's
    /// `is_punctuation` (Pc, Pd, Pe, Pf, Pi, Po, Ps from its own tables).
    private static func isBertPunctuation(_ value: UInt32) -> Bool {
        switch value {
        case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E:
            return true
        default:
            return contains(punctuation, value)
        }
    }

    private static func contains(_ ranges: [ClosedRange<UInt32>], _ value: UInt32) -> Bool {
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if ranges[middle].upperBound < value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < ranges.count && ranges[low].contains(value)
    }

    private static func flag(_ object: NSDictionary, _ key: String) throws -> Bool {
        guard let value = object[key] as? NSNumber else {
            throw PunctuationError("PnC tokenizer.json normalizer has no \(key)")
        }
        return value.boolValue
    }

    /// unicode_categories 0.1.1 `OTHER_FORMAT` (Cf), as sorted ranges.
    private static let otherFormat: [ClosedRange<UInt32>] = [
        0x00AD...0x00AD, 0x0600...0x0605, 0x061C...0x061C, 0x06DD...0x06DD, 0x070F...0x070F,
        0x180E...0x180E, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x206F,
        0xFEFF...0xFEFF, 0xFFF9...0xFFFB, 0x110BD...0x110BD, 0x1BCA0...0x1BCA3, 0x1D173...0x1D17A,
        0xE0001...0xE0001, 0xE0020...0xE007F,
    ]

    /// unicode_categories 0.1.1 `PUNCTUATION_*` (all P categories), as sorted ranges.
    private static let punctuation: [ClosedRange<UInt32>] = [
        0x0021...0x0023, 0x0025...0x002A, 0x002C...0x002F, 0x003A...0x003B, 0x003F...0x0040,
        0x005B...0x005D, 0x005F...0x005F, 0x007B...0x007B, 0x007D...0x007D, 0x00A1...0x00A1,
        0x00A7...0x00A7, 0x00AB...0x00AB, 0x00B6...0x00B7, 0x00BB...0x00BB, 0x00BF...0x00BF,
        0x037E...0x037E, 0x0387...0x0387, 0x055A...0x055F, 0x0589...0x058A, 0x05BE...0x05BE,
        0x05C0...0x05C0, 0x05C3...0x05C3, 0x05C6...0x05C6, 0x05F3...0x05F4, 0x0609...0x060A,
        0x060C...0x060D, 0x061B...0x061B, 0x061E...0x061F, 0x066A...0x066D, 0x06D4...0x06D4,
        0x0700...0x070D, 0x07F7...0x07F9, 0x0830...0x083E, 0x085E...0x085E, 0x0964...0x0965,
        0x0970...0x0970, 0x0AF0...0x0AF0, 0x0DF4...0x0DF4, 0x0E4F...0x0E4F, 0x0E5A...0x0E5B,
        0x0F04...0x0F12, 0x0F14...0x0F14, 0x0F3A...0x0F3D, 0x0F85...0x0F85, 0x0FD0...0x0FD4,
        0x0FD9...0x0FDA, 0x104A...0x104F, 0x10FB...0x10FB, 0x1360...0x1368, 0x1400...0x1400,
        0x166D...0x166E, 0x169B...0x169C, 0x16EB...0x16ED, 0x1735...0x1736, 0x17D4...0x17D6,
        0x17D8...0x17DA, 0x1800...0x180A, 0x1944...0x1945, 0x1A1E...0x1A1F, 0x1AA0...0x1AA6,
        0x1AA8...0x1AAD, 0x1B5A...0x1B60, 0x1BFC...0x1BFF, 0x1C3B...0x1C3F, 0x1C7E...0x1C7F,
        0x1CC0...0x1CC7, 0x1CD3...0x1CD3, 0x2010...0x2027, 0x2030...0x2043, 0x2045...0x2051,
        0x2053...0x205E, 0x207D...0x207E, 0x208D...0x208E, 0x2308...0x230B, 0x2329...0x232A,
        0x2768...0x2775, 0x27C5...0x27C6, 0x27E6...0x27EF, 0x2983...0x2998, 0x29D8...0x29DB,
        0x29FC...0x29FD, 0x2CF9...0x2CFC, 0x2CFE...0x2CFF, 0x2D70...0x2D70, 0x2E00...0x2E2E,
        0x2E30...0x2E42, 0x3001...0x3003, 0x3008...0x3011, 0x3014...0x301F, 0x3030...0x3030,
        0x303D...0x303D, 0x30A0...0x30A0, 0x30FB...0x30FB, 0xA4FE...0xA4FF, 0xA60D...0xA60F,
        0xA673...0xA673, 0xA67E...0xA67E, 0xA6F2...0xA6F7, 0xA874...0xA877, 0xA8CE...0xA8CF,
        0xA8F8...0xA8FA, 0xA8FC...0xA8FC, 0xA92E...0xA92F, 0xA95F...0xA95F, 0xA9C1...0xA9CD,
        0xA9DE...0xA9DF, 0xAA5C...0xAA5F, 0xAADE...0xAADF, 0xAAF0...0xAAF1, 0xABEB...0xABEB,
        0xFD3E...0xFD3F, 0xFE10...0xFE19, 0xFE30...0xFE52, 0xFE54...0xFE61, 0xFE63...0xFE63,
        0xFE68...0xFE68, 0xFE6A...0xFE6B, 0xFF01...0xFF03, 0xFF05...0xFF0A, 0xFF0C...0xFF0F,
        0xFF1A...0xFF1B, 0xFF1F...0xFF20, 0xFF3B...0xFF3D, 0xFF3F...0xFF3F, 0xFF5B...0xFF5B,
        0xFF5D...0xFF5D, 0xFF5F...0xFF65, 0x10100...0x10102, 0x1039F...0x1039F, 0x103D0...0x103D0,
        0x1056F...0x1056F, 0x10857...0x10857, 0x1091F...0x1091F, 0x1093F...0x1093F,
        0x10A50...0x10A58, 0x10A7F...0x10A7F, 0x10AF0...0x10AF6, 0x10B39...0x10B3F,
        0x10B99...0x10B9C, 0x11047...0x1104D, 0x110BB...0x110BC, 0x110BE...0x110C1,
        0x11140...0x11143, 0x11174...0x11175, 0x111C5...0x111C9, 0x111CD...0x111CD,
        0x111DB...0x111DB, 0x111DD...0x111DF, 0x11238...0x1123D, 0x112A9...0x112A9,
        0x114C6...0x114C6, 0x115C1...0x115D7, 0x11641...0x11643, 0x1173C...0x1173E,
        0x12470...0x12474, 0x16A6E...0x16A6F, 0x16AF5...0x16AF5, 0x16B37...0x16B3B,
        0x16B44...0x16B44, 0x1BC9F...0x1BC9F, 0x1DA87...0x1DA8B,
    ]
}
