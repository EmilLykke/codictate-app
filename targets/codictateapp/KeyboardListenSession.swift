import AVFoundation
import Foundation

/// Keeps the host app alive for keyboard dictation while the user works in other apps.
///
/// Pattern: continuous AVAudioEngine (UIBackgroundModes audio) + DispatchSourceTimer polling
/// App Group phase keys. Darwin notifications are optional hints only.
///
/// The keyboard extension must NEVER call extensionContext.open on the warm path.
final class KeyboardListenSession {

    static let shared = KeyboardListenSession()

    private var engine: AVAudioEngine?
    private let samplesLock = NSLock()
    private var capturedSamples: [Float] = []
    private(set) var isCapturing = false
    private var pollSource: DispatchSourceTimer?
    private var expirySource: DispatchSourceTimer?

    private init() {}

    var isRunning: Bool { engine?.isRunning == true }

    func isReady(suite: UserDefaults) -> Bool {
        guard isRunning else { return false }
        let expiry = suite.double(forKey: KeyboardDictationBridge.warmSessionExpiryKey)
        return expiry > Date().timeIntervalSince1970
            && suite.bool(forKey: KeyboardDictationBridge.listenSessionReadyKey)
    }

    // MARK: - Public

    func start(suite: UserDefaults) {
        if isRunning {
            markReady(suite: suite, ready: true)
            refreshExpiry(suite: suite)
            return
        }

        guard prepareAudioSession() else {
            NSLog("[KeyboardListen] Audio session prepare failed")
            markReady(suite: suite, ready: false)
            return
        }

        let avEngine = AVAudioEngine()
        let input = avEngine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)
        installCaptureTap(on: input, nativeFormat: nativeFormat)

        do {
            try avEngine.start()
            engine = avEngine
            isCapturing = false
            NSLog("[KeyboardListen] Engine started")
        } catch {
            NSLog("[KeyboardListen] Engine start failed: \(error.localizedDescription)")
            input.removeTap(onBus: 0)
            markReady(suite: suite, ready: false)
            return
        }

