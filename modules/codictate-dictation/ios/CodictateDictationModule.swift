import ExpoModulesCore
import Foundation

/// Expo bridge for in-app dictation. Drives the host-app's `KeyboardHostRecorder` via
/// NotificationCenter (cross-Swift-module decoupling) and reads shared App Group state
/// for status/transcript values.
///
/// Symbol names like `codictate.dictation.start` and the App Group key strings are
/// duplicated here intentionally — a separate Swift module cannot import the main app
/// target's types directly, and the App Group keys are part of our public IPC contract.
public final class CodictateDictationModule: Module {

    // Mirror of `KeyboardDictationBridge` — keep in sync.
    private static let appGroupID = "group.com.emillo2003.codictate-app"
    private static let phaseKey = "kbdDictationPhase"
    private static let transcriptKey = "kbdTranscript"
    private static let errorKey = "kbdDictationHostError"
    private static let sourceKey = "kbdDictationSource"

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

        Events("onStateChange", "onTranscript", "onError")

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
            // produced while the app was suspended (e.g. keyboard or Action Button flow).
            guard let suite = UserDefaults(suiteName: Self.appGroupID) else { return nil }
            let phase = suite.string(forKey: Self.phaseKey) ?? "idle"
            guard phase == "ready", let text = suite.string(forKey: Self.transcriptKey), !text.isEmpty else {
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
    }

    // MARK: - NotificationCenter observers → JS events

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

    private func removeObservers() {
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
        if let transcriptObserver { NotificationCenter.default.removeObserver(transcriptObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        stateObserver = nil
        transcriptObserver = nil
        failureObserver = nil
    }
}
