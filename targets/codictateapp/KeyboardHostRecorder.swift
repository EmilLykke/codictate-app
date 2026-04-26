import AVFoundation
import Foundation
import UIKit

/// App-group keys shared with `KeyboardViewController` in the keyboard extension.
/// Dictation runs in the **main app** (mic + Whisper); the keyboard only coordinates
/// via the shared group + `codictateapp://keyboard-record`.
enum KeyboardDictationBridge {
    static let suiteName = "group.com.emillo2003.codictate-app"
    static let phaseKey = "kbdDictationPhase"
    static let wavFileKey = "kbdDictationWavFile"
    static let errorKey = "kbdDictationHostError"
    static let transcriptKey = "kbdTranscript"

    static let phaseIdle = "idle"
    static let phaseStart = "start"
    static let phaseRecording = "recording"
    static let phaseStopRequested = "stop_requested"
    static let phaseProcessing = "processing"
    static let phaseReady = "ready"
    static let phaseFailed = "failed"
}

/// Native Whisper + model download for keyboard handoff (main app only).
private final class KeyboardHostTranscription: NSObject {
    static let shared = KeyboardHostTranscription()
    private let bridge = WhisperBridge()

    private override init() {
        super.init()
    }

    func transcribeWav(atPath wavPath: String, suite: UserDefaults, onComplete: @escaping () -> Void) {
        ModelManager.shared.ensureModel(
            onProgress: { _ in },
            onComplete: { [weak self] result in
                guard let self else {
                    onComplete()
                    return
                }
                switch result {
                case .failure(let error):
                    KeyboardHostRecorder.shared.fail(
                        suite,
                        "Speech model: \(error.localizedDescription). Open Codictate once on Wi‑Fi to download the small model."
                    )
                    onComplete()
                case .success(let modelPath):
                    if !self.bridge.isLoaded {
                        guard self.bridge.loadModel(atPath: modelPath) else {
                            KeyboardHostRecorder.shared.fail(suite, "Could not load the speech model.")
                            onComplete()
                            return
                        }
                    }
                    let lang = Self.currentWhisperLanguageTag()
                    self.bridge.transcribeWavFile(wavPath, language: lang) { transcript, errorMsg in
                        defer { onComplete() }
                        if let text = transcript, !text.isEmpty {
                            UIPasteboard.general.string = text
                            suite.set(text, forKey: KeyboardDictationBridge.transcriptKey)
                            suite.set(KeyboardDictationBridge.phaseReady, forKey: KeyboardDictationBridge.phaseKey)
                            suite.removeObject(forKey: KeyboardDictationBridge.errorKey)
                            suite.synchronize()
                            NSLog("[KeyboardHost] Transcription ready, length=\(text.count)")
                        } else {
                            let msg = errorMsg ?? "No speech detected."
                            KeyboardHostRecorder.shared.fail(suite, msg)
                        }
                    }
                }
            }
        )
    }

    private static func currentWhisperLanguageTag() -> String? {
        if #available(iOS 16, *) {
            Locale.current.language.languageCode?.identifier
        } else {
            Locale.current.languageCode
        }
    }
}

/// Runs inside the **main iOS app**. Records to the App Group while the user types in another app
/// (after returning from the URL handoff). `UIBackgroundModes` must include `audio`.
final class KeyboardHostRecorder: NSObject {

    static let shared = KeyboardHostRecorder()

    private var recorder: AVAudioRecorder?
    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    private static let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    private override init() {
        super.init()
    }

    deinit {
        cancelActivationWait()
    }

    /// Call from `AppDelegate.application(_:open:options:)` when the keyboard opens `codictateapp://keyboard-record`.
    func handleDeepLink() {
        DispatchQueue.main.async { [weak self] in
            self?.handleDeepLinkOnMain()
        }
    }

    fileprivate func fail(_ suite: UserDefaults, _ message: String) {
        cancelActivationWait()
        pollTimer?.invalidate()
        pollTimer = nil
        recorder?.stop()
        recorder = nil
        suite.set(KeyboardDictationBridge.phaseFailed, forKey: KeyboardDictationBridge.phaseKey)
        suite.set(message, forKey: KeyboardDictationBridge.errorKey)
        suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
        suite.synchronize()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        NSLog("[KeyboardHost] Failed: \(message)")
    }

