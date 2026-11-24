import UIKit
import Foundation

enum KbdSuite {
    static let suiteName        = "group.app.codictate"
    static let phaseKey         = "kbdDictationPhase"
    static let wavFileKey       = "kbdDictationWavFile"
    static let errorKey         = "kbdDictationHostError"
    static let transcriptKey    = "kbdTranscript"
    static let transcriptTimestampKey = "kbdTranscriptTimestamp"
    static let sourceKey        = "kbdDictationSource"
    static let keyboardVisibleKey = "kbdKeyboardVisible"
    static let warmSessionExpiryKey = "kbdWarmSessionExpiry"
    static let warmSessionActiveKey = "kbdWarmSessionActive"
    static let processingMessageKey = "kbdProcessingMessage"
    /// Read for the In-keyboard path's eligibility; the Host and JS write them.
    static let preferredVariantKey = "preferredModelVariant"
    static let transcriptionLanguageKey = "transcriptionLanguageId"
    static let parakeetModelReadyKey = "parakeetModelReady"
    static let hostMicrophoneGrantedKey = "hostMicrophoneGranted"
    static let sourceKeyboard   = "keyboard"
    static let sourceIntent     = "intent"

    static let phaseIdle        = "idle"
    static let phaseStart       = "start"
    static let phaseRecording   = "recording"
    static let phaseStopRequested = "stop_requested"
    static let phaseProcessing  = "processing"
    static let phaseReady       = "ready"
    static let phaseFailed      = "failed"
}

private let kbdDarwinStartName = "app.codictate.dictation.keyboard.start"
private let intentDarwinStopName = "app.codictate.dictation.intent.stop"

final class KeyboardViewController: UIInputViewController, DictationKeyboardViewDelegate {

    private lazy var keyboardView = DictationKeyboardView()
    /// The In-keyboard path. Its turns write nothing to the App Group.
    private let inKeyboard = InKeyboardDictation()
    /// An In-keyboard result or error is on screen: clearing it must not reset the shared
    /// phase, which may meanwhile belong to a Host recording (Action Button).
    private var localOutcomeOnScreen = false

    private var suite: UserDefaults? { UserDefaults(suiteName: KbdSuite.suiteName) }
    private var phasePollTimer: Timer?
    private var resultPollTimer: Timer?
    private var startFallbackTimer: Timer?

