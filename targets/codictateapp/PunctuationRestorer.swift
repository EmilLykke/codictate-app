import Foundation

/// The Punctuation Restorer: Punctuation Restoration for a Raw Transcript, with ekko-pnc.
/// Port of desktop `src/bun/utils/punctuation/punctuation-restorer.ts`.
///
/// One call, `restore(_:)`, gives back the text with punctuation and capitals added. It
/// never throws: whatever goes wrong (the Punctuation Model fails to load, a model run
/// fails, the result would not have the same words, or it takes too long), the caller gets
/// its input back unchanged, and the cause is logged. A Dictation must never be lost to a
/// punctuation fault.
///
/// Inside it, in order:
///
/// - **The strip step** removes the marks a Speech Engine already put at word ends.
/// - **The port** of the Python reference (`EkkoPnc`), byte-identical to
///   `ekko-stt[pnc]==0.1.2`'s `Punctuator.__call__` on the same weights.
///
/// The Punctuation Model is loaded on the first call (or `warmUp()`) and kept for the life
/// of the restorer; a failed load is tried again on the next call. Every load and model
/// run happens on one serial queue, so the restorer is safe to call from any thread and
/// never loads twice.
final class PunctuationRestorer: @unchecked Sendable {

    struct Result: Equatable {
        /// The punctuated text, or the input unchanged when `restored` is false.
        let text: String
        let restored: Bool
    }

    /// A call gives up after `max(10 s, 100 ms × model runs)`, measured from when it was
    /// made. Desktop measured a model run at 3 to 8 ms and the load at about 250 ms, so only
    /// something stuck gets near it. A run already inside ONNX Runtime cannot be stopped:
    /// it finishes on the queue and its result is dropped.
    private static let timeout: TimeInterval = 10
    private static let timeoutPerWindow: TimeInterval = 0.1

    private let loadModel: () throws -> PunctuationModel
    private let keepExistingPunctuation: Bool
    private let queue = DispatchQueue(label: "com.codictate.punctuation", qos: .userInitiated)
    /// Only touched on `queue`.
    private var model: PunctuationModel?

    /// The restorer for the ekko-pnc weights in `modelDirectory` (`pnc.int8.onnx`,
    /// `tokenizer.json`, `config.json`). Creating it loads nothing.
    convenience init(modelDirectory: String) {
        self.init(loadModel: { try EkkoPncModel(directory: modelDirectory) })
    }

    /// `keepExistingPunctuation` hands the text to the port with its existing marks, as the
    /// Python `__call__` sees it. Only for the parity check against the Python reference;
    /// the app always strips.
    init(keepExistingPunctuation: Bool = false, loadModel: @escaping () throws -> PunctuationModel) {
        self.keepExistingPunctuation = keepExistingPunctuation
        self.loadModel = loadModel
    }

    /// Punctuate a Raw Transcript. Never fails: on any fault, the input comes back as is.
    func restore(_ rawTranscript: String) async -> String {
        await restoreReportingResult(rawTranscript).text
    }

    /// `restore(_:)`, saying whether the text was punctuated.
    func restoreReportingResult(_ text: String) async -> Result {
        let words = PythonText.split(text)
        let input = keepExistingPunctuation ? words : words.map(Self.stripWordEndMarks)
        // `" ".join([])`: what the Python reference gives for a text with no words.
        if input.isEmpty { return Result(text: "", restored: true) }

        let call = Call(startedAt: DispatchTime.now(), text: text, wordCount: words.count)
        return await withCheckedContinuation { continuation in
            call.begin(continuation)
            queue.async { [self] in
                do {
                    let model = try loadedModel()
                    let windows = try EkkoPnc.planWindows(model, input)
                    call.giveUp(after: max(Self.timeout, Self.timeoutPerWindow * Double(windows.count)))
                    let punctuated = try EkkoPnc.punctuateWords(model, input, windows)
                        .joined(separator: " ")
                    let outputWords = PythonText.split(punctuated).count
                    guard outputWords == words.count else {
                        throw PunctuationError(
                            "Punctuation changed the word count: \(words.count) -> \(outputWords)"
                        )
                    }
                    call.finish(Result(text: punctuated, restored: true))
                } catch {
                    call.finish(Result(text: text, restored: false), cause: "\(error)")
                }
            }
        }
    }

    /// Load the Punctuation Model ahead of the first call, for a background warm-up.
    /// Returns once the load has finished or failed; never throws.
    func warmUp() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                do {
                    _ = try loadedModel()
                } catch {
                    NSLog("[PunctuationRestorer] Punctuation Model failed to load: %@", "\(error)")
                }
                continuation.resume()
            }
        }
    }

    // MARK: - Private

    /// On `queue` only.
    private func loadedModel() throws -> PunctuationModel {
        if let model { return model }
        let loaded = try loadModel()
        model = loaded
        return loaded
    }

    /// The strip step: drop the `,` `.` `?` `!` a Speech Engine already put at the end of a
    /// word (`dig,` -> `dig`, `f.eks.` -> `f.eks`; `3,5` keeps its inner comma). The Python
    /// reference keeps existing marks and adds its own, which gives `,,`, `,?` and
    /// `f.eks..` on hviske's output. A word made only of marks is left whole: emptying it
    /// would change the word count. A no-op for ekko, whose Raw Transcript has no marks.
    private static func stripWordEndMarks(_ word: String) -> String {
        var scalars = Array(word.unicodeScalars)
        while let last = scalars.last, last == "," || last == "." || last == "?" || last == "!" {
            scalars.removeLast()
        }
        return scalars.isEmpty ? word : String(String.UnicodeScalarView(scalars))
    }

    /// One `restore` call: settles exactly once, with the result or with the timeout.
    private final class Call: @unchecked Sendable {
        private let lock = NSLock()
        private let startedAt: DispatchTime
        private let text: String
        private let wordCount: Int
        private var continuation: CheckedContinuation<Result, Never>?
        private var settled = false
        private var timer: DispatchSourceTimer?

        init(startedAt: DispatchTime, text: String, wordCount: Int) {
            self.startedAt = startedAt
            self.text = text
            self.wordCount = wordCount
        }

        func begin(_ continuation: CheckedContinuation<Result, Never>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            giveUp(after: PunctuationRestorer.timeout)
        }

        /// (Re)arm the timeout at `budget` seconds after the call was made. A timer source
        /// with a tight leeway: `asyncAfter` lets GCD fire up to about 10% late.
        func giveUp(after budget: TimeInterval) {
            let source = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            source.setEventHandler { [self] in
                finish(
                    Result(text: text, restored: false),
                    cause: "timed out after \(Int(budget * 1000)) ms"
                )
            }
            source.schedule(deadline: startedAt + budget, leeway: .milliseconds(10))
            lock.lock()
            if settled {
                lock.unlock()
                return
            }
            timer?.cancel()
            timer = source
            lock.unlock()
            source.resume()
        }

        func finish(_ result: Result, cause: String? = nil) {
            lock.lock()
            guard !settled, let continuation else {
                lock.unlock()
                return
            }
            settled = true
            timer?.cancel()
            timer = nil
            self.continuation = nil
            lock.unlock()
            if let cause {
                NSLog(
                    "[PunctuationRestorer] Punctuation Restoration failed, kept the text as is: %@ (words: %ld)",
                    cause, wordCount
                )
            }
            continuation.resume(returning: result)
        }
    }
}
