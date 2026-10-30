import Foundation

/// The handful of Python `str` behaviours the ekko-pnc port depends on, matched exactly.
/// Port of desktop `src/bun/utils/punctuation/python-text.ts`.
///
/// Python works on code points, so everything here works on `Unicode.Scalar`s, never on
/// Swift `Character`s (grapheme clusters) or `String` equality (canonical equivalence).
/// The character classes come from the stdlib's Unicode properties, which agree with
/// Python 3.12.2's (Unicode 15.0) on every code point both know; whitespace and titlecase
/// come from tables Python generated (desktop scripts/generate-titlecase-table.py).
enum PythonText {

    /// Python `text.split()`: split on runs of Python whitespace, dropping empty ends.
    static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if whitespace.contains(scalar.value) {
                if !current.isEmpty {
                    words.append(String(current))
                    current = String.UnicodeScalarView()
                }
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { words.append(String(current)) }
        return words
    }

    /// Python `c.isupper() or c.istitle()` for one code point: it has the Uppercase property
    /// (which includes `Ⓐ` and Roman numerals, not only Lu) or is a titlecase letter (Lt).
    static func isUpperOrTitle(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isUppercase || scalar.properties.generalCategory == .titlecaseLetter
    }

    /// Python `c.isalpha()` for one code point: categories Lu, Ll, Lt, Lm and Lo.
    static func isAlpha(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }

    /// Python `c.title()` for one code point, with its special mappings (`ß` -> `Ss`,
    /// `ǆ` -> `ǅ`).
    static func title(_ scalar: Unicode.Scalar) -> String {
        titlecaseExceptions[scalar.value] ?? scalar.properties.uppercaseMapping
    }

    // MARK: - Tables (Python 3.12.2, Unicode 15.0.0; desktop python-text-tables.ts)

    /// Every character Python's `str.split()` splits on (`str.isspace()`).
    private static let whitespace: Set<UInt32> = [
        0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x001C, 0x001D, 0x001E, 0x001F, 0x0020, 0x0085,
        0x00A0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008,
        0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000,
    ]

