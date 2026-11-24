import AudioToolbox
import Darwin
import Foundation

// Adapted from KeyVox (`TranscriptionAUMessageChannel`, `TranscriptionAURestyle`, MIT). See NOTICE.

/// Answers the keyboard's `DictationAUContract` messages. Every answer is immediate: `format`
/// and `transcribe` start their work in the background and `poll` reads where it is. One
/// request at a time; a new one replaces the one before.
///
/// `format` (Parakeet turns, transcribed in the keyboard) never fails a Dictation: anything
/// but `formatted` tells the keyboard to deliver Parakeet's text. `transcribe` (every other
/// Speech Model) runs the Host's `TranscriptionPipeline` and has no text to fall back on when
/// the Speech Model fails; its S1-mini step falls back to the transcript like the Host's.
final class DictationAUMessageChannel: NSObject, AUMessageChannel {
    /// One per process: the AU can be instantiated again while the models stay loaded.
    static let shared = DictationAUMessageChannel()

    private typealias Key = DictationAUContract.Key
    private typealias Status = DictationAUContract.Status

    var callHostBlock: CallHostBlock?

    private let bridge = S1MiniBridge()
    private let speech = DictationAUSpeech.shared
    private let lock = NSLock()
    // Guarded by `lock`.
    private var requestID = ""
    private var status: Status = .unchanged
    private var resultText: String?
    private var reason = "no request"
    private var modelLoaded = false
    private var hasLoadedBefore = false

    private var memoryPressure: DispatchSourceMemoryPressure?