        refreshExpiry(suite: suite)
        markReady(suite: suite, ready: true)
        startPollTimer()
        scheduleExpiry(suite: suite)
    }

    /// Stops engine for Action Button recording; keeps warm expiry flags for resume.
    func pauseKeepingWarmFlags() {
        pollSource?.cancel()
        pollSource = nil
        isCapturing = false
        stopEngineHardware()
        if let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) {
            markReady(suite: suite, ready: false)
        }
        NSLog("[KeyboardListen] Paused (warm flags kept)")
    }

    func stop() {
        expirySource?.cancel()
        expirySource = nil
        pauseKeepingWarmFlags()
        if let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) {
            suite.removeObject(forKey: KeyboardDictationBridge.warmSessionActiveKey)
            suite.removeObject(forKey: KeyboardDictationBridge.warmSessionExpiryKey)
            suite.removeObject(forKey: KeyboardDictationBridge.warmSessionHeartbeatKey)
            suite.synchronize()
        }
        NSLog("[KeyboardListen] Stopped")
    }

    private func stopEngineHardware() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        samplesLock.lock()
        capturedSamples.removeAll(keepingCapacity: true)
        samplesLock.unlock()
    }

    // MARK: - Audio

    private func prepareAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
            )
            try session.setActive(true, options: [])
            return true
        } catch {
            // Session often already active from AVAudioRecorder handoff — keep it hot.
            NSLog("[KeyboardListen] setActive note: \(error.localizedDescription) (continuing if record-capable)")
            return session.category == .playAndRecord
        }
    }

    private func installCaptureTap(on input: AVAudioInputNode, nativeFormat: AVAudioFormat) {
        let targetRate: Double = 16_000
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        ) else { return }

        let converter = AVAudioConverter(from: nativeFormat, to: targetFormat)
        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, _ in
            guard let self, self.isCapturing else { return }
            let pcm: AVAudioPCMBuffer
            if let converter {
                let frameCapacity = AVAudioFrameCount(
                    Double(buffer.frameLength) * targetRate / nativeFormat.sampleRate
                )
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
                    return
                }
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                guard error == nil else { return }
                pcm = converted
            } else {
                pcm = buffer
            }
            guard let channel = pcm.floatChannelData?[0] else { return }
            let count = Int(pcm.frameLength)
            let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
            self.samplesLock.lock()
            self.capturedSamples.append(contentsOf: chunk)
            self.samplesLock.unlock()
        }
    }

    // MARK: - App Group

    private func refreshExpiry(suite: UserDefaults) {
        let seconds = configuredDurationSeconds(suite: suite)
        let expiry = Date().addingTimeInterval(seconds)
        suite.set(true, forKey: KeyboardDictationBridge.warmSessionActiveKey)
        suite.set(expiry.timeIntervalSince1970, forKey: KeyboardDictationBridge.warmSessionExpiryKey)
        suite.set(Date().timeIntervalSince1970, forKey: KeyboardDictationBridge.warmSessionHeartbeatKey)
        suite.synchronize()
    }

    private func markReady(suite: UserDefaults, ready: Bool) {
        suite.set(ready, forKey: KeyboardDictationBridge.listenSessionReadyKey)
        suite.synchronize()
        CFPreferencesAppSynchronize(KeyboardDictationBridge.suiteName as CFString)
    }

    private func configuredDurationSeconds(suite: UserDefaults) -> TimeInterval {
        let stored = suite.integer(forKey: KeyboardDictationBridge.warmSessionDurationKey)
        let seconds = stored > 0 ? TimeInterval(stored) : 60
        return min(max(seconds, 30), 1800)
    }

    // MARK: - Background poll

    private func startPollTimer() {
        pollSource?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.pollAppGroup()
        }
        timer.resume()
        pollSource = timer
    }

    private func scheduleExpiry(suite: UserDefaults) {
        expirySource?.cancel()
        let expiry = suite.double(forKey: KeyboardDictationBridge.warmSessionExpiryKey)
        let delay = max(1, expiry - Date().timeIntervalSince1970)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + delay, repeating: .never)
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                KeyboardHostRecorder.shared.endKeyboardWarmSession(userInitiated: false)
            }
        }
        timer.resume()
        expirySource = timer
    }

    private func pollAppGroup() {
        guard isRunning else { return }
        guard let suite = UserDefaults(suiteName: KeyboardDictationBridge.suiteName) else { return }
        CFPreferencesAppSynchronize(KeyboardDictationBridge.suiteName as CFString)
        suite.synchronize()

        let now = Date().timeIntervalSince1970
        let expiry = suite.double(forKey: KeyboardDictationBridge.warmSessionExpiryKey)
        guard suite.bool(forKey: KeyboardDictationBridge.warmSessionActiveKey), expiry > now else { return }

        suite.set(now, forKey: KeyboardDictationBridge.warmSessionHeartbeatKey)
        suite.synchronize()

        let phase = suite.string(forKey: KeyboardDictationBridge.phaseKey) ?? KeyboardDictationBridge.phaseIdle
        let source = suite.string(forKey: KeyboardDictationBridge.sourceKey) ?? ""
        guard source == KeyboardDictationBridge.sourceKeyboard else { return }

        if phase == KeyboardDictationBridge.phaseStart, !isCapturing {
            DispatchQueue.main.async { [weak self] in
                self?.beginCapture(suite: suite)
            }
        } else if phase == KeyboardDictationBridge.phaseStopRequested, isCapturing {
            DispatchQueue.main.async { [weak self] in
                self?.endCapture(suite: suite)
            }
        }
    }

    // MARK: - Capture lifecycle

    private func beginCapture(suite: UserDefaults) {
        guard isRunning, !isCapturing else { return }
        guard outputURL(suite: suite) != nil else {
            KeyboardHostRecorder.shared.failPublic(suite, "Recording path missing.")
            return
        }

        samplesLock.lock()
        capturedSamples.removeAll(keepingCapacity: true)
        samplesLock.unlock()
        isCapturing = true

        suite.set(KeyboardDictationBridge.phaseRecording, forKey: KeyboardDictationBridge.phaseKey)
        suite.removeObject(forKey: KeyboardDictationBridge.errorKey)
        suite.synchronize()
        KeyboardHostRecorder.reloadControlWidget()

        if #available(iOS 16.2, *) {
            _ = DictationLiveActivityManager.shared.startRecording()
        }
        KeyboardHostRecorder.shared.notifyPhase(KeyboardDictationBridge.phaseRecording)
        KeyboardHostRecorder.shared.scheduleKeyboardAutoStop()
        NSLog("[KeyboardListen] Capture started")
    }

    private func endCapture(suite: UserDefaults) {
        guard isCapturing else { return }
        isCapturing = false
        KeyboardHostRecorder.shared.cancelKeyboardAutoStop()

        guard let url = outputURL(suite: suite) else {
            KeyboardHostRecorder.shared.failPublic(suite, "Recording path missing.")
            return
        }

        samplesLock.lock()
        let samples = capturedSamples
        capturedSamples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        do {
            try writeWAV(samples: samples, to: url)
        } catch {
            KeyboardHostRecorder.shared.failPublic(suite, "Could not save audio: \(error.localizedDescription)")
            return
        }

        KeyboardHostRecorder.shared.enterProcessingPhase(suite: suite)

        KeyboardHostRecorder.shared.transcribeWav(atPath: url.path, suite: suite)
        ensureWarmListenContinues(suite: suite)
        NSLog("[KeyboardListen] Capture ended; transcribing (listen engine kept alive)")
    }

    /// After a capture segment ends, the engine must keep running for the next keyboard tap.
    private func ensureWarmListenContinues(suite: UserDefaults) {
        if isRunning {
            markReady(suite: suite, ready: true)
            refreshExpiry(suite: suite)
            scheduleExpiry(suite: suite)
            return
        }
        NSLog("[KeyboardListen] Engine stopped after capture; restarting warm listen")
        start(suite: suite)
    }

    private func outputURL(suite: UserDefaults) -> URL? {
        guard let name = suite.string(forKey: KeyboardDictationBridge.wavFileKey), !name.isEmpty else {
            return nil
        }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: KeyboardDictationBridge.suiteName
        ) else { return nil }
        let dir = container.appendingPathComponent("KeyboardRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private func writeWAV(samples: [Float], to url: URL) throws {
        let sampleRate: UInt32 = 16_000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * Int(bitsPerSample / 8))
        let chunkSize = 36 + dataSize

        func appendUInt32LE(_ value: UInt32, to data: inout Data) {
            var le = value.littleEndian
            data.append(Data(bytes: &le, count: 4))
        }
        func appendUInt16LE(_ value: UInt16, to data: inout Data) {
            var le = value.littleEndian
            data.append(Data(bytes: &le, count: 2))
        }

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        appendUInt32LE(chunkSize, to: &header)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        appendUInt32LE(16, to: &header)
        appendUInt16LE(1, to: &header)
        appendUInt16LE(channels, to: &header)
        appendUInt32LE(sampleRate, to: &header)
        appendUInt32LE(byteRate, to: &header)
        appendUInt16LE(blockAlign, to: &header)
        appendUInt16LE(bitsPerSample, to: &header)
        header.append(contentsOf: "data".utf8)
        appendUInt32LE(dataSize, to: &header)

        var pcm = Data(capacity: Int(dataSize))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped * 32767)
            pcm.append(Data(bytes: &value, count: 2))
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try (header + pcm).write(to: url)
    }
}
