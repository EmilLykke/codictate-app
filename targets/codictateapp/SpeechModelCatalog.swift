import Foundation

/// The Speech Models and what is on disk for each: compiled into the Host, the keyboard and
/// the Dictation AU (`CodictateFormattingAU`), so all three read one definition of a Speech
/// Model's Language Lock, files and readiness. Nothing here downloads, posts notifications or
/// uses UIKit; that is `ModelManager`'s, which names these types `ModelManager.Variant`,
/// `ModelManager.PinnedFile` and `ModelManager.PunctuationModel` and adds the download URLs.
///
/// Parakeet's readiness is not here: FluidAudio's folder and the Host's `parakeetModelReady`
/// flag decide it (`ParakeetModelManager`, `KeyboardParakeet.modelIsReady`).
enum SpeechModelCatalog {

    /// A Speech Model: its id, its weights and its declared capabilities (its download URL is
    /// the Host's: `ModelManager.swift`). Keep in sync with `AppGroupModelManager.Variant` and
    /// the canonical table in `docs/adr/0001-crispasr-as-the-ios-asr-harness.md`.
    enum Variant: String {
        case parakeet = "parakeet"
        case base = "base"
        case baseEn = "base_en"
        case hviske = "hviske"
        case ekko = "ekko"

        /// The Transcription Language id meaning "let the Speech Model decide".
        static let automaticLanguageId = "auto"

        /// The runtime that executes this Speech Model's weights.
        /// Replaces the old `isWhisper` flag, which stopped being a sufficient
        /// discriminator the moment a third engine arrived.
        enum Engine: String {
            /// FluidAudio's AsrManager, Core ML on the Neural Engine.
            case parakeet
            /// crispasr's whisper backend.
            case whisper
            /// crispasr's cohere backend, the only runtime that reads hviske GGUF weights.
            case cohere
            /// parakeet.cpp, the only runtime that reads ekko GGUF weights.
            case ekko
        }

        var engine: Engine {
            switch self {
            case .parakeet: return .parakeet
            case .base, .baseEn: return .whisper
            case .hviske: return .cohere
            case .ekko: return .ekko
            }
        }

        var label: String {
            switch self {
            case .parakeet: return "Parakeet TDT v3"
            case .base: return "Base (Q5_1)"
            case .baseEn: return "Base.en (Q5_1)"
            case .hviske: return "Hviske V5 Tiny Q5"
            case .ekko: return "Ekko V1 Tiny Q5"
            }
        }

        /// The short name the keyboard's model switcher shows. Model names keep their own
        /// spelling and casing.
        var shortName: String {
            switch self {
            case .parakeet: return "Parakeet"
            case .base: return "Whisper base"
            case .baseEn: return "Whisper base.en"
            case .hviske: return "hviske"
            case .ekko: return "ekko"
            }
        }

        /// Language Lock: the Transcription Languages this Speech Model accepts.
        /// `nil` means the full picker. Feeding a Speech Model a language it does not
        /// support yields a fluent wrong-language transcript and never an error, which
        /// is why the lock is declared data rather than a runtime guess.
        var supportedLanguages: [String]? {
            switch self {
            case .parakeet: return nil
            case .base: return nil
            case .baseEn: return ["en"]
            case .hviske, .ekko: return ["da"]
            }
        }

        /// Parakeet takes no language input at all, so it locks to automatic rather
        /// than to a list of codes.
        var locksLanguageToAutomatic: Bool {
            switch self {
            case .parakeet: return true
            case .base, .baseEn, .hviske, .ekko: return false
            }
        }

        /// The single Transcription Language a locked Speech Model runs, or nil when it
        /// accepts the full list. The UI shows this instead of an enabled picker.
        var pinnedLanguageId: String? {
            if locksLanguageToAutomatic { return Variant.automaticLanguageId }
            guard let supported = supportedLanguages, supported.count == 1 else { return nil }
            return supported[0]
        }

        /// Human-readable form of the Language Lock, for the Dictation Readiness message.
        var languageLockLabel: String {
            switch self {
            case .parakeet: return "automatic language detection"
            case .base: return "every language"
            case .baseEn: return "English"
            case .hviske, .ekko: return "Danish"
            }
        }

        /// Language Lock check. A Speech Model locked to a language list accepts exactly
        /// that list, plus the automatic id: `auto` is the absence of a choice, not a
        /// conflicting one, and `resolvedLanguageId` turns it into the pinned language
        /// before any engine sees it. Only an explicitly picked other language conflicts.
        /// A Speech Model locked to automatic accepts only automatic.
        func accepts(languageId: String) -> Bool {
            if locksLanguageToAutomatic { return languageId == Variant.automaticLanguageId }
            guard let supported = supportedLanguages else { return true }
            if languageId == Variant.automaticLanguageId, pinnedLanguageId != nil { return true }
            return supported.contains(languageId)
        }

        /// The Transcription Language the engine actually runs with. A Speech Model with
        /// a pinned language reads the automatic id as its own language; everything else
        /// keeps the stored id. This is the single place the stored picker id becomes an
        /// engine input, so a bare `auto` can never reach weights that cannot detect a
        /// language. Idempotent: resolving an already-resolved id returns it unchanged.
        func resolvedLanguageId(_ storedId: String) -> String {
            guard let pinned = pinnedLanguageId, storedId == Variant.automaticLanguageId else {
                return storedId
            }
            return pinned
        }

