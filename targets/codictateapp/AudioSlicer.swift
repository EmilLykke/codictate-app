import Foundation

/// Where Codictate cuts a recording before the ekko Speech Model sees it. A Swift port of
/// desktop's `planVadSlices` (codictate `src/bun/utils/whisper/engines/vad-slices.ts`), loudness
/// path only: iOS has no Silero pass, so speech always comes from loudness. Pure: samples in,
/// slices out. Keep it in step with desktop; the slice boundaries must match it sample for sample.
///
/// The plan is WhisperX's cut-and-merge with faster-whisper's split rule:
/// 1. Loudness in 10 ms frames finds the pauses: a frame is silent when it is within a few dB
///    of the recording's own noise floor (with `pauseBelowSpeechDb`, ekko's only, also when it
///    is that far under the recording's speech level).
/// 2. Speech is the runs of loud frames with pauses shorter than `minPauseMs` bridged.
/// 3. Neighbouring speech is merged into slices. A pause up to `maxMergeGapMs` can stay in a
///    slice; a longer one always ends it. Speech that fits under the cap is one slice.
/// 4. Speech that does not fit is cut in the back half of the cap, at the longest pause there
///    (a gap between speech runs or a pause inside one; the later of two equal ones), else at
///    the centre of the quietest 100 ms.
/// 5. Slices with too little speech are dropped, and each slice keeps `padMs` of real audio on
///    both sides, never overlapping a neighbour and never past the cap.
enum AudioSlicer {

    /// Sample offsets at the audio's own rate. `endSample` is exclusive.
    struct Slice: Equatable {
        let startSample: Int
        let endSample: Int
    }

    struct Options {
        /// No slice is longer than this, padding included.
        var maxSliceSeconds: Double = 30
        /// The shortest silence that counts as a pause.
        var minPauseMs: Double = 98
        /// Real audio kept on each side of a slice, where there is room for it.
        var padMs: Double = 200
        /// A slice with less speech than this is dropped (a click, a cough).
        var minSpeechMs: Double = 250
        /// A pause longer than this always ends a slice; up to this it can stay inside one.
        var maxMergeGapMs: Double = 1500
        /// When set, a frame this many dB or more under the recording's speech level (the 90th
        /// percentile of its frame levels) is silent too, however far it is above the noise floor.
        var pauseBelowSpeechDb: Double?

        /// Desktop's `DEFAULT_VAD_SLICE_OPTIONS`.
        static let defaults = Options()

        /// Desktop's defaults with `EKKO_VAD_SLICE_OPTIONS` on top: room noise 35 dB or more
        /// under the speech is a pause, so a long noisy pause between sentences ends a slice.
        /// ekko-v1-tiny drops the first words of a sentence that follows a long pause inside one
        /// slice (desktop #108).
        static let ekko: Options = {
            var options = Options()
            options.pauseBelowSpeechDb = 35
            return options
        }()
    }

    enum PlanError: Error, LocalizedError {
        case invalidParameters(sampleRate: Int, maxSliceSeconds: Double)

        var errorDescription: String? {
            switch self {
            case let .invalidParameters(sampleRate, maxSliceSeconds):
                return "cannot plan slices at \(sampleRate) Hz with a \(maxSliceSeconds) s cap"
            }
        }
    }

