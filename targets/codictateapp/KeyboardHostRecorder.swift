import AVFoundation
import Foundation
import UIKit

/// App-group keys shared between every dictation entry point: keyboard extension,
/// host-app JS bridge, and the App Intent (Action Button / Shortcuts).
enum KeyboardDictationBridge {
    static let suiteName = "group.com.emillo2003.codictate-app"
    static let phaseKey = "kbdDictationPhase"
    static let wavFileKey = "kbdDictationWavFile"
    static let errorKey = "kbdDictationHostError"
    static let transcriptKey = "kbdTranscript"
    static let sourceKey = "kbdDictationSource"

    static let phaseIdle = "idle"
    static let phaseStart = "start"
    static let phaseRecording = "recording"
    static let phaseStopRequested = "stop_requested"
    static let phaseProcessing = "processing"
    static let phaseReady = "ready"
    static let phaseFailed = "failed"

    static let sourceKeyboard = "keyboard"
    static let sourceHost = "host"
    static let sourceIntent = "intent"
}

/// Cross-module NSNotification names. Using string-based names keeps the JS
/// bridge module (separate Swift module) decoupled from the recorder symbol.
enum DictationNotification {
    static let start = Notification.Name("codictate.dictation.start")
    static let stop = Notification.Name("codictate.dictation.stop")
    static let cancel = Notification.Name("codictate.dictation.cancel")
    static let stateChanged = Notification.Name("codictate.dictation.stateChanged")
    static let transcriptReady = Notification.Name("codictate.dictation.transcriptReady")
    static let failed = Notification.Name("codictate.dictation.failed")
}

/// Native Whisper + model download for keyboard handoff (main app only).
private final class KeyboardHostTranscription: NSObject {
    static let shared = KeyboardHostTranscription()
    private let bridge = WhisperBridge()
    private var loadedModelPath: String?

    private override init() {
        super.init()
    }

    func transcribeWav(atPath wavPath: String, suite: UserDefaults, onComplete: @escaping () -> Void) {
        // Source-aware model pick: keyboard target stays on Tiny (memory-tight extension),
        // host / Action Button paths get Base for higher quality.
        let source = suite.string(forKey: KeyboardDictationBridge.sourceKey)
            ?? KeyboardDictationBridge.sourceHost
        let variant: ModelManager.Variant =
            source == KeyboardDictationBridge.sourceKeyboard ? .tiny : .base

        ModelManager.shared.ensureModel(
            variant: variant,
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
                    // Reload bridge whenever the path changes (variant switch). loadModelAtPath
                    // internally unloads the previous model, so this is safe to call repeatedly.
                    if !self.bridge.isLoaded || self.loadedModelPath != modelPath {
                        guard self.bridge.loadModel(atPath: modelPath) else {
                            KeyboardHostRecorder.shared.fail(suite, "Could not load the speech model.")
                            onComplete()
                            return
                        }
                        self.loadedModelPath = modelPath
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
                            NotificationCenter.default.post(
                                name: DictationNotification.transcriptReady,
                                object: nil,
                                userInfo: ["transcript": text]
                            )
                            NotificationCenter.default.post(
                                name: DictationNotification.stateChanged,
                                object: nil,
                                userInfo: ["phase": KeyboardDictationBridge.phaseReady]
                            )
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

/// Runs inside the **main iOS app**. Records natively to the App Group regardless of which
/// entry point initiated the session — keyboard URL, JS module, or App Intent. JS thread
/// suspension does not stop recording because all control flow lives in Swift.
/// `UIBackgroundModes` must include `audio` for background recording to survive.
final class KeyboardHostRecorder: NSObject {

    static let shared = KeyboardHostRecorder()

    private var recorder: AVAudioRecorder?
    private var pollTimer: Timer?
    private var autoStopTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var didInstallNotificationObservers = false

    /// Auto-stop fallback in case no entry point requests stop (covers stuck-in-background).
    private static let autoStopAfterSeconds: TimeInterval = 60

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

    // MARK: - Bootstrap

    /// Wires NotificationCenter observers so other Swift modules (the JS bridge module,
    /// App Intent, etc.) can drive recording without a direct symbol dependency on this class.
    /// Idempotent — call from `application(_:didFinishLaunchingWithOptions:)`.
    func bootstrap() {
        DispatchQueue.main.async { [weak self] in
            self?.installNotificationObservers()
        }
    }

    private func installNotificationObservers() {
        guard !didInstallNotificationObservers else { return }
        didInstallNotificationObservers = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStartNotification(_:)),
            name: DictationNotification.start,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStopNotification(_:)),
            name: DictationNotification.stop,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCancelNotification(_:)),
            name: DictationNotification.cancel,
            object: nil
        )
        // Pick up pending start writes from App Intent (which runs while app is suspended).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppActivation),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func handleStartNotification(_ note: Notification) {
        let source = (note.userInfo?["source"] as? String) ?? KeyboardDictationBridge.sourceHost
        startSessionDirect(source: source)
    }

    @objc private func handleStopNotification(_ note: Notification) {
        requestStop()
    }

    @objc private func handleCancelNotification(_ note: Notification) {
        cancel()
    }

    @objc private func handleAppActivation() {
        // App Intent path: phase was set to "start" while app was backgrounded.
        // No active recorder yet → kick off session.
        guard recorder == nil else { return }
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
        let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? KeyboardDictationBridge.phaseIdle
        guard phase == KeyboardDictationBridge.phaseStart else { return }
        let source = suite.string(forKey: KeyboardDictationBridge.sourceKey) ?? KeyboardDictationBridge.sourceHost
        startSessionInternal(suite: suite, source: source)
    }

