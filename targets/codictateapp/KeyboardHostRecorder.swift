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
    static let preferredVariantKey = "preferredModelVariant"
    static let phaseKey = "kbdDictationPhase"
    static let wavFileKey = "kbdDictationWavFile"
    static let errorKey = "kbdDictationHostError"
    static let transcriptKey = "kbdTranscript"
    static let transcriptTimestampKey = "kbdTranscriptTimestamp"
    static let sourceKey = "kbdDictationSource"
    static let keyboardVisibleKey = "kbdKeyboardVisible"
    static let keepaliveStartKey = "kbdKeepaliveStart"
    static let keepaliveDurationKey = "kbdKeepaliveDuration"
    static let warmSessionExpiryKey = "kbdWarmSessionExpiry"

    static let phaseIdle = "idle"
    static let phaseStart = "start"
    static let phaseRecording = "recording"
    static let phaseStopRequested = "stop_requested"
    static let phaseProcessing = "processing"
    static let phaseReady = "ready"
    static let phaseFailed = "failed"
    static let liveActivityPhaseStandby = "standby"

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

/// Selects between ParakeetEngine and WhisperEngine based on the user's
/// preferred variant stored in the App Group UserDefaults.
private final class TranscriptionRouter {
    static let shared = TranscriptionRouter()
    private let parakeet = ParakeetEngine()
    private let whisper = WhisperEngine()

    func preloadEngine(suite: UserDefaults) {
        let preferred = suite.string(forKey: KeyboardDictationBridge.preferredVariantKey) ?? "parakeet"
        let engine: TranscriptionEngine = preferred == "base" ? whisper : parakeet
        Task {
            do {
                try await engine.warmUp()
                NSLog("[TranscriptionRouter] Engine pre-loaded")
            } catch {
                NSLog("[TranscriptionRouter] Engine pre-load failed: \(error.localizedDescription)")
            }
        }
    }

