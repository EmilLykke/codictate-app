import AVFoundation
import AudioToolbox
import Foundation

// Adapted from KeyVox (`KeyboardTranscriptionAUClient`, MIT). See NOTICE.

/// Hosts the Formatting AU (`CodictateFormattingAU`) out of process, so an In-keyboard
/// dictation gets S1-mini without the Host. S1-mini cannot run in the keyboard, whose memory
/// limit is far below the model; the AU's process has no such ceiling.
///
/// Every exchange waits for the AU's answer, so the client works on its own queue and
/// reports on the main queue. Formatting never fails a Dictation: every fault, the timeout
/// included, hands back the original text.
final class KeyboardFormattingAUClient: @unchecked Sendable {
    static let shared = KeyboardFormattingAUClient()

    enum Result {
        /// S1-mini's text; empty is a successful cleanup with no output.
        case formatted(String)
        /// Deliver the original text.
        case original(reason: String)
    }

    private typealias Key = FormattingAUContract.Key
    private typealias Status = FormattingAUContract.Status

    private static let componentDiscoveryTimeout: TimeInterval = 2
    private static let componentDiscoveryPollInterval: TimeInterval = 0.02
    private static let instantiationTimeout: TimeInterval = 10
    private static let pollInterval: TimeInterval = 0.05

    private let queue = DispatchQueue(label: "app.codictate.keyboard.formatting-au", qos: .userInitiated)
    // Both only on `queue`.
    private var audioUnit: AVAudioUnit?
    private var channel: (any AUMessageChannel)?

    /// Bumped by every format, cancel and disconnect, so a stale poll loop stops.
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

    /// How long a format may take before Parakeet's text goes in instead: 8 s, plus time for
    /// a long dictation, whose output S1-mini generates token by token.
    static func timeout(for text: String) -> TimeInterval {
        min(30, 8 + Double(max(0, text.count - 200)) / 40)
    }

    /// Starts the AU if it is not running and has it load S1-mini, while the user speaks.
    func prewarm() {
        queue.async { [self] in
            guard connect() else { return }
            let accepted = send(.prewarm)?[Key.accepted] as? Bool ?? false
            AppGroupLog.write("[Keyboard] Formatting AU prewarm \(accepted ? "accepted" : "refused or no answer")")
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
                    format: "[Keyboard] Formatting AU formatted %d -> %d chars in %.2f s",
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

    /// Abandons the running format.
    func cancel() {
        bumpGeneration()
        queue.async { [self] in _ = send(.cancel) }
    }

    /// The keyboard is going away: the AU frees S1-mini and the keyboard lets go of it.
    func disconnect() {
        bumpGeneration()
        queue.async { [self] in
            guard channel != nil else { return }
            _ = send(.unload)
            channel = nil
            audioUnit = nil
            AppGroupLog.write("[Keyboard] Formatting AU released")
        }
    }

    // MARK: - Queue only

    private func performFormat(
        requestID: String, text: String, languageId: String, style: String?, context: String?,
        turn: Int, deadline: Date
    ) -> Result {
        guard connect() else { return .original(reason: "Formatting AU unavailable") }
        var message: [AnyHashable: Any] = [
            Key.requestID: requestID, Key.text: text, Key.languageId: languageId,
        ]
        if let style { message[Key.style] = style }
        if let context { message[Key.context] = context }
        guard let started = send(.format, message) else { return .original(reason: "Formatting AU process gone") }
        guard started[Key.accepted] as? Bool == true else { return .original(reason: "Formatting AU refused the request") }

        while Date() < deadline {
            guard currentGeneration == turn else { return .original(reason: "cancelled") }
            guard let reply = send(.poll, [Key.requestID: requestID]) else {
                return .original(reason: "Formatting AU process gone while formatting")
            }
            let status = Status(rawValue: reply[Key.status] as? String ?? "") ?? .failed
            let reason = reply[Key.reason] as? String ?? status.rawValue
            switch status {
            case .pending:
                Thread.sleep(forTimeInterval: Self.pollInterval)
            case .formatted:
                guard let output = reply[Key.text] as? String else { return .original(reason: "no text in reply") }
                return .formatted(output)
            case .unchanged:
                return .original(reason: "not formatted: \(reason)")
            case .failed:
                return .original(reason: "S1-mini failed: \(reason)")
            }
        }
        _ = send(.cancel)
        return .original(reason: "timed out")
    }

    private func connect() -> Bool {
        if channel != nil { return true }
        let started = Date()
        guard let unit = instantiateAudioUnit() else { return false }
        audioUnit = unit
        channel = unit.auAudioUnit.messageChannel(for: FormattingAUContract.messageChannelName)
        AppGroupLog.write(String(
            format: "[Keyboard] Formatting AU instantiated out of process in %.2f s %@",
            Date().timeIntervalSince(started), KeyboardParakeet.memory().description
        ))
        return true
    }

    /// Nil when the AU is not connected or its process is gone; a gone process is dropped so
    /// the next call instantiates it again.
    private func send(_ command: FormattingAUContract.Command, _ payload: [AnyHashable: Any] = [:]) -> [AnyHashable: Any]? {
        guard let channel else { return nil }
        var message = payload
        message[Key.command] = command.rawValue
        guard let reply = channel.callAudioUnit?(message), !reply.isEmpty else {
            AppGroupLog.write("[Keyboard] Formatting AU gave no answer to \(command.rawValue): process gone, dropping it")
            self.channel = nil
            audioUnit = nil
            return nil
        }
        return reply
    }

    private func instantiateAudioUnit() -> AVAudioUnit? {
        let description = FormattingAUContract.componentDescription
        // Extension components are reported shortly after the first lookup. Without the
        // keyboard's `inter-app-audio` entitlement iOS never lists another target's AU.
        let discoveryDeadline = Date().addingTimeInterval(Self.componentDiscoveryTimeout)
        while AVAudioUnitComponentManager.shared().components(matching: description).isEmpty {
            guard Date() < discoveryDeadline else {
                AppGroupLog.write("[Keyboard] Formatting AU component not found (inter-app-audio entitlement? AU embedded?)")
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
            AppGroupLog.write("[Keyboard] Formatting AU instantiation timed out after \(Int(Self.instantiationTimeout)) s")
            return nil
        }
        if box.unit == nil {
            AppGroupLog.write("[Keyboard] Formatting AU instantiation failed: \(box.error?.localizedDescription ?? "no unit")")
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

/// Carries `AVAudioUnit.instantiate`'s answer out of its callback.
private final class AudioUnitBox: @unchecked Sendable {
    var unit: AVAudioUnit?
    var error: Error?
}
