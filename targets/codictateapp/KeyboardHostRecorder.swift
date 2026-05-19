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
    static let warmSessionActiveKey = "kbdWarmSessionActive"
    static let warmSessionHeartbeatKey = "kbdWarmSessionHeartbeat"
    /// True only while AVAudioEngine listen session is running (proven background mic path).
    static let listenSessionReadyKey = "kbdListenSessionReady"
    /// User-configurable warm window (seconds). Default 60. Read by host at runtime.
    static let warmSessionDurationKey = "kbdWarmSessionDurationSeconds"
    /// Shown in keyboard strip during processing when first-time Parakeet load is pending.
    static let processingMessageKey = "kbdProcessingMessage"
    static let parakeetModelReadyKey = "parakeetModelReady"

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
    /// Posted when keyboard warm session starts, ends, or is opened from Live Activity.
    static let keyboardWarmSessionChanged = Notification.Name("codictate.dictation.keyboardWarmSessionChanged")
    static let endKeyboardWarmSession = Notification.Name("codictate.dictation.endKeyboardWarmSession")
}

/// Selects between ParakeetEngine and WhisperEngine based on the user's
/// preferred variant stored in the App Group UserDefaults.
private final class TranscriptionRouter {
    static let shared = TranscriptionRouter()
    private let parakeet = ParakeetEngine()
    private let whisper = WhisperEngine()

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
                    suite.removeObject(forKey: KeyboardDictationBridge.processingMessageKey)
                    suite.synchronize()
                    KeyboardHostRecorder.reloadControlWidget()
                    KeyboardHostRecorder.shared.handleTranscriptReadyForSource(
                        source,
                        transcript: text,
                        suite: suite
                    )
                    if #available(iOS 16.2, *) {
                        if source == KeyboardDictationBridge.sourceIntent {
                            // Live Activity handled in handleTranscriptReadyForSource (standby vs end).
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
    private var dismissalObserverTask: Task<Void, Never>?

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

    func updateToProcessing(statusMessage: String? = nil) {
        guard let activity = trackedActivity() else { return }

        let state = DictationActivityAttributes.ContentState(
            phase: "processing",
            startDate: recordingStartDate ?? Date(),
            processingStartDate: Date(),
            statusMessage: statusMessage
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
        beginObservingDismissal(for: activity)
    }

    func end() {
        stopObservingDismissal()
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

    /// Ends keyboard warm session when the user dismisses the standby Live Activity.
    /// Only `.dismissed` is handled. `.ended` also fires on content updates and programmatic
    /// teardown; treating it as user dismiss was clearing warm flags after every dictation.
    private func beginObservingDismissal(for activity: Activity<DictationActivityAttributes>) {
        stopObservingDismissal()
        let activityID = activity.id
        dismissalObserverTask = Task { @MainActor in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                switch state {
                case .dismissed:
                    NSLog("[LiveActivity] Activity \(activityID) dismissed; ending keyboard warm session")
                    KeyboardHostRecorder.shared.endKeyboardWarmSession(userInitiated: true)
                    return
                case .ended:
                    NSLog("[LiveActivity] Activity \(activityID) ended (ignored for warm session)")
                default:
                    break
                }
            }
        }
    }

    private func stopObservingDismissal() {
        dismissalObserverTask?.cancel()
        dismissalObserverTask = nil
    }

    /// Called before programmatically ending the activity to avoid re-entrant warm-session teardown.
    func cancelDismissalObserver() {
        stopObservingDismissal()
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
    private var activeRecordingURL: URL?
    private var pollTimer: Timer?
    private var autoStopTimer: Timer?
    private var keyboardKeepaliveTimer: Timer?
    private var keyboardBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var warmSessionBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var darwinPickupBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var transcriptFallbackWorkItem: DispatchWorkItem?
    private var activationObserver: NSObjectProtocol?
    private var didInstallNotificationObservers = false

    /// Auto-stop fallback in case no entry point requests stop (covers stuck-in-background).
    private static let autoStopAfterSeconds: TimeInterval = 60
    /// Longer auto-stop for Action Button recordings (5 minutes).
    private static let intentAutoStopAfterSeconds: TimeInterval = 300
    private static let defaultWarmSessionSeconds: TimeInterval = 60
    private static let minWarmSessionSeconds: TimeInterval = 30
    private static let maxWarmSessionSeconds: TimeInterval = 1800
    private static let firstUseParakeetKeyboardMessage =
        "Transcribing — first use may take a minute..."
    private static let firstUseParakeetLiveActivityMessage =
        "First use may take a minute"
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

    /// `AVAudioSession.ErrorCode.cannotInterruptOthers` — background app cannot re-activate
    /// a session that would interrupt the foreground app; warm listen uses mixWithOthers instead.
    private static let cannotInterruptOthersCode = 560_557_684

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
        ensureDefaultWarmDurationConfigured()
        installNotificationObservers()
        ParakeetModelManager.shared.installObserver()
        recoverStaleState()
        resumeKeyboardListenSessionIfNeeded()
    }

    private func ensureDefaultWarmDurationConfigured() {
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
        if suite.object(forKey: KeyboardDictationBridge.warmSessionDurationKey) == nil {
            suite.set(Int(Self.defaultWarmSessionSeconds), forKey: KeyboardDictationBridge.warmSessionDurationKey)
            suite.synchronize()
        }
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
             KeyboardDictationBridge.phaseProcessing,
             KeyboardDictationBridge.phaseReady,
             KeyboardDictationBridge.phaseFailed:
            NSLog("[KeyboardHost] Stale phase '\(phase)' at bootstrap; resetting phase to idle (keeping warm session).")
            resetDictationPhaseToIdle(suite: suite, endLiveActivity: true)
        default:
            break
        }
    }

    private func resetDictationPhaseToIdle(suite: UserDefaults, endLiveActivity: Bool) {
        suite.set(KeyboardDictationBridge.phaseIdle, forKey: KeyboardDictationBridge.phaseKey)
        suite.removeObject(forKey: KeyboardDictationBridge.errorKey)
        suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
        suite.removeObject(forKey: KeyboardDictationBridge.transcriptTimestampKey)
        suite.synchronize()
        Self.reloadControlWidget()
        if endLiveActivity, #available(iOS 16.2, *) {
            DictationLiveActivityManager.shared.end()
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEndKeyboardWarmSessionNotification(_:)),
            name: DictationNotification.endKeyboardWarmSession,
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
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

    @objc private func handleEndKeyboardWarmSessionNotification(_ note: Notification) {
        endKeyboardWarmSession(userInitiated: true)
    }

    @objc private func handleAppDidEnterBackground() {
        resumeKeyboardListenSessionIfNeeded()
    }

    @objc private func handleAppWillResignActive() {
        resumeKeyboardListenSessionIfNeeded()
    }

    @objc private func handleAudioInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        if type == .ended {
            NSLog("[KeyboardHost] Audio interruption ended — restoring session")
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
                try session.setActive(true, options: [])
            } catch {
                NSLog("[KeyboardHost] Failed to restore session after interruption: \(error)")
            }
            resumeKeyboardListenSessionIfNeeded()
        }
    }

    @objc private func handleAppActivation() {
        resumeKeyboardListenSessionIfNeeded()
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
        resumeKeyboardListenSessionIfNeeded()
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
        suite.synchronize()
        let source = suite.string(forKey: KeyboardDictationBridge.sourceKey) ?? KeyboardDictationBridge.sourceHost
        let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? KeyboardDictationBridge.phaseIdle
        if source == KeyboardDictationBridge.sourceKeyboard,
           KeyboardListenSession.shared.isRunning,
           phase == KeyboardDictationBridge.phaseStart || phase == KeyboardDictationBridge.phaseStopRequested {
            NSLog("[KeyboardHost] Darwin start handled by listen-session poll")
            return
        }
        guard recorder == nil else { return }
        beginDarwinPickupBackgroundTask()
        attemptDarwinStartPickup(retryCount: 0)
    }

    private func beginDarwinPickupBackgroundTask() {
        guard darwinPickupBackgroundTask == .invalid else { return }
        darwinPickupBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "CodictateDarwinKeyboardStart"
        ) { [weak self] in
            self?.endDarwinPickupBackgroundTask()
        }
    }

    private func endDarwinPickupBackgroundTask() {
        guard darwinPickupBackgroundTask != .invalid else { return }
        let task = darwinPickupBackgroundTask
        darwinPickupBackgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
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
            endDarwinPickupBackgroundTask()
        } else if retryCount < 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.attemptDarwinStartPickup(retryCount: retryCount + 1)
            }
        } else {
            endDarwinPickupBackgroundTask()
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

    /// Live Activity tap (`codictateapp://keyboard-session` or legacy `dictation`).
    /// Native-only: does not route through Expo Linking.
    func handleKeyboardSessionDeepLink() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let active = self.isKeyboardWarmSessionActive()
            NSLog("[KeyboardHost] keyboard-session deep link; warmActive=\(active)")
            NotificationCenter.default.post(
                name: DictationNotification.keyboardWarmSessionChanged,
                object: nil,
                userInfo: ["active": active, "openedFromLiveActivity": true]
            )
        }
    }

    /// Ends keyboard warm session (Live Activity dismiss, Settings, or in-app control).
    func endKeyboardWarmSession(userInitiated: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stopWarmMicSession(endingActivity: true)
            NotificationCenter.default.post(
                name: DictationNotification.keyboardWarmSessionChanged,
                object: nil,
                userInfo: ["active": false, "userInitiated": userInitiated]
            )
            NSLog("[KeyboardHost] Keyboard warm session ended (userInitiated=\(userInitiated))")
        }
    }

    func isKeyboardWarmSessionActive() -> Bool {
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return false }
        suite.synchronize()
        return KeyboardListenSession.shared.isReady(suite: suite)
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
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
        suite.synchronize()
        let now = Date().timeIntervalSince1970
        let hadWarmSession = Self.isWarmSessionConfigured(suite: suite, now: now)
        stopWarmMicSession(endingActivity: false)
        if hadWarmSession {
            NotificationCenter.default.post(
                name: DictationNotification.keyboardWarmSessionChanged,
                object: nil,
                userInfo: ["active": false, "userInitiated": false]
            )
            NSLog("[KeyboardHost] Keyboard warm session ended for Action Button intent")
        }
        let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? ""
        guard phase == KeyboardDictationBridge.phaseStart else { return }

        guard let url = outputURL(suite: suite) else {
            fail(suite, "Could not create recording path (App Group missing?).")
            return
        }

        guard prepareRecordingSession(allowBackgroundWithoutActivate: false) else {
            fail(suite, "Audio session error. Open Codictate once, then try again.")
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
            activeRecordingURL = url
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
        if source == KeyboardDictationBridge.sourceKeyboard,
           isKeyboardListenSessionRunning() {
            // Keyboard wrote phase=start; listen-session poll picks it up within ~250ms.
            // Do not foreground the app and do not start a second recorder here.
            NSLog("[KeyboardHost] Keyboard start deferred to listen-session poll")
            return
        }
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
                let source = suite.string(forKey: KeyboardDictationBridge.sourceKey)
                    ?? KeyboardDictationBridge.sourceHost
                if source == KeyboardDictationBridge.sourceKeyboard,
                   KeyboardListenSession.shared.isCapturing || KeyboardListenSession.shared.isRunning {
                    NSLog("[KeyboardHost] Stop deferred to keyboard listen session")
                    return
                }
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
            self.activeRecordingURL = nil
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
        activeRecordingURL = nil
        suite.set(KeyboardDictationBridge.phaseFailed, forKey: KeyboardDictationBridge.phaseKey)
        suite.set(message, forKey: KeyboardDictationBridge.errorKey)
        suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
        suite.removeObject(forKey: KeyboardDictationBridge.transcriptTimestampKey)
        suite.removeObject(forKey: KeyboardDictationBridge.processingMessageKey)
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

    func failPublic(_ suite: UserDefaults, _ message: String) {
        fail(suite, message)
    }

    func notifyPhase(_ phase: String) {
        NotificationCenter.default.post(
            name: DictationNotification.stateChanged,
            object: nil,
            userInfo: ["phase": phase]
        )
    }

    /// Sets processing phase with optional first-time Parakeet copy for keyboard + Live Activity.
    func enterProcessingPhase(suite: UserDefaults) {
        let laMessage = Self.firstUseParakeetLiveActivityMessageIfNeeded(suite: suite)
        if laMessage != nil {
            suite.set(Self.firstUseParakeetKeyboardMessage, forKey: KeyboardDictationBridge.processingMessageKey)
        } else {
            suite.removeObject(forKey: KeyboardDictationBridge.processingMessageKey)
        }
        suite.set(KeyboardDictationBridge.phaseProcessing, forKey: KeyboardDictationBridge.phaseKey)
        suite.removeObject(forKey: KeyboardDictationBridge.transcriptKey)
        suite.synchronize()
        Self.reloadControlWidget()
        if #available(iOS 16.2, *) {
            DictationLiveActivityManager.shared.updateToProcessing(statusMessage: laMessage)
        }
        notifyPhase(KeyboardDictationBridge.phaseProcessing)
    }

    private static func firstUseParakeetLiveActivityMessageIfNeeded(suite: UserDefaults) -> String? {
        let preferred = suite.string(forKey: KeyboardDictationBridge.preferredVariantKey) ?? "parakeet"
        guard preferred == "parakeet" else { return nil }
        guard !suite.bool(forKey: KeyboardDictationBridge.parakeetModelReadyKey) else { return nil }
        return firstUseParakeetLiveActivityMessage
    }

    func scheduleKeyboardAutoStop() {
        startAutoStopFallback()
    }

    func cancelKeyboardAutoStop() {
        cancelAutoStop()
    }

    func transcribeWav(atPath path: String, suite: UserDefaults, onComplete: ((String?) -> Void)? = nil) {
        TranscriptionRouter.shared.transcribeWav(atPath: path, suite: suite) { transcript in
            onComplete?(transcript)
        }
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

    private func prepareRecordingSession(allowBackgroundWithoutActivate: Bool) -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
        } catch {
            NSLog("[KeyboardHost] setCategory failed: \(error.localizedDescription)")
            return false
        }

        if recorder?.isRecording == true {
            NSLog("[KeyboardHost] Skipping setActive; capture already running")
            return true
        }
        if KeyboardListenSession.shared.isRunning {
            NSLog("[KeyboardHost] Skipping setActive; listen session engine running")
            return true
        }

        do {
            try session.setActive(true, options: [])
            return true
        } catch let error as NSError {
            if error.code == Self.cannotInterruptOthersCode, allowBackgroundWithoutActivate {
                NSLog("[KeyboardHost] setActive cannotInterruptOthers; continuing for warm/background")
                return true
            }
            if UIApplication.shared.applicationState == .active {
                NSLog("[KeyboardHost] setActive failed (\(error)); retrying from foreground")
                do {
                    try session.setActive(false, options: [])
                    try session.setActive(true, options: [])
                    return true
                } catch {
                    NSLog("[KeyboardHost] setActive retry failed: \(error.localizedDescription)")
                    return false
                }
            }
            NSLog("[KeyboardHost] setActive failed in background: \(error.localizedDescription)")
            return allowBackgroundWithoutActivate
        }
    }

    private func isKeyboardListenSessionRunning() -> Bool {
        KeyboardListenSession.shared.isRunning
    }

    private func startKeyboardListenSession(suite: UserDefaults) {
        publishWarmSessionFlags(suite: suite)
        KeyboardListenSession.shared.start(suite: suite)
    }

    private func stopKeyboardListenSession() {
        KeyboardListenSession.shared.stop()
    }

    private static func configuredWarmSessionSeconds(suite: UserDefaults) -> TimeInterval {
        let stored = suite.integer(forKey: KeyboardDictationBridge.warmSessionDurationKey)
        let seconds = stored > 0 ? TimeInterval(stored) : defaultWarmSessionSeconds
        return min(max(seconds, minWarmSessionSeconds), maxWarmSessionSeconds)
    }

    private static func isWarmSessionConfigured(suite: UserDefaults, now: TimeInterval) -> Bool {
        let warmActive = suite.bool(forKey: KeyboardDictationBridge.warmSessionActiveKey)
        let warmExpiry = suite.double(forKey: KeyboardDictationBridge.warmSessionExpiryKey)
        return warmActive && warmExpiry > 0 && now < warmExpiry
    }

    /// Writes warm-session expiry flags. `listenSessionReady` is set only after the engine is running.
    private func publishWarmSessionFlags(suite: UserDefaults) {
        let duration = Self.configuredWarmSessionSeconds(suite: suite)
        let expiry = Date().addingTimeInterval(duration)
        suite.set(Date().timeIntervalSince1970, forKey: KeyboardDictationBridge.keepaliveStartKey)
        suite.set(duration, forKey: KeyboardDictationBridge.keepaliveDurationKey)
        suite.set(expiry.timeIntervalSince1970, forKey: KeyboardDictationBridge.warmSessionExpiryKey)
        suite.set(true, forKey: KeyboardDictationBridge.warmSessionActiveKey)
        suite.set(Date().timeIntervalSince1970, forKey: KeyboardDictationBridge.warmSessionHeartbeatKey)
        suite.synchronize()
        startWarmSessionBackgroundTask()
        NSLog("[KeyboardHost] Warm session flags published until \(expiry)")
    }

    private func beginWarmMicSession(suite: UserDefaults) {
        startKeyboardListenSession(suite: suite)
        if !KeyboardListenSession.shared.isRunning {
            NSLog("[KeyboardHost] Warm listen session failed to start after dictation stop")
        } else {
            NSLog("[KeyboardHost] Warm listen session active after dictation stop")
        }
    }

    /// Restarts the background listen engine when warm-window flags are still valid.
    private func resumeKeyboardListenSessionIfNeeded() {
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
        suite.synchronize()
        let now = Date().timeIntervalSince1970
        guard Self.isWarmSessionConfigured(suite: suite, now: now) else { return }
        guard !KeyboardListenSession.shared.isRunning else { return }
        NSLog("[KeyboardHost] Resuming keyboard listen session")
        publishWarmSessionFlags(suite: suite)
        KeyboardListenSession.shared.start(suite: suite)
    }

    private func startWarmSessionBackgroundTask() {
        guard warmSessionBackgroundTask == .invalid else { return }
        warmSessionBackgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "CodictateWarmListenSession"
        ) { [weak self] in
            self?.endWarmSessionBackgroundTask()
        }
        if warmSessionBackgroundTask == .invalid {
            NSLog("[KeyboardHost] Warm session background task could not start")
        }
    }

    private func endWarmSessionBackgroundTask() {
        guard warmSessionBackgroundTask != .invalid else { return }
        let task = warmSessionBackgroundTask
        warmSessionBackgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    private func stopWarmMicSession(endingActivity: Bool, deactivateAudio: Bool = true) {
        endWarmSessionBackgroundTask()
        endDarwinPickupBackgroundTask()

        if endingActivity, #available(iOS 16.2, *) {
            DictationLiveActivityManager.shared.cancelDismissalObserver()
        }

        stopKeyboardListenSession()
        NSLog("[KeyboardHost] Keyboard listen session stopped")

        let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName)
        suite?.removeObject(forKey: KeyboardDictationBridge.keepaliveStartKey)
        suite?.removeObject(forKey: KeyboardDictationBridge.keepaliveDurationKey)
        suite?.synchronize()

        if deactivateAudio, recorder == nil, !KeyboardListenSession.shared.isRunning {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if endingActivity, #available(iOS 16.2, *) {
            DictationLiveActivityManager.shared.end()
        }
    }

    private func endKeyboardKeepalive() {
        keyboardKeepaliveTimer?.invalidate()
        keyboardKeepaliveTimer = nil
        let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName)
        suite?.removeObject(forKey: KeyboardDictationBridge.keepaliveStartKey)
        suite?.removeObject(forKey: KeyboardDictationBridge.keepaliveDurationKey)
        // Do not clear warm session flags here — they belong to the warm mic session, not the BG task.
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
            if #available(iOS 16.2, *) {
                DictationLiveActivityManager.shared.updateToStandby()
            }
            NotificationCenter.default.post(
                name: DictationNotification.keyboardWarmSessionChanged,
                object: nil,
                userInfo: ["active": KeyboardListenSession.shared.isReady(suite: suite)]
            )
            return
        }

        guard source == KeyboardDictationBridge.sourceIntent else {
            return
        }

        if #available(iOS 16.2, *) {
            DictationLiveActivityManager.shared.end()
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
            let source = suite.string(forKey: KeyboardDictationBridge.sourceKey)
                ?? KeyboardDictationBridge.sourceHost
            let warmListenActive = source == KeyboardDictationBridge.sourceKeyboard
                && Self.isWarmSessionConfigured(
                    suite: suite,
                    now: Date().timeIntervalSince1970
                )
            if isKeyboardListenSessionRunning() || warmListenActive {
                NSLog(
                    "[KeyboardHost] Background keyboard start (listenEngine=\(isKeyboardListenSessionRunning()), warmFlags=\(warmListenActive))"
                )
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
        let source = suite.string(forKey: KeyboardDictationBridge.sourceKey)
            ?? KeyboardDictationBridge.sourceHost
        let isKeyboard = source == KeyboardDictationBridge.sourceKeyboard
        let warmListen = isKeyboard
            && Self.isWarmSessionConfigured(suite: suite, now: Date().timeIntervalSince1970)

        if source == KeyboardDictationBridge.sourceIntent {
            stopWarmMicSession(endingActivity: false)
        } else if !isKeyboard {
            stopWarmMicSession(endingActivity: false)
        }

        guard let url = outputURL(suite: suite) else {
            fail(suite, "Could not create recording path (App Group missing?).")
            return
        }

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

        guard prepareRecordingSession(allowBackgroundWithoutActivate: warmListen) else {
            NSLog("[KeyboardHost] Audio session prepare failed (warmListen=\(warmListen))")
            fail(suite, "Audio session error. Open Codictate once, then try again.")
            return
        }
        NSLog("[KeyboardHost] Audio session ready")

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
            activeRecordingURL = url
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
        activeRecordingURL = nil

        let source = suite.string(forKey: KeyboardDictationBridge.sourceKey)
            ?? KeyboardDictationBridge.sourceHost
        NSLog("[KeyboardHost] Recording stopped, source=\(source)")

        if source == KeyboardDictationBridge.sourceKeyboard {
            // Start listen session while the audio session is still hot from this recording.
            beginWarmMicSession(suite: suite)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.resumeKeyboardListenSessionIfNeeded()
            }
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        enterProcessingPhase(suite: suite)

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
        endKeyboardKeepalive()
        recorder?.stop()
        recorder = nil
        activeRecordingURL = nil

        let warmStillValid = Self.isWarmSessionConfigured(
            suite: suite,
            now: Date().timeIntervalSince1970
        )
        if warmStillValid || KeyboardListenSession.shared.isRunning {
            NSLog("[KeyboardHost] Stop before record; keeping warm listen session alive")
            resumeKeyboardListenSessionIfNeeded()
        } else {
            stopWarmMicSession(endingActivity: true, deactivateAudio: true)
        }

        resetDictationPhaseToIdle(suite: suite, endLiveActivity: !warmStillValid)
        NotificationCenter.default.post(
            name: DictationNotification.stateChanged,
            object: nil,
            userInfo: ["phase": KeyboardDictationBridge.phaseIdle]
        )
        NSLog("[KeyboardHost] Stop requested before recording; reset to idle")
    }
}
