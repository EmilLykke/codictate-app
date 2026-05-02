import Foundation

/// Mirrors `ModelManager` from the main app target.
/// Duplicated intentionally — the Expo module pod cannot import main-app symbols.
/// Keep variant filenames, URLs, and minBytes in sync with `ModelManager.swift`.
final class AppGroupModelManager {

    enum Variant: String {
        case base
        case small

        var filename: String {
            switch self {
            case .base: return "ggml-base.bin"
            case .small: return "ggml-small-q5_1.bin"
            }
        }

        var url: URL {
            switch self {
            case .base:
                return URL(string:
                    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
                )!
            case .small:
                return URL(string:
                    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin"
                )!
            }
        }

        var minBytes: Int64 {
            switch self {
            case .base: return 130 * 1024 * 1024
            case .small: return 160 * 1024 * 1024
            }
        }
    }

    static let shared = AppGroupModelManager()

    private let groupID = "group.app.codictate"

    private init() {}

    var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    func modelFilePath(for variant: Variant) -> String? {
        containerURL?.appendingPathComponent(variant.filename).path
    }

    func modelIsReady(for variant: Variant) -> Bool {
        guard let path = modelFilePath(for: variant) else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int64) ?? 0
        return size >= variant.minBytes
    }

    func ensureModel(
        variant: Variant,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
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
                // File move must happen synchronously before this callback returns —
                // iOS deletes the temp file the moment didFinishDownloadingTo exits.
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
            // Move the file synchronously here — iOS deletes it once this method returns.
            onDone(location, nil)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { onDone(nil, error) }
        }
    }
}
