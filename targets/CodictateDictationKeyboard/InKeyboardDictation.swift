import AVFAudio
import Foundation
import UIKit

/// The In-keyboard path: one Dictation turn recorded (`KeyboardWebCapture`) and transcribed
/// (`KeyboardParakeet`) inside the keyboard, so the user never leaves the app they type in,
/// even with Codictate closed. Local to the keyboard: it writes no phase to the App Group,
/// so the Host never records the same words.
///
/// Used only when `eligibility` says so; otherwise the keyboard keeps the Warm or Cold path.
/// A capture that never gets going (getUserMedia refused, WebKit's process gone, no audio,
/// under half a second when it ends by itself) hands the tap back to that path with
/// `.fallBack`, so a dictation is never lost silently.
@MainActor
final class InKeyboardDictation {
    enum Outcome {
        case text(String)
        case noSpeech
        /// Use the Warm or Cold path for this tap.
        case fallBack(String)
        case failed(String)
    }

    var onProcessing: ((String?) -> Void)?
    var onFinish: ((Outcome) -> Void)?

    private enum Phase {
        case idle
        case recording
        case stopping
        case transcribing
    }

    private var phase: Phase = .idle
    private var capture: KeyboardWebCapture?
    private var file: KeyboardPCMFile?
    private var userStopped = false
    private var otherAudioAtStart = false
    private var autoStopTimer: Timer?
    private var firstAudioTimer: Timer?
    private var stopTimeoutTimer: Timer?
    /// Bumped by every start and cancel, so a stale transcription delivers nothing.
    private var generation = 0

    /// Same as the Host's keyboard auto-stop (`autoStopAfterSeconds`).
    static let autoStopAfterSeconds: TimeInterval = 60
    /// No audio this long after the tap: the capture is not coming (WebKit's first capture
    /// in a keyboard process takes up to about 1.4 s).
    static let firstAudioDeadline: TimeInterval = 3
    /// A capture that ends by itself with less than this recorded never really started
    /// (Dictus saw `context-interrupted` right after the app switcher).
    static let shortestCapture: TimeInterval = 0.5
    static let firstUseMessage = "Transcribing. First use may take a minute..."
    private static let filePrefix = "kbd-local-"

    var isActive: Bool { phase != .idle }

    /// Back to idle; the model may go on a memory warning again.
    private func endTurn() {
        phase = .idle
        KeyboardParakeet.shared.isHeldForTurn = false
    }

    // MARK: - Eligibility

    /// Whether this tap may use the In-keyboard path, with the reason when it may not.
    /// `forTap` adds the checks that change from moment to moment (a Host already
    /// recording or listening, the model and memory right now); without it, the answer
    /// decides whether to preload the page and the model when the keyboard appears.
    static func eligibility(hasFullAccess: Bool, suite: UserDefaults?, forTap: Bool) -> (eligible: Bool, reason: String) {
        guard hasFullAccess else { return (false, "no Full Access") }
        guard let suite, KeyboardParakeet.modelDirectory != nil else { return (false, "no App Group") }
        suite.synchronize()
        if KeyboardParakeet.shared.isSetAside { return (false, "set aside in this process") }
        // The Host's own default when the key is unset (`TranscriptionRouter`, `DictationReadiness`).
        let variant = suite.string(forKey: KbdSuite.preferredVariantKey) ?? "base"
        guard variant == "parakeet" else { return (false, "Speech Model is \(variant)") }
        // Parakeet's Language Lock accepts only automatic; any other language is the Host's
        // `languageUnsupportedByModel`, which the Host path reports.
        let language = suite.string(forKey: KbdSuite.transcriptionLanguageKey) ?? "auto"
        guard language == "auto" else { return (false, "Transcription Language is \(language)") }
        guard KeyboardParakeet.modelIsReady(suite: suite) else { return (false, "Parakeet not ready in the App Group") }
        guard AVAudioApplication.shared.recordPermission == .granted else { return (false, "microphone not granted") }
        guard KeyboardParakeet.deviceFits else { return (false, "no Neural Engine or under 5 GiB") }
        // S1-mini cannot run in the keyboard, and dropping the user's formatting silently is
        // worse than switching to the Host.
        if suite.string(forKey: KbdSuite.formattingModelKey) == "s1-mini",
           suite.bool(forKey: KbdSuite.s1MiniVerifiedKey) {
            return (false, "S1-mini formatting is on")
        }
        guard forTap else { return (true, "eligible") }

        // A listening Host already records without a switch; two microphone owners would fight.
        let now = Date().timeIntervalSince1970
        let warmExpiry = suite.double(forKey: KbdSuite.warmSessionExpiryKey)
        if suite.bool(forKey: KbdSuite.warmSessionActiveKey), warmExpiry > now {
            return (false, "Host warm session active")
        }
        let shared = suite.string(forKey: KbdSuite.phaseKey) ?? KbdSuite.phaseIdle
        guard [KbdSuite.phaseIdle, KbdSuite.phaseReady, KbdSuite.phaseFailed].contains(shared) else {
            return (false, "shared phase is \(shared)")
        }
        let parakeet = KeyboardParakeet.shared
        if let blocked = parakeet.loadBlockedReason() { return (false, blocked) }
        let memory = KeyboardParakeet.memory()
        guard KeyboardParakeetBudget.allowsTranscription(
            footprint: memory.footprint, available: memory.available, audioSeconds: KeyboardParakeetBudget.longestAudio
        ) else {
            return (false, "short of memory for a \(Int(KeyboardParakeetBudget.longestAudio)) s turn \(memory)")
        }
        return (true, "eligible")
    }