        var filename: String {
            switch self {
            case .parakeet: return ""
            case .base: return "ggml-base-q5_1.bin"
            case .baseEn: return "ggml-base.en-q5_1.bin"
            case .hviske: return "hviske-v5-tiny-q5_0.gguf"
            case .ekko: return "ekko-v1-tiny-q5_0.gguf"
            }
        }

        /// The exact file a download must be, for a Speech Model pinned by size and sha256.
        /// A downloaded file that does not match is never installed. nil for the Speech
        /// Models fetched from an unpinned `main`, which only get the `minBytes` floor.
        var pinnedFile: PinnedFile? {
            switch self {
            case .parakeet, .base, .baseEn, .hviske: return nil
            case .ekko:
                return PinnedFile(
                    bytes: 134_710_976,
                    sha256: "f5380485d80d552ae46313185126d7ade54b2e7360cb0d15b91f1ab26ced7791"
                )
            }
        }

        /// Sanity floor for "these are real weights, not a truncated file or an error page".
        var minBytes: Int64 {
            switch self {
            case .parakeet: return 0
            case .base, .baseEn: return 50 * 1024 * 1024
            case .hviske: return 150 * 1024 * 1024
            case .ekko: return pinnedFile?.bytes ?? 0
            }
        }

        /// Every Speech Model whose weights are a single file in the App Group container.
        /// ekko's weights are, though it also needs the Punctuation Model to count as ready.
        static let fileBacked: [Variant] = [.base, .baseEn, .hviske, .ekko]

        static let all: [Variant] = [.parakeet, .base, .baseEn, .hviske, .ekko]
    }

    /// A downloaded file's pinned size and sha256.
    struct PinnedFile: Equatable {
        let bytes: Int64
        let sha256: String
    }

    /// ekko-pnc, the Punctuation Model every ekko Raw Transcript goes through: the runtime files Punctuation Restoration reads, as desktop pins them
    /// in `src/shared/punctuation-model-files.ts` (the Mirror's licence files are carried in
    /// `third-party/ekko-pnc` instead). Installed in its own App Group folder, beside the
    /// Speech Models, and downloaded as part of ekko.
    enum PunctuationModel {
        struct File: Equatable {
            /// Path inside the Mirror, and inside `directoryName`.
            let path: String
            let pinned: PinnedFile
        }

        /// The App Group folder the runtime files install into.
        static let directoryName = "ekko-pnc"

        /// What `EkkoPncModel` opens. The Punctuation Model is installed only with all three.
        static let runtimeFiles: [File] = [
            File(path: "pnc.int8.onnx", pinned: PinnedFile(
                bytes: 22_424_741,
                sha256: "46bb979d409731872f10b6cb71298594595f16368d2aec2fcaf94d87b4266527")),
            File(path: "tokenizer.json", pinned: PinnedFile(
                bytes: 2_301_084,
                sha256: "a1e0d43ee307ad7a1ccc23e6e5398d877a68ca7f576067ac507625a0d50e9502")),
            File(path: "config.json", pinned: PinnedFile(
                bytes: 1_062,
                sha256: "dc655c46f69eeb15dd43786ad58fb5862cc794b36cc9d2c426ab5bc4b01f23ca")),
        ]
    }

    /// The App Group container, or nil in a process without the entitlement.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.codictate")
    }

    /// Where a file-backed Speech Model's weights live; nil for Parakeet.
    static func weightsPath(for variant: Variant) -> String? {
        guard variant != .parakeet else { return nil }
        return containerURL?.appendingPathComponent(variant.filename).path
    }

    /// The weights are on disk at their `minBytes` floor.
    static func weightsArePresent(_ variant: Variant) -> Bool {
        guard let path = weightsPath(for: variant) else { return false }
        return fileSize(URL(fileURLWithPath: path)) >= variant.minBytes
    }

    /// The folder holding ekko-pnc's runtime files, which `PunctuationRestorer` opens.
    static var punctuationModelDirectory: URL? {
        containerURL?.appendingPathComponent(PunctuationModel.directoryName, isDirectory: true)
    }

    /// Every ekko-pnc runtime file is on disk at its pinned size.
    static var punctuationModelIsInstalled: Bool {
        PunctuationModel.runtimeFiles.allSatisfy { file in
            guard let url = punctuationModelDirectory?.appendingPathComponent(file.path) else {
                return false
            }
            return fileSize(url) == file.pinned.bytes
        }
    }

    /// A file-backed Speech Model can run: its weights are on disk, and for ekko the
    /// Punctuation Model too (its Raw Transcript is lowercase and unpunctuated, and
    /// Punctuation Restoration always runs on it). Always false for Parakeet.
    static func filesAreInstalled(for variant: Variant) -> Bool {
        switch variant {
        case .parakeet:
            return false
        case .base, .baseEn, .hviske:
            return weightsArePresent(variant)
        case .ekko:
            return weightsArePresent(variant) && punctuationModelIsInstalled
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int64) ?? 0
    }
}
