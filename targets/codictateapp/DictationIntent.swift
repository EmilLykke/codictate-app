import AppIntents
import Foundation

/// Single toggle intent assignable to the Action Button (iPhone 15 Pro+) or to a Siri /
/// Shortcuts trigger. Reads the App Group phase and either starts a session (opening the
/// app to activate the audio session) or stops the in-flight session in place.
///
/// `openAppWhenRun = true` brings the app to the foreground without any confirmation dialog.
/// A Darwin cross-process notification additionally handles the case where the app is
/// already in the foreground (didBecomeActiveNotification never fires then).
@available(iOS 16.4, *)
struct DictationToggleIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Codictate Dictation"
    static var description = IntentDescription(
        "Start a Codictate dictation session, or stop the one currently running."
    )

    // Opens the app to the foreground so the audio session can activate — iOS blocks
    // new AVAudioSession activation from a suspended background process.
    // After recording starts the Live Activity keeps the UI; the user can immediately
    // press home and recording continues via UIBackgroundModes:audio.
    static var openAppWhenRun: Bool = true

    func perform() async -> some IntentResult {
        guard let suite = UserDefaults(
            suiteName: "group.com.emillo2003.codictate-app"
        ) else {
            return .result()
        }

        let phase = suite.string(forKey: "kbdDictationPhase") ?? "idle"

        switch phase {
        case "start", "recording":
            // Stop: flip phase and signal the recorder via Darwin (cross-process).
            suite.set("stop_requested", forKey: "kbdDictationPhase")
            suite.synchronize()
            postDarwin("com.emillo2003.codictate.dictation.intent.stop")
            return .result()

        case "stop_requested", "processing":
            return .result()

        default:
            // Start: write pending session state, then signal via Darwin.
            // `didBecomeActiveNotification` in the host app handles the start when the app
            // comes to the foreground. The Darwin notification covers the rare case where the
            // app is already active when the intent runs.
            let filename = "intent-\(UUID().uuidString).wav"
            suite.set("start", forKey: "kbdDictationPhase")
            suite.set(filename, forKey: "kbdDictationWavFile")
            suite.set("intent", forKey: "kbdDictationSource")
            suite.removeObject(forKey: "kbdDictationHostError")
            suite.removeObject(forKey: "kbdTranscript")
            suite.synchronize()
            postDarwin("com.emillo2003.codictate.dictation.intent.start")
            return .result()
        }
    }

    private func postDarwin(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name as CFString),
            nil, nil, true
        )
    }
}

/// Optional siloed Stop intent — handy for users who want a Shortcut that *only* stops,
/// e.g. via voice ("Hey Siri, stop Codictate"). Same App Group phase flip, no foregrounding.
@available(iOS 16.0, *)
struct StopDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Codictate Dictation"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        guard let suite = UserDefaults(
            suiteName: "group.com.emillo2003.codictate-app"
        ) else {
            return .result()
        }
        let phase = suite.string(forKey: "kbdDictationPhase") ?? "idle"
        if phase == "recording" || phase == "start" {
            suite.set("stop_requested", forKey: "kbdDictationPhase")
            suite.synchronize()
        }
        return .result()
    }
}

/// Surfaces the toggle intent in the Shortcuts app suggestions.
@available(iOS 16.0, *)
struct CodictateAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        if #available(iOS 16.4, *) {
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
