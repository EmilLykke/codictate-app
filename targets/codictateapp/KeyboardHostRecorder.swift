import ActivityKit
import AVFoundation
import Foundation
import UIKit
import WidgetKit

/// App-group keys shared between every dictation entry point: keyboard extension,
/// host-app JS bridge, and the App Intent (Action Button / Shortcuts).
enum KeyboardDictationBridge {
    static let suiteName = "group.app.codictate"
    /// In-app dictation + Action Button / Shortcut. Must match CodictateDictationModule.
    static let preferredVariantKey = "preferredWhisperVariant"
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

    /// Keyboard sessions always use Tiny (extension memory budget). Other entry points
    /// use the user preference from the App Group, falling back to any ready model.
    private static func transcriptionVariant(source: String, suite: UserDefaults) -> ModelManager.Variant {
        if source == KeyboardDictationBridge.sourceKeyboard {
            return .tiny
        }
        let raw = suite.string(forKey: KeyboardDictationBridge.preferredVariantKey) ?? "base"
        let preferred: ModelManager.Variant = raw == "tiny" ? .tiny : .base
        if ModelManager.shared.modelIsReady(for: preferred) {
            return preferred
        }
        if ModelManager.shared.modelIsReady(for: .base) {
            return .base
        }
        if ModelManager.shared.modelIsReady(for: .tiny) {
            return .tiny
        }
        return preferred
    }

    func transcribeWav(atPath wavPath: String, suite: UserDefaults, onComplete: @escaping (String?) -> Void) {
        let source = suite.string(forKey: KeyboardDictationBridge.sourceKey)
            ?? KeyboardDictationBridge.sourceHost
        let variant = Self.transcriptionVariant(source: source, suite: suite)

        ModelManager.shared.ensureModel(
            variant: variant,
            onProgress: { _ in },
            onComplete: { [weak self] result in
                guard let self else {
                    onComplete(nil)
                    return
                }
                switch result {
                case .failure(let error):
                    KeyboardHostRecorder.shared.fail(
                        suite,
                        "Speech model: \(error.localizedDescription). Open Codictate once on Wi‑Fi to download the small model."
                    )
                    onComplete(nil)
                case .success(let modelPath):
                    // Reload bridge whenever the path changes (variant switch). loadModelAtPath
                    // internally unloads the previous model, so this is safe to call repeatedly.
                    if !self.bridge.isLoaded || self.loadedModelPath != modelPath {
                        guard self.bridge.loadModel(atPath: modelPath) else {
                            KeyboardHostRecorder.shared.fail(suite, "Could not load the speech model.")
                            onComplete(nil)
                            return
                        }
                        self.loadedModelPath = modelPath
                    }
                    let lang = Self.currentWhisperLanguageTag()
                    self.bridge.transcribeWavFile(wavPath, language: lang) { transcript, errorMsg in
                        if let text = transcript, !text.isEmpty {
                            let isIntentSession = source == KeyboardDictationBridge.sourceIntent
                            if source != KeyboardDictationBridge.sourceKeyboard {
                                Self.copyToClipboard(text)
                            }

                            if isIntentSession {
                                suite.set(KeyboardDictationBridge.phaseIdle, forKey: KeyboardDictationBridge.phaseKey)
                                suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
                            } else {
                                suite.set(text, forKey: KeyboardDictationBridge.transcriptKey)
                                suite.set(KeyboardDictationBridge.phaseReady, forKey: KeyboardDictationBridge.phaseKey)
                            }
                            suite.removeObject(forKey: KeyboardDictationBridge.errorKey)
                            suite.synchronize()
                            KeyboardHostRecorder.reloadControlWidget()
                            if #available(iOS 16.2, *) {
                                DictationLiveActivityManager.shared.end()
                            }
                            // Include source so the JS bridge knows whether to handle the
                            // transcript or leave it to the keyboard extension (which inserts
                            // via textDocumentProxy, avoiding double-paste inside this app).
                            NotificationCenter.default.post(
                                name: DictationNotification.transcriptReady,
                                object: nil,
                                userInfo: ["transcript": text, "source": source]
                            )
                            NotificationCenter.default.post(
                                name: DictationNotification.stateChanged,
                                object: nil,
                                userInfo: [
                                    "phase": isIntentSession
                                        ? KeyboardDictationBridge.phaseIdle
                                        : KeyboardDictationBridge.phaseReady
                                ]
                            )
                            NSLog("[KeyboardHost] Transcription ready, length=\(text.count)")
                            onComplete(text)
                        } else {
                            let msg = errorMsg ?? "No speech detected."
                            KeyboardHostRecorder.shared.fail(suite, msg)
                            onComplete(nil)
                        }
                    }
                }
            }
        )
    }

    private static func copyToClipboard(_ text: String) {
        if Thread.isMainThread {
            UIPasteboard.general.string = text
        } else {
            DispatchQueue.main.sync {
                UIPasteboard.general.string = text
            }
        }
    }

    private static func currentWhisperLanguageTag() -> String? {
        if #available(iOS 16, *) {
            Locale.current.language.languageCode?.identifier
        } else {
            Locale.current.languageCode
        }
    }
}

