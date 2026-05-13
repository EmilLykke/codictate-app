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
        NSLog("[DictationIntent] perform() entry")

        guard let suite = UserDefaults(suiteName: Self.suiteName) else {
            NSLog("[DictationIntent] No App Group suite")
            return .result(value: "")
        }
        suite.synchronize()
        let phase = suite.string(forKey: Self.phaseKey) ?? "idle"
        let source = suite.string(forKey: Self.sourceKey) ?? ""
        NSLog("[DictationIntent] phase=\(phase), source=\(source)")

        switch phase {
        case "start":
            if source == Self.sourceKeyboard && !KeyboardHostRecorder.shared.hasActiveRecording() {
                NSLog("[DictationIntent] stale keyboard start detected; replacing with intent start")
                startNewSession(suite)
            } else {
                NSLog("[DictationIntent] stopping pending start")
                let transcript = await stopCurrentSession(suite)
                return .result(value: transcript ?? "")
            }

        case "recording":
            NSLog("[DictationIntent] stopping recording")
            let transcript = await stopCurrentSession(suite)
            return .result(value: transcript ?? "")

        case "stop_requested", "processing":
            NSLog("[DictationIntent] already stopping/processing")

        default:
            NSLog("[DictationIntent] starting")
            startNewSession(suite)
        }

        return .result(value: "")
    }

    private func startNewSession(_ suite: UserDefaults) {
        let filename = "intent-\(UUID().uuidString).wav"
        suite.set("start", forKey: Self.phaseKey)
        suite.set(filename, forKey: Self.wavFileKey)
        suite.set(Self.sourceIntent, forKey: Self.sourceKey)
        suite.removeObject(forKey: Self.errorKey)
        suite.removeObject(forKey: Self.transcriptKey)
        // Skip synchronize() here: beginRecordingIfPending runs in the same
        // process and reads from the in-memory UserDefaults cache. The cross-
        // process flush is only needed for the keyboard extension path.

        // Fire-and-forget on the main thread so perform() returns instantly and
        // the Shortcuts running indicator disappears right away. The recording
        // will start on the next main run loop iteration; the Live Activity
        // appears once the audio session is ready.
        Task { @MainActor in
            KeyboardHostRecorder.shared.beginRecordingIfPending()
        }
    }

    private func stopCurrentSession(_ suite: UserDefaults) async -> String? {
        suite.set("stop_requested", forKey: Self.phaseKey)
        suite.synchronize()
        // No Darwin notification: the intent calls requestStopAndWaitFromIntent
        // directly. A Darwin stop would race handleDarwinStop, which calls
        // processStopRequested(completion: nil), consuming the recorder before
        // the intent's own completion handler can receive the transcript.
        return await KeyboardHostRecorder.shared.requestStopAndWaitFromIntent()
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