    private var viewState: DictationViewState = .idle {
        didSet {
            keyboardView.apply(state: viewState)
            switch viewState {
            case .result:
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    switch self.viewState {
                    case .result:
                        if !self.localOutcomeOnScreen { self.resetSuiteToIdle() }
                        self.localOutcomeOnScreen = false
                        self.viewState = .idle
                    default: break
                    }
                }
            case .error:
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    switch self.viewState {
                    case .error:
                        if !self.localOutcomeOnScreen { self.resetSuiteToIdle() }
                        self.localOutcomeOnScreen = false
                        self.viewState = .idle
                    default: break
                    }
                }
            default:
                break
            }
        }
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        keyboardView.delegate = self
        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardView)
        NSLayoutConstraint.activate([
            keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardView.topAnchor.constraint(equalTo: view.topAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        if let inputView { inputView.allowsSelfSizing = true }
        inKeyboard.onProcessing = { [weak self] message in
            self?.viewState = .processing(message: message)
        }
        inKeyboard.onFinish = { [weak self] outcome in
            self?.finishInKeyboardTurn(outcome)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if case .result = viewState { viewState = .idle }
        if case .error  = viewState { viewState = .idle }
        localOutcomeOnScreen = false
        suite?.set(true, forKey: KbdSuite.keyboardVisibleKey)
        suite?.synchronize()
        let activePhase = suite?.string(forKey: KbdSuite.phaseKey) ?? KbdSuite.phaseIdle
        let canInsertResult = suite.map { isKeyboardConsumableSession($0) } ?? false
        switch activePhase {
        case KbdSuite.phaseStart, KbdSuite.phaseRecording:
            viewState = .recording
        case KbdSuite.phaseStopRequested, KbdSuite.phaseProcessing:
            if canInsertResult, let suite {
                viewState = processingViewState(from: suite)
                startResultPolling()
            }
        case KbdSuite.phaseReady:
            if canInsertResult, let suite {
                let ts = suite.double(forKey: KbdSuite.transcriptTimestampKey)
                let age = Date().timeIntervalSince1970 - ts
                if age < 10 {
                    viewState = processingViewState(from: suite)
                    startResultPolling()
                } else {
                    suite.set(KbdSuite.phaseIdle, forKey: KbdSuite.phaseKey)
                    suite.removeObject(forKey: KbdSuite.transcriptKey)
                    suite.removeObject(forKey: KbdSuite.transcriptTimestampKey)
                    suite.synchronize()
                }
            }
        default:
            break
        }
        startPhasePolling()
    }

    /// After the first frame: preloads the In-keyboard path's capture page and Parakeet, so a
    /// tap finds them ready.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let verdict = InKeyboardDictation.eligibility(hasFullAccess: hasFullAccess, suite: suite, forTap: false)
        NSLog("[Keyboard] In-keyboard path at appear: \(verdict.reason)")
        guard verdict.eligible else { return }
        inKeyboard.prepare(in: view)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        suite?.set(false, forKey: KbdSuite.keyboardVisibleKey)
        suite?.synchronize()
        stopStartFallback()
        stopPhasePolling()
        stopResultPolling()
        // The microphone must never outlive the keyboard; a turn cut short is discarded.
        if inKeyboard.isActive {
            inKeyboard.cancel()
            viewState = .idle
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        KeyboardParakeet.shared.handleMemoryWarning()
    }

    // MARK: DictationKeyboardViewDelegate

    func didTapDictate() {
        if inKeyboard.isActive {
            inKeyboard.stop()
            return
        }
        suite?.synchronize()
        let activePhase = suite?.string(forKey: KbdSuite.phaseKey) ?? KbdSuite.phaseIdle
        switch activePhase {
        case KbdSuite.phaseStart, KbdSuite.phaseRecording:
            requestStop()
        case KbdSuite.phaseStopRequested, KbdSuite.phaseProcessing:
            guard let suite else { return }
            viewState = processingViewState(from: suite)
            startResultPolling()
        default:
            if startInKeyboardTurnIfEligible() { return }
            startHandoff()
        }
    }

    func didInsertText(_ text: String) {
        textDocumentProxy.insertText(text)
    }

    func didTapBackspace() {
        textDocumentProxy.deleteBackward()
    }

    func didTapDismiss() {
        dismissKeyboard()
    }

    func didTapNextKeyboard() {
        advanceToNextInputMode()
    }

    // MARK: In-keyboard path

    private func startInKeyboardTurnIfEligible() -> Bool {
        let verdict = InKeyboardDictation.eligibility(hasFullAccess: hasFullAccess, suite: suite, forTap: true)
        NSLog("[Keyboard] In-keyboard path at tap: \(verdict.reason)")
        guard verdict.eligible, inKeyboard.start(in: view) else { return false }
        stopStartFallback()
        stopResultPolling()
        localOutcomeOnScreen = false
        viewState = .recording
        return true
    }

    /// Delivers an In-keyboard turn exactly as the `.ready` handling in `checkPhase` delivers
    /// a Host transcript.
    private func finishInKeyboardTurn(_ outcome: InKeyboardDictation.Outcome) {
        switch outcome {
        case .text(let text):
            textDocumentProxy.insertText(text)
            localOutcomeOnScreen = true
            viewState = .result(text)
        case .noSpeech:
            viewState = .idle
        case .fallBack(let reason):
            NSLog("[Keyboard] In-keyboard path fell back for this tap: \(reason)")
            viewState = .idle
            startHandoff()
        case .failed(let message):
            localOutcomeOnScreen = true
            viewState = .error(message)
        }
    }

    // MARK: Handoff

    private func startHandoff() {
        localOutcomeOnScreen = false
        guard hasFullAccess else {
            viewState = .error("Enable \"Allow Full Access\" in Settings > General > Keyboard.")
            return
        }
        guard let suite else {
            viewState = .error("App Group unavailable. Reinstall Codictate.")
            return
        }

        let current = suite.string(forKey: KbdSuite.phaseKey) ?? KbdSuite.phaseIdle
        guard current == KbdSuite.phaseIdle
           || current == KbdSuite.phaseReady
           || current == KbdSuite.phaseFailed
        else {
            viewState = .error("Dictation already in progress.")
            return
        }

        let fileName = "kbd-\(UUID().uuidString).wav"
        stopStartFallback()
        suite.set(KbdSuite.phaseStart, forKey: KbdSuite.phaseKey)
        suite.set(fileName, forKey: KbdSuite.wavFileKey)
        suite.set(KbdSuite.sourceKeyboard, forKey: KbdSuite.sourceKey)
        suite.removeObject(forKey: KbdSuite.errorKey)
        suite.removeObject(forKey: KbdSuite.transcriptKey)
        suite.removeObject(forKey: KbdSuite.transcriptTimestampKey)
        CFPreferencesAppSynchronize(KbdSuite.suiteName as CFString)
        suite.synchronize()
        viewState = .recording

        let now = Date().timeIntervalSince1970
        let warmActive = suite.bool(forKey: KbdSuite.warmSessionActiveKey)
        let warmExpiry = suite.double(forKey: KbdSuite.warmSessionExpiryKey)
        let isHostWarm = warmActive && warmExpiry > now

        NSLog("[Keyboard] startHandoff warm=\(isHostWarm) expiry=\(warmExpiry)")

        if isHostWarm {
            // Wake host via Darwin (does not open app). Listen poll picks up phase=start.
            postDarwinNotification(kbdDarwinStartName)
            return
        }

        NSLog("[Keyboard] Cold start — opening Codictate once")
        guard let url = URL(string: "codictateapp://keyboard-record") else { return }
        openApp(url)
        startFallback(for: suite)
    }

    private func requestStop() {
        guard let suite else { return }
        stopStartFallback()
        let phase = suite.string(forKey: KbdSuite.phaseKey) ?? KbdSuite.phaseIdle
        guard phase == KbdSuite.phaseRecording || phase == KbdSuite.phaseStart else {
            viewState = .error("Not recording yet.")
            return
        }
        suite.set(KbdSuite.phaseStopRequested, forKey: KbdSuite.phaseKey)
        CFPreferencesAppSynchronize(KbdSuite.suiteName as CFString)
        suite.synchronize()
        let source = suite.string(forKey: KbdSuite.sourceKey) ?? ""
        if source == KbdSuite.sourceIntent {
            postDarwinNotification(intentDarwinStopName)
        }
        viewState = processingViewState(from: suite)
        startResultPolling()
    }

    private func postDarwinNotification(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name as CFString),
            nil, nil, true
        )
    }

    private func openApp(_ url: URL) {
        extensionContext?.open(url) { [weak self] ok in
            guard let self, !ok else { return }
            DispatchQueue.main.async {
                var responder: UIResponder? = self as UIResponder
                while let r = responder {
                    if let app = r as? UIApplication {
                        app.open(url, options: [:], completionHandler: nil)
                        return
                    }
                    responder = r.next
                }
            }
        }
    }

    private func isKeyboardConsumableSession(_ suite: UserDefaults) -> Bool {
        let source = suite.string(forKey: KbdSuite.sourceKey) ?? ""
        return source == KbdSuite.sourceKeyboard || source == KbdSuite.sourceIntent
    }

    private func processingViewState(from suite: UserDefaults) -> DictationViewState {
        .processing(message: suite.string(forKey: KbdSuite.processingMessageKey))
    }

    /// Benign outcomes where the keyboard should recover immediately (main app may still show a notice).
    private func isBenignNoSpeechOutcome(_ message: String?) -> Bool {
        guard let message else { return true }
        let lower = message.lowercased()
        return lower.contains("no speech")
            || lower.contains("empty transcript")
            || lower.contains("no transcript")
    }

    private func resetSuiteToIdle() {
        guard let suite else { return }
        suite.set(KbdSuite.phaseIdle, forKey: KbdSuite.phaseKey)
        suite.removeObject(forKey: KbdSuite.errorKey)
        suite.removeObject(forKey: KbdSuite.transcriptKey)
        suite.removeObject(forKey: KbdSuite.transcriptTimestampKey)
        suite.removeObject(forKey: KbdSuite.processingMessageKey)
        CFPreferencesAppSynchronize(KbdSuite.suiteName as CFString)
        suite.synchronize()
    }

    private func recoverFromBenignFailure() {
        stopResultPolling()
        stopStartFallback()
        resetSuiteToIdle()
        viewState = .idle
    }

    private func showFailure(_ message: String) {
        stopResultPolling()
        stopStartFallback()
        if isBenignNoSpeechOutcome(message) {
            recoverFromBenignFailure()
            return
        }
        viewState = .error(message)
    }

    // MARK: Phase polling

    private func startPhasePolling() {
        phasePollTimer?.invalidate()
        phasePollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.checkPhase()
        }
        RunLoop.main.add(phasePollTimer!, forMode: .common)
    }

    private func stopPhasePolling() {
        phasePollTimer?.invalidate()
        phasePollTimer = nil
    }

    private func startFallback(for suite: UserDefaults) {
        stopStartFallback()
        startFallbackTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self, weak suite] _ in
            guard let self, let suite else { return }
            suite.synchronize()
            let phase = suite.string(forKey: KbdSuite.phaseKey) ?? KbdSuite.phaseIdle
            let source = suite.string(forKey: KbdSuite.sourceKey) ?? ""
            guard phase == KbdSuite.phaseStart, source == KbdSuite.sourceKeyboard else { return }
            suite.set(KbdSuite.phaseIdle, forKey: KbdSuite.phaseKey)
            suite.removeObject(forKey: KbdSuite.wavFileKey)
            suite.removeObject(forKey: KbdSuite.transcriptKey)
            suite.removeObject(forKey: KbdSuite.errorKey)
            suite.synchronize()
            self.viewState = .error("Open Codictate once, then try dictation again.")
        }
        RunLoop.main.add(startFallbackTimer!, forMode: .common)
    }

    private func stopStartFallback() {
        startFallbackTimer?.invalidate()
        startFallbackTimer = nil
    }

    private func checkPhase() {
        // An In-keyboard turn owns the view state; the shared phase says nothing about it.
        guard !inKeyboard.isActive else { return }
        guard let suite else { return }
        suite.synchronize()
        let phase = suite.string(forKey: KbdSuite.phaseKey) ?? KbdSuite.phaseIdle

        switch viewState {
        case .idle, .result, .error:
            if phase == KbdSuite.phaseFailed,
               isBenignNoSpeechOutcome(suite.string(forKey: KbdSuite.errorKey)) {
                recoverFromBenignFailure()
                break
            }
            switch phase {
            case KbdSuite.phaseStart, KbdSuite.phaseRecording:
                viewState = .recording
            case KbdSuite.phaseStopRequested, KbdSuite.phaseProcessing:
                if isKeyboardConsumableSession(suite) {
                    viewState = processingViewState(from: suite)
                    startResultPolling()
                }
            case KbdSuite.phaseReady:
                if isKeyboardConsumableSession(suite) {
                    viewState = processingViewState(from: suite)
                    startResultPolling()
                }
            default:
                break
            }

        case .recording:
            switch phase {
            case KbdSuite.phaseRecording:
                stopStartFallback()
            case KbdSuite.phaseStopRequested, KbdSuite.phaseProcessing, KbdSuite.phaseReady:
                stopStartFallback()
                viewState = processingViewState(from: suite)
                startResultPolling()
            case KbdSuite.phaseFailed:
                stopStartFallback()
                showFailure(suite.string(forKey: KbdSuite.errorKey) ?? "Dictation failed.")
            case KbdSuite.phaseIdle:
                stopStartFallback()
                viewState = .idle
            default:
                break
            }

        case .processing:
            switch phase {
            case KbdSuite.phaseIdle:
                stopResultPolling()
                viewState = .idle
            case KbdSuite.phaseStopRequested, KbdSuite.phaseProcessing:
                viewState = processingViewState(from: suite)
            case KbdSuite.phaseReady:
                stopResultPolling()
                if let text = suite.string(forKey: KbdSuite.transcriptKey) {
                    if !text.isEmpty {
                        textDocumentProxy.insertText(text)
                        viewState = .result(text)
                    } else {
                        viewState = .idle
                    }
                    suite.set(KbdSuite.phaseIdle, forKey: KbdSuite.phaseKey)
                    suite.removeObject(forKey: KbdSuite.transcriptKey)
                    suite.removeObject(forKey: KbdSuite.transcriptTimestampKey)
                    suite.synchronize()
                } else {
                    recoverFromBenignFailure()
                }
            case KbdSuite.phaseFailed:
                stopResultPolling()
                showFailure(suite.string(forKey: KbdSuite.errorKey) ?? "Dictation failed.")
            default:
                break
            }
        }
    }

    // MARK: Result polling

    private func startResultPolling() {
        guard resultPollTimer == nil else { return }
        resultPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkPhase()
        }
        RunLoop.main.add(resultPollTimer!, forMode: .common)
    }

    private func stopResultPolling() {
        resultPollTimer?.invalidate()
        resultPollTimer = nil
    }
}
