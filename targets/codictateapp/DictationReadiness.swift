import AVFoundation
import Foundation
import UIKit

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

    /// The Host's inputs to `DictationReadinessState.resolve`, which decides the order.
    func resolve(variant: ModelManager.Variant, languageId: String) -> DictationReadinessState {
        DictationReadinessState.resolve(
            variant: variant,
            languageId: languageId,
            micPermissionDenied: micPermissionDenied(),
            downloadInProgress: inFlightVariants.contains(variant.rawValue),
            modelIsReady: { ModelManager.shared.modelIsReady(for: variant) }
        )
    }

    // MARK: - Publishing

    /// Resolves, and if the answer changed, writes it to the App Group and posts
    /// `codictate.readiness.changed`. Returns the current answer either way.
    @discardableResult
    func publish() -> DictationReadinessState {
        publishMicrophoneGrant()
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

    /// The keyboard reads the microphone permission once when its process starts and iOS
    /// does not update it there, so a keyboard opened before the grant (or one iOS keeps
    /// alive) can read it as undetermined. The In-keyboard path also trusts the Host's word.
    private func publishMicrophoneGrant() {
        guard let suite = UserDefaults(suiteName: groupID) else { return }
        // The deployment target is iOS 17, where `AVAudioApplication` reads the permission.
        let granted = AVAudioApplication.shared.recordPermission == .granted
        guard suite.object(forKey: KeyboardDictationBridge.hostMicrophoneGrantedKey) as? Bool != granted else { return }
        suite.set(granted, forKey: KeyboardDictationBridge.hostMicrophoneGrantedKey)
        suite.synchronize()
    }

    /// Only a denied microphone blocks. Undetermined does not: the recording path prompts
    /// for it, and blocking would stop the prompt from ever appearing.
    private func micPermissionDenied() -> Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }
}