    func transcribeWav(atPath wavPath: String, suite: UserDefaults, onComplete: @escaping (String?) -> Void) {
        let source = suite.string(forKey: KeyboardDictationBridge.sourceKey)
            ?? KeyboardDictationBridge.sourceHost
        let preferred = suite.string(forKey: KeyboardDictationBridge.preferredVariantKey) ?? "parakeet"
        let engine: TranscriptionEngine = preferred == "base" ? whisper : parakeet

        Task {
            do {
                let text = try await engine.transcribe(wavPath: wavPath)
                await MainActor.run {
                    guard !text.isEmpty else {
                        KeyboardHostRecorder.shared.fail(suite, "No speech detected.")
                        onComplete(nil)
                        return
                    }
                    suite.set(text, forKey: KeyboardDictationBridge.transcriptKey)
                    suite.set(Date().timeIntervalSince1970, forKey: KeyboardDictationBridge.transcriptTimestampKey)
                    suite.set(KeyboardDictationBridge.phaseReady, forKey: KeyboardDictationBridge.phaseKey)
                    suite.removeObject(forKey: KeyboardDictationBridge.errorKey)
                    suite.synchronize()
                    KeyboardHostRecorder.reloadControlWidget()
                    KeyboardHostRecorder.shared.handleTranscriptReadyForSource(
                        source,
                        transcript: text,
                        suite: suite
                    )
                    if #available(iOS 16.2, *) {
                        if source == KeyboardDictationBridge.sourceIntent {
                            DictationLiveActivityManager.shared.end()
                        } else if source != KeyboardDictationBridge.sourceKeyboard {
                            DictationLiveActivityManager.shared.updateToReady()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                DictationLiveActivityManager.shared.end()
                            }
                        }
                    }
                    NotificationCenter.default.post(
                        name: DictationNotification.transcriptReady,
                        object: nil,
                        userInfo: ["transcript": text, "source": source]
                    )
                    NotificationCenter.default.post(
                        name: DictationNotification.stateChanged,
                        object: nil,
                        userInfo: ["phase": KeyboardDictationBridge.phaseReady]
                    )
                    NSLog("[KeyboardHost] Transcription ready, length=\(text.count)")
                    onComplete(text)
                }
            } catch {
                await MainActor.run {
                    KeyboardHostRecorder.shared.fail(
                        suite,
                        "Transcription failed: \(error.localizedDescription)"
                    )
                    onComplete(nil)
                }
            }
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
        // End any lingering activities from previous sessions before starting
        // a fresh one. Ended activities can persist in the Dynamic Island for
        // minutes with .default dismissal, showing stale "processing" state.
        endAllStale()

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
            startDate: recordingStartDate ?? Date(),
            processingStartDate: Date()
        )
        currentActivityID = activity.id
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
            NSLog("[LiveActivity] Updated to processing")
        }
    }

    func updateToReady() {
        guard let activity = trackedActivity() else { return }

        let state = DictationActivityAttributes.ContentState(
            phase: "ready",
            startDate: recordingStartDate ?? Date()
        )
        currentActivityID = activity.id
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
            NSLog("[LiveActivity] Updated to ready")
        }
    }

    func updateToStandby() {
        guard let activity = trackedActivity() else { return }

        let state = DictationActivityAttributes.ContentState(
            phase: KeyboardDictationBridge.liveActivityPhaseStandby,
            startDate: recordingStartDate ?? Date()
        )
        currentActivityID = activity.id
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
            NSLog("[LiveActivity] Updated to standby")
        }
    }

    func end() {
        let activitiesToEnd: [Activity<DictationActivityAttributes>]
        if let activity = trackedActivity() {
            activitiesToEnd = [activity]
        } else {
            activitiesToEnd = Activity<DictationActivityAttributes>.activities
        }

        let finalState = DictationActivityAttributes.ContentState(
            phase: "ready",
            startDate: recordingStartDate ?? Date()
        )
        for activity in activitiesToEnd {
            Task {
                await activity.end(
                    ActivityContent(state: finalState, staleDate: nil),
                    dismissalPolicy: .immediate
                )
                NSLog("[LiveActivity] Ended id=\(activity.id)")
            }
        }
        currentActivityID = nil
        recordingStartDate = nil
    }

    private func trackedActivity() -> Activity<DictationActivityAttributes>? {
        let active = Activity<DictationActivityAttributes>.activities.filter {
            $0.activityState == .active
        }
        if let id = currentActivityID,
           let activity = active.first(where: { $0.id == id }) {
            return activity
        }
        return active.first
    }

    private func endAllStale() {
        let stale = Activity<DictationActivityAttributes>.activities.filter {
            $0.activityState != .active
        }
        guard !stale.isEmpty else { return }
        let dismissState = DictationActivityAttributes.ContentState(
            phase: "ready", startDate: Date()
        )
        for activity in stale {
            Task {
                await activity.end(
                    ActivityContent(state: dismissState, staleDate: nil),
                    dismissalPolicy: .immediate
                )
            }
        }
        NSLog("[LiveActivity] Dismissed \(stale.count) stale activit(ies)")
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

// MARK: - Darwin IPC (keyboard extension to host app)

private let kbdDarwinStartName    = "app.codictate.dictation.keyboard.start"
private let kbdDarwinStopName     = "app.codictate.dictation.keyboard.stop"
private let intentDarwinStartName = "app.codictate.dictation.intent.start"
private let intentDarwinStopName  = "app.codictate.dictation.intent.stop"

// C-compatible callback. Relays Darwin notification name to NSNotificationCenter on the main thread.
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
/// entry point initiated the session: keyboard URL, JS module, or App Intent. JS thread
/// suspension does not stop recording because all control flow lives in Swift.
/// `UIBackgroundModes` must include `audio` for background recording to survive.
final class KeyboardHostRecorder: NSObject {

    static let shared = KeyboardHostRecorder()

    private var recorder: AVAudioRecorder?
    private var warmMicRecorder: AVAudioRecorder?
    private var pollTimer: Timer?
    private var autoStopTimer: Timer?
    private var keyboardKeepaliveTimer: Timer?
    private var warmMicTimer: Timer?
    private var warmMicPollTimer: Timer?
    private var keyboardBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var transcriptFallbackWorkItem: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?
    private var didInstallNotificationObservers = false

    /// Auto-stop fallback in case no entry point requests stop (covers stuck-in-background).
    private static let autoStopAfterSeconds: TimeInterval = 60
    /// Longer auto-stop for Action Button recordings (5 minutes).
    private static let intentAutoStopAfterSeconds: TimeInterval = 300
    /// Keeps a real microphone session alive so follow-up keyboard starts can avoid app switching.
    private static let warmMicSessionSeconds: TimeInterval = 60
    /// Short background task fallback in case the warm microphone session cannot start.
    private static let keyboardKeepaliveSeconds: TimeInterval = 15
    /// Gives the visible keyboard first chance to insert Action Button output before clipboard fallback.
    private static let transcriptFallbackSeconds: TimeInterval = 2

    private static let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16_000,
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
        stopWarmMicSession(endingActivity: true)
        endKeyboardKeepalive()
    }

    // MARK: - Bootstrap

    /// Wires NotificationCenter observers so other Swift modules (the JS bridge module,
    /// App Intent, etc.) can drive recording without a direct symbol dependency on this class.
    /// Idempotent. Call from `application(_:didFinishLaunchingWithOptions:)`.
    /// Called from `application(_:didFinishLaunchingWithOptions:)`, already on the main thread.
    /// Installs observers synchronously so they are ready before `applicationDidBecomeActive` fires.
    func bootstrap() {
        NSLog("[KeyboardHost] bootstrap() - installing observers")
        installNotificationObservers()
        ParakeetModelManager.shared.installObserver()
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
            let source = suite.string(forKey: KeyboardDictationBridge.sourceKey)
                ?? KeyboardDictationBridge.sourceHost
            if source == KeyboardDictationBridge.sourceIntent {
                NSLog("[KeyboardHost] Skipping stale-start recovery for intent source")
                break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.recorder == nil else { return }
                guard let s = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
                s.synchronize()
                let current = s.string(forKey: KeyboardDictationBridge.phaseKey)
                    ?? KeyboardDictationBridge.phaseIdle
                if current == KeyboardDictationBridge.phaseStart {
                    let src = s.string(forKey: KeyboardDictationBridge.sourceKey)
                        ?? KeyboardDictationBridge.sourceHost
                    NSLog("[KeyboardHost] Recovering stale 'start' phase; attempting recording (source=\(src))")
                    self.startSessionInternal(suite: s, source: src)
                }
            }
        case KeyboardDictationBridge.phaseRecording,
             KeyboardDictationBridge.phaseStopRequested,
             KeyboardDictationBridge.phaseProcessing:
            NSLog("[KeyboardHost] Stale phase '\(phase)' at bootstrap; resetting to idle.")
            suite.set(KeyboardDictationBridge.phaseIdle, forKey: KeyboardDictationBridge.phaseKey)
            suite.removeObject(forKey: KeyboardDictationBridge.errorKey)
            suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
            suite.removeObject(forKey: KeyboardDictationBridge.transcriptTimestampKey)
            suite.removeObject(forKey: KeyboardDictationBridge.warmSessionExpiryKey)
            suite.synchronize()
            Self.reloadControlWidget()
            if #available(iOS 16.2, *) {
                DictationLiveActivityManager.shared.end()
            }
        case KeyboardDictationBridge.phaseReady,
             KeyboardDictationBridge.phaseFailed:
            NSLog("[KeyboardHost] Stale phase '\(phase)' at bootstrap; resetting to idle.")
            suite.set(KeyboardDictationBridge.phaseIdle, forKey: KeyboardDictationBridge.phaseKey)
            suite.removeObject(forKey: KeyboardDictationBridge.errorKey)
            suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
            suite.removeObject(forKey: KeyboardDictationBridge.transcriptTimestampKey)
            suite.removeObject(forKey: KeyboardDictationBridge.warmSessionExpiryKey)
            suite.synchronize()
            Self.reloadControlWidget()
            if #available(iOS 16.2, *) {
                DictationLiveActivityManager.shared.end()
            }
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )

        // Darwin (cross-process) listeners for keyboard extension.
        // Handles the case where Codictate is already in the foreground when the keyboard
        // Dictate button is tapped. didBecomeActiveNotification never fires then.
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

    @objc private func handleAudioInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        if type == .ended, recorder != nil || warmMicRecorder != nil {
            NSLog("[KeyboardHost] Audio interruption ended while recording — restoring session")
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
                try session.setActive(true, options: [])
            } catch {
                NSLog("[KeyboardHost] Failed to restore session after interruption: \(error)")
            }
        }
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
        // Intent-initiated starts are handled by beginRecordingIfPending called
        // directly from DictationToggleIntent.perform(). Allowing this handler to
        // race that call can cause a double-start or, if one path fails first, it
        // changes the phase and prevents the other from recovering.
        guard source != KeyboardDictationBridge.sourceIntent else { return }
        startSessionInternal(suite: suite, source: source)
    }

    // Received when the keyboard extension posts a Darwin start notification.
    // Fires even when Codictate is already in the foreground (unlike didBecomeActiveNotification).
    @objc private func handleDarwinStart() {
        NSLog("[KeyboardHost] handleDarwinStart fired, recorder=\(recorder != nil)")
        transcriptFallbackWorkItem?.cancel()
        transcriptFallbackWorkItem = nil
        guard recorder == nil else { return }
        attemptDarwinStartPickup(retryCount: 0)
    }

    private func attemptDarwinStartPickup(retryCount: Int) {
        guard recorder == nil else { return }
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
        CFPreferencesAppSynchronize(KeyboardDictationBridge.suiteName as CFString)
        suite.synchronize()
        let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? KeyboardDictationBridge.phaseIdle
        NSLog("[KeyboardHost] attemptDarwinStartPickup phase=\(phase) retry=\(retryCount)")
        if phase == KeyboardDictationBridge.phaseStart {
            let source = suite.string(forKey: KeyboardDictationBridge.sourceKey) ?? KeyboardDictationBridge.sourceHost
            startSessionInternal(suite: suite, source: source)
        } else if retryCount < 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.attemptDarwinStartPickup(retryCount: retryCount + 1)
            }
        }
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
            self.transcriptFallbackWorkItem?.cancel()
            self.transcriptFallbackWorkItem = nil

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
        transcriptFallbackWorkItem?.cancel()
        transcriptFallbackWorkItem = nil

        let filename = "intent-\(UUID().uuidString).wav"
        suite.set(KeyboardDictationBridge.phaseStart, forKey: KeyboardDictationBridge.phaseKey)
        suite.set(filename, forKey: KeyboardDictationBridge.wavFileKey)
        suite.set(KeyboardDictationBridge.sourceIntent, forKey: KeyboardDictationBridge.sourceKey)
        suite.removeObject(forKey: KeyboardDictationBridge.errorKey)
        suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
        suite.synchronize()

        beginRecording(suite: suite)
    }

    /// Dedicated recording start for Action Button intent. Assumes Live Activity
    /// was already started by DictationToggleIntent.perform(). Skips permission
    /// checks, app-state gates, and Live Activity creation to avoid race conditions.
    func startRecordingForIntent() {
        guard recorder == nil else { return }
        stopWarmMicSession(endingActivity: false)
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
        let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? ""
        guard phase == KeyboardDictationBridge.phaseStart else { return }

        guard let url = outputURL(suite: suite) else {
            fail(suite, "Could not create recording path (App Group missing?).")
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
            do {
                try session.setActive(true, options: [])
            } catch {
                NSLog("[KeyboardHost] Intent setActive failed (\(error)), resetting and retrying")
                try? session.setActive(false, options: [])
                try session.setActive(true, options: [])
            }
        } catch let error as NSError {
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
                fail(suite, "Could not start microphone recording.")
                return
            }
            guard rec.isRecording else {
                fail(suite, "Microphone did not enter recording state.")
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

        cancelAutoStop()
        autoStopTimer = Timer.scheduledTimer(
            withTimeInterval: Self.intentAutoStopAfterSeconds,
            repeats: false
        ) { [weak self] _ in
            NSLog("[KeyboardHost] Intent auto-stop fired after \(Self.intentAutoStopAfterSeconds)s")
            self?.requestStop()
        }

        startPollingForStop(suite: suite)
        TranscriptionRouter.shared.preloadEngine(suite: suite)

        NSLog("[KeyboardHost] Intent recording started")
    }

    /// Reads App Group state and begins recording if phase is "start".
    /// Called by the intent after it has already written state to the App Group.
    func beginRecordingIfPending() {
        guard recorder == nil else { return }
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
        transcriptFallbackWorkItem?.cancel()
        transcriptFallbackWorkItem = nil
        // No synchronize() needed when called from the in-process intent path;
        // the in-memory UserDefaults cache already has the values.
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
                fail(suite, "Microphone access denied. Enable Codictate in Settings > Privacy > Microphone.")
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
                fail(suite, "Microphone access denied. Enable Codictate in Settings > Privacy > Microphone.")
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
            self.transcriptFallbackWorkItem?.cancel()
            self.transcriptFallbackWorkItem = nil
            self.pollTimer?.invalidate()
            self.pollTimer = nil
            self.cancelAutoStop()
            self.stopWarmMicSession(endingActivity: true)
            self.endKeyboardKeepalive()
            self.recorder?.stop()
            self.recorder = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            suite.set(KeyboardDictationBridge.phaseIdle, forKey: KeyboardDictationBridge.phaseKey)
            suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
            suite.removeObject(forKey: KeyboardDictationBridge.transcriptTimestampKey)
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

    /// Lookup-only. Used by the JS bridge to seed initial state without polling.
    func currentPhase() -> String {
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else {
            return KeyboardDictationBridge.phaseIdle
        }
        return suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? KeyboardDictationBridge.phaseIdle
    }

    func hasActiveRecording() -> Bool {
        recorder?.isRecording == true
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
        transcriptFallbackWorkItem?.cancel()
        transcriptFallbackWorkItem = nil
        pollTimer?.invalidate()
        pollTimer = nil
        cancelAutoStop()
        stopWarmMicSession(endingActivity: true)
        endKeyboardKeepalive()
        recorder?.stop()
        recorder = nil
        suite.set(KeyboardDictationBridge.phaseFailed, forKey: KeyboardDictationBridge.phaseKey)
        suite.set(message, forKey: KeyboardDictationBridge.errorKey)
        suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
        suite.removeObject(forKey: KeyboardDictationBridge.transcriptTimestampKey)
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

    private func beginKeyboardKeepaliveIfNeeded(source: String) {
        guard source == KeyboardDictationBridge.sourceKeyboard else { return }
        keyboardKeepaliveTimer?.invalidate()
        keyboardKeepaliveTimer = nil

        guard keyboardBackgroundTask == .invalid else { return }
        keyboardBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "CodictateKeyboardDictation"
        ) { [weak self] in
            DispatchQueue.main.async {
                self?.handleKeyboardKeepaliveExpired()
            }
        }
        if keyboardBackgroundTask == .invalid {
            NSLog("[KeyboardHost] Keyboard keepalive could not start")
        } else {
            NSLog("[KeyboardHost] Keyboard keepalive started")
        }
    }

    private func scheduleKeyboardKeepaliveEnd() {
        guard keyboardBackgroundTask != .invalid else { return }
        let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName)
        let configured = suite?.double(forKey: KeyboardDictationBridge.keepaliveDurationKey) ?? 0
        let duration = configured > 0 ? configured : Self.keyboardKeepaliveSeconds
        suite?.set(Date().timeIntervalSince1970, forKey: KeyboardDictationBridge.keepaliveStartKey)
        suite?.set(duration, forKey: KeyboardDictationBridge.keepaliveDurationKey)
        suite?.synchronize()
        keyboardKeepaliveTimer?.invalidate()
        keyboardKeepaliveTimer = Timer.scheduledTimer(
            withTimeInterval: duration,
            repeats: false
        ) { [weak self] _ in
            self?.endKeyboardKeepalive()
        }
        RunLoop.main.add(keyboardKeepaliveTimer!, forMode: .common)
    }

    private func warmMicURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("codictate_warm_mic.wav")
    }

    private func startWarmMicRecorder() {
        guard warmMicRecorder == nil else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
            do {
                try session.setActive(true, options: [])
            } catch {
                NSLog("[KeyboardHost] Warm mic setActive failed (\(error)), resetting and retrying")
                try? session.setActive(false, options: [])
                try session.setActive(true, options: [])
            }

            let rec = try AVAudioRecorder(url: warmMicURL(), settings: Self.recordingSettings)
            guard rec.prepareToRecord(), rec.record(), rec.isRecording else {
                NSLog("[KeyboardHost] Warm mic recorder failed to start")
                return
            }
            warmMicRecorder = rec
            NSLog("[KeyboardHost] Warm mic recorder started")
        } catch {
            NSLog("[KeyboardHost] Warm mic recorder error: \(error.localizedDescription)")
        }
    }

    private func beginWarmMicSession(suite: UserDefaults) {
        startWarmMicRecorder()
        guard warmMicRecorder?.isRecording == true else {
            scheduleKeyboardKeepaliveEnd()
            return
        }

        let expiry = Date().addingTimeInterval(Self.warmMicSessionSeconds)
        suite.set(Date().timeIntervalSince1970, forKey: KeyboardDictationBridge.keepaliveStartKey)
        suite.set(Self.warmMicSessionSeconds, forKey: KeyboardDictationBridge.keepaliveDurationKey)
        suite.set(expiry.timeIntervalSince1970, forKey: KeyboardDictationBridge.warmSessionExpiryKey)
        suite.synchronize()

        warmMicTimer?.invalidate()
        warmMicTimer = Timer.scheduledTimer(
            withTimeInterval: Self.warmMicSessionSeconds,
            repeats: false
        ) { [weak self] _ in
            self?.stopWarmMicSession(endingActivity: true)
        }
        RunLoop.main.add(warmMicTimer!, forMode: .common)

        warmMicPollTimer?.invalidate()
        warmMicPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkForPendingWarmKeyboardStart()
        }
        RunLoop.main.add(warmMicPollTimer!, forMode: .common)

        if #available(iOS 16.2, *) {
            DictationLiveActivityManager.shared.updateToStandby()
        }
        NSLog("[KeyboardHost] Warm mic session active until \(expiry)")
    }

    private func stopWarmMicSession(endingActivity: Bool) {
        warmMicTimer?.invalidate()
        warmMicTimer = nil
        warmMicPollTimer?.invalidate()
        warmMicPollTimer = nil

        if let rec = warmMicRecorder {
            rec.stop()
            warmMicRecorder = nil
            try? FileManager.default.removeItem(at: warmMicURL())
            NSLog("[KeyboardHost] Warm mic recorder stopped")
        }

        let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName)
        suite?.removeObject(forKey: KeyboardDictationBridge.warmSessionExpiryKey)
        suite?.removeObject(forKey: KeyboardDictationBridge.keepaliveStartKey)
        suite?.removeObject(forKey: KeyboardDictationBridge.keepaliveDurationKey)
        suite?.synchronize()

        if recorder == nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if endingActivity, #available(iOS 16.2, *) {
            DictationLiveActivityManager.shared.end()
        }
    }

    private func checkForPendingWarmKeyboardStart() {
        guard recorder == nil else { return }
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
        CFPreferencesAppSynchronize(KeyboardDictationBridge.suiteName as CFString)
        suite.synchronize()
        let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey)
            ?? KeyboardDictationBridge.phaseIdle
        let source = suite.string(forKey: KeyboardDictationBridge.sourceKey)
            ?? KeyboardDictationBridge.sourceHost
        guard phase == KeyboardDictationBridge.phaseStart,
              source == KeyboardDictationBridge.sourceKeyboard else { return }
        NSLog("[KeyboardHost] Warm mic poll detected pending keyboard start")
        startSessionInternal(suite: suite, source: source)
    }

    private func endKeyboardKeepalive() {
        keyboardKeepaliveTimer?.invalidate()
        keyboardKeepaliveTimer = nil
        let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName)
        suite?.removeObject(forKey: KeyboardDictationBridge.keepaliveStartKey)
        suite?.removeObject(forKey: KeyboardDictationBridge.keepaliveDurationKey)
        suite?.synchronize()
        guard keyboardBackgroundTask != .invalid else { return }
        let task = keyboardBackgroundTask
        keyboardBackgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
        NSLog("[KeyboardHost] Keyboard keepalive ended")
    }

    private func handleKeyboardKeepaliveExpired() {
        keyboardKeepaliveTimer?.invalidate()
        keyboardKeepaliveTimer = nil
        if recorder != nil {
            requestStop()
        }
        endKeyboardKeepalive()
    }

    fileprivate func handleTranscriptReadyForSource(
        _ source: String,
        transcript: String,
        suite: UserDefaults
    ) {
        transcriptFallbackWorkItem?.cancel()

        if source == KeyboardDictationBridge.sourceKeyboard {
            beginWarmMicSession(suite: suite)
            return
        }

        guard source == KeyboardDictationBridge.sourceIntent else {
            return
        }

        let fallback = DispatchWorkItem { [weak self, weak suite] in
            guard let self, let suite else { return }
            suite.synchronize()
            let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey)
                ?? KeyboardDictationBridge.phaseIdle
            let pendingText = suite.string(forKey: KeyboardDictationBridge.transcriptKey)
            guard phase == KeyboardDictationBridge.phaseReady,
                  pendingText == transcript else { return }
            self.copyTranscriptToClipboard(transcript)
            suite.set(KeyboardDictationBridge.phaseIdle, forKey: KeyboardDictationBridge.phaseKey)
            suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
            suite.removeObject(forKey: KeyboardDictationBridge.transcriptTimestampKey)
            suite.synchronize()
            Self.reloadControlWidget()
            NotificationCenter.default.post(
                name: DictationNotification.stateChanged,
                object: nil,
                userInfo: ["phase": KeyboardDictationBridge.phaseIdle]
            )
        }

        transcriptFallbackWorkItem = fallback
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.transcriptFallbackSeconds,
            execute: fallback
        )
    }

    private func copyTranscriptToClipboard(_ text: String) {
        if Thread.isMainThread {
            UIPasteboard.general.string = text
        } else {
            DispatchQueue.main.async {
                UIPasteboard.general.string = text
            }
        }
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
        case .background, .inactive:
            if warmMicRecorder?.isRecording == true {
                NSLog("[KeyboardHost] Warm mic active — starting keyboard recording in background")
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
        @unknown default:
            attemptStart()
        }
    }

    private func handleDeepLinkOnMain() {
        transcriptFallbackWorkItem?.cancel()
        transcriptFallbackWorkItem = nil
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
        stopWarmMicSession(endingActivity: false)

        guard let url = outputURL(suite: suite) else {
            fail(suite, "Could not create recording path (App Group missing?).")
            return
        }

        let source = suite.string(forKey: KeyboardDictationBridge.sourceKey)
            ?? KeyboardDictationBridge.sourceHost
        let isIntentStart = source == KeyboardDictationBridge.sourceIntent

        beginKeyboardKeepaliveIfNeeded(source: source)

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
            do {
                try session.setActive(true, options: [])
            } catch {
                NSLog("[KeyboardHost] setActive failed (\(error)), resetting and retrying")
                try? session.setActive(false, options: [])
                try session.setActive(true, options: [])
            }
            NSLog("[KeyboardHost] Audio session ready")
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

        let source = suite.string(forKey: KeyboardDictationBridge.sourceKey)
            ?? KeyboardDictationBridge.sourceHost
        NSLog("[KeyboardHost] Recording stopped, source=\(source)")

        if source == KeyboardDictationBridge.sourceKeyboard {
            startWarmMicRecorder()
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

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

        TranscriptionRouter.shared.transcribeWav(atPath: path, suite: suite) { transcript in
            completion?(transcript)
        }
    }

    private func resetPendingStartAfterStop(suite: UserDefaults) {
        cancelActivationWait()
        transcriptFallbackWorkItem?.cancel()
        transcriptFallbackWorkItem = nil
        pollTimer?.invalidate()
        pollTimer = nil
        cancelAutoStop()
        stopWarmMicSession(endingActivity: true)
        endKeyboardKeepalive()
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        suite.set(KeyboardDictationBridge.phaseIdle, forKey: KeyboardDictationBridge.phaseKey)
        suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
        suite.removeObject(forKey: KeyboardDictationBridge.transcriptTimestampKey)
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
