import AppIntents
import Foundation

/// Single toggle intent assignable to the Action Button (iPhone 15 Pro+) or to a Siri /
/// Shortcuts trigger. Reads the App Group phase and either starts a session (foregrounding
/// the app briefly to activate the audio session) or stops the in-flight session in place.
///
/// The actual recording lives in `KeyboardHostRecorder` which observes App Group state and
/// `UIApplication.didBecomeActiveNotification` — this intent's only job is to flip the
/// phase + nudge the runtime.
@available(iOS 16.4, *)
struct DictationToggleIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Toggle Codictate Dictation"
    static var description = IntentDescription(
        "Start a Codictate dictation session, or stop the one currently running."
    )

    /// Default: do not bring the app to the foreground. The start branch overrides this
    /// at runtime via `requestToContinueInForeground()` when an audio session needs to spin up.
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        guard let suite = UserDefaults(
            suiteName: "group.com.emillo2003.codictate-app"
        ) else {
            return .result()
        }

        let phase = suite.string(forKey: "kbdDictationPhase") ?? "idle"

        switch phase {
        case "start", "recording":
            // Stop branch: phase flip is enough — KeyboardHostRecorder polls App Group
            // every 150 ms and runs entirely in native code, so JS suspension is irrelevant.
            suite.set("stop_requested", forKey: "kbdDictationPhase")
            suite.synchronize()
            return .result()

        case "stop_requested", "processing":
            // Already wrapping up — leave it alone.
            return .result()

        default:
            // Start branch: write the pending session and bring the app forward so the
            // audio session can activate. After foreground continuation,
            // `UIApplication.didBecomeActiveNotification` triggers KeyboardHostRecorder.
            let filename = "intent-\(UUID().uuidString).wav"
            suite.set("start", forKey: "kbdDictationPhase")
            suite.set(filename, forKey: "kbdDictationWavFile")
            suite.set("intent", forKey: "kbdDictationSource")
            suite.removeObject(forKey: "kbdDictationHostError")
            suite.removeObject(forKey: "kbdTranscript")
            suite.synchronize()

            try await requestToContinueInForeground()

            // Belt-and-suspenders: post the start notification too, in case the app was
            // already active (no foreground transition fires) when the intent ran.
            await MainActor.run {
                NotificationCenter.default.post(
                    name: Notification.Name("codictate.dictation.start"),
                    object: nil,
                    userInfo: ["source": "intent"]
                )
            }

            return .result()
        }
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