    // MARK: - Lifecycle

    /// Loads the capture page (no microphone) and starts loading Parakeet, off the tap's path.
    func prepare(in host: UIView) {
        if capture == nil { makeCapture(in: host) }
        KeyboardParakeet.shared.warmUp()
        removeLeftoverRecordings()
    }

    /// Starts a turn. False when it cannot start, and the tap should use the existing path.
    func start(in host: UIView) -> Bool {
        guard phase == .idle else { return false }
        guard KeyboardParakeet.shared.warmUp() else { return false }
        if capture == nil { makeCapture(in: host) }
        generation += 1
        phase = .recording
        KeyboardParakeet.shared.isHeldForTurn = true
        userStopped = false
        file = nil
        otherAudioAtStart = AVAudioSession.sharedInstance().isOtherAudioPlaying
        capture?.start()
        autoStopTimer = scheduledTimer(Self.autoStopAfterSeconds) { [weak self] in
            NSLog("[Keyboard] In-keyboard auto-stop after \(Int(Self.autoStopAfterSeconds)) s")
            self?.stop()
        }
        firstAudioTimer = scheduledTimer(Self.firstAudioDeadline) { [weak self] in
            guard let self, self.phase == .recording, (self.file?.frames ?? 0) == 0 else { return }
            self.abandonCapture(fallBack: "no audio \(Self.firstAudioDeadline) s after the tap")
        }
        NSLog("[Keyboard] In-keyboard turn started \(KeyboardParakeet.memory())")
        return true
    }

    /// The user's second tap (or the auto-stop): waits for the page's flushed tail, then transcribes.
    func stop() {
        guard phase == .recording else { return }
        userStopped = true
        phase = .stopping
        invalidateTimers()
        capture?.stop()
        // A page that never loaded, or a process that went quiet, posts no `stopped`.
        stopTimeoutTimer = scheduledTimer(1.5) { [weak self] in
            guard let self, self.phase == .stopping else { return }
            NSLog("[Keyboard] In-keyboard capture did not confirm its stop")
            self.captureEnded(reason: "stop not confirmed")
        }
    }

    /// The keyboard is going away: stop the microphone and discard everything.
    func cancel() {
        guard phase != .idle else { return }
        NSLog("[Keyboard] In-keyboard turn discarded (keyboard hidden)")
        generation += 1
        let wasCapturing = phase == .recording || phase == .stopping
        endTurn()
        invalidateTimers()
        if wasCapturing { capture?.stop() }
        discardFile()
        if wasCapturing { releaseAudioSession() }
    }

    // MARK: - Capture events

    private func makeCapture(in host: UIView) {
        let capture = KeyboardWebCapture(host: host)
        capture.onEvent = { [weak self] event in self?.handle(event) }
        self.capture = capture
    }

    private func handle(_ event: KeyboardWebCapture.Event) {
        switch event {
        case .started(let sampleRate):
            guard phase == .recording || phase == .stopping, file == nil else { return }
            do {
                file = try KeyboardPCMFile(url: try Self.newRecordingURL(), sampleRate: sampleRate)
                NSLog("[Keyboard] In-keyboard capture started at \(Int(sampleRate)) Hz")
            } catch {
                abandonCapture(fallBack: "could not create the WAV: \(error.localizedDescription)")
            }
        case .samples(let data):
            guard phase == .recording || phase == .stopping else { return }
            file?.append(data)
        case .stopped(let reason):
            guard phase == .recording || phase == .stopping else { return }
            captureEnded(reason: reason)
        case .failed(let message):
            guard phase == .recording || phase == .stopping else { return }
            captureEnded(reason: "failed: \(message)")
        case .processTerminated:
            // A new web view takes its place at the next prepare or start.
            capture?.tearDown()
            capture = nil
            guard phase == .recording || phase == .stopping else { return }
            captureEnded(reason: "web content process terminated")
        }
    }

