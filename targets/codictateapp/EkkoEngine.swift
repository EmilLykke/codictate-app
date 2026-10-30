import Foundation

/// The Danish ekko Speech Model (RyeAI ekko-v1-tiny, q5_0) on parakeet.cpp. A port of
/// desktop's ekko Speech Engine Adapter (codictate `ekko-engine.ts`), in-process through
/// EkkoBridge instead of one `parakeet-cli` per slice.
///
/// Codictate cuts the recording itself (`AudioSlicer` with `.ekko`, as desktop does) and
/// transcribes slice by slice, in order, one at a time: never the whole recording in one call,
/// since the model's memory grows with the square of the audio's length. The result is the Raw
/// Transcript, lowercase and unpunctuated, exactly what ekko said; Punctuation Restoration
/// runs after the engine. A silent recording returns "".
///
/// The model is loaded once and held, like CohereEngine's. `warmUp()` or `preload(modelPath:)`
/// loads it ahead of a Dictation turn, for example while the user speaks; a `transcribe()` that
/// arrives meanwhile waits for that load instead of starting another.
final class EkkoEngine: TranscriptionEngine {

    /// ekko is Danish only and parakeet.cpp takes no language for it, so the language is
    /// pinned here for callers and never passed on.
    static let pinnedLanguageId = "da"

    private static let sampleRate = 16_000

    /// Resolves the ekko GGUF on disk, downloading it if the caller does that.
    typealias ModelPathProvider = () async throws -> String

    private let modelPath: ModelPathProvider
    private let bridge = EkkoBridge()
    /// Every load, transcription and unload runs here, one at a time and in arrival order.
    private let queue = DispatchQueue(label: "com.codictate.ekko", qos: .userInitiated)

    init(modelPath: @escaping ModelPathProvider) {
        self.modelPath = modelPath
    }

    /// `languageId` is ignored: the Language Lock pins ekko to Danish before a turn starts.
    func transcribe(wavPath: String, languageId: String) async throws -> String {
        let started = Date()
        let path = try await modelPath()
        let samples = try Self.readSamples(wavPath: wavPath)
        let slices = try samples.withUnsafeBufferPointer {
            try AudioSlicer.plan(samples: $0, sampleRate: Self.sampleRate, options: .ekko)
        }
        guard !slices.isEmpty else {
            NSLog("[EkkoEngine] No speech detected (0 slices)")
            return ""
        }

        var texts: [String] = []
        for slice in slices {
            try Task.checkCancellation()
            let pcm = Self.pcm16RoundTrip(samples, slice)
            let text = try await onQueue { [bridge] in
                try bridge.loadModel(atPath: path)
                return try pcm.withUnsafeBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return "" }
                    return try bridge.transcribe(
                        samples: base, count: buffer.count, sampleRate: Self.sampleRate)
                }
            }
            texts.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let transcript = Self.joinSliceTexts(texts)
        NSLog("[EkkoEngine] Transcribed \(slices.count) slices in \(String(format: "%.2f", Date().timeIntervalSince(started)))s, \(transcript.count) characters")
        return transcript
    }

    func warmUp() async throws {
        try await preload(modelPath: modelPath())
    }

    /// Loads the GGUF at `modelPath` and holds it. A no-op when it is already loaded.
    func preload(modelPath: String) async throws {
        let started = Date()
        let loaded = try await onQueue { [bridge] () -> Bool in
            if bridge.isLoaded && bridge.loadedModelPath == modelPath { return false }
            try bridge.loadModel(atPath: modelPath)
            return true
        }
        if loaded {
            NSLog("[EkkoEngine] Model loaded in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        }
    }

    /// Releases the model, after any transcription already queued. The next turn loads it again.
    func unload() {
        queue.async { [bridge] in bridge.unloadModel() }
    }

    // MARK: - Private

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private static func readSamples(wavPath: String) throws -> [Float] {
        let data = try EkkoBridge.readWavAsPCMF32(atPath: wavPath)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// The slice as desktop hands it to `parakeet-cli`: written as 16-bit PCM (`pcm16MonoWav`,
    /// which scales by 0x8000 below zero and 0x7fff above, rounding like `Math.round`) and read
    /// back by dr_wav as `int16 / 32768`. So ekko hears exactly what desktop's benchmark measured.
    private static func pcm16RoundTrip(_ samples: [Float], _ slice: AudioSlicer.Slice) -> [Float] {
        var out = [Float](repeating: 0, count: max(0, slice.endSample - slice.startSample))
        for i in out.indices {
            let s = max(-1, min(1, Double(samples[slice.startSample + i])))
            let scaled = s < 0 ? s * 32768 : s * 32767
            let down = scaled.rounded(.down)
            let quantised = scaled - down >= 0.5 ? down + 1 : down
            out[i] = Float(Int16(quantised)) * (1 / 32768)
        }
        return out
    }

    /// Desktop's `joinTranscriptPieces(texts, { separateDecodes: true })` for trimmed slice
    /// texts: empty ones dropped, one space between the rest. Desktop's exception for scripts
    /// written without spaces (Han, kana, Thai...) never applies: ekko writes only Danish.
    /// `<unk>` needs nothing here: parakeet.cpp drops special pieces from the text it returns,
    /// and desktop strips `<unk>` only from per-word timings, which iOS does not use.
    static func joinSliceTexts(_ texts: [String]) -> String {
        texts.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
