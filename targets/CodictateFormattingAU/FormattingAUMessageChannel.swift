import AudioToolbox
import Darwin
import Foundation

// Adapted from KeyVox (`TranscriptionAUMessageChannel`, `TranscriptionAURestyle`, MIT). See NOTICE.

/// Answers the keyboard's `FormattingAUContract` messages. Every answer is immediate: a
/// `format` starts S1-mini in the background and `poll` reads where it is. One request at a
/// time; a new one replaces the one running. Formatting never fails a Dictation: anything
/// but `formatted` tells the keyboard to deliver Parakeet's text.
final class FormattingAUMessageChannel: NSObject, AUMessageChannel {
    /// One per process: the AU can be instantiated again while the model stays loaded.
    static let shared = FormattingAUMessageChannel()

    private typealias Key = FormattingAUContract.Key
    private typealias Status = FormattingAUContract.Status

    var callHostBlock: CallHostBlock?

    private let bridge = S1MiniBridge()
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
        bridge.logHandler = { line in AppGroupLog.write("[FormattingAU] \(line)") }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data.contains(.critical) ? "critical" : "warning"
            AppGroupLog.write("[FormattingAU] Memory pressure \(event): unloading \(FormattingAUMemory.current())")
            self.unload()
        }
        source.resume()
        memoryPressure = source
        AppGroupLog.write("[FormattingAU] Channel ready in pid \(getpid()) \(FormattingAUMemory.current())")
    }

    func callAudioUnit(_ message: [AnyHashable: Any]) -> [AnyHashable: Any] {
        guard let raw = message[Key.command] as? String,
              let command = FormattingAUContract.Command(rawValue: raw) else { return [Key.accepted: false] }
        switch command {
        case .prewarm:
            return [Key.accepted: prewarm()]
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
        case .poll:
            return poll(id: message[Key.requestID] as? String ?? "")
        case .cancel:
            cancel()
            return [Key.accepted: true]
        case .unload:
            unload()
            return [Key.accepted: true]
        }
    }

    // MARK: - Commands

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

    private func prewarm() -> Bool {
        if let reason = blockedReason() {
            AppGroupLog.write("[FormattingAU] Prewarm skipped: \(reason)")
            return false
        }
        guard let path = FormattingConfiguration.modelPath else { return false }
        lock.lock()
        let loaded = modelLoaded
        let kind = hasLoadedBefore ? "reload" : "first load in this process"
        lock.unlock()
        if loaded {
            AppGroupLog.write("[FormattingAU] Prewarm: S1-mini already loaded (warm) \(FormattingAUMemory.current())")
            return true
        }
        let started = Date()
        AppGroupLog.write("[FormattingAU] Prewarm: loading S1-mini (\(kind)) \(FormattingAUMemory.current())")
        bridge.prewarmModel(atPath: path) { [weak self] ok in
            self?.markLoaded(ok)
            AppGroupLog.write(String(
                format: "[FormattingAU] Prewarm %@ in %.2f s (%@) %@",
                ok ? "loaded" : "failed", Date().timeIntervalSince(started), kind, FormattingAUMemory.current()
            ))
        }
        return true
    }

    private func startFormat(
        id: String, text: String, languageId: String, style: FormattingStyle, context: FormattingContext
    ) {
        bridge.cancelPending()
        lock.lock()
        requestID = id
        status = .pending
        resultText = nil
        reason = ""
        let wasLoaded = modelLoaded
        lock.unlock()

        AppGroupLog.write(
            "[FormattingAU] Format \(id.prefix(8)): \(text.count) chars, language \(languageId), \(style.rawValue)/\(context.rawValue), model \(wasLoaded ? "warm" : "cold") \(FormattingAUMemory.current())"
        )
        let started = Date()
        Task.detached(priority: .userInitiated) { [weak self, bridge] in
            let outcome: (Status, String?, String)
            if let blocked = self?.blockedReason() {
                outcome = (.unchanged, nil, blocked)
            } else if let ineligible = S1MiniFormatter.ineligibilityReason(text, languageId: languageId) {
                outcome = (.unchanged, nil, ineligible)
            } else if let path = FormattingConfiguration.modelPath {
                do {
                    let formatted = try await S1MiniFormatter(bridge: bridge)
                        .format(text, modelPath: path, style: style, context: context)
                    outcome = (.formatted, formatted, "")
                } catch {
                    outcome = (.failed, nil, error.localizedDescription)
                }
            } else {
                outcome = (.unchanged, nil, "no App Group")
            }
            let seconds = Date().timeIntervalSince(started)
            guard let self else { return }
            if outcome.0 == .formatted { self.markLoaded(true) }
            self.finish(id: id, status: outcome.0, text: outcome.1, reason: outcome.2)
            AppGroupLog.write(String(
                format: "[FormattingAU] Format %@ %@ in %.2f s%@ %@",
                String(id.prefix(8)), outcome.0.rawValue, seconds,
                outcome.2.isEmpty ? "" : " (\(outcome.2))", FormattingAUMemory.current()
            ))
        }
    }

    private func finish(id: String, status: Status, text: String?, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard requestID == id else { return }
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
        if status == .pending {
            status = .failed
            reason = "cancelled"
        }
        lock.unlock()
    }

    private func unload() {
        cancel()
        bridge.unloadModel()
        markLoaded(false)
        AppGroupLog.write("[FormattingAU] S1-mini unloaded \(FormattingAUMemory.current())")
    }

    private func markLoaded(_ loaded: Bool) {
        lock.lock()
        modelLoaded = loaded
        if loaded { hasLoadedBefore = true }
        lock.unlock()
    }
}

/// This process's memory, for the logs.
enum FormattingAUMemory {
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