    private override init() {
        super.init()
        bridge.allowsGPU = true
        bridge.fallsBackToCPU = true
        bridge.logHandler = { line in AppGroupLog.write("[DictationAU] \(line)") }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data.contains(.critical) ? "critical" : "warning"
            AppGroupLog.write("[DictationAU] Memory pressure \(event): unloading \(DictationAUMemory.current())")
            self.unload(reason: "memory \(event)")
        }
        source.resume()
        memoryPressure = source
        AppGroupLog.write("[DictationAU] Channel ready in pid \(getpid()) \(DictationAUMemory.current())")
    }

    func callAudioUnit(_ message: [AnyHashable: Any]) -> [AnyHashable: Any] {
        guard let raw = message[Key.command] as? String,
              let command = DictationAUContract.Command(rawValue: raw) else { return [Key.accepted: false] }
        switch command {
        case .prewarm:
            let variant = (message[Key.variant] as? String).flatMap(SpeechModelCatalog.Variant.init(rawValue:))
            return [Key.accepted: prewarm(variant: variant)]
        case .format:
            guard let id = message[Key.requestID] as? String,
                  let text = message[Key.text] as? String else { return [Key.accepted: false] }
            startFormat(
                id: id,
                text: text,
                languageId: message[Key.languageId] as? String ?? FormattingConfiguration.automaticLanguageId,
                style: FormattingStyle(rawValue: message[Key.style] as? String ?? "") ?? .semiFormal,
                context: FormattingContext(rawValue: message[Key.context] as? String ?? "") ?? .general
            )
            return [Key.accepted: true]
        case .transcribe:
            guard let id = message[Key.requestID] as? String,
                  let relativePath = message[Key.wavPath] as? String,
                  let rawVariant = message[Key.variant] as? String,
                  let variant = SpeechModelCatalog.Variant(rawValue: rawVariant),
                  variant != .parakeet
            else { return [Key.accepted: false] }
            startTranscribe(
                id: id,
                relativePath: relativePath,
                variant: variant,
                storedLanguageId: message[Key.languageId] as? String ?? SpeechModelCatalog.Variant.automaticLanguageId,
                audioSeconds: message[Key.audioSeconds] as? Double ?? 0
            )
            return [Key.accepted: true]
        case .poll:
            return poll(id: message[Key.requestID] as? String ?? "")
        case .cancel:
            cancel()
            return [Key.accepted: true]
        case .unload:
            unload(reason: "keyboard went away")
            return [Key.accepted: true]
        }
    }

    // MARK: - S1-mini

    private var suite: UserDefaults? { UserDefaults(suiteName: FormattingConfiguration.appGroupID) }

    /// Why S1-mini cannot run in this process now, or nil.
    private func blockedReason() -> String? {
        let suite = suite
        let selected = suite?.string(forKey: FormattingConfiguration.modelKey) ?? FormattingModel.off.rawValue
        guard selected == FormattingModel.s1Mini.rawValue else { return "Formatting Model is \(selected)" }
        guard FormattingConfiguration.modelIsReady(suite: suite), FormattingConfiguration.modelPath != nil else {
            return "S1-mini not ready in the App Group"
        }
        return nil
    }

    /// Starts loading S1-mini when it is selected, and `variant` on the speech chain. True
    /// when either started. Also lets go of what the keyboard no longer uses: the Speech
    /// Model when `variant` is Parakeet (the keyboard switched to it), and S1-mini when it is
    /// no longer selected.
    private func prewarm(variant: SpeechModelCatalog.Variant?) -> Bool {
        var started = false
        if variant == .parakeet {
            speech.unloadAll(reason: "Parakeet selected")
        } else if let variant {
            AppGroupLog.write("[DictationAU] Prewarm \(variant.rawValue) \(DictationAUMemory.current())")
            speech.enqueue { [speech] in await speech.prewarm(variant) }
            started = true
        }
        return prewarmS1Mini() || started
    }

    private func prewarmS1Mini() -> Bool {
        if let reason = blockedReason() {
            AppGroupLog.write("[DictationAU] S1-mini prewarm skipped: \(reason)")
            unloadS1MiniIfIdle(reason: reason)
            return false
        }
        guard let path = FormattingConfiguration.modelPath else { return false }
        lock.lock()
        let loaded = modelLoaded
        let kind = hasLoadedBefore ? "reload" : "first load in this process"
        lock.unlock()
        if loaded {
            AppGroupLog.write("[DictationAU] Prewarm: S1-mini already loaded (warm) \(DictationAUMemory.current())")
            return true
        }
        let started = Date()
        AppGroupLog.write("[DictationAU] Prewarm: loading S1-mini (\(kind)) \(DictationAUMemory.current())")
        bridge.prewarmModel(atPath: path) { [weak self] ok in
            self?.markLoaded(ok)
            AppGroupLog.write(String(
                format: "[DictationAU] Prewarm %@ in %.2f s (%@) %@",
                ok ? "loaded" : "failed", Date().timeIntervalSince(started), kind, DictationAUMemory.current()
            ))
        }
        return true
    }

    /// S1-mini on `text`, as the Host's `FormattingManager.formatIfEligible` decides it.
    /// `.formatted` with the cleaned text, or `.unchanged` / `.failed` with the reason.
    private func runS1Mini(
        _ text: String, languageId: String, style: FormattingStyle, context: FormattingContext,
        willRun: () -> Void = {}
    ) async -> (Status, String?, String) {
        if let blocked = blockedReason() { return (.unchanged, nil, blocked) }
        if let ineligible = S1MiniFormatter.ineligibilityReason(text, languageId: languageId) {
            return (.unchanged, nil, ineligible)
        }
        guard let path = FormattingConfiguration.modelPath else { return (.unchanged, nil, "no App Group") }
        willRun()
        do {
            let formatted = try await S1MiniFormatter(bridge: bridge)
                .format(text, modelPath: path, style: style, context: context)
            markLoaded(true)
            return (.formatted, formatted, "")
        } catch {
            return (.failed, nil, error.localizedDescription)
        }
    }

    // MARK: - format

    private func startFormat(
        id: String, text: String, languageId: String, style: FormattingStyle, context: FormattingContext
    ) {
        begin(id)
        let wasLoaded = isModelLoaded
        AppGroupLog.write(
            "[DictationAU] Format \(id.prefix(8)): \(text.count) chars, language \(languageId), \(style.rawValue)/\(context.rawValue), S1-mini \(wasLoaded ? "warm" : "cold") \(DictationAUMemory.current())"
        )
        let started = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let outcome = await self.runS1Mini(text, languageId: languageId, style: style, context: context)
            self.finish(id: id, status: outcome.0, text: outcome.1, reason: outcome.2)
            AppGroupLog.write(String(
                format: "[DictationAU] Format %@ %@ in %.2f s%@ %@",
                String(id.prefix(8)), outcome.0.rawValue, Date().timeIntervalSince(started),
                outcome.2.isEmpty ? "" : " (\(outcome.2))", DictationAUMemory.current()
            ))
        }
    }

    // MARK: - transcribe

    private func startTranscribe(
        id: String, relativePath: String, variant: SpeechModelCatalog.Variant,
        storedLanguageId: String, audioSeconds: Double
    ) {
        begin(id)
        AppGroupLog.write(String(
            format: "[DictationAU] Transcribe %@: %@, %.1f s of audio, language %@ %@",
            String(id.prefix(8)), variant.rawValue, audioSeconds, storedLanguageId, DictationAUMemory.current()
        ))
        guard let wavPath = Self.recordingPath(relativePath) else {
            finish(id: id, status: .failed, text: nil, reason: "the recording is not in KeyboardRecordings/")
            return
        }
        let received = Date()
        speech.enqueue { [weak self] in
            guard let self, self.isCurrent(id) else { return }
            let started = Date()
            let outcome = await self.transcribe(id: id, wavPath: wavPath, variant: variant, storedLanguageId: storedLanguageId)
            self.finish(id: id, status: outcome.0, text: outcome.1, reason: outcome.2)
            AppGroupLog.write(String(
                format: "[DictationAU] Transcribe %@ %@ in %.2f s (%.2f s queued)%@ %@",
                String(id.prefix(8)), outcome.0.rawValue, Date().timeIntervalSince(started),
                started.timeIntervalSince(received), outcome.2.isEmpty ? "" : " (\(outcome.2))",
                DictationAUMemory.current()
            ))
        }
    }

    /// The Host's pipeline in this process. On the speech chain.
    private func transcribe(
        id: String, wavPath: String, variant: SpeechModelCatalog.Variant, storedLanguageId: String
    ) async -> (Status, String?, String) {
        // A recording that cannot be read is no Metal fault; never let it reach an engine.
        guard DictationAUSpeech.audioSeconds(wavPath) != nil else {
            return (.failed, nil, "could not read the recording")
        }
        let suite = suite
        let pipeline = TranscriptionPipeline(
            readiness: DictationAUSpeech.readiness,
            engine: { [speech] in speech.engine(for: $0) },
            punctuation: speech.punctuation,
            format: { [weak self] text, languageId in
                guard let self else { return text }
                let style = FormattingStyle(rawValue: suite?.string(forKey: FormattingConfiguration.styleKey) ?? "") ?? .semiFormal
                let context = FormattingContext(rawValue: suite?.string(forKey: FormattingConfiguration.contextKey) ?? "") ?? .general
                let started = Date()
                var ran = false
                let outcome = await self.runS1Mini(text, languageId: languageId, style: style, context: context) {
                    ran = true
                    self.markFormatting(id: id, text: text)
                    AppGroupLog.write(
                        "[DictationAU] Transcribe \(id.prefix(8)): S1-mini formatting \(text.count) chars, \(style.rawValue)/\(context.rawValue)"
                    )
                }
                guard outcome.0 == .formatted, let formatted = outcome.1 else {
                    AppGroupLog.write(String(
                        format: "[DictationAU] Transcribe %@: S1-mini %@ (%@)%@; delivering the transcript",
                        String(id.prefix(8)), outcome.0.rawValue, outcome.2,
                        ran ? String(format: " after %.2f s", Date().timeIntervalSince(started)) : ""
                    ))
                    return text
                }
                AppGroupLog.write(String(
                    format: "[DictationAU] Transcribe %@: S1-mini formatted %d -> %d chars in %.2f s",
                    String(id.prefix(8)), text.count, formatted.count, Date().timeIntervalSince(started)
                ))
                return formatted
            }
        )

        let languageId: String
        switch pipeline.admit(variant: variant, storedLanguageId: storedLanguageId) {
        case .blocked(let readiness):
            return (.blocked, nil, readiness.message ?? "Dictation cannot start right now.")
        case .run(let resolved):
            languageId = resolved
        }
        if speech.punctuation == nil, variant.engine == .ekko {
            AppGroupLog.write("[DictationAU] No App Group: ekko's Punctuation Restoration is skipped")
        }
        switch await pipeline.transcribe(wavPath: wavPath, variant: variant, languageId: languageId) {
        case .text(let text):
            return (.transcribed, text, "")
        case .noSpeech:
            return (.transcribed, "", "no speech")
        case .failed(let error) where error is TranscriptionEngineError:
            // The engine heard no words; the Host reports it as a benign failure.
            return (.transcribed, "", "no speech")
        case .failed(let error):
            return (.failed, nil, error.localizedDescription)
        }
    }

    /// `relativePath` inside the App Group's `KeyboardRecordings/`, or nil when it points
    /// anywhere else.
    private static func recordingPath(_ relativePath: String) -> String? {
        guard let container = SpeechModelCatalog.containerURL else { return nil }
        let recordings = container.appendingPathComponent("KeyboardRecordings", isDirectory: true)
            .standardizedFileURL.path + "/"
        let path = container.appendingPathComponent(relativePath).standardizedFileURL.path
        return path.hasPrefix(recordings) ? path : nil
    }

    // MARK: - Request state

    private var isModelLoaded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return modelLoaded
    }

    /// A new request replaces the one before; S1-mini abandons any generation it is running.
    private func begin(_ id: String) {
        bridge.cancelPending()
        lock.lock()
        requestID = id
        status = .pending
        resultText = nil
        reason = ""
        lock.unlock()
    }

    private func isCurrent(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestID == id && (status == .pending || status == .formatting)
    }

    private func markFormatting(id: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard requestID == id, status == .pending else { return }
        status = .formatting
        resultText = text
    }

    /// Settles `id` unless it was replaced or cancelled meanwhile.
    private func finish(id: String, status: Status, text: String?, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard requestID == id, self.status == .pending || self.status == .formatting else { return }
        self.status = status
        resultText = text
        self.reason = reason
    }

    private func poll(id: String) -> [AnyHashable: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard id == requestID else {
            return [Key.status: Status.failed.rawValue, Key.reason: "unknown request (AU process restarted?)"]
        }
        var reply: [AnyHashable: Any] = [Key.status: status.rawValue]
        if let resultText { reply[Key.text] = resultText }
        if !reason.isEmpty { reply[Key.reason] = reason }
        return reply
    }

    private func cancel() {
        bridge.cancelPending()
        lock.lock()
        if status == .pending || status == .formatting {
            status = .failed
            resultText = nil
            reason = "cancelled"
        }
        lock.unlock()
    }

    /// Frees S1-mini when it is loaded and no request is using it.
    private func unloadS1MiniIfIdle(reason: String) {
        lock.lock()
        let busy = status == .pending || status == .formatting
        let loaded = modelLoaded
        lock.unlock()
        guard loaded, !busy else { return }
        bridge.unloadModel()
        markLoaded(false)
        AppGroupLog.write("[DictationAU] S1-mini unloaded (\(reason)) \(DictationAUMemory.current())")
    }

    private func unload(reason: String) {
        cancel()
        bridge.unloadModel()
        markLoaded(false)
        speech.unloadAll(reason: reason)
        AppGroupLog.write("[DictationAU] S1-mini unloaded (\(reason)) \(DictationAUMemory.current())")
    }

    private func markLoaded(_ loaded: Bool) {
        lock.lock()
        modelLoaded = loaded
        if loaded { hasLoadedBefore = true }
        lock.unlock()
    }
}

/// This process's memory, for the logs.
enum DictationAUMemory {
    static func current() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let available = os_proc_available_memory()
        let megabyte = 1_048_576.0
        guard result == KERN_SUCCESS else {
            return String(format: "[footprint ?, available %.1f MB]", Double(available) / megabyte)
        }
        let footprint = Double(info.phys_footprint) / megabyte
        // `available` 0: iOS sets this process no limit.
        return String(
            format: "[footprint %.1f MB, available %.1f MB, limit %@]",
            footprint, Double(available) / megabyte,
            available > 0 ? String(format: "%.0f MB", footprint + Double(available) / megabyte) : "none"
        )
    }
}
