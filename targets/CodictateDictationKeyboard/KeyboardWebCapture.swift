import AVFAudio
import Foundation
import UIKit
import WebKit

// Adapted from Hex (anomalyco/hex, MIT, `KeyboardWebCapture.swift`) and
// stephancill/ios-keyboard-dictation (MIT, `WebAudioCapture.swift`). See NOTICE.

/// 16-bit mono PCM chunks from the capture page, written as a WAV file.
final class KeyboardPCMFile {
    let url: URL
    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private(set) var frames: AVAudioFramePosition = 0

    init(url: URL, sampleRate: Double) throws {
        self.url = url
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true
        ) else {
            throw CocoaError(.featureUnsupported)
        }
        self.format = format
        file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true
        )
    }

    func append(_ data: Data) {
        let count = data.count / 2
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
        else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, let target = buffer.int16ChannelData?[0] else { return }
            memcpy(target, base, count * 2)
        }
        try? file?.write(from: buffer)
        frames += AVAudioFramePosition(count)
    }

    var seconds: Double { Double(frames) / format.sampleRate }

    /// Closing releases the `AVAudioFile`, which finishes the WAV header.
    func close() {
        file = nil
    }
}

/// Records the microphone from inside the keyboard through `getUserMedia` in a hidden
/// `WKWebView`. iOS refuses to record from a keyboard extension's own process, but WebKit
/// captures in its own process under Codictate's microphone permission, so the restriction
/// does not apply. The page loads when the keyboard appears and opens the microphone only on
/// `start()`, so no orange dot shows until the user dictates.
///
/// While capturing, native pings the page every second and the page stops the microphone
/// when pings stop for 3 s: a suspended or killed keyboard can never leave the microphone
/// open in WebKit's process.
@MainActor
final class KeyboardWebCapture: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    enum Event {
        case started(sampleRate: Double)
        /// One processor buffer (4,096 samples) and its RMS level, 0...1.
        case samples(Data, rms: Float)
        /// The capture ended, with the audio the processor still held delivered first.
        /// `reason` is nil for a `stop()`, else why the page ended it by itself (its track
        /// ended, its context closed, or native's heartbeat stopped).
        case stopped(reason: String?)
        /// `getUserMedia` or the audio context failed before any audio.
        case failed(String)
        case processTerminated
    }

    var onEvent: ((Event) -> Void)?
    private let webView: WKWebView
    private var isLoaded = false
    private var startWhenLoaded = false
    private var heartbeat: Timer?

    init(host: UIView) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakMessageHandler(self), name: "codictate")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        // WebKit captures only for a web view in the window; nearly transparent, not hidden.
        webView.alpha = 0.02
        host.addSubview(webView)
        host.sendSubviewToBack(webView)
        load()
    }

    func start() {
        startHeartbeat()
        guard isLoaded else {
            startWhenLoaded = true
            return
        }
        webView.evaluateJavaScript("kbStart(); 0")
    }

    /// Waits in the page for the processor's last buffer (at most 250 ms), then releases the
    /// microphone and posts `.stopped(reason: nil)`.
    func stop() {
        startWhenLoaded = false
        webView.evaluateJavaScript("kbStop(); 0")
    }

    /// Takes the web view out of the keyboard, after its content process ended, so a new one
    /// can take its place.
    func tearDown() {
        onEvent = nil
        stopHeartbeat()
        startWhenLoaded = false
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "codictate")
        webView.removeFromSuperview()
    }

    private func load() {
        // An https base URL gives the page a secure context, which getUserMedia requires.
        webView.loadHTMLString(Self.page, baseURL: URL(string: "https://keyboard.codictate.invalid/"))
    }

    private func startHeartbeat() {
        stopHeartbeat()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.webView.evaluateJavaScript("kbPing(); 0") }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
    }

    // MARK: WKNavigationDelegate / WKUIDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        if startWhenLoaded {
            startWhenLoaded = false
            webView.evaluateJavaScript("kbStart(); 0")
        }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decisionHandler(type == .microphone ? .grant : .deny)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoaded = false
        stopHeartbeat()
        onEvent?(.processTerminated)
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "started":
            onEvent?(.started(sampleRate: (body["rate"] as? Double) ?? 48_000))
        case "pcm":
            guard let encoded = body["data"] as? String, let data = Data(base64Encoded: encoded) else { return }
            onEvent?(.samples(data, rms: Float((body["rms"] as? Double) ?? 0)))
        case "stopped":
            stopHeartbeat()
            let reason = (body["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            onEvent?(.stopped(reason: reason))
        case "error":
            stopHeartbeat()
            onEvent?(.failed((body["message"] as? String) ?? "unknown"))
        default:
            break
        }
    }

    /// The processor hands audio over 4,096 samples at a time (85 ms at 48 kHz), so at a stop
    /// it still holds the end of what was said: `kbStop` waits for that buffer before it lets
    /// the microphone go. Every 250 ms the page resumes a context another sound interrupted,
    /// ends a capture whose track ended, and ends one native stopped pinging.
    private static let page = """
    <!doctype html><meta charset="utf-8"><script>
    let ctx, stream, source, node, running = false, generation = 0, revive = null;
    let flushed = null, stopping = null, lastPing = 0;
    const post = (m) => webkit.messageHandlers.codictate.postMessage(m);
    const release = (s, c) => {
      if (s) s.getTracks().forEach((t) => t.stop());
      if (c) c.close().catch(() => {});
    };
    function kbPing() { lastPing = Date.now(); }
    function check() {
      if (!running || !ctx) return;
      if (Date.now() - lastPing > 3000) return kbStop("heartbeat");
      if (ctx.state === "closed") return kbStop("context-closed");
      if (ctx.state !== "running") ctx.resume().catch(() => {});
      const t = stream && stream.getAudioTracks()[0];
      if (!t || t.readyState === "ended") return kbStop("track-ended");
    }
    async function kbStart() {
      while (stopping) await stopping;
      if (running) return;
      running = true;
      lastPing = Date.now();
      // A kbStop while this start waits makes it stale: it releases what it opened.
      const start = ++generation;
      const stale = () => start !== generation;
      let s = null, c = null;
      try {
        s = await navigator.mediaDevices.getUserMedia({
          audio: { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false },
        });
        if (stale()) return release(s);
        c = new AudioContext();
        await c.resume();
        if (stale()) return release(s, c);
        stream = s;
        ctx = c;
        source = ctx.createMediaStreamSource(stream);
        node = ctx.createScriptProcessor(4096, 1, 1);
        node.onaudioprocess = (event) => {
          if (!running && !flushed) return;
          const input = event.inputBuffer.getChannelData(0);
          const pcm = new Int16Array(input.length);
          let squares = 0;
          for (let i = 0; i < input.length; i++) {
            const v = Math.max(-1, Math.min(1, input[i]));
            squares += v * v;
            pcm[i] = v < 0 ? v * 0x8000 : v * 0x7fff;
          }
          const bytes = new Uint8Array(pcm.buffer);
          let binary = "";
          for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
          post({ type: "pcm", data: btoa(binary), rms: Math.sqrt(squares / Math.max(1, input.length)) });
          if (flushed) flushed();
        };
        source.connect(node);
        node.connect(ctx.destination);
        revive = setInterval(check, 250);
        post({ type: "started", rate: ctx.sampleRate });
      } catch (error) {
        if (stale()) return release(s, c);
        running = false;
        release(s, c);
        post({ type: "error", message: (error && (error.name + ": " + error.message)) || String(error) });
      }
    }
    async function kbStop(reason) {
      generation++;
      const wasRunning = running;
      running = false;
      if (revive) { clearInterval(revive); revive = null; }
      if (flushed) flushed();
      let done = () => {};
      if (wasRunning) stopping = new Promise((resolve) => (done = resolve));
      if (wasRunning && node && ctx && ctx.state === "running") {
        await new Promise((resolve) => {
          const timer = setTimeout(() => flushed && flushed(), 250);
          flushed = () => { clearTimeout(timer); flushed = null; resolve(); };
        });
      }
      try { node && node.disconnect(); source && source.disconnect(); } catch (e) {}
      if (stream) stream.getTracks().forEach((t) => t.stop());
      if (ctx) { try { await ctx.close(); } catch (e) {} }
      ctx = stream = source = node = null;
      if (wasRunning) post({ type: "stopped", reason: reason || "" });
      if (wasRunning) stopping = null;
      done();
    }
    </script>
    """
}

/// Breaks the retain cycle between `WKUserContentController` and its handler.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
