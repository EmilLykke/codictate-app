import Foundation

// Dictation Readiness's verdict and the rule that reaches it, compiled into the Host
// (`DictationReadiness`, which gathers the inputs and publishes the verdict) and the
// Dictation AU (`CodictateFormattingAU`), which checks a keyboard turn against the same rule
// before it runs a Speech Model. Nothing here reads permissions, downloads or UserDefaults.

/// Why a Dictation turn cannot start. A closed set of exactly four; the raw values are
/// the contract with the `DictationBlockedReason` union in `modules/codictate-dictation`.
/// Do not add a fifth without adding it there too.
enum DictationBlockedReason: String {
    case weightsMissing
    case downloadInProgress
    case languageUnsupportedByModel
    case micPermissionMissing
}

/// The answer to "can a Dictation turn start right now": either runnable, or blocked
/// with exactly one reason. There is no third state, no substitution of a different
/// Speech Model and no fallback.
struct DictationReadinessState: Equatable {
    let blocked: Bool
    let reason: DictationBlockedReason?
    let message: String?

    static let runnable = DictationReadinessState(blocked: false, reason: nil, message: nil)

    /// `reason` and `message` are present but null when nothing is blocked, so the shape
    /// JS reads never changes.
    var jsonObject: [String: Any] {
        var object: [String: Any] = ["blocked": blocked]
        if let reason { object["reason"] = reason.rawValue } else { object["reason"] = NSNull() }
        if let message { object["message"] = message } else { object["message"] = NSNull() }
        return object
    }
}

extension DictationReadinessState {
    /// Exactly one reason is reported, and the order decides which. A denied microphone
    /// blocks every Speech Model, so it comes first. A Language Lock conflict is next,
    /// because no download fixes it and telling somebody to fetch 181 MB before they
    /// discover the language is wrong would be worse. A download in flight is a
    /// `weightsMissing` that is already being handled, so it shadows it.
    static func resolve(
        variant: SpeechModelCatalog.Variant,
        languageId: String,
        micPermissionDenied: Bool,
        downloadInProgress: Bool,
        modelIsReady: () -> Bool
    ) -> DictationReadinessState {
        if micPermissionDenied {
            return blocked(.micPermissionMissing, variant)
        }
        if !variant.accepts(languageId: languageId) {
            return blocked(.languageUnsupportedByModel, variant)
        }
        if downloadInProgress {
            return blocked(.downloadInProgress, variant)
        }
        if !modelIsReady() {
            return blocked(.weightsMissing, variant)
        }
        return .runnable
    }

    private static func blocked(
        _ reason: DictationBlockedReason,
        _ variant: SpeechModelCatalog.Variant
    ) -> DictationReadinessState {
        DictationReadinessState(blocked: true, reason: reason, message: message(for: reason, variant: variant))
    }

    /// Exhaustive by construction, with no `default:` clause: a fifth blocked reason
    /// cannot compile until somebody writes its message.
    static func message(
        for reason: DictationBlockedReason,
        variant: SpeechModelCatalog.Variant
    ) -> String {
        switch reason {
        case .weightsMissing:
            return "\(variant.label) is not downloaded yet."
        case .downloadInProgress:
            return "\(variant.label) is still downloading."
        case .languageUnsupportedByModel:
            return "\(variant.label) only supports \(variant.languageLockLabel). Change the language in Settings."
        case .micPermissionMissing:
            return "Microphone access is off. Turn it on in Settings > Privacy & Security > Microphone."
        }
    }
}
