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
    private static let sourceKeyboard = "keyboard"
    private static let sourceIntent = "intent"
    // Darwin notification names kept as documentation; intents no longer post
    // them because they run in-process and call KeyboardHostRecorder directly.
    // The observers in KeyboardHostRecorder still listen for these names so that
    // a future cross-process caller (e.g., keyboard extension) can use them.

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let suite = UserDefaults(suiteName: Self.suiteName) else {
            return .result(value: "")
        }

        let phase = suite.string(forKey: Self.phaseKey) ?? "idle"

        // Stop path: must await transcription so the shortcut receives the text.
        if phase == "recording" {
            suite.set("stop_requested", forKey: Self.phaseKey)
            let transcript = await KeyboardHostRecorder.shared.requestStopAndWaitFromIntent()
            return .result(value: transcript ?? "")
        }

        if phase == "stop_requested" || phase == "processing" {
            return .result(value: "")
        }

        // Start path: Live Activity first for instant Dynamic Island, then
        // dispatch recording setup. Returns immediately.
        if #available(iOS 16.2, *) {
            DictationLiveActivityManager.shared.startRecording()
        }

        suite.set("start", forKey: Self.phaseKey)
        suite.set("intent-\(UUID().uuidString).wav", forKey: Self.wavFileKey)
        suite.set(Self.sourceIntent, forKey: Self.sourceKey)
        suite.removeObject(forKey: Self.errorKey)
        suite.removeObject(forKey: Self.transcriptKey)

        Task { @MainActor in
            KeyboardHostRecorder.shared.startRecordingForIntent()
        }

        return .result(value: "")
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
