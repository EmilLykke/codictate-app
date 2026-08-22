import ExpoModulesCore
import Foundation
import UIKit

/// Expo bridge for in-app dictation. Drives the host-app's `KeyboardHostRecorder` via
/// NotificationCenter (cross-Swift-module decoupling) and reads shared App Group state
/// for status/transcript values.
///
/// Symbol names like `codictate.dictation.start` and the App Group key strings are
/// duplicated here intentionally. A separate Swift module cannot import the main app
/// target's types directly, and the App Group keys are part of our public IPC contract.
public final class CodictateDictationModule: Module {

    // Mirror of `KeyboardDictationBridge`. Keep in sync.
    private static let appGroupID = "group.app.codictate"
    /// In-app dictation + Action Button. Must match KeyboardDictationBridge.preferredVariantKey.
    private static let preferredVariantKey = "preferredModelVariant"
    /// Transcription Language picker id, or "auto". JS writes, the Host reads.
    private static let transcriptionLanguageKey = "transcriptionLanguageId"
    /// Dictation Readiness JSON. The Host writes, JS reads. Never resolved here: keyboard
    /// and Action Button dictation run with no React Native process alive.
    private static let dictationReadinessKey = "dictationReadiness"
    private static let automaticLanguageId = "auto"
    private static let phaseKey = "kbdDictationPhase"
    private static let transcriptKey = "kbdTranscript"
    private static let errorKey = "kbdDictationHostError"
    private static let sourceKey = "kbdDictationSource"
    private static let keyboardVisibleKey = "kbdKeyboardVisible"
    private static let warmSessionDurationKey = "kbdWarmSessionDurationSeconds"
    private static let warmSessionExpiryKey = "kbdWarmSessionExpiry"
    private static let warmSessionActiveKey = "kbdWarmSessionActive"
    private static let warmSessionHeartbeatKey = "kbdWarmSessionHeartbeat"
    private static let endKeyboardWarmSessionNotification = Notification.Name("codictate.dictation.endKeyboardWarmSession")
    private static let defaultWarmDurationSeconds = 60
    private static let minWarmDurationSeconds = 30
    private static let maxWarmDurationSeconds = 1800

    // Mirror of `DictationNotification`.
    private static let startNotification = Notification.Name("codictate.dictation.start")
    private static let stopNotification = Notification.Name("codictate.dictation.stop")
    private static let cancelNotification = Notification.Name("codictate.dictation.cancel")
    private static let stateChangedNotification = Notification.Name("codictate.dictation.stateChanged")
    private static let transcriptReadyNotification = Notification.Name("codictate.dictation.transcriptReady")
    private static let failedNotification = Notification.Name("codictate.dictation.failed")

    // Mirror of `DictationReadinessNotification`.
    private static let readinessChangedNotification = Notification.Name("codictate.readiness.changed")
    private static let readinessRecomputeNotification = Notification.Name("codictate.readiness.recompute")
    /// The JS event name is the same literal as the notification name, on purpose.
    private static let readinessEventName = "codictate.readiness.changed"

    private var stateObserver: NSObjectProtocol?
    private var transcriptObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    private var readinessObserver: NSObjectProtocol?