    private func cancelActivationWait() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    private func beginRecordingWhenActive(suite: UserDefaults) {
        cancelActivationWait()

        let attemptStart: () -> Void = { [weak self] in
            guard let self else { return }
            let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? KeyboardDictationBridge.phaseIdle
            guard phase == KeyboardDictationBridge.phaseStart else {
                NSLog("[KeyboardHost] Aborted start; phase=\(phase)")
                return
            }
            self.beginRecording(suite: suite)
        }

        if UIApplication.shared.applicationState == .active {
            attemptStart()
        } else {
            activationObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.cancelActivationWait()
                attemptStart()
            }
        }
    }

    private func handleDeepLinkOnMain() {
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else {
            NSLog("[KeyboardHost] No app group suite")
            return
        }

        let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? KeyboardDictationBridge.phaseIdle
        guard phase == KeyboardDictationBridge.phaseStart else {
            NSLog("[KeyboardHost] Deep link ignored; phase=\(phase)")
            return
        }

        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .denied:
                fail(suite, "Microphone access denied. Enable Codictate in Settings › Privacy › Microphone.")
            case .undetermined:
                AVAudioApplication.requestRecordPermission { [weak self] granted in
                    DispatchQueue.main.async {
                        if granted {
                            self?.beginRecordingWhenActive(suite: suite)
                        } else {
                            self?.fail(suite, "Microphone access is required for dictation.")
                        }
                    }
                }
            case .granted:
                beginRecordingWhenActive(suite: suite)
            @unknown default:
                beginRecordingWhenActive(suite: suite)
            }
        } else {
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .denied:
                fail(suite, "Microphone access denied. Enable Codictate in Settings › Privacy › Microphone.")
            case .undetermined:
                session.requestRecordPermission { [weak self] granted in
                    DispatchQueue.main.async {
                        if granted {
                            self?.beginRecordingWhenActive(suite: suite)
                        } else {
                            self?.fail(suite, "Microphone access is required for dictation.")
                        }
                    }
                }
            case .granted:
                beginRecordingWhenActive(suite: suite)
            @unknown default:
                beginRecordingWhenActive(suite: suite)
            }
        }
    }

    private func outputURL(suite: UserDefaults) -> URL? {
        guard let name = suite.string(forKey: KeyboardDictationBridge.wavFileKey), !name.isEmpty else {
            return nil
        }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KeyboardDictationBridge.suiteName
        ) else { return nil }
        let dir = container.appendingPathComponent("KeyboardRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private func beginRecording(suite: UserDefaults) {
        guard let url = outputURL(suite: suite) else {
            fail(suite, "Could not create recording path (App Group missing?).")
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true, options: [])
        } catch {
            fail(suite, "Audio session error: \(error.localizedDescription)")
            return
        }

        do {
            let rec = try AVAudioRecorder(url: url, settings: Self.recordingSettings)
            guard rec.prepareToRecord() else {
                fail(suite, "Could not prepare the microphone for recording.")
                return
            }
            guard rec.record() else {
                fail(suite, "Could not start microphone recording in the app.")
                return
            }
            guard rec.isRecording else {
                fail(suite, "Microphone did not enter recording state. Open Codictate once, then try again.")
                return
            }
            recorder = rec
        } catch {
            fail(suite, "Recorder error: \(error.localizedDescription)")
            return
        }

        suite.set(KeyboardDictationBridge.phaseRecording, forKey: KeyboardDictationBridge.phaseKey)
        suite.removeObject(forKey: KeyboardDictationBridge.errorKey)
        suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
        suite.synchronize()

        startPollingForStop(suite: suite)

        NSLog("[KeyboardHost] Recording to \(url.path)")
    }

    private func startPollingForStop(suite: UserDefaults) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] t in
            guard let self else {
                t.invalidate()
                return
            }
            self.suitePollTick(suite: suite, timer: t)
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    private func suitePollTick(suite: UserDefaults, timer: Timer) {
        let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? ""
        guard phase == KeyboardDictationBridge.phaseStopRequested else { return }

        timer.invalidate()
        pollTimer = nil

        guard let wavURL = outputURL(suite: suite) else {
            fail(suite, "Recording file path missing.")
            return
        }

        recorder?.stop()
        recorder = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        suite.set(KeyboardDictationBridge.phaseProcessing, forKey: KeyboardDictationBridge.phaseKey)
        suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
        suite.synchronize()

        let path = wavURL.path
        NSLog("[KeyboardHost] Stop requested; transcribing \(path)")

        KeyboardHostTranscription.shared.transcribeWav(atPath: path, suite: suite) {}
    }
}
