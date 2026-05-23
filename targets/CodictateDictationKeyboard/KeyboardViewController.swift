import UIKit
import Foundation

private enum KbdSuite {
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
                        self.resetSuiteToIdle()
                        self.viewState = .idle
                    default: break
                    }
                }
            case .error:
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    switch self.viewState {
                    case .error:
                        self.resetSuiteToIdle()
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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if case .result = viewState { viewState = .idle }
        if case .error  = viewState { viewState = .idle }
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

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        suite?.set(false, forKey: KbdSuite.keyboardVisibleKey)
        suite?.synchronize()
        stopStartFallback()
        stopPhasePolling()
        stopResultPolling()
    }

    // MARK: DictationKeyboardViewDelegate

    func didTapDictate() {
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

    // MARK: Handoff

    private func startHandoff() {
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
                if let text = suite.string(forKey: KbdSuite.transcriptKey), !text.isEmpty {
                    textDocumentProxy.insertText(text)
                    viewState = .result(text)
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