    public func definition() -> ModuleDefinition {
        Name("CodictateDictation")

        Events("onStateChange", "onTranscript", "onError", "onModelProgress", Self.readinessEventName)

        OnCreate {
            self.installObservers()
            // No background URLSession is attached here on purpose. iOS relaunches a
            // terminated app to finish one without initialising React Native, so this
            // never runs on the launch that matters. The Host owns the session.
            //
            // The Host owns the readiness resolver too; ask it to publish so a first
            // render reads a value that was actually computed rather than an assumed
            // "runnable".
            Self.requestReadinessRecompute()
        }

        OnDestroy {
            self.removeObservers()
        }

        AsyncFunction("start") { (source: String?) -> Void in
            NotificationCenter.default.post(
                name: Self.startNotification,
                object: nil,
                userInfo: ["source": source ?? "host"]
            )
        }

        AsyncFunction("stop") { () -> Void in
            NotificationCenter.default.post(name: Self.stopNotification, object: nil)
        }

        AsyncFunction("cancel") { () -> Void in
            NotificationCenter.default.post(name: Self.cancelNotification, object: nil)
        }

        AsyncFunction("getState") { () -> [String: Any?] in
            let suite = UserDefaults(suiteName: Self.appGroupID)
            return [
                "phase": suite?.string(forKey: Self.phaseKey) ?? "idle",
                "transcript": suite?.string(forKey: Self.transcriptKey),
                "error": suite?.string(forKey: Self.errorKey),
                "source": suite?.string(forKey: Self.sourceKey),
            ]
        }

        AsyncFunction("consumeTranscript") { () -> String? in
            // Read + clear the App Group transcript. Used by JS to flush results
            // produced while the app was suspended. Only in-app sessions return text
            // to JS; keyboard and Action Button sessions finish outside the app UI.
            guard let suite = UserDefaults(suiteName: Self.appGroupID) else { return nil }
            let phase = suite.string(forKey: Self.phaseKey) ?? "idle"
            let source = suite.string(forKey: Self.sourceKey) ?? "host"
            guard phase == "ready", let text = suite.string(forKey: Self.transcriptKey), !text.isEmpty else {
                return nil
            }
            guard source == "host" else {
                if source == "intent" {
                    let keyboardVisible = suite.bool(forKey: Self.keyboardVisibleKey)
                    guard !keyboardVisible else { return nil }
                    UIPasteboard.general.string = text
                    suite.set("idle", forKey: Self.phaseKey)
                    suite.removeObject(forKey: Self.transcriptKey)
                    suite.removeObject(forKey: Self.errorKey)
                    suite.synchronize()
                }
                return nil
            }
            suite.set("idle", forKey: Self.phaseKey)
            suite.removeObject(forKey: Self.transcriptKey)
            suite.removeObject(forKey: Self.errorKey)
            suite.synchronize()
            return text
        }

        AsyncFunction("acknowledgeError") { () -> Void in
            guard let suite = UserDefaults(suiteName: Self.appGroupID) else { return }
            let phase = suite.string(forKey: Self.phaseKey) ?? "idle"
            guard phase == "failed" else { return }
            suite.set("idle", forKey: Self.phaseKey)
            suite.removeObject(forKey: Self.errorKey)
            suite.synchronize()
        }

        // MARK: - Keyboard warm session (native runtime; Settings write App Group only)

        AsyncFunction("getKeyboardWarmDuration") { () -> Int in
            guard let suite = UserDefaults(suiteName: Self.appGroupID) else { return Self.defaultWarmDurationSeconds }
            let stored = suite.integer(forKey: Self.warmSessionDurationKey)
            if stored <= 0 {
                return Self.defaultWarmDurationSeconds
            }
            return Self.clampWarmDuration(stored)
        }

        AsyncFunction("setKeyboardWarmDuration") { (seconds: Int) -> Void in
            guard let suite = UserDefaults(suiteName: Self.appGroupID) else { return }
            suite.set(Self.clampWarmDuration(seconds), forKey: Self.warmSessionDurationKey)
            suite.synchronize()
        }

        AsyncFunction("isKeyboardWarmSessionActive") { () -> Bool in
            guard let suite = UserDefaults(suiteName: Self.appGroupID) else { return false }
            suite.synchronize()
            return Self.isWarmSessionActive(suite: suite)
        }

        AsyncFunction("endKeyboardWarmSession") { () -> Void in
            NotificationCenter.default.post(name: Self.endKeyboardWarmSessionNotification, object: nil)
        }

        // MARK: - Transcription Language + Dictation Readiness

        // Declared `Function`, not `AsyncFunction`, on purpose: JS calls both getters
        // during first render, in a provider and a hook initializer, without a try/catch.

        Function("getTranscriptionLanguageId") { () -> String in
            guard let suite = UserDefaults(suiteName: Self.appGroupID) else {
                return Self.automaticLanguageId
            }
            let raw = (suite.string(forKey: Self.transcriptionLanguageKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? Self.automaticLanguageId : raw
        }

        Function("setTranscriptionLanguageId") { (id: String) -> Void in
            guard let suite = UserDefaults(suiteName: Self.appGroupID) else { return }
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            suite.set(
                trimmed.isEmpty ? Self.automaticLanguageId : trimmed,
                forKey: Self.transcriptionLanguageKey
            )
            suite.synchronize()
            Self.requestReadinessRecompute()
        }

        Function("getDictationReadiness") { () -> [String: Any?] in
            Self.readReadiness()
        }

        // MARK: - Model management

        AsyncFunction("isModelReady") { (variantStr: String?) -> Bool in
            let variant = AppGroupModelManager.Variant(rawValue: variantStr ?? "") ?? .base
            return AppGroupModelManager.shared.modelIsReady(for: variant)
        }

        AsyncFunction("ensureModel") { (variantStr: String?) async throws -> Void in
            let variant = AppGroupModelManager.Variant(rawValue: variantStr ?? "") ?? .base
            return try await withCheckedThrowingContinuation { continuation in
                AppGroupModelManager.shared.ensureModel(
                    variant: variant,
                    onProgress: { [weak self] progress in
                        self?.sendEvent("onModelProgress", ["variant": variant.rawValue, "progress": progress])
                    },
                    onComplete: { result in
                        Self.requestReadinessRecompute()
                        switch result {
                        case .success: continuation.resume()
                        case .failure(let err): continuation.resume(throwing: err)
                        }
                    }
                )
            }
        }

        AsyncFunction("deleteModel") { (variantStr: String?) -> Void in
            let variant = AppGroupModelManager.Variant(rawValue: variantStr ?? "") ?? .base
            if variant == .parakeet {
                if let dir = AppGroupModelManager.shared.parakeetModelDirectory {
                    try? FileManager.default.removeItem(at: dir)
                }
                let suite = UserDefaults(suiteName: Self.appGroupID)
                suite?.removeObject(forKey: "parakeetModelReady")
                suite?.synchronize()
                AppGroupModelManager.shared.resetParakeetDownloadState()
                NotificationCenter.default.post(
                    name: Notification.Name("codictate.parakeet.reset"),
                    object: nil
                )
                Self.requestReadinessRecompute()
                return
            }
            guard let path = AppGroupModelManager.shared.modelFilePath(for: variant) else { return }
            try? FileManager.default.removeItem(atPath: path)
            Self.requestReadinessRecompute()
        }

        AsyncFunction("listModels") { () -> [[String: Any?]] in
            return AppGroupModelManager.Variant.all.map { variant in
                let ready = AppGroupModelManager.shared.modelIsReady(for: variant)
                var size: Int64 = 0
                if variant == .parakeet {
                    // Report total size of the Parakeet CoreML directory
                    if let dir = AppGroupModelManager.shared.parakeetModelDirectory,
                       let enumerator = FileManager.default.enumerator(atPath: dir.path) {
                        while let file = enumerator.nextObject() as? String {
                            let fullPath = dir.appendingPathComponent(file).path
                            if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath) {
                                size += (attrs[.size] as? Int64) ?? 0
                            }
                        }
                    }
                } else if let path = AppGroupModelManager.shared.modelFilePath(for: variant),
                          let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                    size = (attrs[.size] as? Int64) ?? 0
                }
                return [
                    "variant": variant.rawValue,
                    "ready": ready,
                    "size": size,
                    "label": variant.label,
                    "engine": variant.engine.rawValue,
                    // Language Lock. `supportedLanguages` nil means the full picker;
                    // `locksLanguageToAutomatic` is Parakeet, which takes no language input.
                    "supportedLanguages": variant.supportedLanguages,
                    "locksLanguageToAutomatic": variant.locksLanguageToAutomatic,
                    "pinnedLanguageId": variant.pinnedLanguageId,
                ]
            }
        }

        AsyncFunction("getPreferredModel") { () -> String in
            guard let suite = UserDefaults(suiteName: Self.appGroupID) else { return AppGroupModelManager.Variant.base.rawValue }
            let raw = suite.string(forKey: Self.preferredVariantKey) ?? AppGroupModelManager.Variant.base.rawValue
            return AppGroupModelManager.Variant(rawValue: raw)?.rawValue ?? AppGroupModelManager.Variant.base.rawValue
        }

        AsyncFunction("setPreferredModel") { (variantStr: String?) -> Void in
            guard let suite = UserDefaults(suiteName: Self.appGroupID) else { return }
            let trimmed = (variantStr ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = AppGroupModelManager.Variant(rawValue: trimmed)?.rawValue ?? AppGroupModelManager.Variant.base.rawValue
            suite.set(value, forKey: Self.preferredVariantKey)
            suite.synchronize()
            Self.requestReadinessRecompute()
        }
    }

    // MARK: - NotificationCenter observers to JS events

    private func installObservers() {
        stateObserver = NotificationCenter.default.addObserver(
            forName: Self.stateChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let phase = (note.userInfo?["phase"] as? String) ?? "idle"
            var payload: [String: Any] = ["phase": phase]
            if let err = note.userInfo?["error"] as? String { payload["error"] = err }
            self.sendEvent("onStateChange", payload)
        }

        transcriptObserver = NotificationCenter.default.addObserver(
            forName: Self.transcriptReadyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // Keyboard-sourced sessions insert via textDocumentProxy in the extension.
            // Action Button sessions copy to clipboard and should not mutate the app draft.
            let source = (note.userInfo?["source"] as? String) ?? "host"
            guard source == "host" else { return }
            let text = (note.userInfo?["transcript"] as? String) ?? ""
            self.sendEvent("onTranscript", ["transcript": text])
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: Self.failedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let msg = (note.userInfo?["message"] as? String) ?? "Dictation failed."
            self.sendEvent("onError", ["message": msg])
        }

        readinessObserver = NotificationCenter.default.addObserver(
            forName: Self.readinessChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // The payload is the readiness object itself, not a wrapper.
            let raw = (note.userInfo as? [String: Any]) ?? [:]
            self.sendEvent(Self.readinessEventName, Self.normalizeReadiness(raw))
        }
    }

    // MARK: - Dictation Readiness

    /// Asks the Host to re-resolve readiness. The Host owns the resolver; this module
    /// only reads what it published.
    private static func requestReadinessRecompute() {
        NotificationCenter.default.post(name: readinessRecomputeNotification, object: nil)
    }

    private static func readReadiness() -> [String: Any?] {
        guard let suite = UserDefaults(suiteName: appGroupID),
              let data = suite.data(forKey: dictationReadinessKey),
              let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return normalizeReadiness([:])
        }
        return normalizeReadiness(raw)
    }