    /// Plans the slices. Returns `[]` when there is no speech to decode.
    static func plan(
        samples: UnsafeBufferPointer<Float>,
        sampleRate: Int,
        options: Options = .defaults
    ) throws -> [Slice] {
        guard sampleRate > 0, options.maxSliceSeconds > 0 else {
            throw PlanError.invalidParameters(
                sampleRate: sampleRate, maxSliceSeconds: options.maxSliceSeconds)
        }
        guard let loudness = frameLoudness(
            samples, sampleRate: sampleRate, pauseBelowSpeechDb: options.pauseBelowSpeechDb
        ) else { return [] }

        let rate = Double(sampleRate)
        let toSamples = { (ms: Double) in max(0, jsRound((ms / 1000) * rate)) }
        let minPauseSamples = toSamples(options.minPauseMs)
        let pad = toSamples(options.padMs)
        let cap = Int((options.maxSliceSeconds * rate).rounded(.down))
        // Plan the speech short enough that both pads still fit under the cap.
        let speechCap = Int(max(Double(cap) / 2, Double(cap - 2 * pad)).rounded(.down))

        let speech = loudSpeech(loudness, minPauseSamples: minPauseSamples, sampleCount: samples.count)
        let planned = mergeAndCut(
            speech, cap: speechCap, maxGap: toSamples(options.maxMergeGapMs)
        ) { next, sliceStart in
            cutPoint(
                loudness, speech: speech, next: next, sliceStart: sliceStart,
                cap: speechCap, minPauseSamples: minPauseSamples, sampleRate: sampleRate)
        }

        // A piece of a cut-up stretch of speech is never dropped, however short: it is that
        // speech's end.
        let minSpeech = toSamples(options.minSpeechMs)
        var kept: [PlannedSlice] = []
        for (i, slice) in planned.enumerated() {
            let nextStartsAtCut = i + 1 < planned.count && planned[i + 1].startsAtCut
            if slice.startsAtCut || nextStartsAtCut
                || speechWithin(speech, Span(start: slice.start, end: slice.end)) >= minSpeech {
                kept.append(slice)
            }
        }

        // Each side of a gap takes up to `pad` of it, and the rest is in no slice. A gap too
        // short for both pads is split at its middle, so at a forced cut neighbours meet there.
        var midpoints: [Int] = []
        if kept.count > 1 {
            for i in 1..<kept.count { midpoints.append(floorHalf(kept[i - 1].end + kept[i].start)) }
        }
        return kept.enumerated().map { i, slice in
            var startSample = max(slice.start - pad, i > 0 ? midpoints[i - 1] : 0)
            var endSample = min(slice.end + pad, i < midpoints.count ? midpoints[i] : samples.count)
            // The cap wins over the padding: the end pad gives way first.
            if endSample - startSample > cap {
                endSample = max(slice.end, startSample + cap)
                startSample = max(startSample, endSample - cap)
            }
            return Slice(startSample: startSample, endSample: endSample)
        }
    }

    // MARK: - Loudness

    private static let frameSeconds = 0.01
    private static let quietWindowSeconds = 0.1
    /// The noise floor is this percentile of the frame levels.
    private static let noiseFloorPercentile = 0.1
    /// With `pauseBelowSpeechDb`, the speech level is this percentile of the frame levels.
    private static let speechLevelPercentile = 0.9
    /// How far above the noise floor a frame may be and still be silent.
    private static let silenceMarginDb = 6.0
    /// A frame within this of the loudest frame, and louder than `loudFrameDb`, is always speech.
    private static let speechHeadroomDb = 10.0
    private static let loudFrameDb = -30.0
    /// Frames at or below this are digital silence and are left out of the noise floor.
    private static let digitalSilenceDb = -80.0
    /// A recording whose loudest frame is below this has nothing to decode.
    private static let silentClipDb = -60.0

    private struct Loudness {
        let frameLength: Int
        /// Mean square of each frame.
        let energy: [Double]
        /// True where the frame is silent.
        let silent: [Bool]
    }

    /// Frame levels and which frames are silent, or `nil` when the whole recording is silent.
    private static func frameLoudness(
        _ samples: UnsafeBufferPointer<Float>,
        sampleRate: Int,
        pauseBelowSpeechDb: Double?
    ) -> Loudness? {
        let frameLength = max(1, jsRound(Double(sampleRate) * frameSeconds))
        let frameCount = (samples.count + frameLength - 1) / frameLength
        var energy = [Double](repeating: 0, count: frameCount)
        var levels = [Double](repeating: 0, count: frameCount)
        var loudest = -Double.infinity
        for f in 0..<frameCount {
            let start = f * frameLength
            let end = min(samples.count, start + frameLength)
            var sum = 0.0
            for i in start..<end {
                let s = Double(samples[i])
                sum += s * s
            }
            energy[f] = sum / Double(end - start)
            // 1e-20 keeps a frame of zeros finite (-200 dB).
            levels[f] = 10 * log10(max(energy[f], 1e-20))
            loudest = max(loudest, levels[f])
        }
        guard loudest >= silentClipDb else { return nil }

        let audible = levels.filter { $0 > digitalSilenceDb }.sorted()
        let floor = audible[Int((Double(audible.count - 1) * noiseFloorPercentile).rounded(.down))]
        let aboveFloor: Double
        if let pauseBelowSpeechDb {
            let speechLevel =
                audible[Int((Double(audible.count - 1) * speechLevelPercentile).rounded(.down))]
            aboveFloor = max(floor + silenceMarginDb, speechLevel - pauseBelowSpeechDb)
        } else {
            aboveFloor = floor + silenceMarginDb
        }
        let threshold = min(aboveFloor, max(loudest - speechHeadroomDb, loudFrameDb))
        return Loudness(
            frameLength: frameLength,
            energy: energy,
            silent: levels.map { $0 < threshold }
        )
    }

