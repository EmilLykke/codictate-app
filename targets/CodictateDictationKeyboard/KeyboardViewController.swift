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
    static let keepaliveStartKey = "kbdKeepaliveStart"
    static let keepaliveDurationKey = "kbdKeepaliveDuration"
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

// Darwin notification names (cross-process IPC to the host app).
private let kbdDarwinStartName = "app.codictate.dictation.keyboard.start"
private let kbdDarwinStopName  = "app.codictate.dictation.keyboard.stop"

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
            case .result, .error:
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self else { return }
                    switch self.viewState {
                    case .result, .error: self.viewState = .idle
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
        // Sync local view state from App Group. A session may already be underway
        // from another entry point (Action Button or previous keyboard tap).
        let activePhase = suite?.string(forKey: KbdSuite.phaseKey) ?? KbdSuite.phaseIdle
        let canInsertResult = suite.map { isKeyboardConsumableSession($0) } ?? false
        switch activePhase {
        case KbdSuite.phaseStart, KbdSuite.phaseRecording:
            viewState = .recording
        case KbdSuite.phaseStopRequested, KbdSuite.phaseProcessing:
            if canInsertResult {
                viewState = .processing
                startResultPolling()
            }
        case KbdSuite.phaseReady:
            if canInsertResult {
                let ts = suite?.double(forKey: KbdSuite.transcriptTimestampKey) ?? 0
                let age = Date().timeIntervalSince1970 - ts
                if age < 10 {
                    viewState = .processing
                    startResultPolling()
                } else {
                    suite?.set(KbdSuite.phaseIdle, forKey: KbdSuite.phaseKey)
                    suite?.removeObject(forKey: KbdSuite.transcriptKey)
                    suite?.removeObject(forKey: KbdSuite.transcriptTimestampKey)
                    suite?.synchronize()
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
        // Source of truth is the App Group phase, not the keyboard's local viewState.
        // a session may already be underway from a different entry point (Action Button
        // or earlier keyboard tap that left the host app foregrounded). In that case the
        // keyboard should *toggle stop*, never re-open the host app.
        suite?.synchronize()
        let activePhase = suite?.string(forKey: KbdSuite.phaseKey) ?? KbdSuite.phaseIdle
        switch activePhase {
        case KbdSuite.phaseStart, KbdSuite.phaseRecording:
            requestStop()
        case KbdSuite.phaseStopRequested, KbdSuite.phaseProcessing:
            // Already on its way to a result. Wait for ready, don't double-trigger.
            viewState = .processing
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
        suite.synchronize()
        viewState = .recording

        postDarwinNotification(kbdDarwinStartName)

        let keepaliveStart = suite.double(forKey: KbdSuite.keepaliveStartKey)
        let keepaliveDuration = suite.double(forKey: KbdSuite.keepaliveDurationKey)
        let isHostWarm = keepaliveDuration > 0 &&
            (Date().timeIntervalSince1970 - keepaliveStart) < keepaliveDuration

        if isHostWarm {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                guard let suite = self.suite else { return }
                suite.synchronize()
                let phase = suite.string(forKey: KbdSuite.phaseKey) ?? KbdSuite.phaseIdle
                guard phase == KbdSuite.phaseStart else { return }
                guard let url = URL(string: "codictateapp://keyboard-record") else { return }
                self.extensionContext?.open(url) { _ in }
            }
        } else {
            guard let url = URL(string: "codictateapp://keyboard-record") else { return }
            extensionContext?.open(url) { [weak self] ok in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !ok {
                        self.stopStartFallback()
                        self.viewState = .error("Could not open Codictate.")
                        suite.set(KbdSuite.phaseIdle, forKey: KbdSuite.phaseKey)
                        suite.removeObject(forKey: KbdSuite.wavFileKey)
                        suite.synchronize()
                    }
                }
            }
        }

        startFallback(for: suite)
    }

    private func requestStop() {
        guard let suite else { return }
        stopStartFallback()
        let phase = suite.string(forKey: KbdSuite.phaseKey) ?? KbdSuite.phaseIdle
        // Allow stop from start (race: tapped before host began recording) or recording.
        guard phase == KbdSuite.phaseRecording || phase == KbdSuite.phaseStart else {
            viewState = .error("Not recording yet.")
            return
        }
        suite.set(KbdSuite.phaseStopRequested, forKey: KbdSuite.phaseKey)
        suite.synchronize()
        postDarwinNotification(kbdDarwinStopName)
        viewState = .processing
        startResultPolling()
    }

    private func postDarwinNotification(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name as CFString),
            nil, nil, true
        )
    }

    private func isKeyboardConsumableSession(_ suite: UserDefaults) -> Bool {
        let source = suite.string(forKey: KbdSuite.sourceKey) ?? ""
        return source == KbdSuite.sourceKeyboard || source == KbdSuite.sourceIntent
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
            switch phase {
            case KbdSuite.phaseStart, KbdSuite.phaseRecording:
                viewState = .recording
            case KbdSuite.phaseStopRequested, KbdSuite.phaseProcessing:
                if isKeyboardConsumableSession(suite) {
                    viewState = .processing
                    startResultPolling()
                }
            case KbdSuite.phaseReady:
                if isKeyboardConsumableSession(suite) {
                    viewState = .processing
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
                viewState = .processing
                startResultPolling()
            case KbdSuite.phaseFailed:
                stopStartFallback()
                viewState = .error(suite.string(forKey: KbdSuite.errorKey) ?? "Dictation failed.")
            case KbdSuite.phaseIdle:
                stopStartFallback()
                viewState = .idle
            default:
                break
            }

        case .processing:
            if phase == KbdSuite.phaseIdle {
                stopResultPolling()
                viewState = .idle
            } else if phase == KbdSuite.phaseFailed {
                stopResultPolling()
                viewState = .error(suite.string(forKey: KbdSuite.errorKey) ?? "Dictation failed.")
            }
        }
    }

    // MARK: Result polling

    private func startResultPolling() {
        stopResultPolling()
        resultPollTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.checkResult()
        }
        RunLoop.main.add(resultPollTimer!, forMode: .common)
    }

    private func stopResultPolling() {
        resultPollTimer?.invalidate()
        resultPollTimer = nil
    }

    private func checkResult() {
        guard let suite else { return }
        suite.synchronize()
        let phase = suite.string(forKey: KbdSuite.phaseKey) ?? ""

        if phase == KbdSuite.phaseFailed {
            stopResultPolling()
            stopStartFallback()
            viewState = .error(suite.string(forKey: KbdSuite.errorKey) ?? "Dictation failed.")
            return
        }

        guard phase == KbdSuite.phaseReady,
              isKeyboardConsumableSession(suite),
              let text = suite.string(forKey: KbdSuite.transcriptKey), !text.isEmpty
        else { return }

        stopResultPolling()
        stopStartFallback()
        textDocumentProxy.insertText(text.hasSuffix(" ") ? text : text + " ")

        suite.set(KbdSuite.phaseIdle, forKey: KbdSuite.phaseKey)
        suite.removeObject(forKey: KbdSuite.transcriptKey)
        suite.removeObject(forKey: KbdSuite.transcriptTimestampKey)
        suite.removeObject(forKey: KbdSuite.wavFileKey)
        suite.removeObject(forKey: KbdSuite.errorKey)
        suite.synchronize()

        viewState = .result(text)
    }
}
