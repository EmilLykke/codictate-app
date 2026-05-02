import UIKit
import Foundation

private enum KbdSuite {
    static let suiteName        = "group.app.codictate"
    static let phaseKey         = "kbdDictationPhase"
    static let wavFileKey       = "kbdDictationWavFile"
    static let errorKey         = "kbdDictationHostError"
    static let transcriptKey    = "kbdTranscript"
    static let sourceKey        = "kbdDictationSource"
    static let keyboardVisibleKey = "kbdKeyboardVisible"
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

    private var viewState: DictationViewState = .idle {
        didSet { keyboardView.apply(state: viewState) }
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
                viewState = .processing
                startResultPolling()
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
        suite.set(KbdSuite.phaseStart, forKey: KbdSuite.phaseKey)
        suite.set(fileName, forKey: KbdSuite.wavFileKey)
        suite.set(KbdSuite.sourceKeyboard, forKey: KbdSuite.sourceKey)
        suite.removeObject(forKey: KbdSuite.errorKey)
        suite.removeObject(forKey: KbdSuite.transcriptKey)
        suite.synchronize()
        viewState = .recording

        // Darwin notification reaches the host app immediately if it is already running/active.
        // This covers the case where the keyboard is opened while Codictate is in the foreground,
        // because `UIApplication.didBecomeActiveNotification` never fires in that scenario.
        postDarwinNotification(kbdDarwinStartName)

        // URL scheme brings the app to the foreground if it is suspended or not running.
        // `handleDeepLink` guards against double-start by checking the App Group phase.
        guard let url = URL(string: "codictateapp://keyboard-record") else { return }
        extensionContext?.open(url) { [weak self] ok in
            DispatchQueue.main.async {
                guard let self else { return }
                if !ok {
                    self.viewState = .error("Could not open Codictate.")
                    suite.set(KbdSuite.phaseIdle, forKey: KbdSuite.phaseKey)
                    suite.synchronize()
                }
            }
        }
    }

    private func requestStop() {
        guard let suite else { return }
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

    private func checkPhase() {
        guard let suite else { return }
        // Force-read latest cross-process writes from the host app.
        suite.synchronize()
        let phase = suite.string(forKey: KbdSuite.phaseKey) ?? KbdSuite.phaseIdle

        switch viewState {
        case .idle:
            // Detect sessions started externally (shortcut or in-app button).
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
            // Stop was triggered externally (shortcut). Catch all transitions to processing/done.
            switch phase {
            case KbdSuite.phaseStopRequested, KbdSuite.phaseProcessing, KbdSuite.phaseReady:
                viewState = .processing
                startResultPolling()
            case KbdSuite.phaseFailed:
                viewState = .error(suite.string(forKey: KbdSuite.errorKey) ?? "Dictation failed.")
            case KbdSuite.phaseIdle:
                // Session was cancelled externally.
                viewState = .idle
            default:
                break
            }

        default:
            break
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
            viewState = .error(suite.string(forKey: KbdSuite.errorKey) ?? "Dictation failed.")
            return
        }

        guard phase == KbdSuite.phaseReady,
              isKeyboardConsumableSession(suite),
              let text = suite.string(forKey: KbdSuite.transcriptKey), !text.isEmpty
        else { return }

        stopResultPolling()
        textDocumentProxy.insertText(text.hasSuffix(" ") ? text : text + " ")

        suite.set(KbdSuite.phaseIdle, forKey: KbdSuite.phaseKey)
        suite.removeObject(forKey: KbdSuite.transcriptKey)
        suite.removeObject(forKey: KbdSuite.wavFileKey)
        suite.removeObject(forKey: KbdSuite.errorKey)
        suite.synchronize()

        viewState = .result(text)
    }
}