    // MARK: - Speech and cuts

    private struct Span {
        var start: Int
        var end: Int
    }

    /// Runs of loud frames as samples, with pauses shorter than `minPauseSamples` bridged.
    private static func loudSpeech(_ loudness: Loudness, minPauseSamples: Int, sampleCount: Int) -> [Span] {
        let frameLength = loudness.frameLength
        let silent = loudness.silent
        var spans: [Span] = []
        var f = 0
        while f < silent.count {
            if silent[f] {
                f += 1
                continue
            }
            var end = f
            while end < silent.count && !silent[end] { end += 1 }
            let span = Span(start: f * frameLength, end: min(sampleCount, end * frameLength))
            if let last = spans.last, span.start - last.end < minPauseSamples {
                spans[spans.count - 1].end = span.end
            } else {
                spans.append(span)
            }
            f = end
        }
        return spans
    }

    /// Where a slice can end.
    private struct Cut {
        /// The end of the slice before the cut.
        let end: Int
        /// The start of the slice after it.
        let resume: Int
        /// Samples of pause the cut sits in; 0 for a forced cut.
        let length: Int
        /// The cut is inside a run of speech (forced, or at a silence in it): the slices meet there.
        let inSpeech: Bool
    }

    /// The later of two equally long pauses wins.
    private static func longer(_ a: Cut?, _ b: Cut) -> Cut {
        guard let a else { return b }
        return b.length > a.length || (b.length == a.length && b.end > a.end) ? b : a
    }

    /// The longest run of silent frames wholly inside `[from, to)`, at least `minPause` long.
    /// `from` and `to` are fractional on purpose: desktop halves the cap in floating point.
    private static func longestSilence(
        _ loudness: Loudness, from: Double, to: Double, minPauseSamples: Int
    ) -> Cut? {
        let frameLength = loudness.frameLength
        let silent = loudness.silent
        let first = Int((from / Double(frameLength)).rounded(.up))
        let last = Int((to / Double(frameLength)).rounded(.down))
        var longest: Cut?
        var f = first
        while f < last {
            if !silent[f] {
                f += 1
                continue
            }
            var end = f
            while end < last && silent[end] { end += 1 }
            let length = (end - f) * frameLength
            if length >= minPauseSamples {
                let centre = floorHalf((f + end) * frameLength)
                longest = longer(longest, Cut(end: centre, resume: centre, length: length, inSpeech: true))
            }
            f = end
        }
        return longest
    }

    /// Where to cut speech that runs past the cap from `sliceStart`, given the speech from
    /// index `next` on: between half the cap and the cap, at the longest pause, a gap between
    /// two speech runs or a silence inside one (the later of two equal ones), else at the
    /// centre of the quietest 100 ms. A gap counts where the slice before it would end.
    private static func cutPoint(
        _ loudness: Loudness,
        speech: [Span],
        next: Int,
        sliceStart: Int,
        cap: Int,
        minPauseSamples: Int,
        sampleRate: Int
    ) -> Cut {
        let from = Double(sliceStart) + Double(cap) / 2
        let to = Double(sliceStart + cap)

        var longest: Cut?
        var i = next
        while i < speech.count && Double(speech[i].start) < to {
            if let inside = longestSilence(
                loudness,
                from: max(from, Double(speech[i].start)),
                to: min(to, Double(speech[i].end)),
                minPauseSamples: minPauseSamples
            ) {
                longest = longer(longest, inside)
            }
            if i + 1 < speech.count {
                let following = speech[i + 1]
                let end = Double(speech[i].end)
                if end >= from && end <= to && following.start - speech[i].end >= minPauseSamples {
                    longest = longer(longest, Cut(
                        end: speech[i].end,
                        resume: following.start,
                        length: following.start - speech[i].end,
                        inSpeech: false))
                }
            }
            i += 1
        }
        if let longest { return longest }

        let forced = quietestPoint(loudness, sliceStart: sliceStart, from: from, to: to, sampleRate: sampleRate)
        return Cut(end: forced, resume: forced, length: 0, inSpeech: true)
    }

