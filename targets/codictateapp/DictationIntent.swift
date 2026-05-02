import ActivityKit
import AppIntents
import Foundation

// MARK: - Toggle Intent (Action Button / Shortcuts)

@available(iOS 18.0, *)
struct DictationToggleIntent: AudioRecordingIntent, LiveActivityIntent {
    static var title: LocalizedStringResource = "Toggle Codictate Dictation"
    static var description = IntentDescription(
        "Start or stop a Codictate dictation session."
    )
    static var openAppWhenRun: Bool = false

    private static let suiteName = "group.app.codictate"
    private static let phaseKey = "kbdDictationPhase"
    private static let wavFileKey = "kbdDictationWavFile"
    private static let sourceKey = "kbdDictationSource"
    private static let errorKey = "kbdDictationHostError"
    private static let transcriptKey = "kbdTranscript"
    private static let darwinStart = "app.codictate.dictation.intent.start"
    private static let darwinStop = "app.codictate.dictation.intent.stop"

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        NSLog("[DictationIntent] perform() entry")

        guard let suite = UserDefaults(suiteName: Self.suiteName) else {
            NSLog("[DictationIntent] No App Group suite")
            return .result(value: "")
        }
        suite.synchronize()
        let phase = suite.string(forKey: Self.phaseKey) ?? "idle"
        NSLog("[DictationIntent] phase=\(phase)")

        switch phase {
        case "start", "recording":
            NSLog("[DictationIntent] → stopping")
            suite.set("stop_requested", forKey: Self.phaseKey)
            suite.synchronize()
            postDarwin(Self.darwinStop)
            let transcript = await KeyboardHostRecorder.shared.requestStopAndWaitFromIntent()
            return .result(value: transcript ?? "")

        case "stop_requested", "processing":
            NSLog("[DictationIntent] → already stopping/processing")

        default:
            NSLog("[DictationIntent] → starting")

            // 1. Write state to App Group (safe, no crash risk)
            let filename = "intent-\(UUID().uuidString).wav"
            suite.set("start", forKey: Self.phaseKey)
            suite.set(filename, forKey: Self.wavFileKey)
            suite.set("intent", forKey: Self.sourceKey)
            suite.removeObject(forKey: Self.errorKey)
            suite.removeObject(forKey: Self.transcriptKey)
            suite.synchronize()

            // 2. Post Darwin notification for host app
            postDarwin(Self.darwinStart)

            // 3. Start recording synchronously. The recorder starts/reuses the
            // Live Activity before audio activation so the Dynamic Island is live immediately.
            await MainActor.run {
                KeyboardHostRecorder.shared.beginRecordingIfPending()
            }
        }

        return .result(value: "")
    }

    private func postDarwin(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name as CFString),
            nil, nil, true
        )
    }
}

// MARK: - Stop Intent (Siri)

@available(iOS 16.0, *)
struct StopDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Codictate Dictation"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let suite = UserDefaults(
            suiteName: "group.app.codictate"
        ) else { return .result(value: "") }
        suite.synchronize()
        let phase = suite.string(forKey: "kbdDictationPhase") ?? "idle"
        if phase == "recording" || phase == "start" {
            suite.set("stop_requested", forKey: "kbdDictationPhase")
            suite.synchronize()
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(rawValue: "app.codictate.dictation.intent.stop" as CFString),
                nil, nil, true
            )
            let transcript = await KeyboardHostRecorder.shared.requestStopAndWaitFromIntent()
            return .result(value: transcript ?? "")
        }
        return .result(value: "")
    }
}

// MARK: - Shortcuts Provider

@available(iOS 16.0, *)
struct CodictateAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        if #available(iOS 18.0, *) {
            return [
                AppShortcut(
                    intent: DictationToggleIntent(),
                    phrases: [
                        "Start dictation in \(.applicationName)",
                        "Toggle \(.applicationName) dictation",
                    ],
                    shortTitle: "Toggle Dictation",
                    systemImageName: "mic.fill"
                ),
                AppShortcut(
                    intent: StopDictationIntent(),
                    phrases: [
                        "Stop \(.applicationName) dictation",
                        "Stop dictating with \(.applicationName)",
                    ],
                    shortTitle: "Stop Dictation",
                    systemImageName: "stop.fill"
                ),
            ]
        } else {
            return [
                AppShortcut(
                    intent: StopDictationIntent(),
                    phrases: [
                        "Stop \(.applicationName) dictation",
                    ],
                    shortTitle: "Stop Dictation",
                    systemImageName: "stop.fill"
                ),
            ]
        }
    }
}