    /// The microphone is released. `reason` is nil for a confirmed stop the keyboard asked for.
    private func captureEnded(reason: String?) {
        invalidateTimers()
        releaseAudioSession()
        let seconds = file?.seconds ?? 0
        file?.close()
        if let reason { NSLog("[Keyboard] In-keyboard capture ended: \(reason), \(String(format: "%.1f", seconds)) s") }

        if seconds < Self.shortestCapture {
            discardFile()
            endTurn()
            // The user's own quick tap is no speech; a capture that died by itself goes to the Host.
            onFinish?(userStopped ? .noSpeech : .fallBack(reason ?? "capture ended"))
            return
        }
        transcribe(seconds: seconds)
    }

    /// Ends a capture that never got going and hands the tap to the existing path.
    private func abandonCapture(fallBack reason: String) {
        NSLog("[Keyboard] In-keyboard capture abandoned: \(reason)")
        generation += 1
        endTurn()
        invalidateTimers()
        capture?.stop()
        discardFile()
        releaseAudioSession()
        onFinish?(.fallBack(reason))
    }

    // MARK: - Transcription

    private func transcribe(seconds: Double) {
        guard let file else {
            endTurn()
            onFinish?(.noSpeech)
            return
        }
        phase = .transcribing
        let parakeet = KeyboardParakeet.shared
        // A load still running at the stop is compiling the model: warm loads take 0.3 s.
        onProcessing?(parakeet.isLoaded ? nil : Self.firstUseMessage)
        let turn = generation
        let url = file.url
        Task { @MainActor [weak self] in
            let outcome: Outcome
            do {
                let text = try await parakeet.transcribe(url, audioSeconds: seconds)
                // The Host delivers Parakeet's text unchanged and treats an empty one as no speech.
                outcome = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .noSpeech : .text(text)
            } catch {
                parakeet.setAside("transcription failed: \(error.localizedDescription)")
                outcome = .failed("Transcription failed: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: url)
            guard let self, self.generation == turn else { return }
            self.file = nil
            self.endTurn()
            self.onFinish?(outcome)
        }
    }

    // MARK: - Helpers

    /// The Host's `KeyboardRecordings/` folder in the App Group.
    private static func recordingsDirectory() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KbdSuite.suiteName
        ) else { throw CocoaError(.fileNoSuchFile) }
        let directory = container.appendingPathComponent("KeyboardRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func newRecordingURL() throws -> URL {
        try recordingsDirectory().appendingPathComponent("\(filePrefix)\(UUID().uuidString).wav")
    }

    /// Recordings a keyboard process ended mid-turn left behind.
    private func removeLeftoverRecordings() {
        guard phase == .idle, let directory = try? Self.recordingsDirectory(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        for name in names where name.hasPrefix(Self.filePrefix) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func discardFile() {
        guard let file else { return }
        file.close()
        try? FileManager.default.removeItem(at: file.url)
        self.file = nil
    }

    private func invalidateTimers() {
        autoStopTimer?.invalidate()
        autoStopTimer = nil
        firstAudioTimer?.invalidate()
        firstAudioTimer = nil
        stopTimeoutTimer?.invalidate()
        stopTimeoutTimer = nil
    }

    private func scheduledTimer(_ seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Timer {
        // Added to the main run loop, so it fires on the main thread.
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { fire() } }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// WebKit's capture session (`playAndRecord`, no `mixWithOthers`) pauses the user's music
    /// and ends without `notifyOthersOnDeactivation`, so the player is never told it may
    /// resume. When music played at the tap and is silent after the capture, the keyboard
    /// activates its own session and deactivates it with that option (Hex's
    /// `InterruptedAudio`, Dictus' workaround). Harmless where it does not help.
    private func releaseAudioSession() {
        guard otherAudioAtStart else { return }
        otherAudioAtStart = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // Another capture started meanwhile: its end asks instead.
            if let self, self.phase == .recording || self.phase == .stopping {
                self.otherAudioAtStart = true
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let session = AVAudioSession.sharedInstance()
                guard !session.isOtherAudioPlaying else { return }
                do {
                    try session.setCategory(.playback, mode: .default, options: [])
                    try session.setActive(true, options: [])
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                    NSLog("[Keyboard] Asked interrupted audio to resume")
                } catch {
                    NSLog("[Keyboard] Asking interrupted audio to resume failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