// MARK: - Live Activity Manager

@available(iOS 16.2, *)
final class DictationLiveActivityManager {
    static let shared = DictationLiveActivityManager()
    private var currentActivityID: String?
    private var recordingStartDate: Date?

    private init() {}

    @discardableResult
    func startRecording() -> Bool {
        if let activity = trackedActivity() {
            let now = Date()
            currentActivityID = activity.id
            recordingStartDate = now
            update(activity, phase: KeyboardDictationBridge.phaseRecording, startDate: now)
            NSLog("[LiveActivity] Reusing id=\(activity.id)")
            return true
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("[LiveActivity] Activities not enabled by user")
            return false
        }

        let now = Date()
        recordingStartDate = now
        let state = DictationActivityAttributes.ContentState(phase: "recording", startDate: now)
        do {
            let activity = try Activity.request(
                attributes: DictationActivityAttributes(),
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            currentActivityID = activity.id
            NSLog("[LiveActivity] Started id=\(activity.id)")
            return true
        } catch {
            NSLog("[LiveActivity] Start failed: \(error)")
            currentActivityID = nil
            recordingStartDate = nil
            return false
        }
    }

    func updateToProcessing() {
        guard let activity = trackedActivity() else { return }

        let state = DictationActivityAttributes.ContentState(
            phase: "processing",
            startDate: recordingStartDate ?? Date()
        )
        currentActivityID = activity.id
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
            NSLog("[LiveActivity] Updated to processing")
        }
    }

    func end() {
        let activitiesToEnd: [Activity<DictationActivityAttributes>]
        if let activity = trackedActivity() {
            activitiesToEnd = [activity]
        } else {
            activitiesToEnd = Activity<DictationActivityAttributes>.activities
        }

        for activity in activitiesToEnd {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
                NSLog("[LiveActivity] Ended id=\(activity.id)")
            }
        }
        currentActivityID = nil
        recordingStartDate = nil
    }

    private func trackedActivity() -> Activity<DictationActivityAttributes>? {
        if let id = currentActivityID,
           let activity = Activity<DictationActivityAttributes>.activities.first(where: { $0.id == id }) {
            return activity
        }
        return Activity<DictationActivityAttributes>.activities.first
    }

    private func update(
        _ activity: Activity<DictationActivityAttributes>,
        phase: String,
        startDate: Date
    ) {
        let state = DictationActivityAttributes.ContentState(phase: phase, startDate: startDate)
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }
}

// MARK: - Darwin IPC (keyboard extension → host app)

private let kbdDarwinStartName    = "app.codictate.dictation.keyboard.start"
private let kbdDarwinStopName     = "app.codictate.dictation.keyboard.stop"
private let intentDarwinStartName = "app.codictate.dictation.intent.start"
private let intentDarwinStopName  = "app.codictate.dictation.intent.stop"

