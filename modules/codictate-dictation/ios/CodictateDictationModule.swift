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

    private var stateObserver: NSObjectProtocol?
    private var transcriptObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?

    public func definition() -> ModuleDefinition {
        Name("CodictateDictation")

        Events("onStateChange", "onTranscript", "onError", "onModelProgress")

        OnCreate {
            self.installObservers()
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
                return
            }
            guard let path = AppGroupModelManager.shared.modelFilePath(for: variant) else { return }
            try? FileManager.default.removeItem(atPath: path)
        }

        AsyncFunction("listModels") { () -> [[String: Any]] in
            let variants: [AppGroupModelManager.Variant] = [.parakeet, .base, .baseEn]
            return variants.map { variant in
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
                return ["variant": variant.rawValue, "ready": ready, "size": size]
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
        stateObserver = nil
        transcriptObserver = nil
        failureObserver = nil
    }
}
