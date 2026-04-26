import UIKit

private enum KbdSuite {
    static let suiteName        = "group.com.emillo2003.codictate-app"
    static let phaseKey         = "kbdDictationPhase"
    static let wavFileKey       = "kbdDictationWavFile"
    static let errorKey         = "kbdDictationHostError"
    static let transcriptKey    = "kbdTranscript"

    static let phaseIdle        = "idle"
    static let phaseStart       = "start"
    static let phaseRecording   = "recording"
    static let phaseStopRequested = "stop_requested"
    static let phaseProcessing  = "processing"
    static let phaseReady       = "ready"
    static let phaseFailed      = "failed"
}

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
        startPhasePolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopPhasePolling()
        stopResultPolling()
    }

    // MARK: DictationKeyboardViewDelegate

    func didTapDictate() {
        switch viewState {
        case .idle, .result, .error:
            startHandoff()
        case .recording:
            requestStop()
        default:
            break
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

    // MARK: Handoff

    private func startHandoff() {
        guard hasFullAccess else {
            viewState = .error("Enable \"Allow Full Access\" in Settings › General › Keyboard.")
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
        suite.removeObject(forKey: KbdSuite.errorKey)
        suite.removeObject(forKey: KbdSuite.transcriptKey)
        suite.synchronize()
        viewState = .recording

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
        guard suite.string(forKey: KbdSuite.phaseKey) == KbdSuite.phaseRecording else {
            viewState = .error("Not recording yet.")
            return
        }
        suite.set(KbdSuite.phaseStopRequested, forKey: KbdSuite.phaseKey)
        suite.synchronize()
        viewState = .processing
        startResultPolling()
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
        guard let suite, case .recording = viewState else { return }
        if suite.string(forKey: KbdSuite.phaseKey) == KbdSuite.phaseFailed {
            viewState = .error(suite.string(forKey: KbdSuite.errorKey) ?? "Dictation failed.")
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
        let phase = suite.string(forKey: KbdSuite.phaseKey) ?? ""

        if phase == KbdSuite.phaseFailed {
            stopResultPolling()
            viewState = .error(suite.string(forKey: KbdSuite.errorKey) ?? "Dictation failed.")
            return
        }

        guard phase == KbdSuite.phaseReady,
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
