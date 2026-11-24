import AVFoundation
import AudioToolbox
import Foundation

// Adapted from KeyVox (`KeyboardTranscriptionAUClient`, MIT). See NOTICE.

/// Hosts the Dictation AU (`CodictateFormattingAU`) out of process, so an In-keyboard
/// dictation gets every Speech Model and S1-mini without the Host. Neither fits the keyboard's
/// memory limit (Parakeet does, on the Neural Engine, and stays in the keyboard); the AU's
/// process has no such ceiling.
///
/// Every exchange waits for the AU's answer, so the client works on its own queue and
/// reports on the main queue. Formatting never fails a Dictation: every fault, the timeout
/// included, hands back the original text. A transcription that fails has no text to hand
/// back, except once the AU has reached S1-mini: then the transcript goes in unformatted.
final class KeyboardDictationAUClient: @unchecked Sendable {
    static let shared = KeyboardDictationAUClient()

    enum Result {
        /// S1-mini's text; empty is a successful cleanup with no output.
        case formatted(String)
        /// Deliver the original text.
        case original(reason: String)
    }

    enum TranscribeResult {
        /// The text to insert; empty when there is none (no speech, or S1-mini removed it).
        case text(String)
        /// Nothing to insert: the Speech Model failed, Dictation Readiness refused, the AU is
        /// gone, or time ran out before a transcript.
        case failed(reason: String)
    }

    private typealias Key = DictationAUContract.Key
    private typealias Status = DictationAUContract.Status

    private static let componentDiscoveryTimeout: TimeInterval = 2
    private static let componentDiscoveryPollInterval: TimeInterval = 0.02
    private static let instantiationTimeout: TimeInterval = 10
    private static let pollInterval: TimeInterval = 0.05

    private let queue = DispatchQueue(label: "app.codictate.keyboard.dictation-au", qos: .userInitiated)
    // Both only on `queue`.
    private var audioUnit: AVAudioUnit?
    private var channel: (any AUMessageChannel)?

    /// Bumped by every request, cancel and disconnect, so a stale poll loop stops.
    private let generationLock = NSLock()
    private var generation = 0

    private init() {}

    /// Whether this keyboard dictation should go through S1-mini: selected and verified in
    /// the App Group. The AU checks again and also gates on English.
    static func isWanted(suite: UserDefaults?) -> Bool {
        guard let suite else { return false }
        return suite.string(forKey: KbdSuite.formattingModelKey) == "s1-mini"
            && suite.bool(forKey: KbdSuite.s1MiniVerifiedKey)
    }

    /// How long a format may take before the unformatted text goes in instead: 8 s, plus time
    /// for a long dictation, whose output S1-mini generates token by token.
    static func timeout(for text: String) -> TimeInterval {
        min(30, 8 + Double(max(0, text.count - 200)) / 40)
    }

    /// How long the AU may take to reach a transcript of `audioSeconds` of audio, from the
    /// request: up to about 12 s to start the AU's process, a first load of hviske or ekko
    /// with its Metal setup (seconds), a CPU retry after a Metal fault, and the run itself,
    /// which on the CPU can approach the audio's length. S1-mini then gets `timeout(for:)`.
    /// Generous on purpose: running out loses the dictation. Tune from the `[DictationAU]`
    /// load and transcribe times in keyboard.log.
    static func transcriptionTimeout(audioSeconds: Double) -> TimeInterval {
        20 + 1.5 * max(0, audioSeconds)
    }

    /// Starts the AU if it is not running and has it load S1-mini (when selected) and, with
    /// `variant`, that Speech Model, while the user speaks.
    func prewarm(variant: String? = nil) {
        queue.async { [self] in
            guard connect() else { return }
            var payload: [AnyHashable: Any] = [:]
            if let variant { payload[Key.variant] = variant }
            let accepted = send(.prewarm, payload)?[Key.accepted] as? Bool ?? false
            AppGroupLog.write(
                "[Keyboard] Dictation AU prewarm\(variant.map { " \($0)" } ?? "") \(accepted ? "accepted" : "refused or no answer")"
            )
        }
    }

