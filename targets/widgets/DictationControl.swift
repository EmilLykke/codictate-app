import AppIntents
import SwiftUI
import WidgetKit

// MARK: - App Group constants (mirrored from host app)

private enum DictationBridge {
    static let suiteName    = "group.com.emillo2003.codictate-app"
    static let phaseKey     = "kbdDictationPhase"
    static let wavFileKey   = "kbdDictationWavFile"
    static let sourceKey    = "kbdDictationSource"
    static let errorKey     = "kbdDictationHostError"
    static let transcriptKey = "kbdTranscript"
}

// MARK: - Control Widget

@available(iOS 18.0, *)
struct DictationControlWidget: ControlWidget {
    static let kind = "com.emillo2003.codictate.DictationControl"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: Self.kind,
            provider: DictationValueProvider()
        ) { isRecording in
            ControlWidgetToggle(
                "Dictation",
                isOn: isRecording,
                action: DictationControlToggleIntent(),
                valueLabel: { isOn in
                    Label(
                        isOn ? "Recording" : "Dictate",
                        systemImage: isOn ? "mic.fill" : "mic"
                    )
                }
            )
        }
        .displayName("Codictate Dictation")
        .description("Start or stop voice dictation. Transcribed text is copied to the clipboard.")
    }
}

// MARK: - Value Provider

@available(iOS 18.0, *)
struct DictationValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        guard let suite = UserDefaults(suiteName: DictationBridge.suiteName) else {
            return false
        }
        suite.synchronize()
        let phase = suite.string(forKey: DictationBridge.phaseKey) ?? "idle"
        return phase == "recording" || phase == "start"
    }
}

// MARK: - Toggle Intent

@available(iOS 18.0, *)
struct DictationControlToggleIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Codictate Widget Toggle"
    static var description = IntentDescription(
        "Control Center toggle for Codictate dictation."
    )
    static var isDiscoverable: Bool = false

    @Parameter(title: "Recording")
    var value: Bool

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        NSLog("[ControlIntent] perform() called, value=\(value), bundle=\(bundleID)")

        guard let suite = UserDefaults(suiteName: DictationBridge.suiteName) else {
            NSLog("[ControlIntent] FAILED: no App Group suite")
            return .result()
        }

        let phase = suite.string(forKey: DictationBridge.phaseKey) ?? "idle"
        NSLog("[ControlIntent] current phase=\(phase)")

        if value {
            guard phase == "idle" || phase == "ready" || phase == "failed" else {
                NSLog("[ControlIntent] START skipped: phase=\(phase) not idle/ready/failed")
                return .result()
            }
            let filename = "intent-\(UUID().uuidString).wav"
            suite.set("start", forKey: DictationBridge.phaseKey)
            suite.set(filename, forKey: DictationBridge.wavFileKey)
            suite.set("intent", forKey: DictationBridge.sourceKey)
            suite.removeObject(forKey: DictationBridge.errorKey)
            suite.removeObject(forKey: DictationBridge.transcriptKey)
            suite.synchronize()
            NSLog("[ControlIntent] Wrote phase=start, posting Darwin + NSNotification")
            postDarwin("com.emillo2003.codictate.dictation.intent.start")
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("codictate.dictation.start"),
                    object: nil,
                    userInfo: ["source": "intent"]
                )
            }
            NSLog("[ControlIntent] START done")
        } else {
            guard phase == "recording" || phase == "start" else {
                NSLog("[ControlIntent] STOP skipped: phase=\(phase) not recording/start")
                return .result()
            }
            suite.set("stop_requested", forKey: DictationBridge.phaseKey)
            suite.synchronize()
            NSLog("[ControlIntent] Wrote phase=stop_requested, posting Darwin + NSNotification")
            postDarwin("com.emillo2003.codictate.dictation.intent.stop")
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("codictate.dictation.stop"),
                    object: nil
                )
            }
            NSLog("[ControlIntent] STOP done")
        }

        return .result()
    }

    private func postDarwin(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name as CFString),
            nil, nil, true
        )
    }
}
