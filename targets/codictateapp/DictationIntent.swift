import AppIntents
import Foundation

// MARK: - Toggle Intent (Action Button / Shortcuts)

@available(iOS 18.0, *)
struct DictationToggleIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "Toggle Codictate Dictation"
    static var description = IntentDescription(
        "Start or stop a Codictate dictation session."
    )
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let phase = KeyboardHostRecorder.shared.currentPhase()
        NSLog("[DictationIntent] perform() phase=\(phase)")

        switch phase {
        case "start", "recording":
            NSLog("[DictationIntent] → stopping")
            await MainActor.run {
                KeyboardHostRecorder.shared.requestStopFromIntent()
            }
        case "stop_requested", "processing":
            NSLog("[DictationIntent] → already stopping/processing")
        default:
            NSLog("[DictationIntent] → starting")
            await MainActor.run {
                KeyboardHostRecorder.shared.startRecordingFromIntent()
            }
        }

        return .result()
    }
}

// MARK: - Stop Intent (Siri)

@available(iOS 16.0, *)
struct StopDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Codictate Dictation"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let phase = KeyboardHostRecorder.shared.currentPhase()
        if phase == "recording" || phase == "start" {
            await MainActor.run {
                KeyboardHostRecorder.shared.requestStopFromIntent()
            }
        }
        return .result()
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