    /// The centre of the quietest 100 ms wholly inside `[from, to)`.
    private static func quietestPoint(
        _ loudness: Loudness, sliceStart: Int, from: Double, to: Double, sampleRate: Int
    ) -> Int {
        let frameLength = loudness.frameLength
        let energy = loudness.energy
        // Frames wholly inside the range.
        let first = Int((from / Double(frameLength)).rounded(.up))
        let last = Int((to / Double(frameLength)).rounded(.down))
        let window = max(1, jsRound((quietWindowSeconds * Double(sampleRate)) / Double(frameLength)))
        if last - first < window { return max(sliceStart + 1, last * frameLength) }
        var sum = 0.0
        for i in first..<(first + window) { sum += energy[i] }
        var quietest = sum
        var quietestStart = first
        var i = first + 1
        while i + window <= last {
            sum += energy[i + window - 1] - energy[i - 1]
            if sum < quietest {
                quietest = sum
                quietestStart = i
            }
            i += 1
        }
        return floorHalf((quietestStart * 2 + window) * frameLength)
    }

    private struct PlannedSlice {
        let start: Int
        let end: Int
        /// The slice starts where a cut inside speech ended the one before it.
        let startsAtCut: Bool
    }

    /// Speech merged into slices of at most `cap` samples. A pause longer than `maxGap` samples
    /// always ends a slice; speech that runs past the cap is cut where `cutAt` says.
    private static func mergeAndCut(
        _ speech: [Span], cap: Int, maxGap: Int, cutAt: (_ next: Int, _ sliceStart: Int) -> Cut
    ) -> [PlannedSlice] {
        var slices: [PlannedSlice] = []
        var next = 0
        var start = speech.first?.start ?? 0
        var startsAtCut = false
        while next < speech.count {
            // The speech this slice could hold: up to the first pause longer than `maxGap`.
            var last = next
            while last + 1 < speech.count && speech[last + 1].start - speech[last].end <= maxGap {
                last += 1
            }
            if speech[last].end - start <= cap {
                slices.append(PlannedSlice(start: start, end: speech[last].end, startsAtCut: startsAtCut))
                next = last + 1
                if next < speech.count {
                    start = speech[next].start
                    startsAtCut = false
                }
                continue
            }
            let cut = cutAt(next, start)
            slices.append(PlannedSlice(start: start, end: cut.end, startsAtCut: startsAtCut))
            start = cut.resume
            startsAtCut = cut.inSpeech
            while next < speech.count && speech[next].end <= start { next += 1 }
        }
        return slices
    }

    /// How many samples of `speech` (sorted, disjoint) fall inside `span`.
    private static func speechWithin(_ speech: [Span], _ span: Span) -> Int {
        var total = 0
        for region in speech {
            if region.start >= span.end { break }
            total += max(0, min(region.end, span.end) - max(region.start, span.start))
        }
        return total
    }

    // MARK: - JavaScript arithmetic

    /// `Math.round`: the nearest integer, halves toward +infinity.
    private static func jsRound(_ x: Double) -> Int {
        let r = x.rounded(.down)
        return Int(x - r >= 0.5 ? r + 1 : r)
    }

    /// `Math.floor(n / 2)` for an integer `n`.
    private static func floorHalf(_ n: Int) -> Int {
        Int((Double(n) / 2).rounded(.down))
    }
}