// C-compatible callback — relays Darwin notification name to NSNotificationCenter on the main thread.
// Must be file-scope (not a method) because CFNotificationCallback is a C function pointer.
private func kbdDarwinCallback(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    guard let rawName = name?.rawValue as String? else { return }
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: NSNotification.Name(rawName), object: nil)
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
    /// Called from `application(_:didFinishLaunchingWithOptions:)` — already on the main thread.
    /// Installs observers synchronously so they are ready before `applicationDidBecomeActive` fires.
    func bootstrap() {
        NSLog("[KeyboardHost] bootstrap() — installing observers")
        installNotificationObservers()
        recoverStaleState()
    }

    /// Reset App Group phases left over from a previous crash or force-quit.
    /// For "start", wait briefly in case a fresh intent just wrote it and the
    /// Darwin notification hasn't fired yet.
    private func recoverStaleState() {
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
        suite.synchronize()
        let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey)
            ?? KeyboardDictationBridge.phaseIdle

        switch phase {
        case KeyboardDictationBridge.phaseStart:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.recorder == nil else { return }
                guard let s = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
                s.synchronize()
                let current = s.string(forKey: KeyboardDictationBridge.phaseKey)
                    ?? KeyboardDictationBridge.phaseIdle
                if current == KeyboardDictationBridge.phaseStart {
                    let source = s.string(forKey: KeyboardDictationBridge.sourceKey)
                        ?? KeyboardDictationBridge.sourceHost
                    NSLog("[KeyboardHost] Recovering stale 'start' phase; attempting recording (source=\(source))")
                    self.startSessionInternal(suite: s, source: source)
                }
            }
        case KeyboardDictationBridge.phaseRecording,
             KeyboardDictationBridge.phaseStopRequested,
             KeyboardDictationBridge.phaseProcessing:
            NSLog("[KeyboardHost] Stale phase '\(phase)' at bootstrap; resetting to idle.")
            suite.set(KeyboardDictationBridge.phaseIdle, forKey: KeyboardDictationBridge.phaseKey)
            suite.removeObject(forKey: KeyboardDictationBridge.errorKey)
            suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
            suite.synchronize()
            Self.reloadControlWidget()
        default:
            break
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

        // Darwin (cross-process) listeners for keyboard extension.
        // Handles the case where Codictate is already in the foreground when the keyboard
        // Dictate button is tapped — didBecomeActiveNotification never fires then.
        let darwinCenter = CFNotificationCenterGetDarwinNotifyCenter()
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        for startName in [kbdDarwinStartName, intentDarwinStartName] {
            CFNotificationCenterAddObserver(
                darwinCenter, selfPtr, kbdDarwinCallback,
                startName as CFString, nil, .deliverImmediately
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleDarwinStart),
                name: NSNotification.Name(startName), object: nil
            )
        }
        for stopName in [kbdDarwinStopName, intentDarwinStopName] {
            CFNotificationCenterAddObserver(
                darwinCenter, selfPtr, kbdDarwinCallback,
                stopName as CFString, nil, .deliverImmediately
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleDarwinStop),
                name: NSNotification.Name(stopName), object: nil
            )
        }
    }

    @objc private func handleStartNotification(_ note: Notification) {
        let source = (note.userInfo?["source"] as? String) ?? KeyboardDictationBridge.sourceHost
        NSLog("[KeyboardHost] handleStartNotification fired, source=\(source)")
        startSessionDirect(source: source)
    }

    @objc private func handleStopNotification(_ note: Notification) {
        requestStop()
    }

    @objc private func handleCancelNotification(_ note: Notification) {
        cancel()
    }

    @objc private func handleAppActivation() {
        guard recorder == nil else { return }
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
        // Force a reload from the App Group container to pick up writes from the keyboard extension
        // or App Intent that may have occurred while this process was suspended.
        suite.synchronize()
        let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? KeyboardDictationBridge.phaseIdle
        guard phase == KeyboardDictationBridge.phaseStart else { return }
        let source = suite.string(forKey: KeyboardDictationBridge.sourceKey) ?? KeyboardDictationBridge.sourceHost
        startSessionInternal(suite: suite, source: source)
    }

    // Received when the keyboard extension posts a Darwin start notification.
    // Fires even when Codictate is already in the foreground (unlike didBecomeActiveNotification).
    @objc private func handleDarwinStart() {
        NSLog("[KeyboardHost] handleDarwinStart fired, recorder=\(recorder != nil)")
        guard recorder == nil else { return }
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
        suite.synchronize()
        let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? KeyboardDictationBridge.phaseIdle
        NSLog("[KeyboardHost] handleDarwinStart phase=\(phase)")
        guard phase == KeyboardDictationBridge.phaseStart else { return }
        let source = suite.string(forKey: KeyboardDictationBridge.sourceKey) ?? KeyboardDictationBridge.sourceHost
        startSessionInternal(suite: suite, source: source)
    }

    @objc private func handleDarwinStop() {
        requestStop()
    }

    // MARK: - Public entry points

    /// Called from `AppDelegate.application(_:open:options:)` when the keyboard opens
    /// `codictateapp://keyboard-record`. Reads pending phase=start written by the keyboard.
    func handleDeepLink() {
        DispatchQueue.main.async { [weak self] in
            self?.handleDeepLinkOnMain()
        }
    }

    /// Programmatic start (JS module). Generates a filename and writes
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

    /// Synchronous recording start for App Intents. Bypasses async dispatch and
    /// app-state gate because AudioRecordingIntent guarantees background execution.
    /// Must be called on the main thread (via MainActor.run in the intent).
    func startRecordingFromIntent() {
        guard recorder == nil else { return }
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }

        let filename = "intent-\(UUID().uuidString).wav"
        suite.set(KeyboardDictationBridge.phaseStart, forKey: KeyboardDictationBridge.phaseKey)
        suite.set(filename, forKey: KeyboardDictationBridge.wavFileKey)
        suite.set(KeyboardDictationBridge.sourceIntent, forKey: KeyboardDictationBridge.sourceKey)
        suite.removeObject(forKey: KeyboardDictationBridge.errorKey)
        suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
        suite.synchronize()

        beginRecording(suite: suite)
    }

    /// Reads App Group state and begins recording if phase is "start".
    /// Called by the intent after it has already written state to the App Group.
    func beginRecordingIfPending() {
        guard recorder == nil else { return }
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
        suite.synchronize()
        let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? ""
        guard phase == KeyboardDictationBridge.phaseStart else { return }
        beginRecording(suite: suite)
    }

    /// Synchronous stop for App Intents.
    func requestStopFromIntent(completion: ((String?) -> Void)? = nil) {
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
        suite.synchronize()
        let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? ""
        guard phase == KeyboardDictationBridge.phaseRecording
           || phase == KeyboardDictationBridge.phaseStart
           || phase == KeyboardDictationBridge.phaseStopRequested else {
            completion?(nil)
            return
        }
        if phase != KeyboardDictationBridge.phaseStopRequested {
            suite.set(KeyboardDictationBridge.phaseStopRequested, forKey: KeyboardDictationBridge.phaseKey)
            suite.synchronize()
        }
        if recorder == nil {
            resetPendingStartAfterStop(suite: suite)
            completion?(nil)
            return
        }
        if let timer = pollTimer {
            suitePollTick(suite: suite, timer: timer, completion: completion)
        } else {
            processStopRequested(suite: suite, completion: completion)
        }
    }

    func requestStopAndWaitFromIntent() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                self.requestStopFromIntent { transcript in
                    continuation.resume(returning: transcript)
                }
            }
        }
    }

    private func startSessionInternal(suite: UserDefaults, source: String) {
        NSLog("[KeyboardHost] startSessionInternal source=\(source)")
        if #available(iOS 17.0, *) {
            let perm = AVAudioApplication.shared.recordPermission
            NSLog("[KeyboardHost] mic permission=\(perm.rawValue) (0=undetermined, 1=denied, 2=granted)")
            switch perm {
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
            suite.synchronize()
            let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? ""
            guard phase == KeyboardDictationBridge.phaseRecording
               || phase == KeyboardDictationBridge.phaseStart
               || phase == KeyboardDictationBridge.phaseStopRequested else { return }
            if phase != KeyboardDictationBridge.phaseStopRequested {
                suite.set(KeyboardDictationBridge.phaseStopRequested, forKey: KeyboardDictationBridge.phaseKey)
                suite.synchronize()
            }
            if self.recorder == nil {
                self.resetPendingStartAfterStop(suite: suite)
                return
            }
            // Trigger immediately rather than waiting for the next poll tick.
            if let timer = self.pollTimer {
                self.suitePollTick(suite: suite, timer: timer)
            } else {
                self.processStopRequested(suite: suite, completion: nil)
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
            Self.reloadControlWidget()
            if #available(iOS 16.2, *) {
                DictationLiveActivityManager.shared.end()
            }
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

    // MARK: - Control Widget

    static func reloadControlWidget() {
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(
                ofKind: "app.codictate.DictationControl"
            )
        }
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
        Self.reloadControlWidget()
        if #available(iOS 16.2, *) {
            DictationLiveActivityManager.shared.end()
        }
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

        let state = UIApplication.shared.applicationState
        NSLog("[KeyboardHost] beginRecordingWhenActive appState=\(state.rawValue) (0=active, 1=inactive, 2=background)")

        switch state {
        case .active:
            attemptStart()
        case .background:
            attemptStart()
        case .inactive:
            activationObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.cancelActivationWait()
                attemptStart()
            }
        @unknown default:
            attemptStart()
        }
    }

    private func handleDeepLinkOnMain() {
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else {
            NSLog("[KeyboardHost] No app group suite")
            return
        }

        suite.synchronize()
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
        NSLog("[KeyboardHost] beginRecording called")
        guard let url = outputURL(suite: suite) else {
            fail(suite, "Could not create recording path (App Group missing?).")
            return
        }

        let source = suite.string(forKey: KeyboardDictationBridge.sourceKey)
            ?? KeyboardDictationBridge.sourceHost
        let isIntentStart = source == KeyboardDictationBridge.sourceIntent

        if #available(iOS 16.2, *) {
            let didStartLiveActivity = DictationLiveActivityManager.shared.startRecording()
            if isIntentStart && !didStartLiveActivity {
                fail(suite, "Could not start Live Activity for Action Button recording.")
                return
            }
        } else if isIntentStart {
            fail(suite, "Live Activity support is required for Action Button recording.")
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
            NSLog("[KeyboardHost] Audio session category set, activating...")
            try session.setActive(true, options: [])
            NSLog("[KeyboardHost] Audio session activated successfully")
        } catch let error as NSError {
            NSLog("[KeyboardHost] Audio session FAILED: domain=\(error.domain) code=\(error.code) \(error.localizedDescription)")
            fail(suite, "Audio session error (\(error.code)): \(error.localizedDescription)")
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
        Self.reloadControlWidget()

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

    private func suitePollTick(
        suite: UserDefaults,
        timer: Timer,
        completion: ((String?) -> Void)? = nil
    ) {
        let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? ""
        guard phase == KeyboardDictationBridge.phaseStopRequested else { return }

        timer.invalidate()
        pollTimer = nil
        processStopRequested(suite: suite, completion: completion)
    }

    private func processStopRequested(suite: UserDefaults, completion: ((String?) -> Void)?) {
        cancelAutoStop()

        guard recorder != nil else {
            resetPendingStartAfterStop(suite: suite)
            completion?(nil)
            return
        }

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
        Self.reloadControlWidget()

        if #available(iOS 16.2, *) {
            DictationLiveActivityManager.shared.updateToProcessing()
        }

        NotificationCenter.default.post(
            name: DictationNotification.stateChanged,
            object: nil,
            userInfo: ["phase": KeyboardDictationBridge.phaseProcessing]
        )

        let path = wavURL.path
        NSLog("[KeyboardHost] Stop requested; transcribing \(path)")

        KeyboardHostTranscription.shared.transcribeWav(atPath: path, suite: suite) { transcript in
            completion?(transcript)
        }
    }

    private func resetPendingStartAfterStop(suite: UserDefaults) {
        cancelActivationWait()
        pollTimer?.invalidate()
        pollTimer = nil
        cancelAutoStop()
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        suite.set(KeyboardDictationBridge.phaseIdle, forKey: KeyboardDictationBridge.phaseKey)
        suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
        suite.removeObject(forKey: KeyboardDictationBridge.errorKey)
        suite.synchronize()
        Self.reloadControlWidget()
        if #available(iOS 16.2, *) {
            DictationLiveActivityManager.shared.end()
        }
        NotificationCenter.default.post(
            name: DictationNotification.stateChanged,
            object: nil,
            userInfo: ["phase": KeyboardDictationBridge.phaseIdle]
        )
        NSLog("[KeyboardHost] Stop requested before recording; reset to idle")
    }
}
