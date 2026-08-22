import AVFoundation
import Foundation
import UIKit

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

/// Cross-module NSNotification names. String-based so the Expo module, which is a
/// separate Swift module and cannot import these symbols, can post and observe them.
enum DictationReadinessNotification {
    /// Ask the Host to re-resolve readiness. Posted by anything that changes an input.
    static let recompute = Notification.Name("codictate.readiness.recompute")
    /// Readiness actually changed. userInfo is the readiness JSON object.
    static let changed = Notification.Name("codictate.readiness.changed")
}

/// Resolves Dictation Readiness from (selected Speech Model, stored Transcription
/// Language, weights on disk, download in flight, microphone permission) and publishes
/// the result to the App Group.
///
/// Computed in the Host, never in React Native: keyboard and Action Button dictation run
/// with no React Native process alive, so a resolver living in JavaScript could not
/// answer for them. React Native reads the published value and renders it.
final class DictationReadiness {

    static let shared = DictationReadiness()

    private let groupID = "group.app.codictate"
    private var inFlightVariants: Set<String> = []
    private var published: DictationReadinessState?
    private var observersInstalled = false

    private init() {}

    // MARK: - Messages

    /// Exhaustive by construction, with no `default:` clause: a fifth blocked reason
    /// cannot compile until somebody writes its message.
    static func message(
        for reason: DictationBlockedReason,
        variant: ModelManager.Variant
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

    // MARK: - Resolving

    /// Reads the current inputs from the App Group and resolves them.
    func currentState() -> DictationReadinessState {
        guard let suite = UserDefaults(suiteName: groupID) else { return .runnable }
        suite.synchronize()

        let rawVariant = suite.string(forKey: KeyboardDictationBridge.preferredVariantKey)
            ?? ModelManager.Variant.base.rawValue
        let variant = ModelManager.Variant(rawValue: rawVariant) ?? .base
        let storedLanguageId = suite.string(forKey: KeyboardDictationBridge.transcriptionLanguageKey)
            ?? ModelManager.Variant.automaticLanguageId
        // The same resolution the engine applies, so the published verdict describes the
        // Dictation turn that would actually run rather than the raw stored id.
        let languageId = variant.resolvedLanguageId(storedLanguageId)

        return resolve(variant: variant, languageId: languageId)
    }

    /// Exactly one reason is reported, and the order decides which. A denied microphone
    /// blocks every Speech Model, so it comes first. A Language Lock conflict is next,
    /// because no download fixes it and telling somebody to fetch 181 MB before they
    /// discover the language is wrong would be worse. A download in flight is a
    /// `weightsMissing` that is already being handled, so it shadows it.
    func resolve(variant: ModelManager.Variant, languageId: String) -> DictationReadinessState {
        if micPermissionDenied() {
            return blockedState(.micPermissionMissing, variant)
        }
        if !variant.accepts(languageId: languageId) {
            return blockedState(.languageUnsupportedByModel, variant)
        }
        if inFlightVariants.contains(variant.rawValue) {
            return blockedState(.downloadInProgress, variant)
        }
        if !ModelManager.shared.modelIsReady(for: variant) {
            return blockedState(.weightsMissing, variant)
        }
        return .runnable
    }

    private func blockedState(
        _ reason: DictationBlockedReason,
        _ variant: ModelManager.Variant
    ) -> DictationReadinessState {
        DictationReadinessState(
            blocked: true,
            reason: reason,
            message: Self.message(for: reason, variant: variant)
        )
    }

    // MARK: - Publishing

    /// Resolves, and if the answer changed, writes it to the App Group and posts
    /// `codictate.readiness.changed`. Returns the current answer either way.
    @discardableResult
    func publish() -> DictationReadinessState {
        let state = currentState()
        guard state != published else { return state }
        published = state

        if let suite = UserDefaults(suiteName: groupID),
           let data = try? JSONSerialization.data(withJSONObject: state.jsonObject) {
            suite.set(data, forKey: KeyboardDictationBridge.dictationReadinessKey)
            suite.synchronize()
        }

        NotificationCenter.default.post(
            name: DictationReadinessNotification.changed,
            object: nil,
            userInfo: state.jsonObject
        )
        return state
    }

    /// Installs every trigger that can change the answer. Called once from
    /// `KeyboardHostRecorder.bootstrap()`.
    func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true

        NotificationCenter.default.addObserver(
            forName: DictationReadinessNotification.recompute,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.publish()
        }

        NotificationCenter.default.addObserver(
            forName: ModelDownloadNotification.stateChanged,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let variant = note.userInfo?["variant"] as? String else { return }
            let inFlight = (note.userInfo?["inFlight"] as? Bool) ?? false
            if inFlight {
                self.inFlightVariants.insert(variant)
            } else {
                self.inFlightVariants.remove(variant)
            }
            self.publish()
        }

        for name in [ParakeetModelNotification.ready, ParakeetModelNotification.failed] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.publish()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            // Microphone access can be revoked in Settings while the app is suspended.
            self?.publish()
        }

        publish()
    }

    // MARK: - Private

    /// Only a denied microphone blocks. Undetermined does not: the recording path prompts
    /// for it, and blocking would stop the prompt from ever appearing.
    private func micPermissionDenied() -> Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .denied
        }
        return AVAudioSession.sharedInstance().recordPermission == .denied
    }
}
