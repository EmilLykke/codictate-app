import AVFAudio
import Foundation
import UIKit

/// The In-keyboard path: one Dictation turn recorded (`KeyboardWebCapture`) and transcribed
/// without the Host, so the user never leaves the app they type in, even with Codictate
/// closed. Parakeet transcribes inside the keyboard (`KeyboardParakeet`); every other Speech
/// Model runs in the Dictation AU (`KeyboardDictationAUClient`), which reads the recording
/// from the App Group. Local to the keyboard: it writes no phase to the App Group, so the
/// Host never records the same words.
///
/// Used only when `eligibility` says so; otherwise the keyboard keeps the Warm or Cold path.
/// A capture that never gets going (getUserMedia refused, WebKit's process gone, no audio,
/// under half a second when it ends by itself) hands the tap back to that path with
/// `.fallBack`, so a dictation is never lost silently. A failed transcription shows its
/// error and sets the path aside for that Speech Model in this keyboard process.
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
    /// RMS levels (0...1) of each captured buffer's five slices while recording, about 12
    /// buffers a second.
    var onLevel: (([Float]) -> Void)?

    private enum Phase {
        case idle
        case recording
        case stopping
        case transcribing
    }

    private var phase: Phase = .idle
    /// The Speech Model of the turn in progress, read at its tap.
    private var variant: SpeechModelCatalog.Variant = .parakeet
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
    static let formattingMessage = "Formatting\u{2026}"
    private static let filePrefix = "kbd-local-"

    var isActive: Bool { phase != .idle }
    /// Capturing and not yet stopped: a tap now stops the turn.
    var isRecording: Bool { phase == .recording }
    /// The processing state's message right after the stop: Parakeet's first-use line while
    /// it is still compiling, nothing otherwise.
    var processingMessageAtStop: String? {
        variant == .parakeet && !KeyboardParakeet.shared.isLoaded ? Self.firstUseMessage : nil
    }

    /// Speech Models whose transcription failed in the Dictation AU in this keyboard process:
    /// their next taps use the Warm or Cold path. Parakeet's is `KeyboardParakeet.isSetAside`.
    private static var setAsideVariants: Set<SpeechModelCatalog.Variant> = []

    /// Back to idle; the model may go on a memory warning again.
    private func endTurn() {
        phase = .idle
        KeyboardParakeet.shared.isHeldForTurn = false
    }

    // MARK: - Eligibility

    /// The Speech Model selected in the App Group: the Host's default `base` when unset
    /// (`TranscriptionRouter`, `DictationReadiness`), nil when the id is unknown.
    static func selectedVariant(suite: UserDefaults?) -> SpeechModelCatalog.Variant? {
        SpeechModelCatalog.Variant(rawValue: suite?.string(forKey: KbdSuite.preferredVariantKey) ?? "base")
    }

    /// Whether this tap may use the In-keyboard path, with the reason when it may not.
    /// `forTap` adds the checks that change from moment to moment (a Host already
    /// recording or listening, the model and memory right now); without it, the answer
    /// decides whether to preload the page and the model when the keyboard appears.
    static func eligibility(hasFullAccess: Bool, suite: UserDefaults?, forTap: Bool) -> (eligible: Bool, reason: String) {
        guard hasFullAccess else { return (false, "no Full Access") }
        guard let suite, SpeechModelCatalog.containerURL != nil else { return (false, "no App Group") }
        suite.synchronize()
        guard let variant = selectedVariant(suite: suite) else {
            return (false, "unknown Speech Model \(suite.string(forKey: KbdSuite.preferredVariantKey) ?? "")")
        }
        if variant == .parakeet ? KeyboardParakeet.shared.isSetAside : setAsideVariants.contains(variant) {
            return (false, "set aside for \(variant.rawValue) in this process")
        }
        // The Language Lock, as the Host checks it: an explicitly picked language the Speech
        // Model cannot run is the Host's `languageUnsupportedByModel`, which its path reports.
        let language = suite.string(forKey: KbdSuite.transcriptionLanguageKey) ?? SpeechModelCatalog.Variant.automaticLanguageId
        guard variant.accepts(languageId: language) else {
            return (false, "Transcription Language \(language) is outside \(variant.rawValue)'s Language Lock")
        }
        // Dictation Readiness as the Host last published it; a blocked state is the Host's to report.
        if let blocked = publishedReadinessBlock(suite: suite) {
            return (false, "Dictation Readiness blocked: \(blocked)")
        }
        if variant == .parakeet {
            guard KeyboardParakeet.modelIsReady(suite: suite) else { return (false, "Parakeet not ready in the App Group") }
        } else {
            // What `ModelManager.modelIsReady` reads in the Host: the weights, and for ekko the
            // Punctuation Model too.
            guard SpeechModelCatalog.filesAreInstalled(for: variant) else {
                return (false, "\(variant.rawValue) files not in the App Group")
            }
        }
        // This process keeps the permission it read when it started, so the Host's own
        // reading counts too (`DictationReadiness`). WebKit still checks when it opens the mic.
        guard AVAudioApplication.shared.recordPermission == .granted
                || suite.bool(forKey: KbdSuite.hostMicrophoneGrantedKey)
        else { return (false, "microphone not granted") }
        if variant == .parakeet {
            guard KeyboardParakeet.deviceFits else { return (false, "no Neural Engine or under 5 GiB") }
        }
        // S1-mini does not block: it cannot run in the keyboard, so a warm Host (checked
        // below) formats as before, and without one the Dictation AU formats the text out of
        // process (`KeyboardDictationAUClient`).
        guard forTap else { return (true, "eligible (\(variant.rawValue))") }

        // A listening Host already records and formats without a switch; two microphone
        // owners would fight.
        let now = Date().timeIntervalSince1970
        let warmExpiry = suite.double(forKey: KbdSuite.warmSessionExpiryKey)
        if suite.bool(forKey: KbdSuite.warmSessionActiveKey), warmExpiry > now {
            return (false, "Host warm session active")
        }
        let shared = suite.string(forKey: KbdSuite.phaseKey) ?? KbdSuite.phaseIdle
        guard [KbdSuite.phaseIdle, KbdSuite.phaseReady, KbdSuite.phaseFailed].contains(shared) else {
            return (false, "shared phase is \(shared)")
        }
        // The other Speech Models run in the Dictation AU's process, not under the keyboard's
        // memory limit; the keyboard only writes the recording to disk.
        guard variant == .parakeet else { return (true, "eligible (\(variant.rawValue) in the Dictation AU)") }
        let parakeet = KeyboardParakeet.shared
        if let blocked = parakeet.loadBlockedReason() { return (false, blocked) }
        let memory = KeyboardParakeet.memory()
        guard KeyboardParakeetBudget.allowsTranscription(
            footprint: memory.footprint, available: memory.available, audioSeconds: KeyboardParakeetBudget.longestAudio
        ) else {
            return (false, "short of memory for a \(Int(KeyboardParakeetBudget.longestAudio)) s turn \(memory)")
        }
        return (true, "eligible (parakeet in the keyboard)")
    }

    /// The blocked reason in the Host's published `dictationReadiness` JSON, or nil when it
    /// is runnable or was never published. The Host re-resolves it whenever the Speech Model
    /// or the Transcription Language changes.
    ///
    /// A Language Lock conflict or missing weights describe the Speech Model the Host last
    /// saw, which is stale after a switch in the keyboard while the Host is not running.
    /// `eligibility` checks both itself for the selected Speech Model, so only the other
    /// reasons count here.
    private static func publishedReadinessBlock(suite: UserDefaults) -> String? {
        guard let data = suite.data(forKey: KbdSuite.dictationReadinessKey),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["blocked"] as? Bool == true
        else { return nil }
        let reason = object["reason"] as? String ?? "blocked"
        guard !["languageUnsupportedByModel", "weightsMissing"].contains(reason) else { return nil }
        return reason
    }

    // MARK: - Lifecycle

    /// Loads the capture page (no microphone) and, for Parakeet, starts loading it, off the
    /// tap's path. The Dictation AU's models load when a turn starts.
    func prepare(in host: UIView) {
        if capture == nil { makeCapture(in: host) }
        if Self.selectedVariant(suite: Self.suite) == .parakeet {
            KeyboardParakeet.shared.warmUp()
        }
        removeLeftoverRecordings()
    }

    /// Starts a turn. False when it cannot start, and the tap should use the existing path.
    func start(in host: UIView) -> Bool {
        guard phase == .idle, let variant = Self.selectedVariant(suite: Self.suite) else { return false }
        if variant == .parakeet {
            guard KeyboardParakeet.shared.warmUp() else { return false }
        }
        if capture == nil { makeCapture(in: host) }
        self.variant = variant
        generation += 1
        phase = .recording
        KeyboardParakeet.shared.isHeldForTurn = variant == .parakeet
        userStopped = false
        file = nil
        otherAudioAtStart = AVAudioSession.sharedInstance().isOtherAudioPlaying
        capture?.start()
        autoStopTimer = scheduledTimer(Self.autoStopAfterSeconds) { [weak self] in
            AppGroupLog.write("[Keyboard] In-keyboard auto-stop after \(Int(Self.autoStopAfterSeconds)) s")
            self?.stop()
        }
        firstAudioTimer = scheduledTimer(Self.firstAudioDeadline) { [weak self] in
            guard let self, self.phase == .recording, (self.file?.frames ?? 0) == 0 else { return }
            self.abandonCapture(fallBack: "no audio \(Self.firstAudioDeadline) s after the tap")
        }
        AppGroupLog.write("[Keyboard] In-keyboard turn started with \(variant.rawValue) \(KeyboardParakeet.memory())")
        // The Speech Model (other than Parakeet) and S1-mini load in the Dictation AU's
        // process while the user speaks.
        if variant != .parakeet {
            KeyboardDictationAUClient.shared.prewarm(variant: variant.rawValue)
        } else if KeyboardDictationAUClient.isWanted(suite: Self.suite) {
            KeyboardDictationAUClient.shared.prewarm()
        }
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
            AppGroupLog.write("[Keyboard] In-keyboard capture did not confirm its stop")
            self.captureEnded(reason: "stop not confirmed")
        }
    }

    /// The keyboard is going away: stop the microphone and discard everything.
    func cancel() {
        guard phase != .idle else { return }
        AppGroupLog.write("[Keyboard] In-keyboard turn discarded (keyboard hidden)")
        generation += 1
        let wasCapturing = phase == .recording || phase == .stopping
        if phase == .transcribing { KeyboardDictationAUClient.shared.cancel() }
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
                AppGroupLog.write("[Keyboard] In-keyboard capture started at \(Int(sampleRate)) Hz")
            } catch {
                abandonCapture(fallBack: "could not create the WAV: \(error.localizedDescription)")
            }
        case .samples(let data, let levels):
            guard phase == .recording || phase == .stopping else { return }
            file?.append(data)
            if phase == .recording { onLevel?(levels) }
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
        if let reason { AppGroupLog.write("[Keyboard] In-keyboard capture ended: \(reason), \(String(format: "%.1f", seconds)) s") }

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
        AppGroupLog.write("[Keyboard] In-keyboard capture abandoned: \(reason)")
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
        guard variant == .parakeet else {
            transcribeInDictationAU(file.url, seconds: seconds)
            return
        }
        let parakeet = KeyboardParakeet.shared
        // A load still running at the stop is compiling the model: warm loads take 0.3 s.
        onProcessing?(parakeet.isLoaded ? nil : Self.firstUseMessage)
        let turn = generation
        let url = file.url
        Task { @MainActor [weak self] in
            var outcome: Outcome
            do {
                let text = try await parakeet.transcribe(url, audioSeconds: seconds)
                // The Host treats an empty transcript as no speech.
                outcome = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .noSpeech : .text(text)
            } catch {
                parakeet.setAside("transcription failed: \(error.localizedDescription)")
                outcome = .failed("Transcription failed: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: url)
            guard let self, self.generation == turn else { return }
            if case .text(let text) = outcome, KeyboardDictationAUClient.isWanted(suite: Self.suite) {
                self.onProcessing?(Self.formattingMessage)
                outcome = await Self.format(text)
                guard self.generation == turn else { return }
            }
            self.file = nil
            self.endTurn()
            self.onFinish?(outcome)
        }
    }

    /// Every Speech Model but Parakeet: one request to the Dictation AU, which transcribes
    /// the recording as the Host would and formats it with S1-mini when eligible. There is no
    /// model in the keyboard to fall back on, so a failure is shown and sets the path aside
    /// for this Speech Model, and the next tap goes to the Host.
    private func transcribeInDictationAU(_ url: URL, seconds: Double) {
        onProcessing?(nil)
        let turn = generation
        let variant = variant
        let languageId = Self.suite?.string(forKey: KbdSuite.transcriptionLanguageKey)
            ?? SpeechModelCatalog.Variant.automaticLanguageId
        guard let container = SpeechModelCatalog.containerURL,
              url.path.hasPrefix(container.path + "/") else {
            finishAUTurn(.failed("Transcription failed: no App Group"), url: url, turn: turn)
            return
        }
        let relativePath = String(url.path.dropFirst(container.path.count + 1))
        KeyboardDictationAUClient.shared.transcribe(
            wavPath: relativePath,
            variant: variant.rawValue,
            languageId: languageId,
            audioSeconds: seconds
        ) { [weak self] result in
            // A turn discarded meanwhile (keyboard hidden) ends in `cancelled`, which says
            // nothing about the Speech Model.
            guard let self, self.generation == turn else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            switch result {
            case .text(let text):
                // The Host treats an empty transcript as no speech.
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.finishAUTurn(trimmed.isEmpty ? .noSpeech : .text(text), url: url, turn: turn)
            case .failed(let reason):
                Self.setAside(variant, "Dictation AU: \(reason)")
                self.finishAUTurn(.failed("Transcription failed"), url: url, turn: turn)
            }
        }
    }

    private func finishAUTurn(_ outcome: Outcome, url: URL, turn: Int) {
        try? FileManager.default.removeItem(at: url)
        guard generation == turn else { return }
        file = nil
        endTurn()
        onFinish?(outcome)
    }

    /// The In-keyboard path is off for `variant` for the rest of this keyboard process.
    private static func setAside(_ variant: SpeechModelCatalog.Variant, _ reason: String) {
        setAsideVariants.insert(variant)
        AppGroupLog.write("[Keyboard] In-keyboard path set aside for \(variant.rawValue): \(reason)")
    }

    // MARK: - Formatting

    private static var suite: UserDefaults? { UserDefaults(suiteName: KbdSuite.suiteName) }

    /// S1-mini in the Dictation AU, as the Host's `formatIfEligible` would run it. Never
    /// fails the turn: any fault or the timeout gives back Parakeet's text, and a successful
    /// empty cleanup is no speech, as on the Host.
    private static func format(_ text: String) async -> Outcome {
        let suite = suite
        let result = await withCheckedContinuation { continuation in
            KeyboardDictationAUClient.shared.format(
                text,
                // Eligibility pins Parakeet to the automatic Transcription Language.
                languageId: suite?.string(forKey: KbdSuite.transcriptionLanguageKey) ?? "auto",
                style: suite?.string(forKey: KbdSuite.formattingStyleKey),
                context: suite?.string(forKey: KbdSuite.formattingContextKey),
                timeout: KeyboardDictationAUClient.timeout(for: text)
            ) { continuation.resume(returning: $0) }
        }
        switch result {
        case .formatted(let output):
            return output.isEmpty ? .noSpeech : .text(output)
        case .original:
            return .text(text)
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
                    AppGroupLog.write("[Keyboard] Asked interrupted audio to resume")
                } catch {
                    AppGroupLog.write("[Keyboard] Asking interrupted audio to resume failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
