import Foundation

/// Mirrors `ModelManager` from the main app target.
/// Duplicated intentionally -- the Expo module pod cannot import main-app symbols.
/// Keep variant filenames, URLs, and minBytes in sync with `ModelManager.swift`.
final class AppGroupModelManager {

    enum Variant: String {
        case parakeet = "parakeet"
        case base = "base"
        case baseEn = "base_en"

        var isWhisper: Bool {
            switch self {
            case .parakeet: return false
            case .base, .baseEn: return true
            }
        }

        var filename: String {
            switch self {
            case .parakeet: return ""
            case .base: return "ggml-base-q5_1.bin"
            case .baseEn: return "ggml-base.en-q5_1.bin"
            }
        }

        var url: URL {
            switch self {
            case .parakeet:
                return URL(string:
                    "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml"
                )!
            case .base:
                return URL(string:
                    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin"
                )!
            case .baseEn:
                return URL(string:
                    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en-q5_1.bin"
                )!
            }
        }

        var minBytes: Int64 {
            switch self {
            case .parakeet: return 0
            case .base, .baseEn: return 50 * 1024 * 1024
            }
        }
    }

    static let shared = AppGroupModelManager()

    private let groupID = "group.app.codictate"

    private typealias ParakeetWaiter = (
        onProgress: (Double) -> Void,
        onComplete: (Result<String, Error>) -> Void
    )

    private var parakeetWaiters: [ParakeetWaiter] = []
    private var parakeetDownloadInFlight = false
    private var parakeetProgressObserver: NSObjectProtocol?
    private var parakeetReadyObserver: NSObjectProtocol?
    private var parakeetFailedObserver: NSObjectProtocol?

    private init() {}

    var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    // MARK: - Parakeet readiness (managed by ParakeetModelManager in main app target)

    private static let parakeetReadyKey = "parakeetModelReady"

    var parakeetModelDirectory: URL? {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return docs?.appendingPathComponent("parakeet-tdt-v3")
    }

    /// Checks the persistent flag set by ParakeetModelManager after a successful download.
    /// FluidAudio manages its own CoreML cache, so we rely on this flag
    /// rather than checking for specific files on disk.
    func parakeetModelIsReady() -> Bool {
        guard let suite = UserDefaults(suiteName: groupID) else { return false }
        return suite.bool(forKey: Self.parakeetReadyKey)
    }

    func resetParakeetDownloadState() {
        parakeetDownloadInFlight = false
        parakeetWaiters = []
    }

    func modelFilePath(for variant: Variant) -> String? {
        switch variant {
        case .parakeet:
            return parakeetModelDirectory?.path
        case .base, .baseEn:
            return containerURL?.appendingPathComponent(variant.filename).path
        }
    }

    func modelIsReady(for variant: Variant) -> Bool {
        switch variant {
        case .parakeet:
            return parakeetModelIsReady()
        case .base, .baseEn:
            guard let path = modelFilePath(for: variant) else { return false }
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? Int64) ?? 0
            return size >= variant.minBytes
        }
    }

    func ensureModel(
        variant: Variant,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        if variant == .parakeet {
            if parakeetModelIsReady(), let path = parakeetModelDirectory?.path {
                onComplete(.success(path))
                return
            }

            parakeetWaiters.append((onProgress, onComplete))
            installParakeetObserversIfNeeded()

            guard !parakeetDownloadInFlight else { return }
            parakeetDownloadInFlight = true
            onProgress(0)

            NotificationCenter.default.post(
                name: Notification.Name("codictate.parakeet.ensureModel"),
                object: nil
            )
            return
        }

        guard let container = containerURL else {
            onComplete(.failure(NSError(
                domain: "AppGroupModelManager", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable."]
            )))
            return
        }

        let destURL = container.appendingPathComponent(variant.filename)

        if modelIsReady(for: variant), let path = modelFilePath(for: variant) {
            onComplete(.success(path))
            return
        }

        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }

        onProgress(0)
        let delegate = DownloadDelegate(
            onProgress: onProgress,
            onDone: { tempURL, error in
                if let error { DispatchQueue.main.async { onComplete(.failure(error)) }; return }
                guard let tempURL else {
                    DispatchQueue.main.async {
                        onComplete(.failure(NSError(
                            domain: "AppGroupModelManager", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Download produced no file."]
                        )))
                    }
                    return
                }
                do {
                    if !FileManager.default.fileExists(atPath: container.path) {
                        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destURL)
                    DispatchQueue.main.async { onComplete(.success(destURL.path)) }
                } catch {
                    DispatchQueue.main.async { onComplete(.failure(error)) }
                }
            }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: variant.url)
        task.resume()
        objc_setAssociatedObject(session, &AppGroupModelManager.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
    }

    private static var delegateKey: UInt8 = 0

    private func installParakeetObserversIfNeeded() {
        guard parakeetProgressObserver == nil else { return }

        parakeetProgressObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("codictate.parakeet.progress"),
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let p = (note.userInfo?["progress"] as? Double) ?? 0
            for waiter in self.parakeetWaiters {
                waiter.onProgress(p)
            }
        }

        parakeetReadyObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("codictate.parakeet.ready"),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let path = self.parakeetModelDirectory?.path ?? ""
            self.finishParakeetDownload(.success(path))
        }

        parakeetFailedObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("codictate.parakeet.failed"),
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let msg = (note.userInfo?["error"] as? String) ?? "Parakeet model download failed."
            self.finishParakeetDownload(.failure(NSError(
                domain: "AppGroupModelManager", code: 3,
                userInfo: [NSLocalizedDescriptionKey: msg]
            )))
        }
    }

    private func finishParakeetDownload(_ result: Result<String, Error>) {
        parakeetDownloadInFlight = false
        let waiters = parakeetWaiters
        parakeetWaiters = []
        for waiter in waiters {
            switch result {
            case .success(let path):
                waiter.onComplete(.success(path))
            case .failure(let error):
                waiter.onComplete(.failure(error))
            }
        }
    }

    private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        let onProgress: (Double) -> Void
        let onDone: (URL?, Error?) -> Void

        init(onProgress: @escaping (Double) -> Void, onDone: @escaping (URL?, Error?) -> Void) {
            self.onProgress = onProgress
            self.onDone = onDone
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData _: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite expected: Int64) {
            guard expected > 0 else { return }
            DispatchQueue.main.async { self.onProgress(Double(totalBytesWritten) / Double(expected)) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // Move the file synchronously here; iOS deletes it once this method returns.
            onDone(location, nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { onDone(nil, error) }
        }
    }
}
