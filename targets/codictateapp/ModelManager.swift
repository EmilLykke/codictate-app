import Foundation

/// Downloads and locates ASR models.
///
/// Two variants:
///   - `parakeet` - FluidAudio Parakeet TDT v3 CoreML (stored in Documents via ParakeetModelManager)
///   - `base`     - Whisper base-q5_1 GGML (~57 MB, stored in App Group)
final class ModelManager {

    enum Variant: String {
        case parakeet = "parakeet"
        case base = "base"

        var filename: String {
            switch self {
            case .parakeet: return ""
            case .base: return "ggml-base-q5_1.bin"
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
            }
        }

        var minBytes: Int64 {
            switch self {
            case .parakeet: return 0
            case .base: return 50 * 1024 * 1024
            }
        }
    }

    static let shared = ModelManager()

    private let groupID = "group.app.codictate"

    private init() {}

    // MARK: - Public API

    /// Default model used when only the legacy `modelFilePath` property is read.
    /// Host / intent paths use `transcriptionVariant(...)` and the App Group preference.
    var modelFilePath: String? {
        modelFilePath(for: .base)
    }

    var modelIsReady: Bool {
        modelIsReady(for: .base)
    }

    func modelFilePath(for variant: Variant) -> String? {
        switch variant {
        case .parakeet:
            return ParakeetModelManager.shared.modelDirectory.path
        case .base:
            return containerURL?.appendingPathComponent(variant.filename).path
        }
    }

    func modelIsReady(for variant: Variant) -> Bool {
        switch variant {
        case .parakeet:
            return ParakeetModelManager.shared.isReady
        case .base:
            guard let path = containerURL?.appendingPathComponent(variant.filename).path else {
                return false
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? Int64) ?? 0
            return size >= variant.minBytes
        }
    }

    /// Default ensure (Base) — kept for backward compatibility with keyboard flow.
    func ensureModel(
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        ensureModel(variant: .base, onProgress: onProgress, onComplete: onComplete)
    }

    /// Pick a specific variant. Skips the network if the file already exists at >= minBytes.
    /// For `parakeet`, readiness is checked via ParakeetModelManager (CoreML directory layout).
    func ensureModel(
        variant: Variant,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        if variant == .parakeet {
            if ParakeetModelManager.shared.isReady {
                onComplete(.success(ParakeetModelManager.shared.modelDirectory.path))
            } else {
                onComplete(.failure(NSError(
                    domain: "ModelManager", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "Parakeet model not downloaded yet. Open Codictate to download."]
                )))
            }
            return
        }

        guard let container = containerURL else {
            onComplete(.failure(NSError(
                domain: "ModelManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable."]
            )))
            return
        }

        let destPath = container.appendingPathComponent(variant.filename)

        if modelIsReady(for: variant), let path = modelFilePath(for: variant) {
            onComplete(.success(path))
            return
        }

        // Stale / partial file: clear before downloading.
        if FileManager.default.fileExists(atPath: destPath.path) {
            try? FileManager.default.removeItem(at: destPath)
        }

        onProgress(0)
        let delegate = DownloadDelegate(
            onProgress: onProgress,
            onDone: { tempURL, error in
                if let error { DispatchQueue.main.async { onComplete(.failure(error)) }; return }
                guard let tempURL else {
                    DispatchQueue.main.async {
                        onComplete(.failure(NSError(
                            domain: "ModelManager", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Download produced no file."]
                        )))
                    }
                    return
                }
                do {
                    if !FileManager.default.fileExists(atPath: container.path) {
                        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destPath)
                    DispatchQueue.main.async { onComplete(.success(destPath.path)) }
                } catch {
                    DispatchQueue.main.async { onComplete(.failure(error)) }
                }
            }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let task = session.downloadTask(with: variant.url)
        task.resume()
        objc_setAssociatedObject(session, &ModelManager.delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
    }

    private static var delegateKey: UInt8 = 0

    // MARK: - Private

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
            onDone(location, nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { onDone(nil, error) }
        }
    }

    private var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        )
    }
}