    /// Formats `text` in the AU. `completion` runs once on the main queue: with the AU's
    /// result, or `.original` on any fault or after `timeout`.
    func format(
        _ text: String,
        languageId: String,
        style: String?,
        context: String?,
        timeout: TimeInterval,
        completion: @escaping @MainActor (Result) -> Void
    ) {
        let turn = bumpGeneration()
        let requestID = UUID().uuidString
        let started = Date()
        var delivered = false
        let deliver: @MainActor (Result) -> Void = { result in
            guard !delivered else { return }
            delivered = true
            let seconds = Date().timeIntervalSince(started)
            switch result {
            case .formatted(let output):
                AppGroupLog.write(String(
                    format: "[Keyboard] Dictation AU formatted %d -> %d chars in %.2f s",
                    text.count, output.count, seconds
                ))
            case .original(let reason):
                AppGroupLog.write(String(
                    format: "[Keyboard] Formatting fallback after %.2f s: %@; inserting Parakeet's text", seconds, reason
                ))
            }
            completion(result)
        }
        // The timer runs on the main queue, so it fires even while `queue` is stuck
        // instantiating the AU or waiting on a dead one.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            MainActor.assumeIsolated {
                guard !delivered else { return }
                self?.cancel()
                deliver(.original(reason: String(format: "timed out after %.0f s", timeout)))
            }
        }
        let deadline = started.addingTimeInterval(timeout)
        queue.async { [self] in
            let result = performFormat(
                requestID: requestID, text: text, languageId: languageId, style: style,
                context: context, turn: turn, deadline: deadline
            )
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(result) } }
        }
    }

    /// Transcribes the WAV at `wavPath` (relative to the App Group container) with `variant`
    /// in the AU, which formats it with S1-mini when eligible, all in one request.
    /// `completion` runs once on the main queue. Past `transcriptionTimeout` with no
    /// transcript it fails; once the AU is formatting, past `timeout(for:)` the unformatted
    /// transcript is delivered.
    func transcribe(
        wavPath: String,
        variant: String,
        languageId: String,
        audioSeconds: Double,
        completion: @escaping @MainActor (TranscribeResult) -> Void
    ) {
        let turn = bumpGeneration()
        let requestID = UUID().uuidString
        let started = Date()
        let watch = TranscribeWatch(deadline: started.addingTimeInterval(Self.transcriptionTimeout(audioSeconds: audioSeconds)))
        var delivered = false
        var watchdog: Timer?
        let deliver: @MainActor (TranscribeResult) -> Void = { result in
            guard !delivered else { return }
            delivered = true
            watchdog?.invalidate()
            let seconds = Date().timeIntervalSince(started)
            switch result {
            case .text(let text):
                AppGroupLog.write(String(
                    format: "[Keyboard] Dictation AU %@: %d chars for %.1f s of audio in %.2f s",
                    variant, text.count, audioSeconds, seconds
                ))
            case .failed(let reason):
                AppGroupLog.write(String(
                    format: "[Keyboard] Dictation AU %@ failed after %.2f s: %@", variant, seconds, reason
                ))
            }
            completion(result)
        }
        // On the main run loop, so it fires even while `queue` is stuck instantiating the AU
        // or waiting on a dead one.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard !delivered else { return }
                let (deadline, fallback) = watch.read()
                guard Date() >= deadline else { return }
                self?.cancel()
                if let fallback {
                    deliver(.text(fallback))
                    AppGroupLog.write("[Keyboard] S1-mini out of time; inserted the unformatted transcript")
                } else {
                    deliver(.failed(reason: String(format: "timed out after %.0f s", deadline.timeIntervalSince(started))))
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer

        queue.async { [self] in
            let result = performTranscribe(
                requestID: requestID, wavPath: wavPath, variant: variant, languageId: languageId,
                audioSeconds: audioSeconds, turn: turn, watch: watch
            )
            DispatchQueue.main.async { MainActor.assumeIsolated { deliver(result) } }
        }
    }

    /// Abandons the running request.
    func cancel() {
        bumpGeneration()
        queue.async { [self] in _ = send(.cancel) }
    }

    /// The keyboard is going away: the AU frees its models and the keyboard lets go of it.
    func disconnect() {
        bumpGeneration()
        queue.async { [self] in
            guard channel != nil else { return }
            _ = send(.unload)
            channel = nil
            audioUnit = nil
            AppGroupLog.write("[Keyboard] Dictation AU released")
        }
    }

    // MARK: - Queue only

    private func performFormat(
        requestID: String, text: String, languageId: String, style: String?, context: String?,
        turn: Int, deadline: Date
    ) -> Result {
        guard connect() else { return .original(reason: "Dictation AU unavailable") }
        var message: [AnyHashable: Any] = [
            Key.requestID: requestID, Key.text: text, Key.languageId: languageId,
        ]
        if let style { message[Key.style] = style }
        if let context { message[Key.context] = context }
        guard let started = send(.format, message) else { return .original(reason: "Dictation AU process gone") }
        guard started[Key.accepted] as? Bool == true else { return .original(reason: "Dictation AU refused the request") }

        while Date() < deadline {
            guard currentGeneration == turn else { return .original(reason: "cancelled") }
            guard let reply = send(.poll, [Key.requestID: requestID]) else {
                return .original(reason: "Dictation AU process gone while formatting")
            }
            let status = Status(rawValue: reply[Key.status] as? String ?? "") ?? .failed
            let reason = reply[Key.reason] as? String ?? status.rawValue
            switch status {
            case .pending, .formatting:
                Thread.sleep(forTimeInterval: Self.pollInterval)
            case .formatted:
                guard let output = reply[Key.text] as? String else { return .original(reason: "no text in reply") }
                return .formatted(output)
            case .unchanged:
                return .original(reason: "not formatted: \(reason)")
            case .failed, .transcribed, .blocked:
                return .original(reason: "S1-mini failed: \(reason)")
            }
        }
        _ = send(.cancel)
        return .original(reason: "timed out")
    }

    private func performTranscribe(
        requestID: String, wavPath: String, variant: String, languageId: String,
        audioSeconds: Double, turn: Int, watch: TranscribeWatch
    ) -> TranscribeResult {
        guard connect() else { return .failed(reason: "Dictation AU unavailable") }
        let message: [AnyHashable: Any] = [
            Key.requestID: requestID, Key.wavPath: wavPath, Key.variant: variant,
            Key.languageId: languageId, Key.audioSeconds: audioSeconds,
        ]
        guard let started = send(.transcribe, message) else { return .failed(reason: "Dictation AU process gone") }
        guard started[Key.accepted] as? Bool == true else { return .failed(reason: "Dictation AU refused the request") }

        var formattingFrom: String?
        while true {
            guard currentGeneration == turn else { return .failed(reason: "cancelled") }
            guard let reply = send(.poll, [Key.requestID: requestID]) else {
                // Past S1-mini's start the transcript is in hand; a crash in S1-mini does not lose it.
                if let formattingFrom { return .text(formattingFrom) }
                return .failed(reason: "Dictation AU process gone while transcribing")
            }
            let status = Status(rawValue: reply[Key.status] as? String ?? "") ?? .failed
            let reason = reply[Key.reason] as? String ?? status.rawValue
            switch status {
            case .pending:
                Thread.sleep(forTimeInterval: Self.pollInterval)
            case .formatting:
                if formattingFrom == nil, let text = reply[Key.text] as? String {
                    formattingFrom = text
                    watch.formatting(text, timeout: Self.timeout(for: text))
                }
                Thread.sleep(forTimeInterval: Self.pollInterval)
            case .transcribed:
                guard let text = reply[Key.text] as? String else { return .failed(reason: "no text in reply") }
                return .text(text)
            case .blocked:
                return .failed(reason: "blocked: \(reason)")
            case .failed, .formatted, .unchanged:
                return .failed(reason: reason)
            }
        }
    }

    private func connect() -> Bool {
        if channel != nil { return true }
        let started = Date()
        guard let unit = instantiateAudioUnit() else { return false }
        audioUnit = unit
        channel = unit.auAudioUnit.messageChannel(for: DictationAUContract.messageChannelName)
        AppGroupLog.write(String(
            format: "[Keyboard] Dictation AU instantiated out of process in %.2f s %@",
            Date().timeIntervalSince(started), KeyboardParakeet.memory().description
        ))
        return true
    }

    /// Nil when the AU is not connected or its process is gone; a gone process is dropped so
    /// the next call instantiates it again.
    private func send(_ command: DictationAUContract.Command, _ payload: [AnyHashable: Any] = [:]) -> [AnyHashable: Any]? {
        guard let channel else { return nil }
        var message = payload
        message[Key.command] = command.rawValue
        guard let reply = channel.callAudioUnit?(message), !reply.isEmpty else {
            AppGroupLog.write("[Keyboard] Dictation AU gave no answer to \(command.rawValue): process gone, dropping it")
            self.channel = nil
            audioUnit = nil
            return nil
        }
        return reply
    }

    private func instantiateAudioUnit() -> AVAudioUnit? {
        let description = DictationAUContract.componentDescription
        // Extension components are reported shortly after the first lookup. Without the
        // keyboard's `inter-app-audio` entitlement iOS never lists another target's AU.
        let discoveryDeadline = Date().addingTimeInterval(Self.componentDiscoveryTimeout)
        while AVAudioUnitComponentManager.shared().components(matching: description).isEmpty {
            guard Date() < discoveryDeadline else {
                AppGroupLog.write("[Keyboard] Dictation AU component not found (inter-app-audio entitlement? AU embedded?)")
                return nil
            }
            Thread.sleep(forTimeInterval: Self.componentDiscoveryPollInterval)
        }

        let instantiated = DispatchSemaphore(value: 0)
        let box = AudioUnitBox()
        AVAudioUnit.instantiate(with: description, options: [.loadOutOfProcess]) { unit, error in
            box.unit = unit
            box.error = error
            instantiated.signal()
        }
        guard instantiated.wait(timeout: .now() + Self.instantiationTimeout) == .success else {
            AppGroupLog.write("[Keyboard] Dictation AU instantiation timed out after \(Int(Self.instantiationTimeout)) s")
            return nil
        }
        if box.unit == nil {
            AppGroupLog.write("[Keyboard] Dictation AU instantiation failed: \(box.error?.localizedDescription ?? "no unit")")
        }
        return box.unit
    }

    @discardableResult
    private func bumpGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        generation += 1
        return generation
    }

    private var currentGeneration: Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }
}

/// A transcribe request's deadline, which moves once the AU reaches S1-mini, and the
/// unformatted transcript to deliver if S1-mini runs out of time. Written by the poll loop,
/// read by the main-queue watchdog.
private final class TranscribeWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: Date
    private var fallback: String?

    init(deadline: Date) {
        self.deadline = deadline
    }

    func formatting(_ text: String, timeout: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        fallback = text
        deadline = Date().addingTimeInterval(timeout)
    }

    func read() -> (Date, String?) {
        lock.lock()
        defer { lock.unlock() }
        return (deadline, fallback)
    }
}

/// Carries `AVAudioUnit.instantiate`'s answer out of its callback.
private final class AudioUnitBox: @unchecked Sendable {
    var unit: AVAudioUnit?
    var error: Error?
}