    /// The stored JSON carries NSNull for the two nullable fields; JS wants real nulls.
    /// `as? String` turns NSNull into nil, which is exactly the conversion needed.
    private static func normalizeReadiness(_ raw: [String: Any]) -> [String: Any?] {
        let blocked = (raw["blocked"] as? Bool) ?? false
        return [
            "blocked": blocked,
            "reason": blocked ? (raw["reason"] as? String) : nil,
            "message": blocked ? (raw["message"] as? String) : nil,
        ]
    }

    private static func clampWarmDuration(_ seconds: Int) -> Int {
        min(max(seconds, minWarmDurationSeconds), maxWarmDurationSeconds)
    }

    private static func isWarmSessionActive(suite: UserDefaults) -> Bool {
        let now = Date().timeIntervalSince1970
        let warmActive = suite.bool(forKey: warmSessionActiveKey)
        let warmExpiry = suite.double(forKey: warmSessionExpiryKey)
        return warmActive && warmExpiry > 0 && now < warmExpiry
    }

    private func removeObservers() {
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
        if let transcriptObserver { NotificationCenter.default.removeObserver(transcriptObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        if let readinessObserver { NotificationCenter.default.removeObserver(readinessObserver) }
        stateObserver = nil
        transcriptObserver = nil
        failureObserver = nil
        readinessObserver = nil
    }
}
