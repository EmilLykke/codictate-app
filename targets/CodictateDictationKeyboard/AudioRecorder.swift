import AVFoundation
import CoreAudio

/// iOS keyboard-extension capture via `AVAudioEngine`.
/// Uses `AVAudioFile(forWriting:settings:)` with **hand-built** Linear PCM settings derived from the
/// hardware `AVAudioFormat` (raw `format.settings` is unreliable on device). Tap uses the same `hwFormat`.
final class AudioRecorder: NSObject {

    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var recordingURL: URL?
    private var didInstallTap = false

    var isRecording: Bool { engine?.isRunning ?? false }

    private static let appGroupID = "group.com.emillo2003.codictate-app"

    func start() throws -> URL {
        stop()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            // Minimal iOS session: avoid Bluetooth / preferred rate tweaks that can desync hardware vs file.
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: [])
        } catch {
            throw RecorderError.sessionFailed(Self.describeAudioError(error))
        }

        let url = try Self.makeRecordingOutputURL()

        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        newEngine.prepare()

        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw RecorderError.couldNotStart(
                "Microphone is not available. On iOS: enable Full Access for the keyboard and allow Microphone for this keyboard in Settings › Privacy & Security › Microphone."
            )
        }

        let settings = Self.linearPCMWriteSettings(forHardwareFormat: hwFormat)
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw RecorderError.sessionFailed(Self.describeAudioError(error))
        }

        audioFile = file
        input.removeTap(onBus: 0)
        // Tap format must match hardware (non-nil must equal input format on iOS).
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self, let out = self.audioFile else { return }
            do {
                try out.write(from: buffer)
            } catch {
                NSLog("[AudioRecorder] write failed: \(Self.describeAudioError(error))")
            }
        }
        didInstallTap = true

        do {
            try newEngine.start()
        } catch {
            tearDownEngine(newEngine)
            audioFile = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw RecorderError.sessionFailed(Self.describeAudioError(error))
        }

        engine = newEngine
        recordingURL = url
        return url
    }

    /// Builds a settings dict suitable for `AVAudioFile(forWriting:settings:)` matching `hwFormat`.
    private static func linearPCMWriteSettings(forHardwareFormat format: AVAudioFormat) -> [String: Any] {
        let rate = format.sampleRate
        let ch = Int(format.channelCount)
        let nonInterleaved = !format.isInterleaved

        func pcmDict(bitDepth: Int, isFloat: Bool) -> [String: Any] {
            [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: ch,
                AVLinearPCMBitDepthKey: bitDepth,
                AVLinearPCMIsFloatKey: isFloat,
                AVLinearPCMIsBigEndianKey: false,
                "AVLinearPCMIsNonInterleaved": nonInterleaved,
            ]
        }

        switch format.commonFormat {
        case .pcmFormatFloat32:
            return pcmDict(bitDepth: 32, isFloat: true)
        case .pcmFormatFloat64:
            return pcmDict(bitDepth: 64, isFloat: true)
        case .pcmFormatInt16:
            return pcmDict(bitDepth: 16, isFloat: false)
        case .pcmFormatInt32:
            return pcmDict(bitDepth: 32, isFloat: false)
        default:
            let asbd = format.streamDescription.pointee
            let flags = asbd.mFormatFlags
            let isFloat = (flags & UInt32(kAudioFormatFlagIsFloat)) != 0
            let isBigEndian = (flags & UInt32(kAudioFormatFlagIsBigEndian)) != 0
            let isNonInterleaved = (flags & UInt32(kAudioFormatFlagIsNonInterleaved)) != 0
            return [
                AVFormatIDKey: Int(asbd.mFormatID),
                AVSampleRateKey: asbd.mSampleRate,
                AVNumberOfChannelsKey: Int(asbd.mChannelsPerFrame),
                AVLinearPCMBitDepthKey: Int(asbd.mBitsPerChannel),
                AVLinearPCMIsFloatKey: isFloat,
                AVLinearPCMIsBigEndianKey: isBigEndian,
                "AVLinearPCMIsNonInterleaved": isNonInterleaved,
            ]
        }
    }

    private static func describeAudioError(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSOSStatusErrorDomain || ns.domain == "com.apple.coreaudio.avfaudio" {
            let suffix = ns.code == 2003
                ? " (often invalid audio format or session; try again after closing other mic apps)"
                : ""
            return "\(error.localizedDescription)\(suffix)"
        }
        return error.localizedDescription
    }

    private func tearDownEngine(_ e: AVAudioEngine) {
        if didInstallTap {
            e.inputNode.removeTap(onBus: 0)
            didInstallTap = false
        }
        if e.isRunning {
            e.stop()
        }
    }

    private static func makeRecordingOutputURL() throws -> URL {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) {
            let dir = container.appendingPathComponent("KeyboardRecordings", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("dictation_\(UUID().uuidString).caf")
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation_\(UUID().uuidString).caf")
    }

    @discardableResult
    func stop() -> URL? {
        let url = recordingURL
        if let e = engine {
            tearDownEngine(e)
        }
        engine = nil
        audioFile = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return url
    }

    func cleanup() {
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
            recordingURL = nil
        }
    }

    enum RecorderError: LocalizedError {
        case couldNotStart(String)
        case sessionFailed(String)

        var errorDescription: String? {
            switch self {
            case .couldNotStart(let detail):
                return detail
            case .sessionFailed(let detail):
                return detail
            }
        }
    }
}