    // MARK: - Public entry points

    /// Called from `AppDelegate.application(_:open:options:)` when the keyboard opens
    /// `codictateapp://keyboard-record`. Reads pending phase=start written by the keyboard.
    func handleDeepLink() {
        DispatchQueue.main.async { [weak self] in
            self?.handleDeepLinkOnMain()
        }
    }

    /// Programmatic start (JS module / App Intent). Generates a filename and writes
    /// pending state to App Group, then begins recording.
    func startSessionDirect(source: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.recorder == nil else { return }
            guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }

            let filename = "host-\(UUID().uuidString).wav"
            suite.set(KeyboardDictationBridge.phaseStart, forKey: KeyboardDictationBridge.phaseKey)
            suite.set(filename, forKey: KeyboardDictationBridge.wavFileKey)
            suite.set(source, forKey: KeyboardDictationBridge.sourceKey)
            suite.removeObject(forKey: KeyboardDictationBridge.errorKey)
            suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
            suite.synchronize()

            self.startSessionInternal(suite: suite, source: source)
        }
    }

    private func startSessionInternal(suite: UserDefaults, source: String) {
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

    /// Programmatic stop (JS module / App Intent / keyboard). Triggers transcription on the
    /// current recording. Safe to call when not recording.
    func requestStop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
            let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? ""
            guard phase == KeyboardDictationBridge.phaseRecording
               || phase == KeyboardDictationBridge.phaseStart else { return }
            suite.set(KeyboardDictationBridge.phaseStopRequested, forKey: KeyboardDictationBridge.phaseKey)
            suite.synchronize()
            // Trigger immediately rather than waiting for the next poll tick.
            if let timer = self.pollTimer {
                self.suitePollTick(suite: suite, timer: timer)
            }
        }
    }

    /// Discard the current recording without transcribing. JS-driven cancel.
    func cancel() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
            self.pollTimer?.invalidate()
            self.pollTimer = nil
            self.cancelAutoStop()
            self.recorder?.stop()
            self.recorder = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            suite.set(KeyboardDictationBridge.phaseIdle, forKey: KeyboardDictationBridge.phaseKey)
            suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
            suite.removeObject(forKey: KeyboardDictationBridge.errorKey)
            suite.synchronize()
            NotificationCenter.default.post(
                name: DictationNotification.stateChanged,
                object: nil,
                userInfo: ["phase": KeyboardDictationBridge.phaseIdle]
            )
        }
    }

    /// Lookup-only — used by the JS bridge to seed initial state without polling.
    func currentPhase() -> String {
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else {
            return KeyboardDictationBridge.phaseIdle
        }
        return suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? KeyboardDictationBridge.phaseIdle
    }

    // MARK: - Failure

    fileprivate func fail(_ suite: UserDefaults, _ message: String) {
        cancelActivationWait()
        pollTimer?.invalidate()
        pollTimer = nil
        cancelAutoStop()
        recorder?.stop()
        recorder = nil
        suite.set(KeyboardDictationBridge.phaseFailed, forKey: KeyboardDictationBridge.phaseKey)
        suite.set(message, forKey: KeyboardDictationBridge.errorKey)
        suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
        suite.synchronize()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        NotificationCenter.default.post(
            name: DictationNotification.failed,
            object: nil,
            userInfo: ["message": message]
        )
        NotificationCenter.default.post(
            name: DictationNotification.stateChanged,
            object: nil,
            userInfo: ["phase": KeyboardDictationBridge.phaseFailed, "error": message]
        )
        NSLog("[KeyboardHost] Failed: \(message)")
    }

    private func cancelActivationWait() {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    private func cancelAutoStop() {
        autoStopTimer?.invalidate()
        autoStopTimer = nil
    }

    // MARK: - Recording lifecycle

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

        // Mark the source so JS can distinguish keyboard-initiated vs in-app sessions.
        suite.set(KeyboardDictationBridge.sourceKeyboard, forKey: KeyboardDictationBridge.sourceKey)
        suite.synchronize()

        startSessionInternal(suite: suite, source: KeyboardDictationBridge.sourceKeyboard)
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

        NotificationCenter.default.post(
            name: DictationNotification.stateChanged,
            object: nil,
            userInfo: ["phase": KeyboardDictationBridge.phaseRecording]
        )

        startPollingForStop(suite: suite)
        startAutoStopFallback()

        NSLog("[KeyboardHost] Recording to \(url.path)")
    }

    private func startAutoStopFallback() {
        cancelAutoStop()
        autoStopTimer = Timer.scheduledTimer(
            withTimeInterval: Self.autoStopAfterSeconds,
            repeats: false
        ) { [weak self] _ in
            NSLog("[KeyboardHost] Auto-stop fallback fired after \(Self.autoStopAfterSeconds)s")
            self?.requestStop()
        }
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
        cancelAutoStop()

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

        NotificationCenter.default.post(
            name: DictationNotification.stateChanged,
            object: nil,
            userInfo: ["phase": KeyboardDictationBridge.phaseProcessing]
        )

        let path = wavURL.path
        NSLog("[KeyboardHost] Stop requested; transcribing \(path)")

        KeyboardHostTranscription.shared.transcribeWav(atPath: path, suite: suite) {}
    }
}