    /// Every code point whose Python `str.title()` differs from its `str.upper()`, with its
    /// `str.title()`. For any other code point, the full uppercase mapping is the title case.
    private static let titlecaseExceptions: [UInt32: String] = [
        0x00DF: "\u{0053}\u{0073}", 0x01C4: "\u{01C5}", 0x01C5: "\u{01C5}", 0x01C6: "\u{01C5}",
        0x01C7: "\u{01C8}", 0x01C8: "\u{01C8}", 0x01C9: "\u{01C8}", 0x01CA: "\u{01CB}",
        0x01CB: "\u{01CB}", 0x01CC: "\u{01CB}", 0x01F1: "\u{01F2}", 0x01F2: "\u{01F2}",
        0x01F3: "\u{01F2}", 0x0587: "\u{0535}\u{0582}", 0x10D0: "\u{10D0}", 0x10D1: "\u{10D1}",
        0x10D2: "\u{10D2}", 0x10D3: "\u{10D3}", 0x10D4: "\u{10D4}", 0x10D5: "\u{10D5}",
        0x10D6: "\u{10D6}", 0x10D7: "\u{10D7}", 0x10D8: "\u{10D8}", 0x10D9: "\u{10D9}",
        0x10DA: "\u{10DA}", 0x10DB: "\u{10DB}", 0x10DC: "\u{10DC}", 0x10DD: "\u{10DD}",
        0x10DE: "\u{10DE}", 0x10DF: "\u{10DF}", 0x10E0: "\u{10E0}", 0x10E1: "\u{10E1}",
        0x10E2: "\u{10E2}", 0x10E3: "\u{10E3}", 0x10E4: "\u{10E4}", 0x10E5: "\u{10E5}",
        0x10E6: "\u{10E6}", 0x10E7: "\u{10E7}", 0x10E8: "\u{10E8}", 0x10E9: "\u{10E9}",
        0x10EA: "\u{10EA}", 0x10EB: "\u{10EB}", 0x10EC: "\u{10EC}", 0x10ED: "\u{10ED}",
        0x10EE: "\u{10EE}", 0x10EF: "\u{10EF}", 0x10F0: "\u{10F0}", 0x10F1: "\u{10F1}",
        0x10F2: "\u{10F2}", 0x10F3: "\u{10F3}", 0x10F4: "\u{10F4}", 0x10F5: "\u{10F5}",
        0x10F6: "\u{10F6}", 0x10F7: "\u{10F7}", 0x10F8: "\u{10F8}", 0x10F9: "\u{10F9}",
        0x10FA: "\u{10FA}", 0x10FD: "\u{10FD}", 0x10FE: "\u{10FE}", 0x10FF: "\u{10FF}",
        0x1F80: "\u{1F88}", 0x1F81: "\u{1F89}", 0x1F82: "\u{1F8A}", 0x1F83: "\u{1F8B}",
        0x1F84: "\u{1F8C}", 0x1F85: "\u{1F8D}", 0x1F86: "\u{1F8E}", 0x1F87: "\u{1F8F}",
        0x1F88: "\u{1F88}", 0x1F89: "\u{1F89}", 0x1F8A: "\u{1F8A}", 0x1F8B: "\u{1F8B}",
        0x1F8C: "\u{1F8C}", 0x1F8D: "\u{1F8D}", 0x1F8E: "\u{1F8E}", 0x1F8F: "\u{1F8F}",
        0x1F90: "\u{1F98}", 0x1F91: "\u{1F99}", 0x1F92: "\u{1F9A}", 0x1F93: "\u{1F9B}",
        0x1F94: "\u{1F9C}", 0x1F95: "\u{1F9D}", 0x1F96: "\u{1F9E}", 0x1F97: "\u{1F9F}",
        0x1F98: "\u{1F98}", 0x1F99: "\u{1F99}", 0x1F9A: "\u{1F9A}", 0x1F9B: "\u{1F9B}",
        0x1F9C: "\u{1F9C}", 0x1F9D: "\u{1F9D}", 0x1F9E: "\u{1F9E}", 0x1F9F: "\u{1F9F}",
        0x1FA0: "\u{1FA8}", 0x1FA1: "\u{1FA9}", 0x1FA2: "\u{1FAA}", 0x1FA3: "\u{1FAB}",
        0x1FA4: "\u{1FAC}", 0x1FA5: "\u{1FAD}", 0x1FA6: "\u{1FAE}", 0x1FA7: "\u{1FAF}",
        0x1FA8: "\u{1FA8}", 0x1FA9: "\u{1FA9}", 0x1FAA: "\u{1FAA}", 0x1FAB: "\u{1FAB}",
        0x1FAC: "\u{1FAC}", 0x1FAD: "\u{1FAD}", 0x1FAE: "\u{1FAE}", 0x1FAF: "\u{1FAF}",
        0x1FB2: "\u{1FBA}\u{0345}", 0x1FB3: "\u{1FBC}", 0x1FB4: "\u{0386}\u{0345}",
        0x1FB7: "\u{0391}\u{0342}\u{0345}", 0x1FBC: "\u{1FBC}", 0x1FC2: "\u{1FCA}\u{0345}",
        0x1FC3: "\u{1FCC}", 0x1FC4: "\u{0389}\u{0345}", 0x1FC7: "\u{0397}\u{0342}\u{0345}",
        0x1FCC: "\u{1FCC}", 0x1FF2: "\u{1FFA}\u{0345}", 0x1FF3: "\u{1FFC}",
        0x1FF4: "\u{038F}\u{0345}", 0x1FF7: "\u{03A9}\u{0342}\u{0345}", 0x1FFC: "\u{1FFC}",
        0xFB00: "\u{0046}\u{0066}", 0xFB01: "\u{0046}\u{0069}", 0xFB02: "\u{0046}\u{006C}",
        0xFB03: "\u{0046}\u{0066}\u{0069}", 0xFB04: "\u{0046}\u{0066}\u{006C}",
        0xFB05: "\u{0053}\u{0074}", 0xFB06: "\u{0053}\u{0074}", 0xFB13: "\u{0544}\u{0576}",
        0xFB14: "\u{0544}\u{0565}", 0xFB15: "\u{0544}\u{056B}", 0xFB16: "\u{054E}\u{0576}",
        0xFB17: "\u{0544}\u{056D}",
    ]
}
